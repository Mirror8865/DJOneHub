package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

type smsMessage struct {
	Sender     string    `json:"sender"`
	Content    string    `json:"content"`
	Code       string    `json:"code,omitempty"`
	Timestamp  time.Time `json:"timestamp"`
	DeliveryID string    `json:"delivery_id,omitempty"`
}

type storedSMS struct {
	Index   int
	Memory  string
	Message smsMessage
}

var verificationCodePattern = regexp.MustCompile(`(?:^|[^0-9])([0-9]{4,8})(?:[^0-9]|$)`)

// maxDeliveredSMSIDs 已确认交付 ID 的记忆上限；超出就整体丢弃重建。
// 交付 ID 自带「存储区 + 槽位 + 正文摘要」，槽位被复用时摘要不同的新短信不会误伤。
const maxDeliveredSMSIDs = 512

func (a *agent) refreshSMS(force bool) {
	// 便宜闸门：先只发一条 AT+CPMS? 拿两个存储区的已用条数。条数没变说明基带存储
	// 没有新短信（App 读完会把已交付的记录删掉，used 只会减少），这时跳过
	// 「切模式 + 选存储区 + CMGL 整段扫描」这几条最重的 AT——SIM 存储区尤其慢。
	used, probed := a.readSMSUsedCounts()
	if !force && !a.smsScanNeeded(used, probed) {
		return
	}
	items, err := a.readAllSMS()
	if err != nil {
		a.mu.Lock()
		a.smsError = err.Error()
		a.mu.Unlock()
		return
	}

	a.mu.Lock()
	if a.delivered == nil {
		a.delivered = make(map[string]bool)
	}
	combined := append([]storedSMS(nil), a.messages...)
	for _, item := range items {
		// 手机已经确认落盘并让模块删掉的记录不再入队：本轮的 AT 读取可能早于
		// 删除完成，重新入队会让同一条短信在 /api/sms 里反复出现。
		if item.Message.DeliveryID != "" && a.delivered[item.Message.DeliveryID] {
			continue
		}
		if !containsStoredSMS(combined, item) {
			combined = append(combined, item)
		}
	}
	sort.SliceStable(combined, func(left, right int) bool {
		return combined[left].Message.Timestamp.After(combined[right].Message.Timestamp)
	})
	a.messages = combined
	a.smsError = ""
	a.smsScannedAt = time.Now()
	if probed {
		a.smsUsedCounts = used
	} else {
		// 读不到条数时留空，下一轮强制整段扫描。
		a.smsUsedCounts = nil
	}
	a.mu.Unlock()
}

// smsStorageGateInterval 兜底：即使 AT+CPMS? 的条数没变，也要在这个间隔内整段扫一次。
// 覆盖「同一窗口里既来了新短信、又删掉了旧记录」这种 used 不变的极端情况。
const smsStorageGateInterval = 30 * time.Second

// smsScanNeeded 用一条 AT+CPMS? 判断要不要做整段短信扫描。
// 存储条数没变就不扫；读不到条数时失败开放（返回 true），宁可多扫一次也不能漏短信。
func (a *agent) smsScanNeeded(used map[string]int, probed bool) bool {
	a.mu.RLock()
	scannedAt := a.smsScannedAt
	previous := a.smsUsedCounts
	a.mu.RUnlock()
	if time.Since(scannedAt) > smsStorageGateInterval {
		return true
	}
	if !probed {
		return true
	}
	return !sameSMSUsedCounts(previous, used)
}

// readSMSUsedCounts 只发一条 AT+CPMS?，读出各存储区的已用条数。
func (a *agent) readSMSUsedCounts() (map[string]int, bool) {
	response, err := a.at.command("AT+CPMS?", 3*time.Second)
	if err != nil {
		return nil, false
	}
	used := parseCPMSUsedCounts(response)
	if len(used) == 0 {
		return nil, false
	}
	return used, true
}

