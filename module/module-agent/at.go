package main

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
)

// atPort 串行化所有基带请求。SMD AT 通道不支持并发交错命令。
type atPort struct {
	path string
	mu   sync.Mutex
	file *os.File
}

func newATPort(path string) *atPort {
	return &atPort{path: path}
}

func (p *atPort) open() error {
	if p.file != nil {
		return nil
	}
	fd, err := syscall.Open(p.path, syscall.O_RDWR|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("打开 AT 端口失败: %w", err)
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		_ = syscall.Close(fd)
		return fmt.Errorf("设置 AT 端口非阻塞模式失败: %w", err)
	}
	p.file = os.NewFile(uintptr(fd), p.path)
	return nil
}

func (p *atPort) close() error {
	if p.file == nil {
		return nil
	}
	err := p.file.Close()
	p.file = nil
	return err
}

// command 发送普通 AT 指令并等待 OK/ERROR 终止行。
func (p *atPort) command(command string, timeout time.Duration) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.open(); err != nil {
		return "", err
	}
	if strings.ContainsAny(command, "\r\n\x00") {
		return "", errors.New("AT 指令包含非法控制字符")
	}
	isCCHO := strings.HasPrefix(command, "AT+CCHO=")
	if isCCHO {
		log.Printf("AT CCHO 阶段: 端口已打开")
	}
	p.drain()
	if isCCHO {
		log.Printf("AT CCHO 阶段: 缓冲已清理")
	}
	if err := p.writeAll([]byte(command+"\r"), 5*time.Second); err != nil {
		return "", fmt.Errorf("写入 AT 指令失败: %w", err)
	}
	if isCCHO {
		log.Printf("AT CCHO 阶段: 指令已写入")
	}
	response, err := p.readUntil(timeout, func(buffer []byte) bool {
		return hasTerminalResult(buffer)
	})
	if err != nil {
		return string(response), err
	}
	if isCCHO {
		log.Printf("AT CCHO 阶段: 已收到终止响应")
	}
	text := normalizeATText(response)
	if hasATError(text) {
		return text, fmt.Errorf("AT 指令失败: %s", lastNonEmptyLine(text))
	}
	return text, nil
}

// promptCommand 处理 AT+CMGS 这类先返回提示符、再接收载荷的交互命令。
func (p *atPort) promptCommand(command string, payload []byte, timeout time.Duration) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.open(); err != nil {
		return "", err
	}
	p.drain()
	if err := p.writeAll([]byte(command+"\r"), 5*time.Second); err != nil {
		return "", err
	}
	prompt, err := p.readUntil(5*time.Second, func(buffer []byte) bool {
		return bytes.Contains(buffer, []byte(">")) || hasTerminalResult(buffer)
	})
	if err != nil {
		return string(prompt), fmt.Errorf("等待短信输入提示符失败: %w", err)
	}
	if !bytes.Contains(prompt, []byte(">")) {
		return normalizeATText(prompt), errors.New("模块未返回短信输入提示符")
	}
	if err := p.writeAll(payload, 10*time.Second); err != nil {
		return "", err
	}
	response, err := p.readUntil(timeout, func(buffer []byte) bool {
		return hasTerminalResult(buffer)
	})
	text := normalizeATText(response)
	if err != nil {
		return text, err
	}
	if hasATError(text) {
		return text, fmt.Errorf("短信发送失败: %s", lastNonEmptyLine(text))
	}
	return text, nil
}

// writeAll 直接使用非阻塞 fd 写入，并给字符设备背压设置硬截止时间。
func (p *atPort) writeAll(payload []byte, timeout time.Duration) error {
	if p.file == nil {
		return errors.New("AT 端口尚未打开")
	}
	deadline := time.Now().Add(timeout)
	for len(payload) > 0 {
		written, err := syscall.Write(int(p.file.Fd()), payload)
		if written > 0 {
			payload = payload[written:]
			continue
		}
		if err != nil && !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EWOULDBLOCK) {
			return err
		}
		if time.Now().After(deadline) {
			return errors.New("等待 AT 端口可写超时")
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil
}

func (p *atPort) readUntil(timeout time.Duration, complete func([]byte) bool) ([]byte, error) {
	deadline := time.Now().Add(timeout)
	buffer := make([]byte, 0, 4096)
	temporary := make([]byte, 1024)
	for time.Now().Before(deadline) {
		count, err := syscall.Read(int(p.file.Fd()), temporary)
		if count > 0 {
			buffer = append(buffer, temporary[:count]...)
			if len(buffer) > 256*1024 {
				return buffer, errors.New("AT 响应超过安全上限")
			}
			if complete(buffer) {
				return buffer, nil
			}
		}
		if err != nil && !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EWOULDBLOCK) {
			return buffer, fmt.Errorf("读取 AT 响应失败: %w", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	return buffer, errors.New("等待 AT 响应超时")
}

// drain 清走上次命令残留和异步 URC；呼叫与短信状态由专门轮询恢复。
// SMD 端口可能持续输出 URC，因此必须同时限制时间和字节数，不能等待“绝对安静”。
func (p *atPort) drain() {
	if p.file == nil {
		return
	}
	temporary := make([]byte, 1024)
	deadline := time.Now().Add(100 * time.Millisecond)
	drained := 0
	for time.Now().Before(deadline) && drained < 64*1024 {
		count, err := syscall.Read(int(p.file.Fd()), temporary)
		drained += count
		if count == 0 || err != nil {
			return
		}
	}
}

func hasTerminalResult(buffer []byte) bool {
	normalized := strings.ReplaceAll(string(buffer), "\r", "")
	return strings.Contains(normalized, "\nOK\n") ||
		strings.Contains(normalized, "\nERROR\n") ||
		strings.Contains(normalized, "\n+CME ERROR:") ||
		strings.Contains(normalized, "\n+CMS ERROR:")
}

func normalizeATText(value []byte) string {
	text := strings.ReplaceAll(string(value), "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	lines := strings.Split(text, "\n")
	clean := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" {
			clean = append(clean, line)
		}
	}
	return strings.Join(clean, "\n")
}

func hasATError(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		if line == "ERROR" || strings.HasPrefix(line, "+CME ERROR:") || strings.HasPrefix(line, "+CMS ERROR:") {
			return true
		}
	}
	return false
}

func lastNonEmptyLine(text string) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) == 0 {
		return "未知错误"
	}
	return lines[len(lines)-1]
}
