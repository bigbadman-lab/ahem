import SwiftUI

struct AboutView: View {
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version \(version ?? "—")"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            header
                .padding(.top, 48)
                .padding(.bottom, 24)

            Text(versionString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(versionString)
                .padding(.bottom, 28)

            privacySection
                .padding(.horizontal, 36)
                .padding(.bottom, 28)

            linksSection
                .padding(.bottom, 28)

            Spacer(minLength: 16)

            Text("© 2026 Ahem")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .frame(
            minWidth: AhemLayout.aboutWindowMinWidth,
            minHeight: AhemLayout.aboutWindowMinHeight
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 16) {
            AhemAppIconView()

            VStack(spacing: 6) {
                Text("Ahem")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("for awkward moments.")
                    .font(.title3)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var privacySection: some View {
        VStack(spacing: 6) {
            Text("Everything happens locally.")
            Text("Your audio never leaves your Mac.")
            Text("No recordings are stored.")
            Text("No cloud.")
            Text("No analytics.")
        }
        .font(.body)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var linksSection: some View {
        VStack(spacing: 10) {
            Link("getahem.com", destination: AboutLinks.website)
            Link("X profile", destination: AboutLinks.xProfile)
            Link("Support", destination: AboutLinks.support)
        }
        .font(.body)
    }
}

enum AboutWindowID {
    static let value = "about"
}