// parseCPMSUsedCounts 解析 "+CPMS: \"SM\",3,50,\"ME\",0,50,\"SM\",3,50"。
// 三元组是 <存储区>,<已用>,<总数>，所以按 3 步长取前两个字段。
func parseCPMSUsedCounts(response string) map[string]int {
	used := map[string]int{}
	for _, line := range strings.Split(strings.ReplaceAll(response, "\r", ""), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "+CPMS:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(line, "+CPMS:")))
		for index := 0; index+1 < len(fields); index += 3 {
			name := strings.ToUpper(strings.Trim(strings.TrimSpace(fields[index]), `"`))
			if name == "" {
				continue
			}
			used[name] = parseInt(fields[index+1])
		}
	}
	return used
}

// sameSMSUsedCounts 两个存储区快照是否完全一致；空快照一律视为「不一致」。
func sameSMSUsedCounts(left, right map[string]int) bool {
	if len(left) == 0 || len(left) != len(right) {
		return false
	}
	for name, value := range right {
		if left[name] != value {
			return false
		}
	}
	return true
}

// containsStoredSMS 防止 8 秒轮询把同一条模块存储记录重复加入交付队列。
func containsStoredSMS(messages []storedSMS, candidate storedSMS) bool {
	for _, message := range messages {
		if message.Memory == candidate.Memory && message.Index == candidate.Index &&
			message.Message.DeliveryID == candidate.Message.DeliveryID {
			return true
		}
	}
	return false
}

func containsSMS(messages []smsMessage, candidate smsMessage) bool {
	for _, message := range messages {
		if message.Sender == candidate.Sender && message.Content == candidate.Content && message.Timestamp.Equal(candidate.Timestamp) {
			return true
		}
	}
	return false
}

func (a *agent) readAllSMS() ([]storedSMS, error) {
	if _, err := a.at.command("AT+CMGF=1", 3*time.Second); err != nil {
		return nil, formatError("切换短信文本模式", err)
	}
	if _, err := a.at.command(`AT+CSCS="UCS2"`, 3*time.Second); err != nil {
		return nil, formatError("切换短信 UCS2 字符集", err)
	}

	var result []storedSMS
	var failures []string
	for _, memory := range []string{"SM", "ME"} {
		if _, err := a.at.command(fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, memory, memory, memory), 5*time.Second); err != nil {
			failures = append(failures, memory+": "+err.Error())
			continue
		}
		response, err := a.at.command(`AT+CMGL="ALL"`, 15*time.Second)
		if err != nil {
			failures = append(failures, memory+": "+err.Error())
			continue
		}
		result = append(result, parseTextModeSMS(response, memory)...)
	}
	// 字符集是基带的全局状态：读完后必须切回 GSM。
	// 留在 UCS2 上会让后续的文本类 AT 响应（例如运营商名 AT+COPS?）
	// 以 UCS2 十六进制返回，界面就会显示成乱码。
	_, _ = a.at.command(`AT+CSCS="GSM"`, 3*time.Second)
	if len(result) == 0 && len(failures) == 2 {
		return nil, fmt.Errorf("读取短信失败: %s", strings.Join(failures, "; "))
	}
	return result, nil
}

