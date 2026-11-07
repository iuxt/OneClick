# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OneClick is a macOS desktop application that extends Finder's context menu with custom functionality. It's a menu bar application that adds various right-click actions to macOS Finder, built with Swift 6.2+ and SwiftUI.

**Key Technologies:**
- Swift 6.2+ (required)
- SwiftUI (all UI components)
- AppKit (system integration only, no UI)
- SwiftData (persistence)
- FinderSync framework (Finder extension)
- Authenticated UNIX-domain stream (inter-process communication)
- Xcode 27+ (required for development)

## Architecture

OneClick follows a dual-process architecture:

### 1. Main Application (`OneClick/`)
- SwiftUI-based menu bar application
- Manages global settings and state via `AppState.swift`
- Provides settings interface (Settings window)
- Handles file operations triggered from context menu
- Entry point: [OneClickApp.swift](OneClick/OneClickApp.swift)

### 2. FinderSync Extension (`FinderSyncExt/`)
- Runs as a separate process, injected into Finder
- Injects custom context menu items into Finder
- Communicates with main app via `Messager` class
- Entry point: [FinderSyncExt.swift](FinderSyncExt/FinderSyncExt.swift)

### 3. Communication Layer
The main app and extension communicate over a UNIX-domain stream (`LocalIPCTransport`):
- **Extension → App**: `OneClick.ExtensionToMain` (click events, heartbeat, requestConfig)
- **App → Extension**: `OneClick.MainToExtension` (menu config, running, quit, actionAck)
- Peers are authenticated by kernel audit token and installed code-signing requirement; versioned JSON frames reject stale/replayed messages. No communication key or Keychain access is used. See `docs/ipc-security.md`.
- Implementation: [Messager.swift](Shared/Messager.swift)

### 4. State Management
- **AppState**: `@MainActor ObservableObject` holding runtime state (in-memory config arrays, fold toggles)
- **ConfigService**: SwiftData config load/save/reset (persistence separated from runtime state)
- **RCRuntime**: in-process dependency container (`OneClick/Runtime/`) holding AppState + ConfigService + MenuService + ActionService + PermissionService + Messager. **It is NOT a separate process / Helper.**
- **File access**: the main app and archive tools are non-sandboxed. `PermissionService` uses direct file access; filesystem/TCC errors are reported by the operation. Only Finder Sync retains the system-required sandbox. Legacy `BookmarkEntity` records remain for database compatibility.
- Data categories: Apps (external apps), Actions (context menu actions), NewFiles (file templates), CommonDirs (quick access folders), BookmarkEntity (authorized folder credentials)
- Persistence: SwiftData with shared App Group container between app and extension
- Location: [AppState.swift](OneClick/AppState.swift) / [OneClick/Runtime/](OneClick/Runtime/)

### 5. Data Models
SwiftData `@Model` entities are in [OneClick/Model/](OneClick/Model/), one file per entity:
- `AppEntity.swift`, `ActionEntity.swift`, `NewFileTypeEntity.swift`, `CommonDirEntity.swift`, `BookmarkEntity.swift`, `DataVersion.swift`
- In-memory models & IPC DTOs are in [Shared/RCBase.swift](Shared/RCBase.swift) (`OpenWithApp`, `RCAction`, `NewFile`, `CommonDir`, `AppMenuItem`, `ActionMenuItem`, …)
- `ModelContainer.swift`: Shared App Group SwiftData container configuration

## Build and Development Commands

### Building
```bash
# Build the project
xcodebuild -project OneClick.xcodeproj -scheme OneClick -destination 'platform=macOS'

# Build for release
xcodebuild -project OneClick.xcodeproj -scheme OneClick -configuration Release
```

### Running
- Open `OneClick.xcodeproj` in Xcode 27+
- Select the OneClick scheme
- Press Cmd+R to build and run
- The FinderSync extension will be automatically registered

### Testing
```bash
# Run tests (if test targets exist)
xcodebuild test -project OneClick.xcodeproj -scheme OneClick -destination 'platform=macOS'
```

### Linting
```bash
# Run SwiftLint (if configured)
swiftlint
```

## Key Development Patterns

### Adding New Context Menu Actions

1. Define action model in [Shared/RCBase.swift](Shared/RCBase.swift)
2. Add to `RCAction.all` static property
3. Handle action in [ActionService.swift](OneClick/Runtime/ActionService.swift) in `actionHandler()` method
4. Extension receives action via menu callback and sends `.click` message to main app (via `Messager`)

