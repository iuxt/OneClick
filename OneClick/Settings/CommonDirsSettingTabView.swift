//
//  CommonDirsSettingTabView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/10.
//

import AppKit
import Cocoa
import FinderSync
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct CommonDirsSettingTabView: View {
    @AppLog(category: "settings-general")
    private var logger
    
    @EnvironmentObject var store: AppState
    
    @State private var showCommonDirImporter = false
    
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.showCommonDirs) {
                    Text(appLocalized: "Enable common folders")
                }
                    .onChange(of: store.showCommonDirs) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
                Toggle(isOn: $store.foldCommonDirMenu) {
                    Text(appLocalized: "Collapse common folders menu")
                }
                    .disabled(!store.showCommonDirs)
                    .onChange(of: store.foldCommonDirMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        showCommonDirImporter = true
                    } label: {
                        Label(AppLocalization.localized("Add Folder"), systemImage: "folder.badge.plus")
                    }
                }

                ForEach(store.cdirs) { item in
                    LabeledContent {
                        Button {
                            removeCommonDir(item)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(AppLocalization.localized("Remove Folder"))
                        .accessibilityLabel(String(format: AppLocalization.localized("Remove folder %@"), item.url.path))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayName)
                                Text(item.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: item.icon.isEmpty ? "folder" : item.icon)
                        }
                        .help(item.url.path)
                    }
                }
            } header: {
                Text(appLocalized: "Added Folders")
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showCommonDirImporter,
            allowedContentTypes: [.directory],
            allowsMultipleSelection: false
        ) { result in
            switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let commonDir = CommonDir(id: UUID().uuidString, name: url.lastPathComponent, url: url, icon: iconForDirectory(url: url))
                        if !store.cdirs.contains(where: { $0.url == commonDir.url }) {
                            store.cdirs.append(commonDir)
                            store.sync()
                        }
                    }
                case .failure(let error):
                    logger.error("Failed to select common folder: \(error.localizedDescription)")
            }
        }
    }

    @MainActor private func removeCommonDir(_ item: CommonDir) {
        if let index = store.cdirs.firstIndex(of: item) {
            store.cdirs.remove(at: index)
            store.sync()
        }
    }
}
