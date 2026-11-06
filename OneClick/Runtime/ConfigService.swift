//
//  ConfigService.swift
//  OneClick
//
//  配置持久化服务：负责配置数据的读取、保存（SwiftData）。
//  与 AppState 分离：AppState 持有运行时状态（内存数组），ConfigService 负责持久化。
//

import Foundation
import SwiftData
import os.log

/// 配置数据快照（AppState 持有的内存配置）
struct AppConfigData: Codable {
    var apps: [OpenWithApp] = []
    var actions: [RCAction] = []
    var newFiles: [NewFile] = []
    var commonDirs: [CommonDir] = []
}

@MainActor
final class ConfigService {
    @AppLog(category: "ConfigService")
    private var logger

    let modelContext: ModelContext
    // This service owns configuration writes. A reload or pending context changes
    // invalidates the baseline; failed transactions never advance it.
    private var lastSaved: AppConfigData?

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext ?? ModelContext(SharedDataManager.sharedModelContainer)
    }

    /// 从 SwiftData 读取全部配置
    func load() -> AppConfigData {
        lastSaved = nil
        var data = AppConfigData()

        // Apps
        let appDescriptor = FetchDescriptor<AppEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        data.apps = (try? modelContext.fetch(appDescriptor))?.map { entity in
            var app = OpenWithApp(id: entity.id, appURL: entity.url)
            app.itemName = entity.itemName
            app.inheritFromGlobalArguments = entity.inheritFromGlobalArguments
            app.inheritFromGlobalEnvironment = entity.inheritFromGlobalEnvironment
            app.arguments = entity.arguments
            app.environment = entity.environment
            app.opensNewInstance = entity.opensNewInstance
            app.showInToolbar = entity.showInToolbar
            app.showInContextMenu = entity.showInContextMenu
            app.opensContainingDir = entity.opensContainingDir
            return app
        } ?? []

        // Actions
        let actionDescriptor = FetchDescriptor<ActionEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        let savedActions = (try? modelContext.fetch(actionDescriptor)) ?? []
        // Password protection is configured in Compress…; retire the standalone shortcuts.
        let retiredActionIDs: Set<String> = ["compress-zip-encrypted", "compress-7z-encrypted"]
        var changedActions = false
        for entity in savedActions where retiredActionIDs.contains(entity.id) {
            modelContext.delete(entity)
            changedActions = true
        }
        // Early extract-and-delete configurations used a nonexistent SF Symbol.
        // Repair the persisted value so settings and Finder both receive the icon.
        for entity in savedActions where entity.id == RCAction.extractAndDelete.id
            && entity.icon == "archivebox.badge.arrow.trianglehead.2.clockwise" {
            entity.icon = RCAction.extractAndDelete.icon
            changedActions = true
        }
        data.actions = savedActions.filter { !retiredActionIDs.contains($0.id) }.map { entity in
            RCAction(
                id: entity.id,
                name: entity.name,
                enabled: entity.isEnabled,
                idx: entity.sortOrder,
                icon: entity.icon
            )
        }

        // Append newly introduced actions once, preserving saved ordering and
        // disabled choices on subsequent loads.
        let newActions: [RCAction] = [
            .checksum, .compressZip, .compressSevenZip, .compressTarGzip, .extract, .compress,
            .compressZipSeparately, .compressSevenZipSeparately,
            .compressZipAndDelete, .compressSevenZipAndDelete,
            .compressZipSeparatelyAndDelete, .compressSevenZipSeparatelyAndDelete,
            .extractAndDelete,
        ]
        for var action in newActions where !data.actions.isEmpty && !data.actions.contains(where: { $0.id == action.id }) {
            action.idx = (data.actions.map(\.idx).max() ?? -1) + 1
            data.actions.append(action)
            modelContext.insert(ActionEntity(from: action))
            changedActions = true
        }
        if changedActions {
            do {
                try modelContext.save()
            } catch {
                logger.error("Could not save built-in actions: \(error.localizedDescription)")
            }
        }

        // NewFiles
        let newFileDescriptor = FetchDescriptor<NewFileTypeEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        let savedFiles = (try? modelContext.fetch(newFileDescriptor)) ?? []
        enableNewlyBundledFileTypes(savedFiles)
        data.newFiles = savedFiles.map { entity in
            var file = NewFile(
                ext: entity.fileExtension,
                name: entity.name,
                enabled: entity.isEnabled,
                idx: entity.sortOrder,
                icon: entity.icon,
                id: entity.id
            )
            file.template = entity.templatePath.map { URL(fileURLWithPath: $0) }
            file.openApp = entity.openAppPath.map { URL(fileURLWithPath: $0) }
            return file
        }

        // CommonDirs（含旧图标自动修复）
        let commonDirDescriptor = FetchDescriptor<CommonDirEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        var needSaveCommonDirs = false
        data.commonDirs = (try? modelContext.fetch(commonDirDescriptor))?.map { entity in
            if entity.migratePath() { needSaveCommonDirs = true }
            let resolvedIcon: String
            if entity.icon == "folder" || entity.icon.isEmpty {
                let newIcon = iconForDirectory(url: entity.path)
                entity.icon = newIcon
                needSaveCommonDirs = true
                resolvedIcon = newIcon
            } else {
                resolvedIcon = entity.icon
            }
            return CommonDir(
                id: entity.id,
                name: entity.name,
                url: entity.path,
                icon: resolvedIcon
            )
        } ?? []
        if needSaveCommonDirs {
            try? modelContext.save()
        }

        logger.debug("Load from SwiftData: \(data.apps.count) apps, \(data.actions.count) actions, \(data.newFiles.count) newFiles, \(data.commonDirs.count) commonDirs")
        return data
    }

    /// The previous release disabled these defaults because their templates were
    /// absent. Enable unchanged built-ins once when upgrading, then honor later
    /// disabled choices. Custom types, templates and app choices stay untouched.
    private func enableNewlyBundledFileTypes(_ files: [NewFileTypeEntity]) {
        guard !files.isEmpty else { return }
        let key = "built-in-document-templates-enabled"
        do {
            guard try modelContext.fetchCount(FetchDescriptor<DataVersion>(predicate: #Predicate { $0.key == key })) == 0 else { return }
            let newlyAvailable: Set<String> = ["docx", "pptx", "pages", "key", "numbers"]
            let defaults = NewFile.all.filter { newlyAvailable.contains($0.id) }
            try modelContext.transaction {
                for entity in files where !entity.isEnabled && entity.templatePath == nil && entity.openAppPath == nil {
                    guard let original = defaults.first(where: { $0.id == entity.id }),
                          entity.fileExtension == original.ext, entity.name == original.name,
                          entity.icon == original.icon,
                          FileCreationPolicy.builtInTemplate(for: original.ext) != nil else { continue }
                    entity.isEnabled = true
                    entity.updatedAt = Date()
                }
                modelContext.insert(DataVersion(key: key, version: 1))
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            logger.error("Could not enable built-in document templates: \(error.localizedDescription)")
        }
    }

    /// Reconcile stable IDs in place. Unchanged rows never become database writes.
    func save(_ data: AppConfigData) throws {
        if modelContext.hasChanges { lastSaved = nil }
        do {
            try modelContext.transaction {
                try reconcile(data.apps, previous: lastSaved?.apps, id: \.id, entityID: \AppEntity.id,
                              same: Self.sameApp, create: { AppEntity(from: $0, sortOrder: $1) }) { entity, app, index in
                    var changed = false
                    self.assign(entity, \.urlString, app.url.path(percentEncoded: false), changed: &changed)
                    self.assign(entity, \.itemName, app.name, changed: &changed)
                    self.assign(entity, \.inheritFromGlobalArguments, app.inheritFromGlobalArguments, changed: &changed)
                    self.assign(entity, \.inheritFromGlobalEnvironment, app.inheritFromGlobalEnvironment, changed: &changed)
                    if entity.arguments != app.arguments {
                        entity.argumentsData = try JSONEncoder().encode(app.arguments)
                        changed = true
                    }
                    if entity.environment != app.environment {
                        entity.environmentData = try JSONEncoder().encode(app.environment)
                        changed = true
                    }
                    self.assign(entity, \.sortOrder, index, changed: &changed)
                    self.assign(entity, \.opensNewInstance, app.opensNewInstance, changed: &changed)
                    self.assign(entity, \.showInToolbar, app.showInToolbar, changed: &changed)
                    self.assign(entity, \.showInContextMenu, app.showInContextMenu, changed: &changed)
                    self.assign(entity, \.opensContainingDir, app.opensContainingDir, changed: &changed)
                    if changed { entity.updatedAt = Date() }
                }
                try reconcile(data.actions, previous: lastSaved?.actions, id: \.id, entityID: \ActionEntity.id,
                              same: { $0.name == $1.name && $0.icon == $1.icon && $0.enabled == $1.enabled && $0.idx == $1.idx },
                              create: { action, _ in ActionEntity(from: action) }) { entity, action, _ in
                    var changed = false
                    self.assign(entity, \.name, action.name, changed: &changed)
                    self.assign(entity, \.icon, action.icon, changed: &changed)
                    self.assign(entity, \.isEnabled, action.enabled, changed: &changed)
                    self.assign(entity, \.sortOrder, action.idx, changed: &changed)
                    if changed { entity.updatedAt = Date() }
                }
                try reconcile(data.newFiles, previous: lastSaved?.newFiles, id: \.id, entityID: \NewFileTypeEntity.id,
                              same: Self.sameFile, create: { file, _ in NewFileTypeEntity(from: file) }) { entity, file, _ in
                    var changed = false
                    self.assign(entity, \.fileExtension, file.ext, changed: &changed)
                    self.assign(entity, \.name, file.name, changed: &changed)
                    self.assign(entity, \.icon, file.icon, changed: &changed)
                    self.assign(entity, \.isEnabled, file.enabled, changed: &changed)
                    self.assign(entity, \.sortOrder, file.idx, changed: &changed)
                    self.assign(entity, \.templatePath, file.template?.path, changed: &changed)
                    self.assign(entity, \.openAppPath, file.openApp?.path, changed: &changed)
                    if changed { entity.updatedAt = Date() }
                }
                try reconcile(data.commonDirs, previous: lastSaved?.commonDirs, id: \.id, entityID: \CommonDirEntity.id,
                              same: { $0.name == $1.name && $0.url == $1.url && $0.icon == $1.icon },
                              create: { directory, index in
                    let entity = CommonDirEntity(from: directory)
                    entity.sortOrder = index
                    return entity
                }) { entity, directory, index in
                    var changed = false
                    self.assign(entity, \.name, directory.name, changed: &changed)
                    self.assign(entity, \.pathString, directory.url.path, changed: &changed)
                    self.assign(entity, \.pathEncodingVersion, 1, changed: &changed)
                    self.assign(entity, \.icon, directory.icon, changed: &changed)
                    self.assign(entity, \.sortOrder, index, changed: &changed)
                    if changed { entity.updatedAt = Date() }
                }
                if modelContext.hasChanges { try modelContext.save() }
            }
            lastSaved = data
        } catch {
            lastSaved = nil
            modelContext.rollback()
            throw error
        }
    }

    private func reconcile<Value, Entity: PersistentModel>(
        _ values: [Value], previous: [Value]?, id: KeyPath<Value, String>, entityID: KeyPath<Entity, String>,
        same: (Value, Value) -> Bool, create: (Value, Int) -> Entity, update: (Entity, Value, Int) throws -> Void
    ) throws {
        if let previous, previous.count == values.count,
           zip(previous, values).allSatisfy({ $0[keyPath: id] == $1[keyPath: id] && same($0, $1) }) { return }
        let baseline = Dictionary(uniqueKeysWithValues: (previous ?? []).enumerated().map {
            ($0.element[keyPath: id], (index: $0.offset, value: $0.element))
        })
        var remaining = Dictionary(uniqueKeysWithValues:
            try modelContext.fetch(FetchDescriptor<Entity>()).map { ($0[keyPath: entityID], $0) })
        for (index, value) in values.enumerated() {
            if let entity = remaining.removeValue(forKey: value[keyPath: id]) {
                if let old = baseline[value[keyPath: id]], old.index == index, same(old.value, value) { continue }
                try update(entity, value, index)
            } else {
                modelContext.insert(create(value, index))
            }
        }
        for entity in remaining.values { modelContext.delete(entity) }
    }

    // RCBase equality compares IDs only, so persistence must compare every stored field.
    private static func sameApp(_ a: OpenWithApp, _ b: OpenWithApp) -> Bool {
        a.url == b.url && a.itemName == b.itemName
            && a.inheritFromGlobalArguments == b.inheritFromGlobalArguments
            && a.inheritFromGlobalEnvironment == b.inheritFromGlobalEnvironment
            && a.arguments == b.arguments && a.environment == b.environment
            && a.opensNewInstance == b.opensNewInstance && a.showInToolbar == b.showInToolbar
            && a.showInContextMenu == b.showInContextMenu && a.opensContainingDir == b.opensContainingDir
    }

    private static func sameFile(_ a: NewFile, _ b: NewFile) -> Bool {
        a.ext == b.ext && a.name == b.name && a.icon == b.icon && a.enabled == b.enabled
            && a.idx == b.idx && a.template == b.template && a.openApp == b.openApp
    }

    private func assign<Entity: AnyObject, Value: Equatable>(
        _ entity: Entity, _ key: ReferenceWritableKeyPath<Entity, Value>, _ value: Value, changed: inout Bool
    ) {
        if entity[keyPath: key] != value {
            entity[keyPath: key] = value
            changed = true
        }
    }
}
