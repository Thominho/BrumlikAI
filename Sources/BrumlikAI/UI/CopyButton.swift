import SwiftUI
import AppKit

struct CopyButton: View {
    let text: String
    var compact: Bool = false

    @EnvironmentObject var loc: LocalizationManager
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                if !compact {
                    Text(copied ? loc.t(.detailCopied) : loc.t(.detailCopy))
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .foregroundColor(copied ? .green : .accentColor)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(copied ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(copied ? Color.green.opacity(0.3) : Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: copied)
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { copied = false }
        }
    }
}
