package main

import (
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type callRecord struct {
	ID        string     `json:"id"`
	Index     int        `json:"index"`
	Direction string     `json:"direction"`
	State     string     `json:"state"`
	Number    string     `json:"number,omitempty"`
	StartedAt time.Time  `json:"started_at"`
	UpdatedAt time.Time  `json:"updated_at"`
	EndedAt   *time.Time `json:"ended_at,omitempty"`
	Missed    bool       `json:"missed"`
}

type callTracker struct {
	Active        *callRecord
	History       []callRecord
	LastPollError string
	Configured    bool
	LastAnswerAt  time.Time
}

type parsedCall struct {
	Index     int
	Direction string
	State     string
	Number    string
}

const callEventWaitTimeout = 20 * time.Second

type callEventResponse struct {
	Revision  uint64      `json:"revision"`
	Active    *callRecord `json:"active"`
	Heartbeat bool        `json:"heartbeat"`
}

var clccPattern = regexp.MustCompile(`\+CLCC:\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*"([^"]*)")?`)

func parseCLCC(response string) []parsedCall {
	matches := clccPattern.FindAllStringSubmatch(response, -1)
	calls := make([]parsedCall, 0, len(matches))
	for _, match := range matches {
		// CLCC mode 0 才是语音，数据会话不能伪装成电话。
		if match[4] != "0" {
			continue
		}
		index, err := strconv.Atoi(match[1])
		if err != nil {
			continue
		}
		direction := "outgoing"
		if match[2] == "1" {
			direction = "incoming"
		}
		calls = append(calls, parsedCall{Index: index, Direction: direction, State: mapCallState(match[3]), Number: strings.TrimSpace(match[6])})
	}
	return calls
}

func mapCallState(raw string) string {
	switch raw {
	case "0":
		return "active"
	case "1":
		return "held"
	case "2":
		return "dialing"
	case "3":
		return "alerting"
	case "4":
		return "incoming"
	case "5":
		return "waiting"
	default:
		return "unknown"
	}
}

func callStatePriority(state string) int {
	switch state {
	case "incoming", "waiting":
		return 5
	case "active":
		return 4
	case "alerting":
		return 3
	case "dialing":
		return 2
	case "held":
		return 1
	default:
		return 0
	}
}

func (a *agent) refreshCalls() {
	a.mu.Lock()
	configured := a.calls.Configured
	a.mu.Unlock()
	if !configured {
		if _, err := a.at.command("AT+CLIP=1", 3*time.Second); err != nil {
			a.setCallError(err)
			return
		}
		a.mu.Lock()
		a.calls.Configured = true
		a.mu.Unlock()
	}

	response, err := a.at.command("AT+CLCC", 3*time.Second)
	if err != nil {
		a.setCallError(err)
		return
	}
	a.applyCallPoll(parseCLCC(response), time.Now())
	a.setCallError(nil)
}

func (a *agent) setCallError(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err == nil {
		a.calls.LastPollError = ""
		return
	}
	a.calls.LastPollError = err.Error()
}

func (a *agent) applyCallPoll(calls []parsedCall, now time.Time) {
	var selected *parsedCall
	for index := range calls {
		candidate := &calls[index]
		if selected == nil || callStatePriority(candidate.State) > callStatePriority(selected.State) {
			selected = candidate
		}
	}

	a.mu.Lock()
	if selected == nil {
		if a.calls.Active == nil {
			a.mu.Unlock()
			return
		}
		ended := now
		endedState := a.calls.Active.State
		a.calls.Active.EndedAt = &ended
		a.calls.Active.UpdatedAt = now
		a.calls.Active.Missed = a.calls.Active.Direction == "incoming" &&
			(a.calls.Active.State == "incoming" || a.calls.Active.State == "waiting")
		a.calls.History = append([]callRecord{*a.calls.Active}, a.calls.History...)
		a.calls.Active = nil
		a.muted = false
		a.isRecording = false
		a.mu.Unlock()
		a.publishCallEvent()
		appendVoiceDiagnosticEvent("通话状态变更: " + endedState + " -> ended")
		// 等基带彻底结束通话后再回滚 UAC 路由，避免尾音被硬切断。
		go func() {
			time.Sleep(1500 * time.Millisecond)
			a.mu.RLock()
			stillIdle := a.calls.Active == nil
			a.mu.RUnlock()
			if stillIdle {
				a.stopVoiceRoute()
			}
		}()
		return
	}

	if a.calls.Active == nil || a.calls.Active.Index != selected.Index || a.calls.Active.Direction != selected.Direction {
		a.calls.Active = &callRecord{
			ID: fmt.Sprintf("%d-%d", now.UnixMilli(), selected.Index), Index: selected.Index,
			Direction: selected.Direction, State: selected.State, Number: selected.Number,
			StartedAt: now, UpdatedAt: now,
		}
		a.mu.Unlock()
		a.publishCallEvent()
		appendVoiceDiagnosticEvent("通话状态变更: idle -> " + selected.State)
		if selected.State == "active" {
			go a.ensureVoiceRoute()
		} else {
			// 在响铃或拨号阶段提前完成驱动加载和 ACDB 校准；接通后只需建立
			// D4/D5/D6 路由，避免把模块冷启动时间暴露给用户。
			go a.ensureVoiceRuntimeWarm()
		}
		return
	}
	previousState := a.calls.Active.State
	previousNumber := a.calls.Active.Number
	a.calls.Active.State = selected.State
	a.calls.Active.UpdatedAt = now
	if selected.Number != "" {
		a.calls.Active.Number = selected.Number
	}
	a.mu.Unlock()
	if selected.State != previousState || (selected.Number != "" && selected.Number != previousNumber) {
		a.publishCallEvent()
	}
	if selected.State != previousState {
		appendVoiceDiagnosticEvent("通话状态变更: " + previousState + " -> " + selected.State)
	}
	if selected.State == "active" && previousState != "active" {
		go a.ensureVoiceRoute()
	}
}

// publishCallEvent 用关闭旧 channel 的方式同时唤醒所有等待者，不会因手机断线阻塞 AT 轮询。
func (a *agent) publishCallEvent() {
	a.callEventMu.Lock()
	defer a.callEventMu.Unlock()
	if a.callEventChanged == nil {
		a.callEventChanged = make(chan struct{})
	}
	previous := a.callEventChanged
	a.callEventRevision++
	a.callEventChanged = make(chan struct{})
	close(previous)
}

// subscribeCallEvents 在同一个锁内读取修订号和 channel，避免状态变化发生在二者之间而丢失唤醒。
func (a *agent) subscribeCallEvents(after uint64) (uint64, <-chan struct{}, bool) {
	a.callEventMu.Lock()
	defer a.callEventMu.Unlock()
	if a.callEventChanged == nil {
		a.callEventChanged = make(chan struct{})
	}
	return a.callEventRevision, a.callEventChanged, after != a.callEventRevision
}

// callEventSnapshot 保证修订号与通话快照一致，防止并发更新导致 App 跳过一次来电。
func (a *agent) callEventSnapshot(heartbeat bool) callEventResponse {
	a.callEventMu.Lock()
	defer a.callEventMu.Unlock()
	a.mu.RLock()
	defer a.mu.RUnlock()
	var active *callRecord
	if a.calls.Active != nil {
		copy := *a.calls.Active
		active = &copy
	}
	return callEventResponse{
		Revision: a.callEventRevision, Active: active, Heartbeat: heartbeat,
	}
}

// callEvents 是 USB 私网内的阻塞式事件桥：有变化立即返回，无变化则定期心跳断开供 App 续接。
func (a *agent) callEvents(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	afterText, hasAfter := request.URL.Query()["after"]
	var after uint64
	if hasAfter {
		if len(afterText) != 1 {
			writeError(response, http.StatusBadRequest, "after 参数无效")
			return
		}
		parsed, err := strconv.ParseUint(afterText[0], 10, 64)
		if err != nil {
			writeError(response, http.StatusBadRequest, "after 参数无效")
			return
		}
		after = parsed
	}

	_, changed, immediate := a.subscribeCallEvents(after)
	heartbeat := false
	// 首次请求不携带 after，必须立即返回当前快照完成握手。
	if hasAfter && !immediate {
		timer := time.NewTimer(callEventWaitTimeout)
		defer timer.Stop()
		select {
		case <-changed:
		case <-timer.C:
			heartbeat = true
		case <-request.Context().Done():
			return
		}
	}

	writeJSON(response, http.StatusOK, a.callEventSnapshot(heartbeat))
}

func (a *agent) callStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	var active *callRecord
	if a.calls.Active != nil {
		copy := *a.calls.Active
		active = &copy
	}
	history := append([]callRecord(nil), a.calls.History...)
	lastError := a.calls.LastPollError
	a.mu.RUnlock()
	if history == nil {
		history = []callRecord{}
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"active": active, "history": history, "polling": true, "event_driven": true,
		"poll_interval_s": 1, "last_poll_error": lastError,
	})
}

