import SwiftUI
import AppKit

struct PermissionsGuideView: View {
    @EnvironmentObject var checklist: SetupChecklist
    @EnvironmentObject var loc: LocalizationManager

    var embedded = false
    var onEnterToken: (() -> Void)?

    @State private var expanded: Set<SetupItem> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section(loc.t(.guideRequired), items: SetupItem.allCases.filter(\.isRequired))
                    section(loc.t(.guideRecommended), items: SetupItem.allCases.filter { !$0.isRequired })
                    updateNote
                }
                .padding(.bottom, 8)
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(minWidth: embedded ? 0 : 620, minHeight: embedded ? 0 : 700)
        .task { await checklist.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checklist.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(loc.t(.guideTitle))
                    .font(.system(size: embedded ? 20 : 24, weight: .bold, design: .rounded))
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundColor(.green)
            }
            Text(loc.t(.guideSubtitle))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ProgressView(value: Double(checklist.doneCount), total: Double(SetupItem.allCases.count))
                    .frame(maxWidth: 220)
                Text(String(format: loc.t(.guideProgress), checklist.doneCount, SetupItem.allCases.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func section(_ title: String, items: [SetupItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.top, 6)
            ForEach(items) { item in
                SetupRow(
                    item: item,
                    onEnterToken: onEnterToken,
                    expanded: Binding(
                        get: { expanded.contains(item) },
                        set: { isExpanded in
                            if isExpanded { expanded.insert(item) } else { expanded.remove(item) }
                        }
                    )
                )
            }
        }
    }

    private var updateNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(loc.t(.guideUpdateNoteTitle), systemImage: "info.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(.blue)
            Text(loc.t(.guideUpdateNote))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.07)))
        .padding(.top, 6)
    }
}

private struct SetupRow: View {
    @EnvironmentObject var checklist: SetupChecklist
    @EnvironmentObject var loc: LocalizationManager

    let item: SetupItem
    let onEnterToken: (() -> Void)?
    @Binding var expanded: Bool

    private var status: SetupStatus { checklist.status(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: item.icon).foregroundColor(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t(item.title)).fontWeight(.semibold)
                    Text(loc.t(item.why))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = status {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    badge
                    actionButton
                }
            }

            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(loc.t(item.steps))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack {
                        if item == .iphoneCalls {
                            Toggle(loc.t(.guideMarkDone), isOn: Binding(
                                get: { status == .done },
                                set: { checklist.setIPhoneCallsConfirmed($0) }
                            ))
                            .toggleStyle(.checkbox)
                        }
                        Spacer()
                        if item.settingsURL != nil {
                            Button(loc.t(.guideOpenSettings)) { checklist.openSystemSettings(for: item) }
                                .buttonStyle(.link)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(loc.t(.guideHowTo)).font(.caption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(status == .done ? 0.3 : 0.12), lineWidth: 1))
    }

    private var tint: Color {
        switch status {
        case .done: return .green
        case .missing, .failed: return item.isRequired ? .orange : .secondary
        case .unknown, .checking: return .accentColor
        }
    }

    private var badge: some View {
        HStack(spacing: 4) {
            if status == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: badgeIcon)
            }
            Text(badgeText)
        }
        .font(.caption.weight(.medium))
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var badgeIcon: String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .missing, .failed: return "exclamationmark.circle.fill"
        case .unknown, .checking: return "questionmark.circle"
        }
    }

    private var badgeText: String {
        switch (item, status) {
        case (_, .checking): return loc.t(.guideStatusChecking)
        case (.systemAudio, .done), (.deepInfra, .done): return loc.t(.guideStatusWorks)
        case (.systemAudio, .missing), (.deepInfra, .failed): return loc.t(.guideStatusNotWorking)
        case (.deepInfra, .missing): return loc.t(.guideStatusMissing)
        case (.iphoneCalls, .done): return loc.t(.guideStatusDone)
        case (_, .done): return loc.t(.guideStatusAllowed)
        case (_, .missing), (_, .failed): return loc.t(.guideStatusNotAllowed)
        case (_, .unknown): return loc.t(.guideStatusNotVerified)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item {
        case .systemAudio:
            Button(loc.t(.guideTest)) { Task { await checklist.perform(item) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(status == .checking)
        case .deepInfra:
            if status == .missing {
                if let onEnterToken {
                    Button(loc.t(.guideEnterToken), action: onEnterToken)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                Button(loc.t(.guideCheckToken)) { Task { await checklist.perform(item) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(status == .checking)
            }
        case .iphoneCalls:
            Button(loc.t(.guideOpenFaceTime)) { Task { await checklist.perform(item) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        default:
            if status != .done {
                Button(loc.t(.guideAllow)) { Task { await checklist.perform(item) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
