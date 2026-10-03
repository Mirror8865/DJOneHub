package main

import (
	"bytes"
	"io"
	"log"
	"os"
	"time"
)

const (
	// init 脚本用 `>>` 把 Agent 的 stdout/stderr 重定向到这个文件。
	agentLogPath = "/data/djonehub/log/agent.log"
	// 模块的 /data 与 /cache、/usrdata 是同一个约 15 MB 的 UBIFS 卷：
	// 日志不设上限会在几天内写满存储，写满后 Agent 起不来，App 也就认不到模块。
	agentLogMaxBytes  = 512 * 1024
	agentLogKeepBytes = 64 * 1024
	agentLogInterval  = 60 * time.Second
)

// startLogCap 周期性地把超限的 Agent 日志截断到末尾若干字节。
//
// 运行中的 Agent 用一个 O_APPEND 的 fd 写日志（由 init 脚本的 `>>` 建立）。
// 这里用独立的 fd 原地截断再写回尾部：不需要重启 Agent，也不会打断写入，
// 因为 O_APPEND 的每次写入都落在文件末尾。
func startLogCap(logger *log.Logger) {
	go func() {
		for {
			rotated, err := capLogFile(agentLogPath, agentLogMaxBytes, agentLogKeepBytes)
			switch {
			case err != nil:
				logger.Printf("日志截断失败: %v", err)
			case rotated:
				logger.Printf(
					"日志超过 %d KB，已截断并保留末尾 %d KB",
					agentLogMaxBytes/1024, agentLogKeepBytes/1024,
				)
			}
			time.Sleep(agentLogInterval)
		}
	}()
}

// capLogFile 在 path 超过 maxBytes 时只保留末尾 keepBytes 字节，返回是否发生了截断。
// 文件不存在时按“还没有日志”处理，不报错。
func capLogFile(path string, maxBytes, keepBytes int64) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if info.Size() <= maxBytes {
		return false, nil
	}
	if keepBytes < 1 || keepBytes > maxBytes {
		keepBytes = maxBytes / 2
	}

	source, err := os.Open(path)
	if err != nil {
		return false, err
	}
	tail := make([]byte, keepBytes)
	read, readErr := source.ReadAt(tail, info.Size()-keepBytes)
	source.Close()
	if readErr != nil && readErr != io.EOF {
		return false, readErr
	}
	tail = tail[:read]
	// 从行首开始保留，避免留下半行日志。
	if index := bytes.IndexByte(tail, '\n'); index >= 0 {
		tail = tail[index+1:]
	}

	truncated, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC|os.O_APPEND, 0o600)
	if err != nil {
		return false, err
	}
	if _, err := truncated.Write(tail); err != nil {
		truncated.Close()
		return false, err
	}
	if err := truncated.Sync(); err != nil {
		truncated.Close()
		return false, err
	}
	return true, truncated.Close()
}