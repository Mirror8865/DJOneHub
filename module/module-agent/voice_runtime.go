package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	voiceHelperName       = "mavo-pcm-bridge.armv7"
	voiceHelperSHA256     = "2236ae9a6b3e9e1b01c5ffbd4ae033e5812befbaa3f74d524ad1e1eaf1b9f476"
	voiceRoutePIDFile     = "/run/mavo-voice-route.pid"
	voiceSessionPIDFile   = "/run/mavo-voice-session.pid"
	voiceRouteLogFile     = agentDataDirectory + "/log/voice-route.log"
	voiceRouteLogBackup   = agentDataDirectory + "/log/voice-route.log.1"
	voiceRouteLogMaxBytes = 1024 * 1024
	voiceNetworkListen    = "192.168.225.1:7580"
	voiceMediaRouteFIFO   = "/run/voc_svr"
	voiceCalibrationLog   = "/run/mavo-alsaucm.log"
	voiceCalibrationFIFO  = "/run/alsaucm_test"
	voiceExpectedKernel   = "3.18.44"
	voiceExpectedCardName = "mdm9607-tomtom-i2s-snd-card"
	// 新 iPad 首次显示麦克风授权并启动 AVAudioEngine 时可能超过原来的 4 秒等待窗口。
	voiceClientConnectTimeout = 15 * time.Second
)

var voiceRuntimeFiles = map[string]string{
	"qdc507_aprv3.ko": "3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a",
	"qdc507_voice.ko": "ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c",
	voiceHelperName:   voiceHelperSHA256,
}

var voiceRequiredDevices = []string{
	"/dev/snd/controlC0", "/dev/snd/pcmC0D4p", "/dev/snd/pcmC0D4c",
	"/dev/snd/pcmC0D5p", "/dev/snd/pcmC0D6c",
}

type voiceTracker struct {
	mu           sync.Mutex
	command      *exec.Cmd
	routeCommand *exec.Cmd
	ready        bool
	routeReady   bool
	stopping     bool
	lastError    string
	startedAt    time.Time
	logOffset    int64
}

type voicePCMStats struct {
	UplinkBytes          uint64 `json:"uplink_bytes"`
	UplinkFrames         uint64 `json:"uplink_frames"`
	UplinkPeak           uint64 `json:"uplink_peak"`
	DownlinkBytes        uint64 `json:"downlink_bytes"`
	DownlinkFrames       uint64 `json:"downlink_frames"`
	DownlinkPeak         uint64 `json:"downlink_peak"`
	DownlinkDroppedFrame uint64 `json:"downlink_dropped_frames"`
}

var voiceDiagnosticLogMu sync.Mutex
var voiceRuntimePrepareMu sync.Mutex

// ensureVoiceRuntimeWarm 只做内核模块加载和 ACDB 校准，不启动通话媒体路由。
// 预热期间即使用户尚未接听，也不会占用 7580 或向基带发送媒体启动命令。
func (a *agent) ensureVoiceRuntimeWarm() {
	appendVoiceDiagnosticEvent("开始预热语音运行时")
	if err := prepareVoiceRuntime(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("语音运行时预热失败: " + err.Error())
		return
	}
	a.voice.mu.Lock()
	a.voice.lastError = ""
	a.voice.mu.Unlock()
	appendVoiceDiagnosticEvent("语音运行时预热完成")
}

// validateVoiceRuntime 在执行任何内核模块前校验固定上游文件，拒绝运行被替换的二进制。
func validateVoiceRuntime() (bool, error) {
	for name, expected := range voiceRuntimeFiles {
		path := filepath.Join(voiceRuntimePath, name)
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("读取语音运行时 %s 失败: %w", name, err)
		}
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != expected {
			return false, fmt.Errorf("语音运行时 %s 的 SHA-256 校验失败", name)
		}
	}
	return true, nil
}

