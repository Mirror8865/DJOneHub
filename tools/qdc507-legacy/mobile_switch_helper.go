// mobile_switch_helper 是一次性运行于 QDC507 的 USB 手机模式切换助手。
// 它必须脱离 ADB 会话运行，否则关闭 USB gadget 时 shell 会被连带终止。
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const (
	gadgetRoot      = "/sys/devices/virtual/android_usb/android0"
	enablePath      = gadgetRoot + "/enable"
	functionsPath   = gadgetRoot + "/functions"
	transportsPath  = gadgetRoot + "/f_serial/transports"
	mobileFunctions = "diag,ecm,ffs"
)

func readTrimmed(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func writeValue(path, value string) error {
	if err := os.WriteFile(path, []byte(value+"\n"), 0); err != nil {
		return fmt.Errorf("写入 %s=%q 失败: %w", path, value, err)
	}
	return nil
}

func containsFunction(functions, target string) bool {
	for _, item := range strings.Split(functions, ",") {
		if strings.TrimSpace(item) == target {
			return true
		}
	}
	return false
}

func validateOriginal(functions string) error {
	// 只允许从已知的 ECM + ADB 组合切换，避免误改未知固件配置。
	for _, required := range []string{"diag", "ecm", "ffs"} {
		if !containsFunction(functions, required) {
			return fmt.Errorf("当前 USB functions=%q 缺少 %s，拒绝切换", functions, required)
		}
	}
	if !containsFunction(functions, "serial") && !containsFunction(functions, "audio") {
		return fmt.Errorf("当前 USB functions=%q 已不是 Mac 组合，拒绝重复切换", functions)
	}
	return nil
}

func restore(original string) {
	// 回滚是尽力而为；每一步都写日志，方便模块重新接回后诊断。
	fmt.Printf("切换失败，尝试恢复原组合 %s\n", original)
	_ = writeValue(enablePath, "0")
	time.Sleep(time.Second)
	_ = writeValue(transportsPath, "tty")
	_ = writeValue(functionsPath, original)
	_ = writeValue(enablePath, "1")
}

func run() (err error) {
	original, err := readTrimmed(functionsPath)
	if err != nil {
		return fmt.Errorf("读取当前 USB functions 失败: %w", err)
	}
	fmt.Printf("当前 USB functions=%s\n", original)
	if original == mobileFunctions {
		fmt.Println("模块已经是手机模式，直接启动 DJOneHub Agent")
	} else {
		if err := validateOriginal(original); err != nil {
			return err
		}

		changed := false
		defer func() {
			if err != nil && changed {
				restore(original)
			}
		}()

		fmt.Println("关闭 USB gadget")
		if err = writeValue(enablePath, "0"); err != nil {
			return err
		}
		changed = true
		time.Sleep(time.Second)

		fmt.Printf("写入手机模式 functions=%s\n", mobileFunctions)
		if err = writeValue(transportsPath, "tty"); err != nil {
			return err
		}
		if err = writeValue(functionsPath, mobileFunctions); err != nil {
			return err
		}
		if err = writeValue(enablePath, "1"); err != nil {
			return err
		}
		time.Sleep(3 * time.Second)

		current, readErr := readTrimmed(functionsPath)
		if readErr != nil {
			return fmt.Errorf("复核 USB functions 失败: %w", readErr)
		}
		if current != mobileFunctions {
			return fmt.Errorf("USB functions 复核不一致: got=%q want=%q", current, mobileFunctions)
		}
		fmt.Printf("USB 手机模式已生效: %s\n", current)
	}

	fmt.Println("启动 DJOneHub Agent")
	command := exec.Command("/etc/init.d/djonehub_agent", "start")
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err = command.Run(); err != nil {
		return fmt.Errorf("启动 DJOneHub Agent 失败: %w", err)
	}
	fmt.Println("手机模式切换完成")
	return nil
}

func main() {
	// ADB gadget 被关闭时忽略挂断信号，保证后续重枚举和 Agent 启动能够完成。
	signal.Ignore(syscall.SIGHUP)
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}
}
