import SwiftUI

struct ClientsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: LocalizationManager

    @State private var editing: Client?
    @State private var showAddMenu = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 260)
        } detail: {
            if let editing = editing {
                ClientEditView(client: editing, onDone: { client in
                    if let client = client { appState.upsertClient(client) }
                    self.editing = nil
                })
                .id(editing.id)
            } else {
                emptyDetail
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Label(loc.t(.clientsTitle), systemImage: "person.2.fill")
                    .font(.headline)
                Spacer()
                Menu {
                    Button(action: { editing = Client(name: "") }) {
                        Label(loc.t(.clientsAddManual), systemImage: "pencil")
                    }
                    if loc.language == .czech {
                        Button(action: { editing = Client(name: ""); showAddMenu = true }) {
                            Label(loc.t(.clientsAddFromAres), systemImage: "building.columns")
                        }
                    }
                } label: {
                    Label(loc.t(.clientsAdd), systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(14)

            Divider()

            if appState.clients.isEmpty {
                Spacer()
                Text(loc.t(.clientsEmpty))
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                List(selection: Binding(
                    get: { editing?.id },
                    set: { id in
                        if let id = id, let c = appState.clients.first(where: { $0.id == id }) {
                            editing = c
                        }
                    }
                )) {
                    ForEach(appState.clients) { client in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).font(.callout).fontWeight(.medium)
                            if !client.assets.isEmpty {
                                Text(client.assets.map { $0.name }.joined(separator: ", "))
                                    .font(.caption).foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(client.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text(loc.t(.clientsEmpty))
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