func (a *agent) ensureVoiceRoute() {
	a.voice.mu.Lock()
	if a.voice.stopping {
		a.voice.mu.Unlock()
		return
	}
	if a.voice.ready {
		a.voice.mu.Unlock()
		return
	}
	// 上一通电话可能还在异步退出。旧进程占着 7580 时直接返回会让新电话
	// 永远等不到 DJ1READY，这是“能拨出但接听后回拨失败”的典型竞态。
	if a.voice.command != nil || a.voice.routeCommand != nil {
		oldCommand := a.voice.command
		oldRouteCommand := a.voice.routeCommand
		a.voice.command = nil
		a.voice.routeCommand = nil
		a.voice.routeReady = false
		a.voice.stopping = true
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("清理未完成的旧网络 PCM 会话")
		terminateVoiceProcess(oldCommand)
		terminateVoiceProcess(oldRouteCommand)
		stopVoiceMediaRoute()
		a.voice.mu.Lock()
		a.voice.stopping = false
	}
	defer a.voice.mu.Unlock()
	appendVoiceDiagnosticEvent("收到语音桥启动请求")
	if err := prepareVoiceRuntime(); err != nil {
		a.voice.lastError = err.Error()
		appendVoiceDiagnosticEvent("语音运行时准备失败: " + err.Error())
		return
	}

	helper := filepath.Join(voiceRuntimePath, voiceHelperName)
	if output, err := exec.Command(helper, "--check").CombinedOutput(); err != nil {
		a.voice.lastError = commandFailure("语音桥自检失败", output, err).Error()
		appendVoiceDiagnosticEvent(a.voice.lastError)
		return
	}
	if err := prepareVoiceDiagnosticLog(); err != nil {
		a.voice.lastError = err.Error()
		return
	}
	startedAt := time.Now().UTC()
	appendVoiceDiagnosticEvent("开始新的网络 PCM 会话")
	logOffset := voiceDiagnosticLogSize()
	a.voice.startedAt = startedAt
	a.voice.logOffset = logOffset
	if err := a.startVoiceRouteSessionLocked(helper, logOffset); err != nil {
		a.voice.lastError = err.Error()
		appendVoiceDiagnosticEvent("VoLTE 路由会话启动失败: " + err.Error())
		return
	}
	// D4 只建立 AFE hostless 路由；voc_svr 的 S 命令负责启动基带媒体时钟，二者缺一不可。
	if err := startVoiceMediaRoute(); err != nil {
		a.voice.lastError = err.Error()
		appendVoiceDiagnosticEvent("基带语音媒体路由启动失败: " + err.Error())
		terminateVoiceProcess(a.voice.routeCommand)
		stopVoiceMediaRoute()
		return
	}
	appendVoiceDiagnosticEvent("基带语音媒体路由已启动")
	logFile, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		a.voice.lastError = err.Error()
		terminateVoiceProcess(a.voice.routeCommand)
		stopVoiceMediaRoute()
		return
	}
	// D5 是主机到基带的播放端，D6 是基带到主机的采集端；不再经过 USB UAC D4。
	command := exec.Command(
		helper,
		"--tcp-listen", voiceNetworkListen,
		"--playback-device", "hw:0,5",
		"--capture-device", "hw:0,6",
		"--no-mixers",
		"--verbose",
	)
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		a.voice.lastError = err.Error()
		appendVoiceDiagnosticEvent("语音桥进程启动失败: " + err.Error())
		terminateVoiceProcess(a.voice.routeCommand)
		stopVoiceMediaRoute()
		return
	}
	a.voice.command = command
	_ = os.WriteFile(voiceRoutePIDFile, []byte(strconv.Itoa(command.Process.Pid)+"\n"), 0o600)
	appendVoiceDiagnosticEvent(fmt.Sprintf("语音桥进程已启动 pid=%d", command.Process.Pid))

	done := make(chan error, 1)
	go func() {
		waitErr := command.Wait()
		done <- waitErr
		_ = logFile.Close()
		var routeCommand *exec.Cmd
		a.voice.mu.Lock()
		if a.voice.command == command {
			a.voice.command = nil
			a.voice.ready = false
			routeCommand = a.voice.routeCommand
			_ = os.Remove(voiceRoutePIDFile)
		}
		a.voice.mu.Unlock()
		// 主 PCM 桥退出后必须同步释放 D4/voc_svr；否则残留 routeCommand 会阻止通话看门狗重新拉起。
		if routeCommand != nil {
			terminateVoiceProcess(routeCommand)
			stopVoiceMediaRoute()
			_ = os.Remove(voiceSessionPIDFile)
		}
		exitDetail := errorText(waitErr)
		if exitDetail == "" {
			exitDetail = "正常退出"
		}
		appendVoiceDiagnosticEvent("语音桥进程退出: " + exitDetail)
	}()

	deadline := time.Now().Add(voiceClientConnectTimeout)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			a.voice.command = nil
			a.voice.lastError = errorText(waitErr)
			terminateVoiceProcess(a.voice.routeCommand)
			stopVoiceMediaRoute()
			return
		default:
		}
		if voiceRouteReadyFrom(logOffset) {
			a.voice.ready = true
			a.voice.lastError = ""
			appendVoiceDiagnosticEvent("网络 PCM 握手与双向工作线程已就绪")
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = command.Process.Signal(syscall.SIGTERM)
	terminateVoiceProcess(a.voice.routeCommand)
	a.voice.lastError = "iPad 网络 PCM 客户端未在限定时间内连接"
	appendVoiceDiagnosticEvent(a.voice.lastError)
	stopVoiceMediaRoute()
}