func parseTextModeSMS(response, memory string) []storedSMS {
	lines := strings.Split(strings.ReplaceAll(response, "\r", ""), "\n")
	items := make([]storedSMS, 0)
	for index := 0; index < len(lines); index++ {
		header := strings.TrimSpace(lines[index])
		if !strings.HasPrefix(header, "+CMGL:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(header, "+CMGL:")))
		if len(fields) < 3 {
			continue
		}
		messageIndex, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		sender := decodeMaybeUCS2(fields[2])
		timestamp := time.Now()
		for fieldIndex := len(fields) - 1; fieldIndex >= 3; fieldIndex-- {
			if parsed, ok := parseSMSTimestamp(decodeMaybeUCS2(fields[fieldIndex])); ok {
				timestamp = parsed
				break
			}
		}
		body := ""
		if index+1 < len(lines) {
			candidate := strings.TrimSpace(lines[index+1])
			if candidate != "OK" && !strings.HasPrefix(candidate, "+CMGL:") {
				body = decodeMaybeUCS2(candidate)
				index++
			}
		}
		code := ""
		if match := verificationCodePattern.FindStringSubmatch(body); len(match) == 2 {
			code = match[1]
		}
		message := smsMessage{
			Sender: sender, Content: body, Code: code, Timestamp: timestamp,
		}
		// 交付 ID 只用于手机落盘后的确认，不参与用户可见的短信去重。
		digest := sha256.Sum256([]byte(sender + "\x00" + body))
		message.DeliveryID = fmt.Sprintf("%s-%d-%x", memory, messageIndex, digest[:8])
		items = append(items, storedSMS{Index: messageIndex, Memory: memory, Message: message})
	}
	return items
}

func decodeMaybeUCS2(value string) string {
	value = strings.Trim(strings.TrimSpace(value), `"`)
	if value == "" || len(value)%4 != 0 {
		return value
	}
	raw, err := hex.DecodeString(value)
	if err != nil || len(raw)%2 != 0 {
		return value
	}
	units := make([]uint16, 0, len(raw)/2)
	for index := 0; index < len(raw); index += 2 {
		units = append(units, uint16(raw[index])<<8|uint16(raw[index+1]))
	}
	decoded := string(utf16.Decode(units))
	if strings.ContainsRune(decoded, '\uFFFD') {
		return value
	}
	return decoded
}

func encodeUCS2(value string) string {
	units := utf16.Encode([]rune(value))
	raw := make([]byte, 0, len(units)*2)
	for _, unit := range units {
		raw = append(raw, byte(unit>>8), byte(unit))
	}
	return strings.ToUpper(hex.EncodeToString(raw))
}

func splitUCS2(value string, limit int) []string {
	if limit <= 0 {
		return nil
	}
	var result []string
	var current []rune
	units := 0
	for _, character := range []rune(value) {
		width := len(utf16.Encode([]rune{character}))
		if units+width > limit && len(current) > 0 {
			result = append(result, string(current))
			current = nil
			units = 0
		}
		current = append(current, character)
		units += width
	}
	if len(current) > 0 {
		result = append(result, string(current))
	}
	return result
}

func parseSMSTimestamp(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	match := regexp.MustCompile(`^(\d{2})/(\d{2})/(\d{2}),(\d{2}):(\d{2}):(\d{2})([+-])(\d{2})$`).FindStringSubmatch(value)
	if len(match) != 9 {
		return time.Time{}, false
	}
	numbers := make([]int, 6)
	for index := range numbers {
		numbers[index], _ = strconv.Atoi(match[index+1])
	}
	quarters, _ := strconv.Atoi(match[8])
	offset := quarters * 15 * 60
	if match[7] == "-" {
		offset = -offset
	}
	zone := time.FixedZone("SMS", offset)
	return time.Date(2000+numbers[0], time.Month(numbers[1]), numbers[2], numbers[3], numbers[4], numbers[5], 0, zone), true
}

// smsMemoryListing 一个存储区的 PDU 原始列表；Listing 为空时 Error 给出原因。
type smsMemoryListing struct {
	Memory  string `json:"memory"`
	Listing string `json:"listing,omitempty"`
	Error   string `json:"error,omitempty"`
}

// readPDUListing 在一个 AT 临界区里读完一个存储区的 PDU 列表。
//
// 只有 PDU 通道还留着 UDH：长短信的参考号 / 总段数 / 段序号全靠它，而文本模式
// （CMGF=1 + CMGL="ALL"）基带已经把 UDH 丢掉，一条长短信会碎成多条记录。
// 「切模式 + 选存储区 + 列短信」必须整段独占 AT 口，见 atPort.commandBatch：
// 这三步以前是三条 /api/at 请求，8 秒文本模式轮询会在中间把模式切回去，
// CMGL=4 于是返回 ERROR，PDU 通道时通时断，长短信就跟着一会儿拼好一会儿裂开。
func (a *agent) readPDUListing(memory string) (string, error) {
	commands := []string{
		"AT+CMGF=0",
		fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, memory, memory, memory),
		"AT+CMGL=4",
	}
	// 15 秒是整段序列（CMGF + CPMS + CMGL）的总预算，正常情况两秒内就返回；
	// 卡住时也不至于把 App 的请求拖过超时。
	responses, err := a.at.commandBatch(commands, 15*time.Second)
	if err != nil {
		return "", err
	}
	if len(responses) < len(commands) {
		return "", fmt.Errorf("读取 %s 存储区短信失败", memory)
	}
	return responses[len(commands)-1], nil
}

