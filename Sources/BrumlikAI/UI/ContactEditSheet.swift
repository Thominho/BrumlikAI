import SwiftUI

struct ContactEditSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    let recording: Recording
    let onSave: () -> Void

    @State private var name: String = ""
    @State private var phone: String = ""
    @State private var selectedClientId: UUID?
    @State private var saving = false
    @State private var saved = false
    @State private var showSaveHint = false
    @State private var doNotRecord = false
    @State private var initialDoNotRecord = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.pencil")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                Text(loc.t(.detailEditContact))
                    .font(.system(.title3, design: .rounded)).fontWeight(.semibold)
                Spacer()
                Button(action: onSave) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }

            Form {
                Section {
                    LabeledContent(loc.t(.detailPhone)) {
                        TextField(loc.t(.detailNoPhone), text: $phone)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent(loc.t(.detailContactName)) {
                        TextField(loc.t(.detailContactName), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(loc.t(.detailContactCompany)) {
                        Menu {
                            Button(loc.t(.detailUnassigned)) { selectedClientId = nil }
                            Divider()
                            ForEach(appState.clients) { client in
                                Button(client.name) { selectedClientId = client.id }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "building.2.fill")
                                    .foregroundColor(selectedClientId == nil ? .secondary : .accentColor)
                                Text(selectedClient?.name ?? loc.t(.detailUnassigned))
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .foregroundColor(.secondary).font(.caption)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                Section {
                    Toggle(isOn: $doNotRecord) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(loc.t(hasPhone ? .contactDoNotRecord : .contactDoNotRecordByName), systemImage: "lock.shield")
                            Text(loc.t(.contactDoNotRecordHint))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(!hasPhone && trimmedName.isEmpty)
                }

                Section {
                    Text(loc.t(.detailContactRememberHint))
                        .font(.footnote).foregroundColor(.secondary)
                    if showSaveHint {
                        Label(loc.t(.detailContactSaveHint), systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green).font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(action: save) {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.mini) }
                        Image(systemName: saved ? "checkmark.circle.fill" : "checkmark")
                        Text(loc.t(.detailContactSave))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                // A name is needed for the phonebook, but flipping "never record" alone can be saved too.
                .disabled(saving || (trimmedName.isEmpty && doNotRecord == initialDoNotRecord))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            name = recording.contactName ?? ""
            phone = recording.phoneNumber ?? ""
            selectedClientId = recording.clientId
            initialDoNotRecord = appState.privateRule(number: recording.phoneNumber, name: recording.contactName) != nil
            doNotRecord = initialDoNotRecord
        }
    }

    private var hasPhone: Bool { !PhonebookEntry.normalize(phone).isEmpty }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var selectedClient: Client? {
        guard let id = selectedClientId else { return nil }
        return appState.clients.first(where: { $0.id == id })
    }

    private func save() {
        saving = true
        Task {
            await coordinator.updateCaller(
                for: recording.id,
                phoneNumber: phone,
                contactName: name,
                clientId: selectedClientId
            )
            if doNotRecord != initialDoNotRecord {
                appState.setDoNotRecord(doNotRecord, number: phone, name: name)
            }
            await MainActor.run {
                saving = false
                saved = true
                showSaveHint = true
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { onSave() }
        }
    }
}
