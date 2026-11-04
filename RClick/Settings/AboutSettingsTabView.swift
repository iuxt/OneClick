//
//  AboutSettingsTabView.swift
//  RClick
//
//  Created by 李旭 on 2024/4/4.
//

import Foundation
import SwiftUI

struct AboutSettingsTabView: View {
    var body: some View {
        Form {
            identitySection
        }
        .formStyle(.grouped)
    }

    // MARK: - 应用标识

    /// 图标、名字、版本、简介同处一个居中的块。
    ///
    /// 简介原先单独占一个 Section，分组样式会在两者之间画一个框、留一段空隙，
    /// 加上一个居中一个左对齐，看起来就是两截互不相干的内容。
    private var identitySection: some View {
        Section {
            VStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text("RClick")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(String(format: AppLocalization.localized("Version %@ (%@)"), getAppVersion(), getBuildVersion()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(appLocalized: "A home for the tools that make everyday work on your Mac easier.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return AppLocalization.localized("Unknown")
    }

    func getBuildVersion() -> String {
        if let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return buildVersion
        }
        return AppLocalization.localized("Unknown")
    }
}

#Preview {
    AboutSettingsTabView()
}
