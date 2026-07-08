import AppKit
import SwiftUI

struct AboutView: View {
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version \(version ?? "—")"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            AhemAppIconView()
                .padding(.bottom, 16)

            Text("Ahem")
                .font(.title)
                .fontWeight(.semibold)
                .padding(.bottom, 6)

            Text(versionString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            VStack(spacing: 4) {
                Text("You cough.")
                Text("Your browser disappears.")
            }
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(.bottom, 24)

            Link("getahem.com", destination: AboutLinks.website)
                .font(.body)
                .padding(.bottom, 28)

            Spacer(minLength: 8)

            Text("© 2026")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .frame(
            minWidth: AhemLayout.aboutWindowMinWidth,
            minHeight: AhemLayout.aboutWindowMinHeight
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keepAhemWindowInFront(titleHint: "About Ahem")
    }
}

enum AboutWindowID {
    static let value = "about"
}