// collectPDUListings 汇总 SM / ME 两个存储区的 PDU 列表；单个存储区失败不影响另一个。
func (a *agent) collectPDUListings() ([]smsMemoryListing, error) {
	memories := []string{"SM", "ME"}
	listings := make([]smsMemoryListing, 0, len(memories))
	failures := make([]string, 0, len(memories))
	for _, memory := range memories {
		listing, err := a.readPDUListing(memory)
		if err != nil {
			listings = append(listings, smsMemoryListing{Memory: memory, Error: err.Error()})
			failures = append(failures, memory+": "+err.Error())
			continue
		}
		listings = append(listings, smsMemoryListing{Memory: memory, Listing: listing})
	}
	if len(failures) == len(memories) {
		return nil, fmt.Errorf("读取短信 PDU 列表失败: %s", strings.Join(failures, "; "))
	}
	return listings, nil
}

// smsPDUListings 一次请求给出两个存储区的 PDU 原始列表，由 App 侧按 UDH 拼接长短信。
//
// 整段读取在模块侧完成，App 不再自己拼 AT 序列，后台被系统唤醒时取数只花一个请求。
func (a *agent) smsPDUListings(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	listings, err := a.collectPDUListings()
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"at":       time.Now().UTC().Format(time.RFC3339),
		"memories": listings,
	})
}

func (a *agent) smsList(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	stored := append([]storedSMS(nil), a.messages...)
	a.mu.RUnlock()
	messages := make([]smsMessage, 0, len(stored))
	for _, item := range stored {
		messages = append(messages, item.Message)
	}
	if messages == nil {
		messages = []smsMessage{}
	}
	writeJSON(response, http.StatusOK, messages)
}

func (a *agent) smsStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	count, lastError := len(a.messages), a.smsError
	a.mu.RUnlock()
	writeJSON(response, http.StatusOK, map[string]any{
		"auto_cleanup_me": true, "count": count, "last_poll_error": lastError,
	})
}

