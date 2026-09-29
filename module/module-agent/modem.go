package main

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// modemStatus 只暴露 iPad 客户端需要的稳定字段，原始 AT 响应不会写入日志或网络。
type modemStatus struct {
	IMEI             string `json:"imei,omitempty"`
	Firmware         string `json:"firmware,omitempty"`
	ICCID            string `json:"iccid,omitempty"`
	IMSI             string `json:"imsi,omitempty"`
	Operator         string `json:"operator,omitempty"`
	SIMInserted      bool   `json:"sim_inserted"`
	SignalDBM        *int   `json:"signal_dbm"`
	NetworkMode      string `json:"network_mode,omitempty"`
	RadioBand        string `json:"radio_band,omitempty"`
	RegistrationText string `json:"reg_status_text,omitempty"`
	LastError        string `json:"-"`
}

var (
	csqPattern     = regexp.MustCompile(`\+CSQ:\s*(\d+),`)
	copsPattern    = regexp.MustCompile(`\+COPS:\s*\d+\s*,\s*\d+\s*,\s*"([^"]*)"`)
	regPattern     = regexp.MustCompile(`\+(?:CE)?REG:\s*\d+\s*,\s*(\d+)`)
	qnwInfoPattern = regexp.MustCompile(`\+QNWINFO:\s*"([^"]*)"\s*,\s*"[^"]*"\s*,\s*"([^"]*)"`)
	digitsPattern  = regexp.MustCompile(`^[0-9]{5,22}$`)
)

// refreshModem 独立读取各项状态；单项失败不会抹掉其他已取得的信息。
func (a *agent) refreshModem() {
	status := modemStatus{}
	var failures []string
	run := func(command string) string {
		response, err := a.at.command(command, 3*time.Second)
		if err != nil {
			failures = append(failures, command+": "+err.Error())
			return response
		}
		return response
	}

	status.Firmware = parseFirmware(run("ATI"))
	cpin := strings.ToUpper(run("AT+CPIN?"))
	status.SIMInserted = strings.Contains(cpin, "READY")
	status.Operator = normalizeOperator(parseOperator(run("AT+COPS?")))
	status.SignalDBM = parseSignalDBM(run("AT+CSQ"))
	status.NetworkMode, status.RadioBand = parseNetworkInfo(run("AT+QNWINFO"))
	status.ICCID = commandValue(run("AT+QCCID"), "+QCCID:")
	status.IMSI = firstNumericLine(run("AT+CIMI"))
	status.IMEI = firstNumericLine(run("AT+CGSN"))
	registration := parseRegistration(run("AT+CEREG?"))
	if registration == 0 {
		registration = parseRegistration(run("AT+CREG?"))
	}
	status.RegistrationText = registrationText(registration)
	if len(failures) > 0 {
		status.LastError = strings.Join(failures, "; ")
	}

	a.mu.Lock()
	a.modem = status
	a.mu.Unlock()
}

func parseFirmware(response string) string {
	var useful []string
	for _, line := range strings.Split(response, "\n") {
		line = strings.TrimSpace(line)
		upper := strings.ToUpper(line)
		if line == "" || upper == "OK" || upper == "ATI" || strings.HasPrefix(upper, "AT+") {
			continue
		}
		useful = append(useful, line)
	}
	return strings.Join(useful, " · ")
}

func firstNumericLine(response string) string {
	for _, line := range strings.Split(response, "\n") {
		line = strings.TrimSpace(line)
		if digitsPattern.MatchString(line) {
			return line
		}
	}
	return ""
}

func parseSignalDBM(response string) *int {
	match := csqPattern.FindStringSubmatch(response)
	if len(match) != 2 {
		return nil
	}
	rssi, err := strconv.Atoi(match[1])
	if err != nil || rssi == 99 || rssi > 31 {
		return nil
	}
	value := -113 + 2*rssi
	return &value
}

func parseOperator(response string) string {
	match := copsPattern.FindStringSubmatch(response)
	if len(match) != 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func normalizeOperator(value string) string {
	upper := strings.ToUpper(strings.TrimSpace(value))
	switch {
	case strings.Contains(upper, "MOBILE") || upper == "CMCC" || upper == "46000" || upper == "46002" || upper == "46007":
		return "中国移动"
	case strings.Contains(upper, "UNICOM") || upper == "46001" || upper == "46006" || upper == "46009":
		return "中国联通"
	case strings.Contains(upper, "TELECOM") || upper == "CTCC" || upper == "46003" || upper == "46005" || upper == "46011":
		return "中国电信"
	case strings.Contains(upper, "BROADNET") || upper == "46015":
		return "中国广电"
	default:
		return strings.TrimSpace(value)
	}
}

func parseNetworkInfo(response string) (string, string) {
	match := qnwInfoPattern.FindStringSubmatch(response)
	if len(match) != 3 {
		return "", ""
	}
	mode := strings.TrimSpace(match[1])
	band := strings.TrimSpace(match[2])
	band = strings.TrimPrefix(band, "LTE ")
	return mode, band
}

func parseRegistration(response string) int {
	match := regPattern.FindStringSubmatch(response)
	if len(match) != 2 {
		return 0
	}
	value, _ := strconv.Atoi(match[1])
	return value
}

func registrationText(value int) string {
	switch value {
	case 1:
		return "已注册"
	case 5:
		return "漫游注册"
	case 2:
		return "搜索中"
	case 3:
		return "注册被拒绝"
	default:
		return "未注册"
	}
}
