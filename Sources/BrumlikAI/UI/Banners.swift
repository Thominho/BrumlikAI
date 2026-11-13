import SwiftUI

struct ErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    self.message = nil
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var loc: LocalizationManager
    @EnvironmentObject var updater: UpdateChecker
    let version: String
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
            Text(String(format: loc.t(.updatesAvailable), version)).font(.caption)
            Spacer(minLength: 4)
            if updater.state == .downloading || updater.state == .installing {
                ProgressView().controlSize(.small)
            } else {
                Button(loc.t(.updatesInstall), action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }
}

struct SetupBanner: View {
    @EnvironmentObject var loc: LocalizationManager
    let missingCount: Int
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield").foregroundColor(.orange)
            Text(String(format: loc.t(.menuSetupIncomplete), missingCount))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(loc.t(.menuOpenGuide), action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}
