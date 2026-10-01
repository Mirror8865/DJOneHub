package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	moduleUpdateFormat      = 1
	moduleUpdatePlatform    = "qdc507-armv7-linux-3.18.44"
	moduleUpdateContentType = "application/vnd.djonehub.update+gzip"
	moduleUpdateMaxBytes    = 16 * 1024 * 1024
	moduleUpdateMarker      = agentDataDirectory + "/update-pending"
)

// moduleUpdateRestartScript 在模块端完成更新后显式重启 Agent，并确认健康接口恢复。
// 备份目录不会在这里删除，避免网络中断时丢失既有回滚材料。
const moduleUpdateRestartScript = `
backup="$1"
# 启动器会把 update-pending 视为“上次启动失败”的信号。新版本首次启动前必须先移除该
# 标记；否则刚安装的新 Agent 会被启动器立即回滚，永远没有机会通过健康检查。
rm -f /data/djonehub/update-pending
/etc/init.d/djonehub_agent stop >>/data/djonehub/log/update.log 2>&1
sleep 1
/etc/init.d/djonehub_agent start >>/data/djonehub/log/update.log 2>&1 || {
  printf '%s\n' "$backup" >/data/djonehub/update-pending
  /etc/init.d/djonehub_agent start >>/data/djonehub/log/update.log 2>&1 || true
  exit 1
}
count=0
while test "$count" -lt 20; do
  if busybox wget -q -T 4 -O - http://127.0.0.1:7575/api/health 2>/dev/null | grep -q '"ok":true'; then
    printf 'update-health-confirmed backup=%s\n' "$backup" >>/data/djonehub/log/update.log
    exit 0
  fi
  count=$((count + 1))
  sleep 1
done
# 健康检查超时才重新写入标记，随后交由既有启动器原子恢复上一版本。
printf '%s\n' "$backup" >/data/djonehub/update-pending
/etc/init.d/djonehub_agent stop >>/data/djonehub/log/update.log 2>&1 || true
sleep 1
/etc/init.d/djonehub_agent start >>/data/djonehub/log/update.log 2>&1 || true
printf 'update-health-timeout backup=%s\n' "$backup" >>/data/djonehub/log/update.log
exit 1
`

type moduleUpdateManifest struct {
	FormatVersion int                `json:"format_version"`
	Version       string             `json:"version"`
	Platform      string             `json:"platform"`
	Files         []moduleUpdateFile `json:"files"`
}

