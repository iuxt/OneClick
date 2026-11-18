import SwiftUI

struct AboutSettingsTabView: View {
    var body: some View {
        SettingsSection {
            HStack(alignment: .center, spacing: 20) {
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "OneClick")
                        .font(.title2.weight(.semibold))
                    Text(String(format: AppLocalization.localized("Version %@ (%@)"),
                                versionValue("CFBundleShortVersionString"), versionValue("CFBundleVersion")))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(appLocalized: "A home for the tools that make everyday work on your Mac easier.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    private func versionValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? AppLocalization.localized("Unknown")
    }
}