// maintainVoiceRoute 只在已有接通通话且当前语音桥未运行时触发恢复。
// 不在通话外启动语音桥，避免空闲时加载内核音频模块和占用 PCM 设备。
func (a *agent) maintainVoiceRoute() {
	a.mu.RLock()
	active := a.calls.Active != nil && a.calls.Active.State == "active"
	a.mu.RUnlock()
	if !active {
		return
	}

	a.voice.mu.Lock()
	running := a.voice.ready || a.voice.command != nil || a.voice.routeCommand != nil
	a.voice.mu.Unlock()
	if !running {
		go a.ensureVoiceRoute()
	}
}

// startVoiceRouteSessionLocked 启动 D4 hostless 会话，把 D5/D6 AFE PCM 真正接入基带通话。
func (a *agent) startVoiceRouteSessionLocked(helper string, logOffset int64) error {
	logFile, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command(helper, "--voice-route-session", "--verbose")
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	a.voice.routeCommand = command
	a.voice.routeReady = false
	_ = os.WriteFile(voiceSessionPIDFile, []byte(strconv.Itoa(command.Process.Pid)+"\n"), 0o600)
	appendVoiceDiagnosticEvent(fmt.Sprintf("VoLTE 路由会话已启动 pid=%d", command.Process.Pid))

	done := make(chan error, 1)
	go func() {
		waitErr := command.Wait()
		done <- waitErr
		_ = logFile.Close()
		a.voice.mu.Lock()
		if a.voice.routeCommand == command {
			a.voice.routeCommand = nil
			a.voice.routeReady = false
			a.voice.ready = false
			_ = os.Remove(voiceSessionPIDFile)
		}
		a.voice.mu.Unlock()
		exitDetail := errorText(waitErr)
		if exitDetail == "" {
			exitDetail = "正常退出"
		}
		appendVoiceDiagnosticEvent("VoLTE 路由会话退出: " + exitDetail)
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			a.voice.routeCommand = nil
			return fmt.Errorf("VoLTE 路由会话提前退出: %s", errorText(waitErr))
		default:
		}
		if voiceRouteSessionReadyFrom(logOffset) {
			a.voice.routeReady = true
			appendVoiceDiagnosticEvent("VoLTE D4 路由与 AFE mixer 已就绪")
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	terminateVoiceProcess(command)
	return errors.New("VoLTE D4 路由会话未在限定时间内就绪")
}

func stopVoiceMediaRoute() {
	_ = writeVoiceMediaRoute(voiceMediaRouteFIFO, "T\nT\nB\n")
}

func startVoiceMediaRoute() error {
	if err := writeVoiceMediaRoute(voiceMediaRouteFIFO, "S\n"); err != nil {
		return fmt.Errorf("启动模块 D5/D6 基带媒体路由失败: %w", err)
	}
	return nil
}

func writeVoiceMediaRoute(path string, command string) error {
	fifo, err := os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("打开语音路由 FIFO 失败: %w", err)
	}
	_, writeErr := fifo.WriteString(command)
	closeErr := fifo.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

// prepareVoiceRuntime 串行化预热与正式语音桥启动，避免快速接听时并发 insmod/校准。
func prepareVoiceRuntime() error {
	voiceRuntimePrepareMu.Lock()
	defer voiceRuntimePrepareMu.Unlock()
	return prepareVoiceRuntimeUnlocked()
}

func prepareVoiceRuntimeUnlocked() error {
	installed, err := validateVoiceRuntime()
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("模块语音运行时未安装")
	}
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil || !strings.Contains(string(release), voiceExpectedKernel) {
		return fmt.Errorf("模块内核不匹配，需要 %s，实际 %s", voiceExpectedKernel, strings.TrimSpace(string(release)))
	}
	modules, _ := os.ReadFile("/proc/modules")
	for _, item := range []struct{ file, module string }{{"qdc507_aprv3.ko", "qdc507_aprv3"}, {"qdc507_voice.ko", "qdc507_voice"}} {
		if strings.Contains(string(modules), item.module+" ") {
			continue
		}
		output, commandErr := exec.Command("/sbin/insmod", filepath.Join(voiceRuntimePath, item.file)).CombinedOutput()
		if errors.Is(commandErr, exec.ErrNotFound) {
			output, commandErr = exec.Command("insmod", filepath.Join(voiceRuntimePath, item.file)).CombinedOutput()
		}
		if commandErr != nil {
			return commandFailure("加载 "+item.file+" 失败", output, commandErr)
		}
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if voiceDevicesReady() {
			return ensureVoiceCalibration()
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("语音驱动已加载，但 ALSA D4/D5/D6 设备没有出现")
}

func voiceDevicesReady() bool {
	for _, device := range voiceRequiredDevices {
		if !fileExists(device) {
			return false
		}
	}
	cards, err := os.ReadFile("/proc/asound/cards")
	return err == nil && strings.Contains(string(cards), voiceExpectedCardName)
}

func ensureVoiceCalibration() error {
	if logContains(voiceCalibrationLog, "ACDB -> Sent VocProc Cal!") {
		return nil
	}
	logFile, err := os.OpenFile(voiceCalibrationLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command("/usr/bin/alsaucm_test")
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		return fmt.Errorf("启动 VoLTE ACDB 校准服务失败: %w", err)
	}
	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && !fileExists(voiceCalibrationFIFO) {
		time.Sleep(100 * time.Millisecond)
	}
	if !fileExists(voiceCalibrationFIFO) {
		return errors.New("VoLTE ACDB 校准 FIFO 没有出现")
	}
	fifo, err := os.OpenFile(voiceCalibrationFIFO, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("打开 VoLTE ACDB 校准 FIFO 失败: %w", err)
	}
	_, writeErr := fifo.WriteString("open snd_soc_msm_9x07_Tomtom_I2S\nset _verb VoLTE\nset _enadev Auxpcm Rx\nset _enadev Auxpcm Tx\n")
	_ = fifo.Close()
	if writeErr != nil {
		return writeErr
	}
	deadline = time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if logContains(voiceCalibrationLog, "ACDB -> Sent VocProc Cal!") {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("VoLTE ACDB 校准未确认完成")
}

func voiceRouteReadyFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteLogReady(data)
}

func voiceRouteSessionReadyFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteSessionLogReady(data)
}

func voiceRouteLogReady(data []byte) bool {
	return voiceRouteSessionLogReady(data) &&
		strings.Contains(string(data), "network PCM client connected") &&
		strings.Contains(string(data), "bridge active on 192.168.225.1:7580")
}

func voiceRouteSessionLogReady(data []byte) bool {
	return strings.Contains(string(data), "VoLTE route session active on hw:0,4")
}

func (a *agent) stopVoiceRoute() {
	a.voice.mu.Lock()
	command := a.voice.command
	routeCommand := a.voice.routeCommand
	a.voice.ready = false
	a.voice.routeReady = false
	a.voice.stopping = true
	// 先从状态中摘除旧进程，新的 ensureVoiceRoute 会看到 stopping 并等待，
	// 避免新旧 helper 同时抢占 7580 端口。
	a.voice.command = nil
	a.voice.routeCommand = nil
	a.voice.mu.Unlock()
	// 先断开 D5/D6 数据桥，再让 D4 route session 反序回滚 mixer 与 audio_enable。
	terminateVoiceProcess(command)
	terminateVoiceProcess(routeCommand)
	_ = os.WriteFile("/sys/class/android_usb/f_audio/audio_enable", []byte("0\n"), 0o600)
	stopVoiceMediaRoute()
	_ = os.Remove(voiceRoutePIDFile)
	_ = os.Remove(voiceSessionPIDFile)
	a.voice.mu.Lock()
	a.voice.stopping = false
	a.voice.mu.Unlock()
	// 如果停止期间已经有新通话接通，立即补起语音桥，不依赖下一轮轮询。
	a.mu.RLock()
	active := a.calls.Active != nil && a.calls.Active.State == "active"
	a.mu.RUnlock()
	if active {
		go a.ensureVoiceRoute()
	}
}

func terminateVoiceProcess(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	pid := command.Process.Pid
	_ = command.Process.Signal(syscall.SIGTERM)
	for attempt := 0; attempt < 30; attempt++ {
		if err := syscall.Kill(pid, 0); err != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func logContains(path, marker string) bool {
	data, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(data), marker)
}

// prepareVoiceDiagnosticLog 限制持久日志大小，避免长期通话耗尽模块的 /data 分区。
func prepareVoiceDiagnosticLog() error {
	voiceDiagnosticLogMu.Lock()
	defer voiceDiagnosticLogMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(voiceRouteLogFile), 0o700); err != nil {
		return fmt.Errorf("创建语音诊断目录失败: %w", err)
	}
	info, err := os.Stat(voiceRouteLogFile)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("读取语音诊断日志失败: %w", err)
	}
	if info.Size() < voiceRouteLogMaxBytes {
		return nil
	}
	if err := os.Rename(voiceRouteLogFile, voiceRouteLogBackup); err != nil {
		return fmt.Errorf("轮换语音诊断日志失败: %w", err)
	}
	return nil
}