// callHistoryAck 仅删除已被手机原子写入成功的通话记录，未确认记录继续留在交付队列。
func (a *agent) callHistoryAck(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		IDs []string `json:"ids"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	acknowledged := make(map[string]bool, len(body.IDs))
	for _, id := range body.IDs {
		if id != "" {
			acknowledged[id] = true
		}
	}

	a.mu.Lock()
	remaining := a.calls.History[:0]
	removed := 0
	for _, record := range a.calls.History {
		if acknowledged[record.ID] {
			removed++
			continue
		}
		remaining = append(remaining, record)
	}
	a.calls.History = remaining
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]int{"acknowledged": removed})
}

func (a *agent) dial(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Number string `json:"number"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	number := normalizeDialNumber(body.Number)
	if number == "" || len(number) > 82 {
		writeError(response, http.StatusBadRequest, "号码为空、过长或包含非法字符")
		return
	}
	result, err := a.at.command("ATD"+number+";", 8*time.Second)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{"dialing": true, "number": number, "response": result})
}

func normalizeDialNumber(raw string) string {
	var result strings.Builder
	for _, character := range strings.TrimSpace(raw) {
		switch {
		case character >= '0' && character <= '9', character == '+', character == '*', character == '#':
			result.WriteRune(character)
		case character == ' ', character == '-', character == '(', character == ')':
			// 仅忽略常见排版字符。
		default:
			return ""
		}
	}
	return result.String()
}

