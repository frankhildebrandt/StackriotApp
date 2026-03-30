import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        SettingsScrollPage(category: .about) {
            AboutStackriotContent()

            VStack(alignment: .leading, spacing: 18) {
                Text("App details")
                    .font(.title3.weight(.semibold))

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Version")
                            .foregroundStyle(.secondary)
                        Text(versionString)
                    }
                    GridRow {
                        Text("Platform")
                            .foregroundStyle(.secondary)
                        Text("macOS 14 or later")
                    }
                    GridRow {
                        Text("Workflow")
                            .foregroundStyle(.secondary)
                        Text("Bare repositories, worktrees, remote management, and structured local task execution")
                    }
                    GridRow {
                        Text("Assumptions")
                            .foregroundStyle(.secondary)
                        Text("Stackriot expects local developer tooling such as Git, SSH, and optional AI provider endpoints to be available on this Mac.")
                    }
                }
            }
        }
    }

    private var versionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion?.nonEmpty, buildNumber?.nonEmpty) {
        case let (shortVersion?, buildNumber?):
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, nil):
            return shortVersion
        case let (nil, buildNumber?):
            return buildNumber
        default:
            return "Development build"
        }
    }
}

struct AboutView: View {
    var body: some View {
        AboutStackriotContent()
            .padding(32)
            .frame(minWidth: 460, minHeight: 320)
            .background(.regularMaterial)
    }
}

private struct AboutStackriotContent: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Stackriot")
                    .font(.largeTitle.weight(.semibold))
                Text("Repository orchestration for focused local development")
                    .foregroundStyle(.secondary)
            }

            Text("Bare repositories, worktrees, editor launchers, remote management, and structured local task execution in one macOS app.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
