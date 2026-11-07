//
//  Up.swift
//  OneClick
//
//  Created by 李旭 on 2025/9/21.
//
import SwiftUI

struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var updateManager: UpdateManager
    
    var body: some View {
        VStack(spacing: 16) {
            if updateManager.isChecking {
                checkingView
            } else if let error = updateManager.updateError {
                errorView(error)
            } else if let release = updateManager.availableUpdate {
                updateAvailableView(release)
            } else {
                noUpdateView
            }
        }
        .padding(20)
        .frame(width: 420)
    }
    
    private var checkingView: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text(appLocalized: "Checking for updates...")
                .font(.headline)
        }
    }
    
    private func updateAvailableView(_ release: GitHubRelease) -> some View {
        // 更新可用视图实现保持不变...
        VStack(spacing: 12) {
            if updateManager.isDownloading { ProgressView().controlSize(.small) }
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            
            Text(appLocalized: "New Version Available")
                .font(.title2)
                .bold()
            
            Text(String(format: AppLocalization.localized("Version %@"), release.version))
                .font(.title3)
                .foregroundColor(.secondary)
            
            ScrollView {
                Text(release.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            
            HStack {
                Button(AppLocalization.localized("Ignore This Version")) {
                    updateManager.ignoreCurrentUpdate()
                    updateManager.dismissUpdateSheet()
                }
                .buttonStyle(.glass)
                
                Button(AppLocalization.localized("Download Manually")) {
                    updateManager.openReleasesPage()
                    updateManager.dismissUpdateSheet()
                }
                .buttonStyle(.glass)
                
                Button(AppLocalization.localized("Download and Install")) {
                    Task {
                        await updateManager.downloadAndInstallUpdate()
                    }
                }
                .buttonStyle(.glassProminent)
            }
            .disabled(updateManager.isDownloading)
        }
    }
    
    private var noUpdateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(.green)
            
            Text(appLocalized: "Up to Date")
                .font(.title2)
                .bold()
            
            Text(appLocalized: "The current version is already up to date.")
                .foregroundColor(.secondary)
            
            Button(AppLocalization.localized("OK")) {
                updateManager.dismissUpdateSheet()
            }
            .buttonStyle(.glassProminent)
        }
    }
    
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.yellow)
            
            Text(appLocalized: "Update Failed")
                .font(.title2)
                .bold()
            
            Text(error)
                .font(.body)
                .multilineTextAlignment(.center)
            
            Button(AppLocalization.localized("OK")) {
                updateManager.dismissUpdateSheet()
            }
            .buttonStyle(.glassProminent)
        }
    }
}
