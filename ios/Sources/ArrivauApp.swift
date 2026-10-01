import SwiftUI

@main
struct ArrivauApp: App {
    @StateObject private var store = DeliveryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "it_IT"))
                .tint(.orange)
                .task { store.setForeground(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in store.setForeground(phase == .active) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: DeliveryStore
    var body: some View {
        Group {
            if let role = store.role {
                NavigationStack {
                    Group {
                        if role == .dispatcher { DispatcherView() }
                        else { DriverView() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { store.logout() } label: {
                                Label("Cambia ruolo", systemImage: "person.crop.circle")
                            }
                                .accessibilityIdentifier("switch_role")
                                .disabled(store.isMutating)
                        }
                    }
                }
            } else { LoginView() }
        }
        .alert("Operazione non riuscita", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Riprova.") }
    }
}

struct LoginView: View {
    @EnvironmentObject private var store: DeliveryStore
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Arrivau", systemImage: "bicycle.circle.fill")
                            .font(.largeTitle.bold()).foregroundStyle(.orange)
                        Text("Consegne, un passo alla volta.").font(.title3)
                        Text("Demo locale").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                Section("Cosa fai oggi?") {
                    ForEach(DemoRole.allCases) { role in
                        Button {
                            Task { await store.login(as: role) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: role == .dispatcher ? "list.clipboard" : "bicycle")
                                    .font(.title2).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(role == .dispatcher ? "Gestisci le consegne" : "Consegna come \(role.title)")
                                        .font(.headline)
                                    Text(role == .dispatcher ? "Crea le consegne e scegli un corriere" : "Vedi la prossima tappa e parti")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }.padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("login_\(role.rawValue)")
                        .disabled(store.isMutating)
                    }
                    if store.isMutating { ProgressView("Connessione…") }
                }
                Section {
                    ExpandableDetails("Impostazioni e limiti della demo", identifier: "demo_settings") {
                        TextField("Indirizzo API", text: $store.apiURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("api_url")
                            .disabled(store.isMutating)
                        Text("Usa il simulatore iOS sul Mac che esegue l’API Rust con ARRIVAU_DEMO=1. Nelle build Debug, HTTP è limitato agli indirizzi locali (loopback).")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Solo identità demo pubbliche. Non sono disponibili autenticazione per l’uso reale, pagamenti, contatti dei clienti, notifiche push o ripristino dopo la chiusura forzata. La posizione in background richiede un consenso separato e verifiche su un dispositivo reale.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Benvenuto")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
