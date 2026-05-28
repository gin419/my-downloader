import SwiftUI

struct RequirementsBannerView: View {
    let tools: [ToolRequirement]
    let onSetup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))

            Text("Missing: \(tools.map(\.name).joined(separator: ", "))")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Spacer()

            Button("Set up…", action: onSetup)
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.orange)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss warning")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.orange.opacity(0.2)),
            alignment: .bottom
        )
    }
}
