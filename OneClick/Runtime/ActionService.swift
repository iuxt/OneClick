//
//  ActionService.swift
//  OneClick
//
//  文件操作 / 动作执行服务。从原 AppDelegate 迁移而来，是主 app 的"动作执行层"。
//  依赖 AppState（只读状态）、PermissionService 与删除确认（经协议注入，可 mock 单测）。
//  注意：第一版不过度拆分，用私有方法 + MARK 分组（FileActions / AppActions / FinderActions / SystemActions）。
//

import AppKit
import Foundation
import os.log

@MainActor
final class ActionService {
    @AppLog(category: "ActionService")
    private var logger

    private let state: ActionStateProviding
    private let permission: PermissionProviding
    private let confirmation: DeleteConfirmationProviding
    private let checksums: ChecksumPresenting
    private let archives: ArchivePresenting
    private let openCreatedFile: @MainActor (URL, URL) async throws -> Void

    init(state: ActionStateProviding, permission: PermissionProviding, confirmation: DeleteConfirmationProviding,
         checksums: ChecksumPresenting = ChecksumWindowPresenter.shared,
         archives: ArchivePresenting = ArchiveWindowPresenter.shared,
         openCreatedFile: @escaping @MainActor (URL, URL) async throws -> Void = { file, application in
             _ = try await NSWorkspace.shared.open([file], withApplicationAt: application,
                                                  configuration: NSWorkspace.OpenConfiguration())
         }) {
        self.state = state
        self.permission = permission
        self.confirmation = confirmation
        self.checksums = checksums
        self.archives = archives
        self.openCreatedFile = openCreatedFile
    }

    // MARK: - SystemActions

    /// 复制路径到剪贴板
    func copyPath(_ target: [String]) {
        if let dirPath = target.first {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(dirPath, forType: .string)
        }
    }

    // MARK: - AppActions

    /// Open the selected files or directories with the configured application.
    func openApp(rid: String, target: [String]) async {
        guard let rcitem = state.getAppItem(rid: rid) else {
            logger.warning("when openapp, but not have app \(rid)")
            return
        }

        let appUrl = rcitem.url
        logger.debug("openApp: rid=\(rid) app=\(appUrl.path) target=\(target) opensNewInstance=\(rcitem.opensNewInstance)")

        let options = AppLaunchOptions(app: rcitem)
        let targets = await FileActionWorker.openTargets(appPath: appUrl.path, explicit: rcitem.opensContainingDir, paths: target)
        var decisions: [URL: Bool] = [:]
        for target in targets {
            guard await authorize(target.directory, decisions: &decisions) else { continue }
            openWithApp(target.url, appUrl: appUrl, options: options)
        }
    }