func (a *agent) answer(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	a.mu.Lock()
	if time.Since(a.calls.LastAnswerAt) < 2*time.Second {
		a.mu.Unlock()
		writeJSON(response, http.StatusOK, map[string]bool{"answered": true})
		return
	}
	a.calls.LastAnswerAt = time.Now()
	a.mu.Unlock()
	if _, err := a.at.command("ATA", 5*time.Second); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"answered": true})
}

func (a *agent) reject(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if _, err := a.at.command("AT+CHUP", 5*time.Second); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"rejected": true})
}

func (a *agent) hangup(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if _, err := a.at.command("ATH", 5*time.Second); err != nil {
		if _, fallbackErr := a.at.command("AT+CHUP", 5*time.Second); fallbackErr != nil {
			writeError(response, http.StatusBadGateway, fallbackErr.Error())
			return
		}
	}
	writeJSON(response, http.StatusOK, map[string]bool{"hung_up": true})
}

func (a *agent) dtmf(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Digit string `json:"digit"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if len(body.Digit) != 1 || !strings.Contains("0123456789*#", body.Digit) {
		writeError(response, http.StatusBadRequest, "DTMF 仅支持 0-9、*、#")
		return
	}
	if _, err := a.at.command(`AT+VTS="`+body.Digit+`"`, 3*time.Second); err != nil {
		if _, fallbackErr := a.at.command("AT+CLDTMF=1,"+body.Digit, 3*time.Second); fallbackErr != nil {
			writeError(response, http.StatusBadGateway, fallbackErr.Error())
			return
		}
	}
	writeJSON(response, http.StatusOK, map[string]bool{"sent": true})
}

func (a *agent) mute(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Muted bool `json:"muted"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	value := "0"
	if body.Muted {
		value = "1"
	}
	if _, err := a.at.command("AT+CMUT="+value, 3*time.Second); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	a.mu.Lock()
	a.muted = body.Muted
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]bool{"muted": body.Muted})
}

