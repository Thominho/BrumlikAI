import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, consent, api, role, permissions, guide, done
}

@MainActor
final class OnboardingState: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var apiToken: String = ""
    @Published var userRole: String = ""
    @Published var consentAccepted: Bool = false
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: LocalizationManager
    @StateObject private var state = OnboardingState()
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch state.step {
                case .welcome: WelcomeStep()
                case .consent: ConsentStep(accepted: $state.consentAccepted)
                case .api: ApiStep(token: $state.apiToken)
                case .role: RoleStep(role: $state.userRole)
                case .permissions: PermissionsGuideView(embedded: true)
                case .guide: GuideStep()
                case .done: DoneStep()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .frame(width: 680, height: 640)
        .background(backgroundGradient)
        .onAppear {
            state.apiToken = appState.deepInfraToken ?? ""
            state.userRole = appState.userRole.isEmpty ? loc.t(.onboardingRoleDefault) : appState.userRole
            state.consentAccepted = appState.consentAcknowledged
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.linearGradient(colors: [.accentColor, .purple], startPoint: .leading, endPoint: .trailing))
            Text(loc.t(.appName))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Picker("", selection: $loc.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            StepsIndicator(current: state.step)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack {
            if state.step != .welcome {
                Button(action: previous) {
                    Label(loc.t(.previous), systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if state.step == .done {
                Button(action: finish) {
                    Text(loc.t(.onboardingFinish))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: next) {
                    HStack {
                        Text(loc.t(state.step == .welcome ? .onboardingContinue : .next))
                        Image(systemName: "chevron.right")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var canAdvance: Bool {
        switch state.step {
        case .consent: return state.consentAccepted
        case .api: return !state.apiToken.trimmingCharacters(in: .whitespaces).isEmpty
        case .role: return !state.userRole.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.12), Color.purple.opacity(0.08), Color.clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func next() {
        switch state.step {
        case .api: appState.deepInfraToken = state.apiToken.trimmingCharacters(in: .whitespaces)
        case .role: appState.userRole = state.userRole.trimmingCharacters(in: .whitespaces)
        case .consent: appState.consentAcknowledged = state.consentAccepted
        default: break
        }
        if let nextStep = OnboardingStep(rawValue: state.step.rawValue + 1) {
            withAnimation(.easeInOut(duration: 0.2)) { state.step = nextStep }
        }
    }

    private func previous() {
        if let previousStep = OnboardingStep(rawValue: state.step.rawValue - 1) {
            withAnimation(.easeInOut(duration: 0.2)) { state.step = previousStep }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onClose()
    }
}

struct StepsIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 18 : 8, height: 4)
                    .animation(.easeInOut(duration: 0.2), value: current)
            }
        }
    }
}

private struct WelcomeStep: View {
    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.linearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(loc.t(.onboardingWelcomeTitle))
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(loc.t(.onboardingWelcomeSubtitle))
                .font(.title3)
                .foregroundColor(.secondary)
            Text(loc.t(.onboardingWelcomeBody))
                .font(.body)
                .lineSpacing(3)
            Spacer()
        }
    }
}

private struct ConsentStep: View {
    @EnvironmentObject var loc: LocalizationManager
    @Binding var accepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label {
                Text(loc.t(.onboardingConsentTitle))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 24))
            }
            Text(loc.t(.onboardingConsentBody))
                .lineSpacing(4)
            Spacer()
            Toggle(isOn: $accepted) {
                Text(loc.t(.onboardingConsentAck))
            }
            .toggleStyle(.checkbox)
        }
    }
}

private struct ApiStep: View {
    @EnvironmentObject var loc: LocalizationManager
    @Binding var token: String
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label {
                Text(loc.t(.onboardingApiTitle))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 24))
            }
            Text(loc.t(.onboardingApiBody))
                .lineSpacing(4)

            HStack {
                Group {
                    if reveal {
                        TextField(loc.t(.onboardingApiPlaceholder), text: $token)
                    } else {
                        SecureField(loc.t(.onboardingApiPlaceholder), text: $token)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button(action: { reveal.toggle() }) {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }

            Link(destination: URL(string: "https://deepinfra.com/dash/api_keys")!) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                    Text(loc.t(.onboardingApiHelp))
                }
                .font(.footnote)
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

private struct RoleStep: View {
    @EnvironmentObject var loc: LocalizationManager
    @Binding var role: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(loc.t(.onboardingRoleTitle))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            } icon: {
                Image(systemName: "briefcase.fill")
                    .foregroundColor(.indigo)
                    .font(.system(size: 24))
            }
            Text(loc.t(.onboardingRoleBody))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                if role.isEmpty {
                    Text(loc.t(.onboardingRolePlaceholder))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                }
                TextEditor(text: $role)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 110)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))

            Text(loc.t(.onboardingRoleHelp))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

private struct GuideStep: View {
    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label {
                Text(loc.t(.onboardingGuideTitle))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            } icon: {
                Image(systemName: "book.fill")
                    .foregroundColor(.indigo)
                    .font(.system(size: 24))
            }
            ScrollView {
                Text(loc.t(.onboardingGuideBody))
                    .font(.body)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
    }
}

private struct DoneStep: View {
    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.linearGradient(colors: [.green, .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(loc.t(.onboardingDoneTitle))
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(loc.t(.onboardingDoneBody))
                .foregroundColor(.secondary)
                .lineSpacing(3)
            Spacer()
        }
    }
}