type moduleUpdateFile struct {
	Name   string `json:"name"`
	Target string `json:"target"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   uint32 `json:"mode"`
}

var moduleUpdateTargets = map[string]struct {
	target string
	mode   uint32
}{
	"qdc507-agent":            {target: "bin/qdc507-agent", mode: 0o755},
	"qdc507_data11_bridge.ko": {target: "kernel/qdc507_data11_bridge.ko", mode: 0o644},
	"qdc507_aprv3.ko":         {target: "voice-runtime/qdc507_aprv3.ko", mode: 0o644},
	"qdc507_voice.ko":         {target: "voice-runtime/qdc507_voice.ko", mode: 0o644},
	voiceHelperName:           {target: "voice-runtime/" + voiceHelperName, mode: 0o755},
}

func (a *agent) systemUpdate(response http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodGet {
		publicKey, err := moduleUpdatePublicKey()
		if err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		keyID := sha256.Sum256(publicKey)
		writeJSON(response, http.StatusOK, map[string]any{
			"supported": true, "format_version": moduleUpdateFormat,
			"platform": moduleUpdatePlatform, "installed_version": agentVersion,
			"public_key_id": hex.EncodeToString(keyID[:8]),
		})
		return
	}
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if mediaType := strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]); mediaType != moduleUpdateContentType {
		writeError(response, http.StatusUnsupportedMediaType, "模块更新包 Content-Type 无效")
		return
	}

	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	a.voice.mu.Lock()
	voiceActive := a.voice.command != nil || a.voice.routeCommand != nil
	a.voice.mu.Unlock()
	if callActive || voiceActive {
		writeError(response, http.StatusConflict, "通话或语音桥运行期间禁止更新模块")
		return
	}

	request.Body = http.MaxBytesReader(response, request.Body, moduleUpdateMaxBytes)
	temporary, err := os.CreateTemp("/data/local/tmp", "djonehub-update-*.tar.gz")
	if err != nil {
		writeError(response, http.StatusInternalServerError, "无法创建更新临时文件: "+err.Error())
		return
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err = io.Copy(temporary, request.Body); err != nil {
		temporary.Close()
		writeError(response, http.StatusBadRequest, "读取模块更新包失败: "+err.Error())
		return
	}
	if err = temporary.Sync(); err == nil {
		err = temporary.Close()
	} else {
		_ = temporary.Close()
	}
	if err != nil {
		writeError(response, http.StatusInternalServerError, "保存模块更新包失败: "+err.Error())
		return
	}

	manifest, err := verifyModuleUpdateArchive(temporaryPath)
	if err != nil {
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	if compareModuleVersions(manifest.Version, agentVersion) <= 0 {
		writeJSON(response, http.StatusOK, map[string]any{
			"updated": false, "version": agentVersion, "message": "模块已是相同或更高版本",
		})
		return
	}

	backupDirectory, err := installModuleUpdate(temporaryPath, manifest)
	if err != nil {
		writeError(response, http.StatusInternalServerError, "安装模块更新失败: "+err.Error())
		return
	}
	if err := os.WriteFile(moduleUpdateMarker, []byte(backupDirectory+"\n"), 0o600); err != nil {
		if rollbackErr := rollbackModuleUpdate(backupDirectory); rollbackErr != nil {
			writeError(response, http.StatusInternalServerError, fmt.Sprintf("写入更新确认标记失败: %v；回滚也失败: %v", err, rollbackErr))
			return
		}
		writeError(response, http.StatusInternalServerError, "写入更新确认标记失败，已回滚: "+err.Error())
		return
	}

	writeJSON(response, http.StatusOK, map[string]any{
		"updated": true, "version": manifest.Version, "restart_required": true,
		"message": "更新已验证并安装，模块代理正在安全重启",
	})
	go func() {
		time.Sleep(750 * time.Millisecond)
		// 不能只依赖 init 脚本的 restart 子命令：不同固件对 restart 的实现不一致，
		// 可能在旧进程尚未退出时直接返回。显式 stop/start 后轮询健康接口，
		// 让更新结果在 update.log 中可诊断；确认标记和备份仍保留给既有回滚流程。
		command := exec.Command("/bin/sh", "-c", moduleUpdateRestartScript, "djonehub-update", backupDirectory)
		_ = command.Start()
	}()
}

func moduleUpdatePublicKey() (ed25519.PublicKey, error) {
	decoded, err := base64.StdEncoding.DecodeString(moduleUpdatePublicKeyBase64)
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errors.New("模块更新公钥配置无效")
	}
	return ed25519.PublicKey(decoded), nil
}

func verifyModuleUpdateArchive(path string) (moduleUpdateManifest, error) {
	manifestData, signature, err := readModuleUpdateMetadata(path)
	if err != nil {
		return moduleUpdateManifest{}, err
	}
	publicKey, err := moduleUpdatePublicKey()
	if err != nil {
		return moduleUpdateManifest{}, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(publicKey, manifestData, signature) {
		return moduleUpdateManifest{}, errors.New("模块更新包签名无效")
	}

	decoder := json.NewDecoder(strings.NewReader(string(manifestData)))
	decoder.DisallowUnknownFields()
	var manifest moduleUpdateManifest
	if err := decoder.Decode(&manifest); err != nil {
		return moduleUpdateManifest{}, fmt.Errorf("模块更新清单无效: %w", err)
	}
	if err := validateModuleUpdateManifest(manifest); err != nil {
		return moduleUpdateManifest{}, err
	}
	return manifest, nil
}

func readModuleUpdateMetadata(path string) ([]byte, []byte, error) {
	reader, closeReader, err := openModuleUpdateArchive(path)
	if err != nil {
		return nil, nil, err
	}
	defer closeReader()

	manifestHeader, err := reader.Next()
	if err != nil || manifestHeader.Name != "manifest.json" || manifestHeader.Size <= 0 || manifestHeader.Size > 64*1024 {
		return nil, nil, errors.New("模块更新包必须以有效 manifest.json 开始")
	}
	manifestData, err := io.ReadAll(io.LimitReader(reader, manifestHeader.Size))
	if err != nil {
		return nil, nil, fmt.Errorf("读取模块更新清单失败: %w", err)
	}
	signatureHeader, err := reader.Next()
	if err != nil || signatureHeader.Name != "manifest.sig" || signatureHeader.Size != ed25519.SignatureSize {
		return nil, nil, errors.New("模块更新包缺少有效 manifest.sig")
	}
	signature, err := io.ReadAll(io.LimitReader(reader, signatureHeader.Size))
	if err != nil {
		return nil, nil, fmt.Errorf("读取模块更新签名失败: %w", err)
	}
	return manifestData, signature, nil
}

func openModuleUpdateArchive(path string) (*tar.Reader, func(), error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, func() {}, err
	}
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		file.Close()
		return nil, func() {}, fmt.Errorf("模块更新包不是有效 gzip: %w", err)
	}
	closeReader := func() {
		_ = gzipReader.Close()
		_ = file.Close()
	}
	return tar.NewReader(gzipReader), closeReader, nil
}

func validateModuleUpdateManifest(manifest moduleUpdateManifest) error {
	if manifest.FormatVersion != moduleUpdateFormat || manifest.Platform != moduleUpdatePlatform {
		return errors.New("模块更新包格式或硬件平台不匹配")
	}
	if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(manifest.Version) {
		return errors.New("模块更新版本号无效")
	}
	if len(manifest.Files) != len(moduleUpdateTargets) {
		return errors.New("模块更新包文件集合不完整")
	}
	seen := make(map[string]bool, len(manifest.Files))
	var totalSize int64
	for _, item := range manifest.Files {
		target, ok := moduleUpdateTargets[item.Name]
		if !ok || seen[item.Name] || item.Target != target.target || item.Mode != target.mode {
			return fmt.Errorf("模块更新文件 %q 的目标或权限无效", item.Name)
		}
		if item.Size <= 0 || item.Size > moduleUpdateMaxBytes || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(item.SHA256) {
			return fmt.Errorf("模块更新文件 %q 的大小或摘要无效", item.Name)
		}
		seen[item.Name] = true
		totalSize += item.Size
	}
	if totalSize > moduleUpdateMaxBytes {
		return errors.New("模块更新包解压后超过大小限制")
	}
	return nil
}

func installModuleUpdate(path string, manifest moduleUpdateManifest) (string, error) {
	stagingDirectory, err := os.MkdirTemp(agentDataDirectory, ".update-stage-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stagingDirectory)

	manifestFiles := make(map[string]moduleUpdateFile, len(manifest.Files))
	for _, item := range manifest.Files {
		manifestFiles[item.Name] = item
	}
	reader, closeReader, err := openModuleUpdateArchive(path)
	if err != nil {
		return "", err
	}
	defer closeReader()
	seen := make(map[string]bool, len(manifest.Files))
	for {
		header, nextErr := reader.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			return "", nextErr
		}
		if header.Name == "manifest.json" || header.Name == "manifest.sig" {
			continue
		}
		if header.Typeflag != tar.TypeReg || !strings.HasPrefix(header.Name, "payload/") {
			return "", fmt.Errorf("模块更新包包含不允许的归档项: %s", header.Name)
		}
		name := strings.TrimPrefix(header.Name, "payload/")
		item, ok := manifestFiles[name]
		if !ok || seen[name] || header.Size != item.Size {
			return "", fmt.Errorf("模块更新载荷 %q 不在清单中或大小不匹配", name)
		}
		destination := filepath.Join(stagingDirectory, name)
		file, createErr := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(item.Mode))
		if createErr != nil {
			return "", createErr
		}
		digest := sha256.New()
		_, copyErr := io.Copy(io.MultiWriter(file, digest), reader)
		syncErr := file.Sync()
		closeErr := file.Close()
		if copyErr != nil || syncErr != nil || closeErr != nil {
			return "", errors.Join(copyErr, syncErr, closeErr)
		}
		if hex.EncodeToString(digest.Sum(nil)) != item.SHA256 {
			return "", fmt.Errorf("模块更新载荷 %q 的 SHA-256 不匹配", name)
		}
		seen[name] = true
	}
	if len(seen) != len(manifest.Files) {
		return "", errors.New("模块更新包缺少清单中的载荷")
	}
	if output, err := exec.Command(filepath.Join(stagingDirectory, "qdc507-agent"), "--startup-probe", "runtime").CombinedOutput(); err != nil {
		return "", fmt.Errorf("新 Agent 启动探针失败: %v (%s)", err, strings.TrimSpace(string(output)))
	}
	if output, err := exec.Command(filepath.Join(stagingDirectory, voiceHelperName), "--check").CombinedOutput(); err != nil {
		return "", fmt.Errorf("新 PCM helper 自检失败: %v (%s)", err, strings.TrimSpace(string(output)))
	}

	backupDirectory := filepath.Join(agentDataDirectory, "backup", fmt.Sprintf("app-update-%d", time.Now().Unix()))
	if err := os.MkdirAll(backupDirectory, 0o700); err != nil {
		return "", err
	}
	installed := make([]moduleUpdateFile, 0, len(manifest.Files))
	for _, item := range manifest.Files {
		targetPath := filepath.Join(agentDataDirectory, item.Target)
		backupPath := filepath.Join(backupDirectory, item.Name)
		if err := os.Rename(targetPath, backupPath); err != nil {
			_ = restoreInstalledUpdateFiles(backupDirectory, installed)
			return "", fmt.Errorf("备份 %s 失败: %w", item.Name, err)
		}
		if err := os.Rename(filepath.Join(stagingDirectory, item.Name), targetPath); err != nil {
			_ = os.Rename(backupPath, targetPath)
			_ = restoreInstalledUpdateFiles(backupDirectory, installed)
			return "", fmt.Errorf("提交 %s 失败: %w", item.Name, err)
		}
		if err := os.Chmod(targetPath, os.FileMode(item.Mode)); err != nil {
			_ = restoreInstalledUpdateFiles(backupDirectory, append(installed, item))
			return "", fmt.Errorf("设置 %s 权限失败: %w", item.Name, err)
		}
		installed = append(installed, item)
	}
	return backupDirectory, nil
}

func restoreInstalledUpdateFiles(backupDirectory string, files []moduleUpdateFile) error {
	var restoreErrors []error
	for index := len(files) - 1; index >= 0; index-- {
		item := files[index]
		targetPath := filepath.Join(agentDataDirectory, item.Target)
		failedPath := targetPath + ".failed"
		_ = os.Remove(failedPath)
		if err := os.Rename(targetPath, failedPath); err != nil && !os.IsNotExist(err) {
			restoreErrors = append(restoreErrors, err)
		}
		if err := os.Rename(filepath.Join(backupDirectory, item.Name), targetPath); err != nil {
			restoreErrors = append(restoreErrors, err)
		}
	}
	return errors.Join(restoreErrors...)
}

func rollbackModuleUpdate(backupDirectory string) error {
	files := make([]moduleUpdateFile, 0, len(moduleUpdateTargets))
	for name, target := range moduleUpdateTargets {
		files = append(files, moduleUpdateFile{Name: name, Target: target.target})
	}
	return restoreInstalledUpdateFiles(backupDirectory, files)
}

func compareModuleVersions(left, right string) int {
	parse := func(value string) [3]int {
		var result [3]int
		parts := strings.Split(value, ".")
		for index := 0; index < len(result) && index < len(parts); index++ {
			result[index], _ = strconv.Atoi(parts[index])
		}
		return result
	}
	lhs, rhs := parse(left), parse(right)
	for index := range lhs {
		if lhs[index] < rhs[index] {
			return -1
		}
		if lhs[index] > rhs[index] {
			return 1
		}
	}
	return 0
}