func (a *agent) recording(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Action string `json:"action"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.Action != "start" && body.Action != "stop" {
		writeError(response, http.StatusBadRequest, "action 必须是 start 或 stop")
		return
	}
	// 模块代理不能伪造录音成功；后续由语音桥输出双向 PCM 后才开放此接口。
	a.unsupported(response, "模块侧双向 PCM 录音尚未接入")
}

func (a *agent) audioHostRegister(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Enabled bool `json:"enabled"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.Enabled {
		a.mu.RLock()
		callActive := a.calls.Active != nil && a.calls.Active.State == "active"
		a.mu.RUnlock()
		if !callActive {
			writeError(response, http.StatusConflict, "通话尚未接通，不能启动网络 PCM")
			return
		}
		go a.ensureVoiceRoute()
	} else {
		go a.stopVoiceRoute()
	}
	writeJSON(response, http.StatusOK, map[string]bool{"enabled": body.Enabled})
}

// audioHostWarmup 只提前加载语音驱动和校准，不打开 D4/D5/D6 媒体路由。
// 拨号或锁屏来电阶段可以安全执行，真正接通后仍由 audioHostRegister 启动完整 PCM 桥。
func (a *agent) audioHostWarmup(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	a.mu.RLock()
	hasCall := a.calls.Active != nil
	a.mu.RUnlock()
	if !hasCall {
		writeError(response, http.StatusConflict, "当前没有进行中的通话，不能预热语音运行时")
		return
	}
	go a.ensureVoiceRuntimeWarm()
	writeJSON(response, http.StatusOK, map[string]bool{"warming": true})
}

func (a *agent) audioHostConfig(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.voice.mu.Lock()
	routeReady := a.voice.ready
	routeSessionReady := a.voice.routeReady
	routeError := a.voice.lastError
	routeRunning := a.voice.command != nil || a.voice.routeCommand != nil
	helperPID := 0
	if a.voice.command != nil && a.voice.command.Process != nil {
		helperPID = a.voice.command.Process.Pid
	}
	routeHelperPID := 0
	if a.voice.routeCommand != nil && a.voice.routeCommand.Process != nil {
		routeHelperPID = a.voice.routeCommand.Process.Pid
	}
	startedAt := a.voice.startedAt
	logOffset := a.voice.logOffset
	a.voice.mu.Unlock()
	stats, statsAvailable, logTail := voiceDiagnosticSnapshot(logOffset)
	startedAtText := ""
	if !startedAt.IsZero() {
		startedAtText = startedAt.UTC().Format(time.RFC3339Nano)
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"vendor_id": 0x2c7c, "product_id": 0x0125, "location_id": 0,
		"transport": "tcp_pcm_s16le", "host": "192.168.225.1", "port": 7580,
		"sample_rate": 8000, "channels": 1,
		"route_ready": routeReady, "route_error": routeError,
		"route_running": routeRunning, "helper_pid": helperPID,
		"route_session_ready": routeSessionReady, "route_helper_pid": routeHelperPID,
		"session_started_at":   startedAtText,
		"statistics_available": statsAvailable, "statistics": stats,
		"diagnostic_log": voiceRouteLogFile, "log_tail": logTail,
	})
}