func (a *agent) smsSend(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Phone   string `json:"phone"`
		Message string `json:"message"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	phone := normalizeDialNumber(body.Phone)
	if phone == "" || len(phone) > 82 || strings.TrimSpace(body.Message) == "" || len([]rune(body.Message)) > 2000 {
		writeError(response, http.StatusBadRequest, "号码或短信内容无效")
		return
	}
	segments := splitUCS2(body.Message, 70)
	if len(segments) == 0 {
		writeError(response, http.StatusBadRequest, "短信内容为空")
		return
	}
	if _, err := a.at.command("AT+CMGF=1", 3*time.Second); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	for _, command := range []string{`AT+CSCS="UCS2"`, "AT+CSMP=17,167,0,8"} {
		if _, err := a.at.command(command, 3*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
	}
	for index, segment := range segments {
		payload := append([]byte(encodeUCS2(segment)), 0x1a)
		if _, err := a.at.promptCommand(`AT+CMGS="`+encodeUCS2(phone)+`"`, payload, 45*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, fmt.Sprintf("发送第 %d/%d 段失败: %v", index+1, len(segments), err))
			return
		}
	}
	writeJSON(response, http.StatusOK, map[string]any{"sent": true, "segments": len(segments)})
}

func (a *agent) smsRefresh(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	// 后台保活只有几十秒执行窗口：一次请求同时做「逼模块把新短信读出来」和
	// 「把能拼接的 PDU 交给 App」两件事，比原先「POST 刷新文本模式缓存 + GET 列表」
	// 少一半往返。文本模式缓存里没有 UDH，长短信在那里永远是碎的。
	listings, err := a.collectPDUListings()
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"at":       time.Now().UTC().Format(time.RFC3339),
		"memories": listings,
	})
}

// smsAck 在手机确认本地 JSON 已原子写入后，才删除对应的 SIM/ME 短信和内存交付项。
func (a *agent) smsAck(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		IDs []string `json:"ids"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	requested := make(map[string]bool, len(body.IDs))
	for _, id := range body.IDs {
		if id != "" {
			requested[id] = true
		}
	}

	a.mu.RLock()
	pending := append([]storedSMS(nil), a.messages...)
	a.mu.RUnlock()
	succeeded := make(map[string]bool)
	var failures []string
	for _, item := range pending {
		id := item.Message.DeliveryID
		if !requested[id] {
			continue
		}
		if err := a.deleteStoredSMS(item); err != nil {
			failures = append(failures, id+": "+err.Error())
			continue
		}
		succeeded[id] = true
	}

	a.mu.Lock()
	remaining := a.messages[:0]
	for _, item := range a.messages {
		if !succeeded[item.Message.DeliveryID] {
			remaining = append(remaining, item)
		}
	}
	a.messages = remaining
	if len(succeeded) > 0 {
		if a.delivered == nil {
			a.delivered = make(map[string]bool)
		}
		for id := range succeeded {
			a.delivered[id] = true
		}
		if len(a.delivered) > maxDeliveredSMSIDs {
			a.delivered = make(map[string]bool)
		}
	}
	a.mu.Unlock()
	if len(failures) > 0 {
		writeError(response, http.StatusBadGateway, "删除已交付模块短信失败: "+strings.Join(failures, "; "))
		return
	}
	writeJSON(response, http.StatusOK, map[string]int{"acknowledged": len(succeeded)})
}

