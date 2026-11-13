import SwiftUI

struct ClientEditView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: LocalizationManager

    @State var client: Client
    let onDone: (Client?) -> Void

    @State private var ico: String = ""
    @State private var aresLoading = false
    @State private var aresError: String?
    @State private var confirmDelete = false

    private var isNew: Bool { !appState.clients.contains(where: { $0.id == client.id }) }

    var body: some View {
        Form {
            if loc.language == .czech {
                Section(loc.t(.clientsAddFromAres)) {
                    Text(loc.t(.clientsAresHint))
                        .font(.footnote).foregroundColor(.secondary)
                    HStack {
                        TextField(loc.t(.clientsIcoPlaceholder), text: $ico)
                            .textFieldStyle(.roundedBorder)
                        Button(action: fetchFromAres) {
                            HStack {
                                if aresLoading { ProgressView().controlSize(.mini) }
                                Text(loc.t(.clientsLookup))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(ico.isEmpty || aresLoading)
                    }
                    if let aresError = aresError {
                        Label(aresError, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange).font(.footnote)
                    }
                }
            }

            Section {
                TextField(loc.t(.clientsName), text: $client.name)
                TextField(loc.t(.clientsContact), text: Binding(
                    get: { client.contactPerson ?? "" },
                    set: { client.contactPerson = $0.isEmpty ? nil : $0 }
                ))
                TextField(loc.t(.clientsEmail), text: Binding(
                    get: { client.email ?? "" },
                    set: { client.email = $0.isEmpty ? nil : $0 }
                ))
                TextField(loc.t(.clientsPhone), text: Binding(
                    get: { client.phone ?? "" },
                    set: { client.phone = $0.isEmpty ? nil : $0 }
                ))
                TextField(loc.t(.clientsAddress), text: Binding(
                    get: { client.address ?? "" },
                    set: { client.address = $0.isEmpty ? nil : $0 }
                ))
            }

            Section(loc.t(.clientsNotes)) {
                TextEditor(text: Binding(
                    get: { client.notes ?? "" },
                    set: { client.notes = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 60)
                .font(.callout)
            }

            Section(loc.t(.clientsAssets)) {
                ForEach($client.assets) { $asset in
                    AssetRow(asset: $asset, onDelete: {
                        client.assets.removeAll { $0.id == asset.id }
                    })
                }
                Button(action: addAsset) {
                    Label(loc.t(.clientsAddAsset), systemImage: "plus.circle")
                }
            }

            Section {
                HStack {
                    if !isNew {
                        Button(role: .destructive, action: { confirmDelete = true }) {
                            Label(loc.t(.clientsDelete), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .confirmationDialog(
                            loc.t(.clientsConfirmDelete),
                            isPresented: $confirmDelete,
                            titleVisibility: .visible
                        ) {
                            Button(loc.t(.delete), role: .destructive) {
                                appState.deleteClient(client)
                                onDone(nil)
                            }
                            Button(loc.t(.cancel), role: .cancel) {}
                        }
                    }
                    Spacer()
                    Button(action: { onDone(client) }) {
                        Label(loc.t(.clientsSave), systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { ico = client.ico ?? "" }
    }

    private func addAsset() {
        client.assets.append(ManagedAsset(name: ""))
    }

    private func fetchFromAres() {
        aresError = nil
        aresLoading = true
        Task {
            do {
                let company = try await AresClient.lookup(ico: ico)
                await MainActor.run {
                    client.name = company.name
                    client.ico = company.ico
                    client.dic = company.dic
                    client.address = company.address
                    aresLoading = false
                }
            } catch {
                await MainActor.run {
                    aresError = error.localizedDescription
                    aresLoading = false
                }
            }
        }
    }
}

struct AssetRow: View {
    @EnvironmentObject var loc: LocalizationManager
    @Binding var asset: ManagedAsset
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $asset.kind) {
                    ForEach(AssetKind.allCases) { kind in
                        Label(loc.t(kind.label), systemImage: kind.icon).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                TextField(loc.t(.clientsAssetName), text: $asset.name)
                    .textFieldStyle(.roundedBorder)
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            TextField(loc.t(.clientsAssetUrl), text: Binding(
                get: { asset.url ?? "" }, set: { asset.url = $0.isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder)
            TextField(loc.t(.clientsAssetServer), text: Binding(
                get: { asset.server ?? "" }, set: { asset.server = $0.isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder)
            TextField(loc.t(.clientsAssetTech), text: Binding(
                get: { asset.technology ?? "" }, set: { asset.technology = $0.isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder)
            TextField(loc.t(.clientsAssetCredentials), text: Binding(
                get: { asset.credentialsHint ?? "" }, set: { asset.credentialsHint = $0.isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder)
            TextField(loc.t(.clientsAssetNotes), text: Binding(
                get: { asset.notes ?? "" }, set: { asset.notes = $0.isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 4)
    }
}
