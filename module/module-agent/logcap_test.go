package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeLog(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("写入测试日志失败: %v", err)
	}
}

func TestCapLogFileKeepsSmallLogUntouched(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.log")
	content := strings.Repeat("一行日志\n", 200)
	writeLog(t, path, content)

	rotated, err := capLogFile(path, 1<<20, 1<<10)
	if err != nil {
		t.Fatalf("截断返回错误: %v", err)
	}
	if rotated {
		t.Fatal("未超限时不应截断")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取日志失败: %v", err)
	}
	if string(after) != content {
		t.Fatal("未超限时日志内容不应变化")
	}
}

func TestCapLogFileKeepsOnlyTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.log")
	var builder strings.Builder
	for index := 0; index < 8000; index++ {
		fmt.Fprintf(&builder, "line-%05d-abcdefghijklmnopqrstuvwxyz\n", index)
	}
	writeLog(t, path, builder.String())

	rotated, err := capLogFile(path, 64*1024, 8*1024)
	if err != nil {
		t.Fatalf("截断返回错误: %v", err)
	}
	if !rotated {
		t.Fatal("超过上限应当截断")
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("读取日志大小失败: %v", err)
	}
	if info.Size() > 64*1024 {
		t.Fatalf("截断后仍有 %d 字节，超过上限", info.Size())
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取日志失败: %v", err)
	}
	text := string(after)
	if !strings.HasSuffix(text, "line-07999-abcdefghijklmnopqrstuvwxyz\n") {
		t.Fatal("应当保留最新一行日志")
	}
	if strings.Contains(text, "line-00000-") {
		t.Fatal("最旧的日志应当被丢弃")
	}
	if !strings.HasSuffix(text, "\n") {
		t.Fatal("保留的尾部应当以完整行结束")
	}
}

func TestCapLogFileMissingFileIsNoop(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.log")
	rotated, err := capLogFile(path, 1024, 256)
	if err != nil {
		t.Fatalf("文件不存在不应报错: %v", err)
	}
	if rotated {
		t.Fatal("文件不存在时不应截断")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("不应创建日志文件")
	}
}