### Adding New File Templates

1. Add to `NewFile` model in [Shared/RCBase.swift](Shared/RCBase.swift)
2. Add a valid blank document as `OneClick/Resources/template.<extension>` (ordinary bundle resource, not an asset-catalog data set)
3. Resolve built-in templates in `FileCreationPolicy`; `FileActionWorker.create` copies the custom template when present, otherwise the built-in blank document

### Inter-Process Communication

When adding new message types:
1. Define the message enum case + payload in [Messager.swift](Shared/Messager.swift)
2. Register message handler in the appropriate `init` / `applicationDidFinishLaunching`
3. If the extension needs to detect whether the main app received a message, add a matching ack message

### File Access and Distribution

- The main application (Debug/Release) and archive helpers run without App Sandbox.
- Finder Sync retains its system-required sandbox and forwards file actions to the host.
- Do not reintroduce folder-grant prompts or security-scoped bookmarks in the host.
- Keep ordinary macOS privacy permissions, protected-directory checks, delete confirmation and authenticated IPC.
- Preserve existing database paths. `LegacySandboxMigration` imports container preferences/history once; legacy grant entities stay in the schema.
- This configuration targets independent distribution, not Mac App Store submission.

### Logging
- Use `@AppLog` property wrapper for structured logging
- Logs use `os.log` framework
- Category parameter should describe the subsystem
- Example: `@AppLog(category: "AppState") private var logger`

### Localization
- Default language is **English** (also the fallback)
- **Simplified Chinese** (`zh-Hans`) is the primary localization target
- **Japanese** (`ja`), **Spanish** (`es`) and **French** (`fr`) are also supported, activated when the system language matches
- All string keys in code use English, localized via `Localizable.xcstrings` (xcstrings format)
- Language detection is fully automatic via `Bundle.main.localizedString` — no manual language picker
- To add a new language: add entries to `Localizable.xcstrings` and register in Xcode project
- There are **two** catalogs — `OneClick/` (app) and `FinderSyncExt/` (extension). Each target resolves against its own via `Bundle.main`, so a key the extension renders must exist in the extension's catalog too
- `scripts/check-localization.py` verifies the catalogs; run it before a release
- Edit the catalogs with exact-string text edits. Re-serializing the JSON rewrites the whole file and does not round-trip byte-for-byte

### Data Persistence
- SwiftData models use `@Model` macro
- Shared container via app group: `.group` `UserDefaults`
- Shared model container: `SharedDataManager.sharedModelContainer`
- Both app and extension access same database

## Directory Structure

```
OneClick/
├── OneClick/                        # Main application target
│   ├── OneClickApp.swift           # App entry point & AppDelegate
│   ├── AppState.swift            # Runtime state
│   ├── Runtime/                  # In-process service layer (MenuService/ActionService/PermissionService/ConfigService/RCRuntime)
│   ├── Model/                    # SwiftData entities
│   ├── Settings/                 # Settings views (UI)
│   ├── Shared/                   # Utilities (LegacySandboxMigration, LaunchAtLogin, Updater, …)
│   ├── Assets.xcassets/          # Images, templates, icons
│   └── Resources/                # Localization files
├── FinderSyncExt/                # Finder extension target (thin: render + forward)
│   └── FinderSyncExt.swift       # Extension main file
├── Shared/                       # Code shared by app & extension (Messager, RCBase, AppLocalization, …)
├── specs/                        # Feature specifications & contracts
└── OneClick.xcodeproj             # Xcode project
```

## Common Issues

### Extension Not Loading
- Ensure extension is enabled in System Settings → Privacy & Security → Extensions
- Check that `FIFinderSyncController.default().directoryURLs` is set
- Verify heartbeat messages are being sent/received

### File Access Fails
- The host uses direct file access; report the actual filesystem or macOS privacy error.
- Keep protected-directory checks and permanent-delete confirmation.
- Do not restore the removed bookmark allowlist or folder-permission prompts.

### SwiftUI Views Not Updating
- Ensure `@MainActor` annotation when updating `@Published` properties
- Use `@StateObject` instead of `@ObservedObject` for view-owned objects
- Remember `AppState.shared` is a singleton - use `@StateObject` appropriately

## Documentation References

- **Feature Specifications**: [specs/](specs/)
- **Git Branch Strategy**: [specs/contracts/git-branch-strategy.md](specs/contracts/git-branch-strategy.md)
