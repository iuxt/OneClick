# 通过 tag 自动发布

工作流：[`release.yml`](../.github/workflows/release.yml)。推送 `v*` tag 后自动构建并发布到 GitHub Releases，普通分支 push 不触发发布。

## 无需 Apple 证书

当前流程使用 **ad-hoc 本地签名**，不需要付费 Apple 开发者账号、签名证书、provisioning profile 或公证 API 密钥，也不需要配置之前的 8 项 Apple Secrets。

仓库需要启用 GitHub Actions。发布使用 GitHub 自动提供的 `GITHUB_TOKEN`，通过工作流的 `contents: write` 权限创建 Release 和上传附件，无需额外配置 GitHub PAT。如果组织策略限制此权限，需要仓库或组织管理员允许。

应用与 Finder 扩展保留沙盒，编译时启用 `RC_LOCAL_BUILD`，使用明确授权的 `~/Library/Application Support/RClickLocal/` 存储数据库和启动标记，不依赖需要 Apple 授权的 App Group。菜单设置由主应用保存，通过 IPC 同步给扩展。此版本与 Developer ID 签名版本使用独立设置，不迁移或覆盖原 App Group 数据。

## 发布命令

先提交并推送需要发布的代码及工作流，再创建 tag：

```bash
git push origin HEAD
git tag -a v2.3.4 -m "Release v2.3.4"
git push origin v2.3.4
```

tag 可以指向任意分支的提交，构建内容以 tag 指向的提交为准；该提交必须包含发布工作流。

| tag 示例 | 发布类型 | 应用内版本号 |
| --- | --- | --- |
| `v2.3.4` | 正式 Release | `2.3.4` |
| `v2.4.0-alpha.1` | Pre-release | `2.4.0` |
| `v2.4.0-beta.2` | Pre-release | `2.4.0` |
| `v2.4.0-rc.1` | Pre-release | `2.4.0` |

版本格式限定为 `vX.Y.Z` 或 `vX.Y.Z-{alpha,beta,rc}.N`，数字不允许多余的前导零。其他以 `v` 开头的 tag 会触发工作流，但在校验步骤失败。应用和扩展的版本号由 tag 自动覆盖，无需手动修改项目中的 `MARKETING_VERSION`；构建号使用 UTC 构建时间。附件名称保留完整版本后缀。

## 流程与产物

1. 使用 `macos-15` runner 和 Xcode 26.3，校验 tag。
2. 编译 Release，目标为 **Apple Silicon（arm64），macOS 15.6+**。
3. 为扩展和主应用生成本地 entitlement、移除 App Group 声明，依次执行 ad-hoc 签名，验证签名完整性。
4. 创建 DMG、应用 ZIP 及 SHA-256 校验文件。
5. 发布 GitHub Release，自动生成更新说明并附上首次安装说明。

以 `v2.3.4` 为例，Release 包含：

```text
OneClick-v2.3.4.dmg
OneClick-v2.3.4.dmg.sha256
OneClick-v2.3.4.app.zip
OneClick-v2.3.4.app.zip.sha256
```

构建、签名和打包成功后才执行发布步骤。构建及打包日志单独保存在 Actions 的 `release-logs-*` artifact 中，保留 14 天，整个 job 上限为 30 分钟。

## 首次安装

此版本没有 Apple Developer ID 签名或 Apple 公证，首次打开可能被 Gatekeeper 拦截。下载 DMG 后将应用拖入 Applications，尝试启动一次，再根据 [Apple 官方说明](https://support.apple.com/en-gb/102445)，在 **系统设置 → 隐私与安全性 → 仍要打开** 中允许该应用。随后在系统设置中启用 OneClick 的 Finder 扩展。

## 失败与重试

- 失败会保留 tag。临时构建或网络故障恢复后，可进入 **Actions → 对应运行 → Re-run all jobs** 重试。
- 重跑仍会使用原 tag 中的代码和工作流。旧的 `v2.3.3` 仍依赖 Apple Secrets；本次无证书工作流从 `v2.3.4` 开始生效。
- 修改源码或工作流后，应提交修复并创建新的版本 tag。
- 若在上传附件时失败，Release 可能已经创建；重跑会更新同 tag 的 Release 及附件。

工作流及依赖行为参考：[GitHub Actions 工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)、[macOS runner 工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)、[Release action](https://github.com/softprops/action-gh-release)。