    private func openWithApp(_ url: URL, appUrl: URL, options: AppLaunchOptions) {
        let logger = self.logger
        let config = options.configuration()
        NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: config) { runningApp, error in
            if let error {
                logger.error("打开失败：\(url.path) — \(error.localizedDescription)")
            } else if let runningApp {
                logger.debug("Successfully opened with application: \(runningApp.localizedName ?? "Unknown")")
            }
        }
    }

    /// Open common directories using the process's normal file access.
    func openCommonDirs(target: [String]) async {
        logger.debug("开始打开常用目录，目标路径：\(target)")

        for dirPath in target {
            let path = dirPath
            let url = URL(fileURLWithPath: path, isDirectory: true)

            if !permission.hasAccess(to: url) {
                guard await permission.promptForPermission(for: url) != nil else {
                    logger.warning("用户取消授权，跳过打开目录：\(path)")
                    continue
                }
            }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - FileActions

    /// 动作分发入口
    func actionHandler(rid: String, target: [String], trigger: String, optionKeyPressed: Bool = false) async {
        guard let rcitem = state.getActionItem(rid: rid) else {
            logger.warning("when actionHandler, but not have action \(rid)")
            return
        }

        switch rcitem.id {
        case "copy-path":
            copyPath(target)
        case "delete-direct":
            await deleteFoldorFile(target, trigger, optionKeyPressed: optionKeyPressed)
        case "unhide":
            await unhideFilesAndDirs(target, trigger)
        case "hide":
            await hideFilesAndDirs(target, trigger)
        case "airdrop":
            await showAirDrop(target, trigger)
        case "checksum":
            await showChecksums(target)
        case "compress-zip-separately", "compress-7z-separately":
            guard trigger == "ctx-items" else { return }
            await showArchives(target, operation: rcitem.id == "compress-zip-separately" ? .zip : .sevenZip,
                               separately: true)
        case "compress-zip-and-delete", "compress-7z-and-delete":
            guard trigger == "ctx-items" else { return }
            await showArchives(target, operation: rcitem.id == "compress-zip-and-delete" ? .zip : .sevenZip,
                               deletesSourcesAfterSuccess: true)
        case "compress-zip-separately-and-delete", "compress-7z-separately-and-delete":
            guard trigger == "ctx-items" else { return }
            await showArchives(target,
                               operation: rcitem.id == "compress-zip-separately-and-delete" ? .zip : .sevenZip,
                               separately: true, deletesSourcesAfterSuccess: true)
        case "compress", "compress-zip", "compress-7z", "compress-targz", "compress-zip-encrypted", "compress-7z-encrypted", "extract", "extract-and-delete":
            guard trigger == "ctx-items", let operation = ArchiveOperation(rawValue: rcitem.id) else { return }
            await showArchives(target, operation: operation)
        default:
            logger.warning("no action id matched")
        }
    }

    func showArchives(_ target: [String], operation: ArchiveOperation, separately: Bool = false,
                      deletesSourcesAfterSuccess: Bool = false) async {
        let targets = await FileActionWorker.inspect(target)
        let urls = targets.map(\.url)
        guard !urls.isEmpty else { return }
        var denied: Set<URL> = []
        var decisions: [URL: Bool] = [:]
        for target in targets {
            if !(await authorize(target.directory, decisions: &decisions)) { denied.insert(target.directory) }
        }
        let accessError = AppLocalization.localized("File access was not granted.")
        if operation.isExtraction || separately {
            archives.show(requests: targets.map { target in
                ArchiveRequest(operation: operation, urls: [target.url],
                               error: denied.contains(target.directory) ? accessError : nil,
                               deletesSourcesAfterSuccess: deletesSourcesAfterSuccess)
            })
        } else {
            // A compression request is all-or-nothing: never silently omit a
            // selected item when authorization for one of its folders is denied.
            archives.show(requests: [ArchiveRequest(operation: operation, urls: urls,
                                                     error: denied.isEmpty ? nil : accessError,
                                                     deletesSourcesAfterSuccess: deletesSourcesAfterSuccess)])
        }
    }

    /// The browser owns progress and errors; only folder authorization uses a panel.
    func extractArchive(_ url: URL, password: String? = nil) async throws -> URL {
        let parent = await FileActionWorker.resolveDirectory(url.deletingLastPathComponent())
        var decisions: [URL: Bool] = [:]
        guard await authorize(parent, decisions: &decisions) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Task.checkCancellation()
        return try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [url]), password: password)
    }

    func showChecksums(_ target: [String]) async {
        let targets = await FileActionWorker.inspect(target, access: .resolvedParent)
        var inputs: [ChecksumInput] = []
        var decisions: [URL: Bool] = [:]
        for target in targets {
            let allowed = await authorize(target.directory, decisions: &decisions)
            inputs.append(ChecksumInput(url: target.url, error: allowed ? nil : AppLocalization.localized("File access was not granted.")))
        }
        checksums.show(inputs: inputs)
    }

    func showAirDrop(_ target: [String], _ trigger: String) async {
        logger.info("---- showAirDrop trigger:\(trigger)")
        var fileURLs: [URL] = []

        if trigger == "ctx-container" {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized("Warning")
            alert.informativeText = AppLocalization.localized("The current folder cannot be shared. Please select files or subfolders instead.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: AppLocalization.localized("OK"))
            alert.runModal()
            return
        }

        let targets = await FileActionWorker.inspect(target, checkProtection: true, readFileType: true)
        var decisions: [URL: Bool] = [:]
        for target in targets {
            let decodedPath = target.url.path
            logger.info("airdrop path \(decodedPath)")

            if target.isProtected {
                let alert = NSAlert()
                alert.messageText = AppLocalization.localized("Warning")
                alert.informativeText = String(format: AppLocalization.localized("Protected system folders cannot be shared: %@"), decodedPath)
                alert.alertStyle = .warning
                alert.addButton(withTitle: AppLocalization.localized("OK"))
                alert.runModal()
                logger.warning("试图分享受保护的系统文件夹，操作已被阻止：\(decodedPath)")
                continue
            }

            if target.exists {
                if target.isDirectory {
                    logger.warning("不能通过 AirDrop 分享文件夹：\(decodedPath)")
                    let alert = NSAlert()
                    alert.messageText = AppLocalization.localized("Notice")
                    alert.informativeText = String(format: AppLocalization.localized("Folders cannot be shared via AirDrop: %@"), decodedPath)
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: AppLocalization.localized("OK"))
                    alert.runModal()
                    continue
                } else {
                    // 确保有文件所在目录的访问权限
                    guard await authorize(target.directory, decisions: &decisions) else { continue }
                    fileURLs.append(target.url)
                }
            }
        }

        if !fileURLs.isEmpty {
            if let airDropService = NSSharingService(named: .sendViaAirDrop) {
                airDropService.perform(withItems: fileURLs)
                logger.info("已通过 AirDrop 分享文件：\(fileURLs.map { $0.path }.joined(separator: ", "))")
            } else {
                logger.warning("无法获取 AirDrop 服务")
            }
        }
    }

    func unhideFilesAndDirs(_ target: [String], _ trigger: String) async {
        await setHidden(false, target: target, trigger: trigger)
    }

    func hideFilesAndDirs(_ target: [String], _ trigger: String) async {
        await setHidden(true, target: target, trigger: trigger)
    }

    private func setHidden(_ hidden: Bool, target: [String], trigger: String) async {
        guard trigger == "ctx-items" || trigger == "ctx-container" else { return }
        let container = trigger == "ctx-container"
        let targets = await FileActionWorker.inspect(container ? Array(target.prefix(1)) : target,
                                                     access: container ? .directory : .parent,
                                                     checkProtection: !container)
        var authorized: [URL] = []
        var decisions: [URL: Bool] = [:]
        for target in targets where !target.isProtected {
            if await authorize(target.directory, decisions: &decisions) { authorized.append(target.url) }
        }
        guard !authorized.isEmpty else { return }
        let activity = FileActionActivity()
        let failures = await FileActionWorker.setHidden(hidden, urls: authorized, contentsOfDirectories: container)
        activity.finish()
        showFileFailures(failures)
    }

    func deleteFoldorFile(_ target: [String], _ trigger: String, optionKeyPressed: Bool = false) async {
        logger.info("---- deleteFoldorFile trigger:\(trigger) option:\(optionKeyPressed)")

        if trigger == "ctx-container" {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized("Warning")
            alert.informativeText = AppLocalization.localized("The current folder cannot be deleted. Please select files or subfolders instead.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: AppLocalization.localized("OK"))
            alert.runModal()
            return
        }

        let targets = await FileActionWorker.inspect(target, checkProtection: true)
        var authorized: [String] = []
        var decisions: [URL: Bool] = [:]
        for target in targets {
            if target.isProtected {
                let alert = NSAlert()
                alert.messageText = AppLocalization.localized("Warning")
                alert.informativeText = String(format: AppLocalization.localized("Protected system folders cannot be deleted: %@"), target.url.path)
                alert.alertStyle = .warning
                alert.addButton(withTitle: AppLocalization.localized("OK"))
                alert.runModal()
                continue
            }
            // Finish authorization before confirmation, and only include granted paths.
            if await authorize(target.directory, decisions: &decisions) { authorized.append(target.url.path) }
        }

        guard !authorized.isEmpty else { return }

        // 绕过废纸篓的删除默认必须确认；按住 Option 点击是唯一跳过确认的方式。
        if !optionKeyPressed {
            guard confirmation.confirmPermanentDelete(paths: authorized) else {
                logger.info("用户取消了删除确认，共 \(authorized.count) 项未删除")
                return
            }
        }

        let activity = FileActionActivity()
        let failures = await FileActionWorker.remove(authorized)
        activity.finish()
        showFileFailures(failures)
    }

    // MARK: - NewFileActions

    func createFile(rid: String, target: [String]) async {
        guard let dirPath = await targetDirectoryForNewFile(target) else {
            logger.warning("when createFile, but not have target directory")
            return
        }

        let dirURL = URL(fileURLWithPath: dirPath)

        // 确保有目标目录的访问权限
        if !permission.hasAccess(to: dirURL) {
            guard await permission.promptForPermission(for: dirURL) != nil else {
                logger.warning("用户取消授权，跳过创建文件")
                return
            }
        }

        let ext: String
        let template: URL?
        let openApp: URL?
        if rid == NewFileMenuItem.customFileId {
            ext = ""
            template = nil
            openApp = nil
        } else {
            guard let item = state.getFileType(rid: rid) else { return }
            ext = item.ext
            template = item.template
            openApp = item.openApp
        }
        let activity = FileActionActivity()
        do {
            let fileURL = try await FileActionWorker.create(in: dirURL, extension: ext, template: template,
                                                          baseName: AppLocalization.localized("Untitled"))
            activity.finish()
            if let openApp {
                try await openCreatedFile(fileURL, openApp)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        } catch {
            activity.finish()
            showFileFailures([FileActionWorker.Failure(url: dirURL, message: error.localizedDescription)])
        }
    }

    private func showFileFailures(_ failures: [FileActionWorker.Failure]) {
        guard !failures.isEmpty else { return }
        for failure in failures { logger.error("File operation failed: \(failure.url.path) — \(failure.message)") }
        let alert = NSAlert()
        alert.messageText = AppLocalization.localized("Some files could not be processed")
        alert.informativeText = failures.prefix(5).map { "\($0.url.lastPathComponent): \($0.message)" }.joined(separator: "\n")
        alert.addButton(withTitle: AppLocalization.localized("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 辅助

    /// Cache decisions only within one action; never persist authorization results.
    private func authorize(_ directory: URL, decisions: inout [URL: Bool]) async -> Bool {
        if let allowed = decisions[directory] { return allowed }
        if permission.hasAccess(toResolvedURL: directory) {
            decisions[directory] = true
            return true
        }
        let chosen = await permission.promptForPermission(for: directory)
        // A newly granted ancestor can cover previously denied siblings.
        if chosen != nil { decisions.removeAll() }
        let allowed: Bool
        if chosen != nil {
            let resolved = await FileActionWorker.resolveDirectory(directory)
            allowed = permission.hasAccess(toResolvedURL: resolved)
        } else {
            allowed = false
        }
        decisions[directory] = allowed
        return allowed
    }

    /// Resolve directory metadata away from the UI thread, including network volumes.
    func targetDirectoryForNewFile(_ target: [String]) async -> String? {
        await FileActionWorker.targetDirectory(target)
    }
}
