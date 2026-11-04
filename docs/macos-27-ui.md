# macOS 27 原生界面

OneClick 使用 Xcode 27 / macOS 27 SDK 构建，主应用、Finder 扩展和测试的最低部署版本均为 macOS 27.0（Golden Gate）。界面继续使用 SwiftUI，未引入第三方 UI 库。应用入口、设置窗口与设置视图显式标注 `@available(macOS 27, *)`。

## 导航与窗口

- `SettingsView` 使用 `NavigationSplitView` 和 `List(selection:)` / `.listStyle(.sidebar)`，由系统提供选中态、键盘导航和侧栏材质。删除原来的品牌栏、彩色色块按钮和外层留白，侧栏列直接贴合窗口边缘；系统行内边距仍保留。
- `SettingsWindow` 使用 `.windowToolbarStyle(.unified)`，原生窗口外框和工具栏自动采用当前系统外观。工具栏保留系统侧栏开关；主界面仅提供设置和设置导航，不提供打开压缩包、创建归档等操作。
- 删除根视图不透明的 `windowBackgroundColor` 覆盖和内容区顶部额外安全区内边距，让系统处理窗口背景与工具栏衔接。各设置页继续使用系统 grouped Form。
- 窗口最小尺寸为 880 × 620，默认 1000 × 720。首页内容面板统一使用 10 pt 连续布局圆角，减少卡片嵌套。

窗口**外框**圆角由 macOS 决定，本次没有强行修改其半径。未采用私有窗口 API、无边框窗口或 `NSWindow` 内容层裁切；这些方式会影响系统阴影、交通灯或缩放行为。10 pt 仅应用于自有内容面板，不代表外框半径。

## 功能分类

侧栏按三大功能分组，首页保留在顶部，通用和关于作为应用级入口放在底部。

- 右键增强：操作、应用、新建文件、常用文件夹、图标样式。图标样式不再出现在通用页。
- 压缩解压：设置页包含文件关联、压缩参数、排除规则和归档右键菜单。
- 输入法切换：设置页包含自动切换、默认输入法、应用规则与记忆选项。

## 玻璃与菜单

首页、压缩解压设置页和工具栏不提供归档操作按钮或菜单。压缩和解压操作通过 Finder 右键菜单触发，压缩包浏览通过打开关联文件触发。

玻璃集中用于导航和操作控件。首页文字与工具列表使用普通语义背景和分隔线，避免多层透明表面影响可读性。没有硬编码白色文字、背景模糊或玻璃透明度，材质随系统外观与辅助功能设置呈现。

侧栏使用单色 SF Symbols；菜单栏应用菜单中的命令只保留文字。首页工具行仅跳转设置，支持悬停、按下和原生按钮键盘焦点。

## 与旧版的视觉差异

| 对比对象 | 本次变化 |
| --- | --- |
| 仓库此前的自绘界面 | 彩色图标底块改为单色符号；独立大卡片改为紧凑分组；内容圆角从 14–18 pt 收到 10 pt；侧栏去除额外包装和品牌区。 |
| macOS 15 的传统外观 | 导航与操作控件由 macOS 27 原生渲染，使用 Liquid Glass；不再依靠传统磨砂或自绘半透明背景模拟。 |
| macOS 26 | Liquid Glass 已在 macOS 26 引入，相关玻璃按钮和容器 API 也来自 26；本次在 Xcode 27 SDK 上采用，并交由 macOS 27 渲染，不把这些 API 误称为 27 首次引入。 |

按项目要求，本版本不支持在 macOS 26 或更早系统运行，因此没有旧版视觉降级分支。

## 验证

构建命令：

```sh
xcodebuild build -project OneClick.xcodeproj -scheme OneClick \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

本机 Xcode 27.0 / macOS 27.2 已完成构建和测试：98 个测试通过（含参数展开共 173 次运行），两个语言目录的西班牙语、日语、简体中文和法语检查通过。

首页、系统侧栏和归档菜单使用实际视图源码搭建独立预览，以示例数据检查浅色 1000 × 720 与深色紧凑布局。预览中的服务为占位实现，不读写真实配置；它只验证视觉布局和导航绑定，不代表归档业务集成测试。

本地安装脚本和 CI 均检查 macOS SDK 主版本不低于 27。CI 选择 runner 中最新安装的 Xcode；runner 必须提供 Xcode 27 或更新版本，执行测试还需要 macOS 27 或更新版本。工作流尚需在 GitHub 上实际运行验证。

## Apple 官方参考

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
