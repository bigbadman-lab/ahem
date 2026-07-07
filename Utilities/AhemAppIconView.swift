import AppKit
import SwiftUI

struct AhemAppIconView: View {
    var size: CGFloat = 72

    private var cornerRadius: CGFloat {
        size * 0.22
    }

    var body: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel("Ahem")
    }
}
