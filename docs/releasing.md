# 通过 tag 自动发布

工作流：[`release.yml`](../.github/workflows/release.yml)。推送 `v*` tag 后自动执行，普通分支 push 不触发发布。

## 首次配置

在目标 GitHub 仓库的 **Settings → Secrets and variables → Actions → Repository secrets** 中配置：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application 证书及私钥导出的 `.p12`，经过 Base64 编码 |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时设置的非空密码 |
| `MACOS_APP_PROVISIONING_PROFILE` | 主应用的 Developer ID provisioning profile，经过 Base64 编码 |
| `MACOS_EXTENSION_PROVISIONING_PROFILE` | FinderSync 扩展的 Developer ID provisioning profile，经过 Base64 编码 |
| `APPLE_TEAM_ID` | 证书及两个 profile 所属的 Apple Developer Team ID |
| `NOTARY_KEY_ID` | App Store Connect 团队 API 密钥的 Key ID，用于 `notarytool` |
| `NOTARY_ISSUER_ID` | 上述 API 密钥的 Issuer ID |
| `NOTARY_PRIVATE_KEY` | 上述 API 密钥的 `.p8` 原文，包含头尾标记并保留换行；不做 Base64 编码 |

将文件编码并复制到剪贴板，例如：

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i RClick.provisionprofile | pbcopy
base64 -i FinderSyncExt.provisionprofile | pbcopy
```

签名证书必须包含私钥，并且是 **Developer ID Application**，不能用 Apple Development 或 Developer ID Installer 证书替代。导入的 `.p12` 应只包含一个有效的 Developer ID Application 签名身份。

两个 profile 必须分别匹配以下标识，授权同一个 App Group，并包含所使用的签名证书：

| 用途 | 标识 |
| --- | --- |
| 主应用 | `cn.wflixu.RClick` |
| FinderSync 扩展 | `cn.wflixu.RClick.FinderSyncExt` |
| App Group | `group.cn.wflixu.RClick` |

如果使用自己的 Apple Developer Team，需要在 Apple Developer 后台注册有权使用的 Bundle ID 和 App Group，并一致更新 Xcode 项目、两份 entitlement、共享代码以及工作流顶部的相关标识。发布构建使用 App Group 存储，因此需要上述证书及 profile。

仓库还需要启用 GitHub Actions。工作流使用 GitHub 自动提供的 `GITHUB_TOKEN`，通过 `contents: write` 创建 Release 和上传附件，无需额外配置 GitHub PAT。如果组织策略限制此权限，需要仓库或组织管理员允许。

## 发布命令

先提交需要发布的代码及工作流，并将提交推送到目标仓库，再创建 tag：

```bash
git push origin HEAD
git tag -a v2.3.3 -m "Release v2.3.3"
git push origin v2.3.3
```

tag 可以指向任意分支的提交，构建内容以 tag 指向的提交为准；该提交必须包含发布工作流。

| tag 示例 | 发布类型 | 应用内版本号 |
| --- | --- | --- |
| `v2.3.3` | 正式 Release | `2.3.3` |
| `v2.4.0-alpha.1` | Pre-release | `2.4.0` |
| `v2.4.0-beta.2` | Pre-release | `2.4.0` |
| `v2.4.0-rc.1` | Pre-release | `2.4.0` |

版本格式限定为 `vX.Y.Z` 或 `vX.Y.Z-{alpha,beta,rc}.N`，数字不允许多余的前导零。其他以 `v` 开头的 tag 会触发工作流，但在校验步骤失败。应用和扩展的版本号由 tag 自动覆盖，无需手动修改项目中的 `MARKETING_VERSION`；构建号使用构建时间。附件名称保留完整版本后缀。

预发布示例：

```bash
git tag -a v2.4.0-rc.1 -m "Release candidate v2.4.0-rc.1"
git push origin v2.4.0-rc.1
```

## 流程与产物

1. 使用 `macos-15` runner 和 Xcode 26.3，校验 tag 及必需的 Secrets。
2. 检查证书和两份 profile 的有效期、Bundle ID、Team、App Group 及证书匹配关系。
3. 编译 Release，目标为 **Apple Silicon（arm64），macOS 15.6+**。
4. 为 FinderSync 扩展和主应用嵌入 profile，依次签名并验证完整性。
5. 将应用提交 Apple 公证，成功后装订公证票据。
6. 创建、签名和公证 DMG，同时生成带公证票据的应用 ZIP。
7. 生成 SHA-256 校验文件，发布 GitHub Release，自动生成更新说明。

以 `v2.3.3` 为例，Release 包含：

```text
RClick-v2.3.3.dmg
RClick-v2.3.3.dmg.sha256
RClick-v2.3.3.app.zip
RClick-v2.3.3.app.zip.sha256
```

签名、公证和打包成功后才执行发布步骤。日志单独保存在 Actions 的 `release-logs-*` artifact 中，保留 14 天。临时钥匙串、证书、profile 和公证私钥会在结束时清理。

## 失败与重试

- 缺少 Secrets、profile 过期或签名身份不匹配时，会在对应校验步骤报错。
- 公证被拒绝时，查看 Actions 日志及 `notarization-*.json` / `notarization-*.log`。单次公证等待上限为 20 分钟，整个 job 上限为 60 分钟。
- 失败会保留 tag。在修复 Secrets 或临时服务故障后，进入 **Actions → 对应运行 → Re-run all jobs**，无需删除或重建 tag。
- 重跑时仍会构建原 tag 指向的提交。如果需要修改源码或工作流，请提交修复并发布新的版本 tag。
- 若在上传附件时失败，Release 可能已经创建；重跑会更新同 tag 的 Release 及附件。

工作流及依赖行为参考：[GitHub Actions 工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)、[macOS runner 工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)、[Release action](https://github.com/softprops/action-gh-release)。