// smsDelete 按「存储区 + 槽位」删除模块短信。
//
// PDU 拼接出来的完整短信没有交付 ID，App 无法走 /api/sms/ack；它知道自己消费掉的
// 是哪些槽位，这里就直接按槽位删。同时把模块内存缓存里对应的记录一并摘掉，
// 否则 8 秒文本模式轮询会把已经落盘的旧记录重新排回 /api/sms。
func (a *agent) smsDelete(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Items []struct {
			Memory string `json:"memory"`
			Index  int    `json:"index"`
		} `json:"items"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	requested := make(map[string]bool, len(body.Items))
	for _, item := range body.Items {
		if item.Memory != "SM" && item.Memory != "ME" {
			writeError(response, http.StatusBadRequest, fmt.Sprintf("未知短信存储区 %q", item.Memory))
			return
		}
		requested[fmt.Sprintf("%s-%d", item.Memory, item.Index)] = true
	}
	if len(requested) == 0 {
		writeJSON(response, http.StatusOK, map[string]int{"deleted": 0})
		return
	}

	var failures []string
	for slot := range requested {
		memory, index, ok := parseSMSSlot(slot)
		if !ok {
			failures = append(failures, slot+": 槽位号无效")
			continue
		}
		if err := a.deleteSlot(memory, index); err != nil {
			failures = append(failures, slot+": "+err.Error())
		}
	}

	a.dropCachedSMS(requested)

	deleted := len(requested) - len(failures)
	if len(failures) > 0 {
		writeError(response, http.StatusBadGateway,
			fmt.Sprintf("删除模块短信失败（成功 %d 条）: %s", deleted, strings.Join(failures, "; ")))
		return
	}
	writeJSON(response, http.StatusOK, map[string]int{"deleted": deleted})
}

// parseSMSSlot 把 `存储区-槽位号` 形式的槽位标识拆成两部分。
func parseSMSSlot(slot string) (memory string, index int, ok bool) {
	separator := strings.LastIndex(slot, "-")
	if separator <= 0 {
		return "", 0, false
	}
	index, err := strconv.Atoi(slot[separator+1:])
	if err != nil {
		return "", 0, false
	}
	memory = slot[:separator]
	if memory != "SM" && memory != "ME" {
		return "", 0, false
	}
	return memory, index, true
}

// dropCachedSMS 把已删除的槽位从模块内存列表里摘掉，并记住它们的交付 ID。
// 不这么做的话，8 秒文本模式轮询会把同一条已经落盘的旧记录重新排回 /api/sms。
func (a *agent) dropCachedSMS(slots map[string]bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	remaining := a.messages[:0]
	for _, item := range a.messages {
		if slots[fmt.Sprintf("%s-%d", item.Memory, item.Index)] {
			if item.Message.DeliveryID != "" {
				if a.delivered == nil {
					a.delivered = make(map[string]bool)
				}
				a.delivered[item.Message.DeliveryID] = true
			}
			continue
		}
		remaining = append(remaining, item)
	}
	a.messages = remaining
	if len(a.delivered) > maxDeliveredSMSIDs {
		a.delivered = make(map[string]bool)
	}
}

// deleteSlot 删除一条存储记录，并在同一个 AT 临界区里先选定存储区。
func (a *agent) deleteSlot(memory string, index int) error {
	if memory != "SM" && memory != "ME" {
		return fmt.Errorf("未知短信存储区 %q", memory)
	}
	_, err := a.at.commandBatch([]string{
		fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, memory, memory, memory),
		fmt.Sprintf("AT+CMGD=%d", index),
	}, 12*time.Second)
	return err
}

func (a *agent) deleteStoredSMS(item storedSMS) error {
	return a.deleteSlot(item.Memory, item.Index)
}

func (a *agent) smsSettings(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPatch) {
		return
	}
	var body struct {
		AutoCleanup *bool `json:"auto_cleanup_me"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.AutoCleanup == nil {
		writeError(response, http.StatusBadRequest, "缺少 auto_cleanup_me")
		return
	}
	// 新协议始终在手机确认落盘后清理，旧客户端的开关请求只保留兼容响应。
	a.mu.Lock()
	a.smsAuto = true
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]bool{"auto_cleanup_me": true})
}

func (a *agent) smsClear(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	totalBefore := 0
	for _, memory := range []string{"SM", "ME"} {
		selectResponse, err := a.at.command(fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, memory, memory, memory), 5*time.Second)
		if err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
		totalBefore += parseCPMSUsed(selectResponse)
		if _, err := a.at.command("AT+CMGD=1,4", 20*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
	}
	a.mu.Lock()
	a.messages = nil
	a.delivered = nil
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{"cleared": true, "before": totalBefore, "after": 0})
}

func parseCPMSUsed(response string) int {
	match := regexp.MustCompile(`\+CPMS:\s*(\d+)`).FindStringSubmatch(response)
	if len(match) != 2 {
		return 0
	}
	value, _ := strconv.Atoi(match[1])
	return value
}

func (a *agent) simIdentity(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	result, err := a.at.command("AT+CNUM", 3*time.Second)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]string{"phone_number": parseCNUM(result)})
}

func parseCNUM(response string) string {
	for _, line := range strings.Split(response, "\n") {
		if !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(line)), "+CNUM:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "+CNUM:")))
		if len(fields) >= 2 {
			return decodeMaybeUCS2(fields[1])
		}
	}
	return ""
}