// appendVoiceDiagnosticEvent 写入带 UTC 时间的控制面事件，不记录号码或原始音频。
func appendVoiceDiagnosticEvent(message string) {
	voiceDiagnosticLogMu.Lock()
	defer voiceDiagnosticLogMu.Unlock()
	if os.MkdirAll(filepath.Dir(voiceRouteLogFile), 0o700) != nil {
		return
	}
	file, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(file, "qdc507-agent[event]: time=%s %s\n", time.Now().UTC().Format(time.RFC3339Nano), message)
	_ = file.Close()
}

func voiceDiagnosticLogSize() int64 {
	info, err := os.Stat(voiceRouteLogFile)
	if err != nil {
		return 0
	}
	return info.Size()
}

func readVoiceDiagnosticLog(offset int64) ([]byte, error) {
	data, err := os.ReadFile(voiceRouteLogFile)
	if err != nil {
		return nil, err
	}
	if offset <= 0 {
		return data, nil
	}
	if offset >= int64(len(data)) {
		return []byte{}, nil
	}
	return data[offset:], nil
}

// parseVoicePCMStats 解析 helper 最后一条累计统计，供 HTTP 与单元测试共同使用。
func parseVoicePCMStats(data []byte) (voicePCMStats, bool) {
	lines := strings.Split(string(data), "\n")
	for lineIndex := len(lines) - 1; lineIndex >= 0; lineIndex-- {
		marker := "mavo-pcm-bridge[stats]: "
		markerIndex := strings.Index(lines[lineIndex], marker)
		if markerIndex < 0 {
			continue
		}
		values := make(map[string]uint64)
		for _, field := range strings.Fields(lines[lineIndex][markerIndex+len(marker):]) {
			parts := strings.SplitN(field, "=", 2)
			if len(parts) != 2 {
				continue
			}
			value, err := strconv.ParseUint(parts[1], 10, 64)
			if err == nil {
				values[parts[0]] = value
			}
		}
		return voicePCMStats{
			UplinkBytes:          values["uplink_bytes"],
			UplinkFrames:         values["uplink_frames"],
			UplinkPeak:           values["uplink_peak"],
			DownlinkBytes:        values["downlink_bytes"],
			DownlinkFrames:       values["downlink_frames"],
			DownlinkPeak:         values["downlink_peak"],
			DownlinkDroppedFrame: values["downlink_dropped_frames"],
		}, true
	}
	return voicePCMStats{}, false
}

func voiceDiagnosticSnapshot(offset int64) (voicePCMStats, bool, []string) {
	data, err := os.ReadFile(voiceRouteLogFile)
	if err != nil {
		return voicePCMStats{}, false, []string{}
	}
	statsData := data
	if offset > 0 && offset < int64(len(data)) {
		statsData = data[offset:]
	}
	stats, available := parseVoicePCMStats(statsData)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) > 24 {
		lines = lines[len(lines)-24:]
	}
	if len(lines) == 1 && lines[0] == "" {
		lines = []string{}
	}
	return stats, available, lines
}

func commandFailure(prefix string, output []byte, err error) error {
	detail := strings.TrimSpace(string(output))
	if len(detail) > 1000 {
		detail = detail[len(detail)-1000:]
	}
	if detail == "" {
		return fmt.Errorf("%s: %w", prefix, err)
	}
	return fmt.Errorf("%s: %s（%v）", prefix, detail, err)
}
