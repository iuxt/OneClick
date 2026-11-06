
[![](./OneClick/Assets.xcassets/AppIcon.appiconset/AppIcon@1x.png)](https://github.com/iuxt/OneClick/releases)

# OneClick

Previously named RClick. Bundle IDs, App Group IDs, database names and template
storage paths retain their original identifiers to preserve existing settings
and folder permissions.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-ED523F.svg?style=flat)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-✓-orange)](https://developer.apple.com/xcode/swiftui/)
[![macOS 27+](https://img.shields.io/badge/macOS_27+-Compatible-green)](https://www.apple.com/macos/macos-golden-gate/)
[![Xcode 27+](https://img.shields.io/badge/Xcode-27%2B-blue)](https://developer.apple.com/xcode/)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/iuxt/OneClick)](https://github.com/iuxt/OneClick/releases)
[![GitHub downloads](https://img.shields.io/github/downloads/iuxt/OneClick/total)](https://github.com/iuxt/OneClick/releases)

An everyday Mac toolkit for Finder right-click actions, archive browsing and input method switching. Built with Swift 6.2 and SwiftUI for macOS 27+. Full dark mode support with adaptive icons.

## 🚀 Features

- [x] **Toolbox Home** — A shared settings home for right-click tools, archive tools and input method switching, with grouped navigation.
- [x] **Automatic Input Method Switching** — Choose an input source per app, set a default or remember each app's choice. Based on [LockIME](https://github.com/oomol-lab/LockIME); see [input method switching](docs/input-methods.md).
- [x] **System Monitor** — Show CPU, memory and live network speed as simultaneous, independently configurable menu bar items, with optional disk, GPU and battery items. Click any item for its history and CPU/memory process, network-interface or disk-volume rankings. Inspired by [Stats](https://github.com/exelban/stats); see [system monitoring](docs/system-monitor.md).
- [x] **Archive Browser & Preview** — Navigate and search archives, preview text and images, or use Quick Look. Associate selected archive formats from the archive settings.

- [x] **Open with External App** — Open files or directories with any installed application, with support for custom arguments and environment variables. Ships with presets for popular editors, terminals and IDEs, per-app visibility for the toolbar and context menus, and none/simple/original icon styles.
- [x] **Copy Path** — Copy the full path of selected files or folders to clipboard.
- [x] **File Checksums** — Right-click selected files to calculate MD5, SHA1, and SHA256 with bounded multi-core parallelism, streaming reads, progress, cancellation, and copyable results. Available by default; toggle it in Settings → Actions.
- [x] **Compress / Extract** — Right-click files or folders to create ZIP, 7Z, TAR.GZ, AES-256 encrypted ZIP, or encrypted 7Z archives. ZIP and 7Z can be created as one combined archive or one archive per selected item, with verified “compress and delete originals” variants. Extract ZIP, 7Z, RAR (including password-protected archives), TAR and other common formats into separate folders alongside the originals. Includes password prompts and retry, batch extraction, cancellation, automatic naming on collisions, and Show in Finder. Enable or disable each action in Settings → Actions; no Keka or Homebrew installation required. See [archive support](docs/archives.md) for format and password details.
- [x] **Delete Direct** — Delete files or folders directly, bypassing Trash. OneClick asks for confirmation first; hold **Option** while choosing the action to skip it.
- [x] **Hide / Unhide** — Toggle file visibility in Finder.
- [x] **AirDrop** — Share files instantly via AirDrop.
- [x] **Create New Files** — Create files directly in Finder. Office (`.docx`, `.pptx`, `.xlsx`) and Apple iWork (`.pages`, `.key`, `.numbers`) formats include built-in blank documents and work without template configuration. Custom templates are optional. Also supports `.txt`, `.json` and `.md`.
- [x] **Quick Access Folders** — Pin frequently used directories to the right-click menu.
- [x] **Terminal-aware Opening** — Terminal presets hand the containing folder to the app by default, with an automatic/on/off override per app.
- [x] **Dark Mode** — Full light/dark appearance support with adaptive icons and SF Symbols.

## 📱 More Apps

If OneClick is useful to you, here are two other apps I maintain:

| App | What it does | Download |
|-----|--------------|----------|
| [![iMonet icon](images/apps/imonet-icon.png)](https://apps.apple.com/cn/app/imonet/id6770070921?mt=12) **iMonet** | A mouse-first image viewer for macOS. Zoom follows your cursor, with native animated GIF, APNG and WebP playback. | [Mac App Store](https://apps.apple.com/cn/app/imonet/id6770070921?mt=12) |
| [![LiveCam icon](images/apps/livecam-icon.png)](https://apps.apple.com/cn/app/livecam/id6476108478?mt=12) **LiveCam** | Show your avatar while recording your screen or live streaming, with configurable size, border and shape. | [Mac App Store](https://apps.apple.com/cn/app/livecam/id6476108478?mt=12) |

## 🏗 Architecture

OneClick uses a dual-process architecture:

| Component | Description |
|-----------|-------------|
| **Main App** (`OneClick/`) | SwiftUI menu bar app — manages settings, state, and file operations |
| **FinderSync Extension** (`FinderSyncExt/`) | Injected into Finder — renders custom context menu items |

Communication between the two processes uses `DistributedNotificationCenter`. Settings are persisted via SwiftData with a shared App Group container.

## 📸 Screenshots


![](./images/oneclick-v2.0.1-screenshot.png)



## 📦 Installation

### Download

Get the latest release from the [Releases page](https://github.com/iuxt/OneClick/releases).

Download the `.dmg`, open it, and drag **OneClick** to your Applications folder.

> **Note:** On first launch, you may need to enable the Finder extension in **System Settings → Privacy & Security → Extensions → Added Extensions**.

### Build from Source

```bash
git clone https://github.com/iuxt/OneClick.git
cd OneClick
open OneClick.xcodeproj
```

- Requires **Xcode 27+** and **macOS 27+**
- Select the **OneClick** scheme, then **Product → Build** (⌘B)
- The FinderSync extension will be automatically registered

To build, install to `/Applications/OneClick.app`, and launch in one step:

```bash
./build.sh
```

The script builds Release by default, quits any running OneClick and its Finder
extension after a successful build, replaces the app, then launches the new
version. The default `local` mode needs no Apple developer account. Both targets
remain sandboxed and receive explicit access only to
`~/Library/Application Support/RClickLocal/` for the database and launch marker.
Local preferences use the main app's standard defaults; the extension receives
menu settings through IPC. Existing App Group data is left untouched, so local
mode starts with separate settings that persist across local updates.

For developer signing with App Group storage, use `BUILD_MODE=developer ./build.sh`.
Both targets then need a valid developer certificate and profiles authorizing
`group.cn.wflixu.RClick`. A different team must configure its own bundle and App
Group identifiers consistently in both targets and the shared code. This mode
verifies App Group authorization before replacing the installed app.

The script asks for administrator privileges only if the installation directory
requires them. Build output and logs are stored in `.build/`.

Optional overrides: `CONFIGURATION=Debug ./build.sh`,
`BUILD_MODE=developer DEVELOPMENT_TEAM="YOUR_TEAM_ID" ./build.sh`, or
`INSTALL_DIR="$HOME/Applications" ./build.sh`.

### Requirements

| Requirement | Details |
|-------------|---------|
| **Folder Access** | Per-folder authorization for file operations (prompted automatically) |
| **Finder Extension** | Must be enabled in System Settings |

## 🔧 Development

```bash
# Build
xcodebuild -project OneClick.xcodeproj -scheme OneClick -destination 'platform=macOS'

# Build for Release
xcodebuild -project OneClick.xcodeproj -scheme OneClick -configuration Release
```

### Key Technologies
- **Swift 6.2** with full concurrency checking
- **SwiftUI** for all UI components
- **AppKit** for system integration only (NSWorkspace, NSPasteboard)
- **SwiftData** for persistence with shared container
- **FinderSync** framework for Finder extension
- **DistributedNotificationCenter** for IPC

### Publishing a Release

Push a version tag such as `v2.3.4` to trigger the release workflow. It builds an
Apple Silicon app with ad-hoc signing, then uploads a DMG, an app ZIP, and SHA-256
checksums to GitHub Releases with automatically generated release notes.
Tags such as `v2.3.3-rc.1` create prereleases instead.

No Apple developer account or signing secrets are required. These builds are not
notarized; the first launch may need approval in macOS Privacy & Security.
See the [release guide](docs/releasing.md) for installation, tag commands, and retries.

### 🌐 Localization

OneClick supports five languages with the following priority:

| Language | Code | Notes |
|----------|------|-------|
| **English** | `en` | Default/base language |
| **Simplified Chinese** | `zh-Hans` | Primary localization target |
| **Japanese** | `ja` | Activated when system language is Japanese |
| **Spanish** | `es` | Activated when system language is Spanish |
| **French** | `fr` | Activated when system language is French |

**Principles:**
- Default language is English (also the fallback for unsupported system languages)
- All string keys are in English in the code, localized via `Localizable.xcstrings`
- System language is auto-detected — no manual language picker in the app
- To add a new language, add an entry to `Localizable.xcstrings` and register it in the Xcode project

## 👥 Contributors

Thanks to all the people who have contributed to OneClick!

<a href="https://github.com/wflixu/RClick/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=wflixu/RClick" />
</a>

Recent contributions:

- **[@SonneFish](https://github.com/SonneFish)** — built-in app presets, per-app visibility and icon styles ([#168](https://github.com/wflixu/RClick/pull/168)); Finder icon-cache and heartbeat performance ([#167](https://github.com/wflixu/RClick/pull/167)); permission status refresh ([#169](https://github.com/wflixu/RClick/pull/169)); quiet offline relaunch and settings reopen ([#170](https://github.com/wflixu/RClick/pull/170))
- **[@Consciencieux](https://github.com/Consciencieux)** — confirmation before Direct Delete ([#163](https://github.com/wflixu/RClick/pull/163))
- **[@Juns-g](https://github.com/Juns-g)** — watching mounted volumes so external and network drives show the menu ([#152](https://github.com/wflixu/RClick/pull/152))
- **[@Dam0rt](https://github.com/Dam0rt)** — French localization ([#149](https://github.com/wflixu/RClick/pull/149))
- **[@stors789](https://github.com/stors789)** — App Groups provisioning in the release pipeline ([#141](https://github.com/wflixu/RClick/pull/141))
- **[@EliasMatDev](https://github.com/EliasMatDev)** — Latin American Spanish localization ([#138](https://github.com/wflixu/RClick/pull/138))
- **[@shoal-rat](https://github.com/shoal-rat)** — Finder observation fix, so the menu appears in every folder ([#126](https://github.com/wflixu/RClick/pull/126))
- **[@P013onEr](https://github.com/P013onEr)** — string catalogs and trilingual localization ([#120](https://github.com/wflixu/RClick/pull/120)), draggable menu ordering ([#121](https://github.com/wflixu/RClick/pull/121))
- **[@chunyang-wen](https://github.com/chunyang-wen)** — removed a needless `await` ([#21](https://github.com/wflixu/RClick/pull/21))

## Similar Projects

- [SzContext](https://github.com/RoadToDream/SzContext)
- [MenuHelper](https://github.com/Kyle-Ye/MenuHelper)
- [SwiftyMenu](https://github.com/lexrus/SwiftyMenu)
- [OpenInTerminal](https://github.com/Ji4n1ng/OpenInTerminal)

## 🤝 Contributing

We welcome contributions! Here's how you can help:

- **[Report a Bug](https://github.com/iuxt/OneClick/issues/new?template=bug_report.md)** — Found something broken? Let us know.
- **[Request a Feature](https://github.com/iuxt/OneClick/issues/new?template=feature_request.md)** — Have an idea? We'd love to hear it.
- **[Submit a PR](CONTRIBUTING.md)** — Read our contribution guide to get started.
- **[Security Policy](SECURITY.md)** — How to responsibly report vulnerabilities.

Please read our [Code of Conduct](CODE_OF_CONDUCT.md) before participating.
