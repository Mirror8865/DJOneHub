# 发布附件：QDC507 Agent 0.3.21

此目录仅用于在本机暂存正式发布包，不会被 Git 提交。

待上传至私有 GitHub Release 的文件：

- 文件名：`module-update-0.3.21.djupdate`
- Agent 版本：`0.3.21`
- 平台：`qdc507-armv7-linux-3.18.44`
- SHA-256：`b3554ad426a623e18dead9b80cfc3356d41f70934b99d0531dcf8dd3e2a17e2b`

上传前在仓库根目录执行：

```sh
shasum -a 256 release-assets/module-update-0.3.21.djupdate
```

输出必须与上面的 SHA-256 完全一致。该包带有签名清单；签名私钥不在本仓库，也绝不能上传。

若需要构建 iPhone/iPad App，上传或下载后还须复制该文件到：

```text
iPadOS/DJOneHub-iPad/Resources/module-update.djupdate
```

该副本同样受 Git 忽略，只用于本地 Xcode 打包。
