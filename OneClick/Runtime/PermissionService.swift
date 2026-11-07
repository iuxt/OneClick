//
//  PermissionService.swift
//  OneClick
//
//  File access policy for the independently distributed, non-sandboxed host.
//

import Foundation

/// 权限服务协议（供 ActionService 注入 mock，便于单测）
@MainActor
protocol PermissionProviding: AnyObject {
    /// Application-level eligibility; filesystem and macOS privacy checks occur at I/O.
    func hasAccess(to url: URL) -> Bool
    /// The caller resolves symlinks off main before using this batch check.
    func hasAccess(toResolvedURL url: URL) -> Bool
    /// Optional policy recovery hook. The production host never prompts for a folder grant.
    func promptForPermission(for url: URL) async -> URL?
}

extension PermissionProviding {
    func hasAccess(toResolvedURL url: URL) -> Bool { hasAccess(to: url) }
}

/// Direct file access. Permission errors are reported by the actual operation;
/// no bookmark allowlist or application-level folder grant is required.
@MainActor
final class PermissionService: PermissionProviding {
    func hasAccess(to url: URL) -> Bool {
        url.isFileURL
    }

    func hasAccess(toResolvedURL url: URL) -> Bool {
        url.isFileURL
    }

    func promptForPermission(for url: URL) async -> URL? {
        nil
    }
}
