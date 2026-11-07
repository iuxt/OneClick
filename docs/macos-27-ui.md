# macOS 27 原生界面

OneClick 使用 Xcode 27 / macOS 27 SDK 构建，主应用、Finder 扩展和测试的最低部署版本均为 macOS 27.0（Golden Gate）。界面继续使用 SwiftUI，未引入第三方 UI 库。应用入口、设置窗口与设置视图显式标注 `@available(macOS 27, *)`。

## 导航与窗口

- `SettingsView` 使用顶部功能模块 Tab。一级 Tab 在右键增强、压缩解压、输入法切换和通用之间切换；右键增强和通用模块使用原生分段控件显示二级 Tab，避免把所有设置入口平铺成同一层级。
- `SettingsWindow` 使用 `.windowToolbarStyle(.unifiedCompact)`，原生窗口外框和工具栏自动采用当前系统外观。主界面仅提供设置和设置导航，不提供打开压缩包、创建归档等操作。
- 删除根视图不透明的 `windowBackgroundColor` 覆盖和内容区顶部额外安全区内边距，让系统处理窗口背景与工具栏衔接。各设置页继续使用系统 grouped Form。
- 设置窗口最小尺寸为 860 × 600，默认 960 × 680，为顶部模块 Tab 和多语言标题保留稳定空间。压缩、校验和短文件任务使用内容自适应的紧凑窗口，不再为任务进度保留固定的大块空白。

窗口**外框**圆角由 macOS 决定，本次没有强行修改其半径。未采用私有窗口 API、无边框窗口或 `NSWindow` 内容层裁切；这些方式会影响系统阴影、交通灯或缩放行为。10 pt 仅应用于自有内容面板，不代表外框半径。

## 功能分类

设置入口按五个一级功能模块组织，模块内相关页面通过二级 Tab 切换。切换模块时会记住该模块上次打开的二级页面。

- 右键增强：操作、应用、新建文件、常用文件夹。图标样式合并至应用页，并提供跟随选择变化的菜单预览。
- 压缩解压：设置页包含文件关联、压缩参数、排除规则和归档右键菜单。
- 输入法切换：设置页包含自动切换、默认输入法、应用规则与记忆选项。
- 通用：包含应用级设置和关于页面。

压缩解压和输入法切换的页面标题分别命名为“压缩解压设置”和“输入法设置”，避免出现两个同名的“设置”。右键增强的计数仅包含普通操作页中已启用的操作，不计入压缩解压操作。

## 设置交互

- 新建文件的“恢复默认”先确认，并明确说明自定义类型和模板等配置会被替换。取消不写入配置。
- 压缩解压页底部使用独立的“重置压缩解压设置…”入口，说明会重置压缩参数、排除规则和归档菜单，并保留文件关联；执行前再次确认。
- 常用文件夹显示完整路径的副标题，长路径在中间截断并支持悬停查看，便于区分同名目录。
- Finder 扩展显示文字状态，不只依赖图标和颜色。新建文件后仅在 Finder 中选中，不自动进入重命名，也不请求设备控制和数据访问权限。
- 文件类型图标通过带图形的菜单选择备用图标，不再要求手填 SF Symbol 名称。预览采用与列表相同的图标来源：所选应用优先，其次文件类型图标，最后使用备用图标。
- 打开设置的请求由设置 Scene 持有的 `SettingsWindowRequests` 接收。接收器独立于菜单栏图标和窗口内容，隐藏图标、关闭窗口后再次打开应用仍能调出设置。

## 玻璃与菜单

首页、压缩解压设置页和工具栏不提供归档操作按钮或菜单。压缩和解压操作通过 Finder 右键菜单触发，压缩包浏览通过打开关联文件触发。

玻璃集中用于导航和操作控件。任务内容直接融入窗口，不再在进度条外嵌套玻璃卡片；标题栏使用透明材质并去除额外分隔层。设置页文字与工具列表使用普通语义背景和系统分组，避免多层透明表面影响可读性。没有硬编码白色文字、背景模糊或玻璃透明度，材质随系统外观与辅助功能设置呈现。

模块和页面 Tab 使用单色 SF Symbols；菜单栏应用菜单中的命令只保留文字。一级 Tab 支持悬停、按下和原生按钮键盘焦点，二级 Tab 使用系统分段控件。

## 与旧版的视觉差异

| 对比对象 | 本次变化 |
| --- | --- |
| 仓库此前的自绘界面 | 彩色图标底块改为单色符号；独立大卡片改为紧凑分组；内容圆角从 14–18 pt 收到 10 pt；侧栏去除额外包装和品牌区。 |
| macOS 15 的传统外观 | 导航与操作控件由 macOS 27 原生渲染，使用 Liquid Glass；不再依靠传统磨砂或自绘半透明背景模拟。 |
| macOS 26 | Liquid Glass 已在 macOS 26 引入，相关玻璃按钮和容器 API 也来自 26；本次在 Xcode 27 SDK 上采用，并交由 macOS 27 渲染，不把这些 API 误称为 27 首次引入。 |

按项目要求，本版本不支持在 macOS 26 或更早系统运行，因此没有旧版视觉降级分支。

## 验证

2026-11-05 的设置交互修复通过 Debug 构建、`SettingsNavigationTests` 与 `InteractionRegressionTests` 共 8 个测试，以及两个语言目录的西班牙语、日语、简体中文和法语检查。

独立预览直接加载构建后的实际设置视图，使用独立偏好设置和内存数据库，检查浅色、深色与最小内容尺寸 820 × 560。已核对恢复默认提示、取消后保留自定义类型、备用图标选择、菜单图标预览、同名目录路径、权限文字状态，以及未显示菜单栏图标时关闭窗口后的重新打开路径。

构建命令：

```sh
xcodebuild build -project OneClick.xcodeproj -scheme OneClick \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

本机 Xcode 27.0 / macOS 27.2 已完成构建和测试：98 个测试通过（含参数展开共 173 次运行），两个语言目录的西班牙语、日语、简体中文和法语检查通过。

首页、系统侧栏和归档菜单使用实际视图源码搭建独立预览，以示例数据检查浅色 900 × 640 与深色紧凑布局。预览中的服务为占位实现，不读写真实配置；它只验证视觉布局和导航绑定，不代表归档业务集成测试。

本地安装脚本和 CI 均检查 macOS SDK 主版本不低于 27。CI 选择 runner 中最新安装的 Xcode；runner 必须提供 Xcode 27 或更新版本，执行测试还需要 macOS 27 或更新版本。工作流尚需在 GitHub 上实际运行验证。

## Apple 官方参考

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
