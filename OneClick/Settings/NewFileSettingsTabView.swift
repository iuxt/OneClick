//
//  NewFileSettingsTabView.swift
//  OneClick
//
//  Created by 李旭 on 2024/11/18.
//

import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct NewFileSettingsTabView: View {
    @AppLog(category: "NewFileSettingsTabView")
    private var logger
    
    @EnvironmentObject var appState: AppState
    @State private var editingFile: NewFile?
    @State private var fileToDelete: NewFile?
    @State private var confirmingRestore = false

    let messager = Messager.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.foldNewFileMenu) {
                    Text(appLocalized: "Collapse new file menu")
                }
                    .onChange(of: appState.foldNewFileMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }

            Section {
                // 操作按钮放在列表顶部，始终可见
                HStack {
                    Button {
                        confirmingRestore = true
                    } label: {
                        Label(AppLocalization.localized("Restore Defaults"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Spacer()
                    Button {
                        editingFile = NewFile(ext: "", name: "", idx: appState.newFiles.count)
                    } label: {
                        Label(AppLocalization.localized("Add File Type"), systemImage: "plus")
                    }
                }

                List {
                    ForEach($appState.newFiles) { $item in
                        LabeledContent {
                            HStack(spacing: 12) {
                                Button {
                                    editingFile = item
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help(AppLocalization.localized("Edit File Type"))

                                Button {
                                    fileToDelete = item
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help(AppLocalization.localized("Delete File Type"))

                                Toggle(AppLocalization.localized("Enabled"), isOn: $item.enabled)
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .onChange(of: item.enabled) {
                                        appState.toggleActionItem()
                                        messager.sendRunningNotification()
                                    }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.secondary)
                                // 图标
                                if let appUrl = item.openApp {
                                    SettingsIcon(source: .application(appUrl))
                                        .frame(width: 24, height: 24)
                                } else {
                                    SettingsIcon(source: .fileType(item.ext, fallback: item.icon))
                                        .frame(width: 20, height: 20)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                    Text(String(format: AppLocalization.localized("Extension: %@"), item.ext))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { source, destination in
                        appState.moveNewFiles(from: source, to: destination)
                        messager.sendRunningNotification()
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingFile) { file in
            EditFileTypeSheetView(file: file, appState: appState)
        }
        .confirmationDialog(
            AppLocalization.localized("Restore Default File Types?"),
            isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.localized("Restore Defaults"), role: .destructive) {
                appState.resetFiletypeItems()
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(appLocalized: "This replaces all file types with the defaults, removing custom types and resetting names, templates, icons, app choices and enabled states. This cannot be undone.")
        }
        .confirmationDialog(
            AppLocalization.localized("Delete File Type"),
            isPresented: Binding(
                get: { fileToDelete != nil },
                set: { if !$0 { fileToDelete = nil } }
            ),
            presenting: fileToDelete
        ) { file in
            Button(AppLocalization.localized("Delete"), role: .destructive) {
                appState.deleteNewFile(id: file.id)
                messager.sendRunningNotification()
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {
                fileToDelete = nil
            }
        } message: { file in
            Text(String(format: AppLocalization.localized("Are you sure you want to delete \"%@\" (%@)? This action cannot be undone."), file.displayName, file.ext))
        }
    }

}
