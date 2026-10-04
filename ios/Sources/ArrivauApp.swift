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
                .task {
                    store.setForeground(scenePhase == .active)
                    await store.restoreSession()
                }
                .overlay {
                    if scenePhase != .active {
                        ZStack { Color(.systemBackground).ignoresSafeArea(); Text("Arrivau").font(.largeTitle.bold()).foregroundStyle(.orange) }
                    }
                }
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
                                Label(store.isDemo ? "Cambia ruolo" : "Esci", systemImage: "person.crop.circle")
                            }
                                .accessibilityIdentifier("switch_role")
                                .disabled(store.isDemo && store.isMutating)
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
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Arrivau", systemImage: "bicycle.circle.fill")
                            .font(.largeTitle.bold()).foregroundStyle(.orange)
                        Text("Consegne, un passo alla volta.").font(.title3)
                        Text(store.isDemo ? "Demo locale · Debug" : "Prova pilota supervisionata")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                #if DEBUG
                if store.isDemo { demoLogin }
                else { pilotLogin }
                #else
                pilotLogin
                #endif
            }
            .navigationTitle("Benvenuto")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var pilotLogin: some View {
        Group {
            Section("Accedi con il tuo account") {
                TextField("Nome utente", text: $username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("login_username").disabled(store.isMutating)
                SecureField("Password", text: $password)
                    .textContentType(.password).accessibilityIdentifier("login_password").disabled(store.isMutating)
                Button {
                    let enteredPassword = password
                    password = ""
                    Task { await store.login(username: username, password: enteredPassword) }
                } label: {
                    if store.isMutating { ProgressView(store.isRestoringSession ? "Verifica accesso…" : "Accesso…") }
                    else { Text("Accedi").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isMutating || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .accessibilityIdentifier("login_submit")
                if store.isMutating {
                    Button("Annulla accesso", role: .cancel) { password = ""; store.logout() }
                        .accessibilityIdentifier("cancel_login")
                }
                if store.canRetryRestore {
                    Button("Riprova l’accesso salvato") { Task { await store.restoreSession(retry: true) } }
                        .accessibilityIdentifier("restore_session")
                    Button("Dimentica l’accesso su questo iPhone", role: .destructive) { store.logout() }
                }
            }
            Section("Server della prova") {
                TextField("https://api.esempio.it", text: $store.apiURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("api_url").disabled(store.isMutating)
                Text("Usa l’indirizzo HTTPS e le credenziali forniti dal responsabile. Il server assegna il ruolo; non serve sceglierlo qui.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("La posizione si condivide solo durante il turno, dopo il tuo consenso. Continuare con lo schermo bloccato richiede un consenso separato. Uscire ferma la condivisione su questo iPhone; il turno e le consegne sul server restano attivi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    #if DEBUG
    private var demoLogin: some View {
        Group {
            Section("Cosa fai oggi?") {
                ForEach(DemoRole.allCases) { role in
                    Button {
                        Task { await store.login(as: role) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: role == .dispatcher ? "list.clipboard" : "bicycle")
                                .font(.title2).frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(role == .dispatcher ? "Gestisci le consegne" : "Consegna come \(role.title)").font(.headline)
                                Text(role == .dispatcher ? "Crea le consegne e scegli un corriere" : "Vedi la prossima tappa e parti")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("login_\(role.rawValue)").disabled(store.isMutating)
                }
                if store.isMutating { ProgressView("Connessione…") }
            }
            Section {
                ExpandableDetails("Impostazioni e limiti della demo", identifier: "demo_settings") {
                    TextField("Indirizzo API", text: $store.apiURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("api_url").disabled(store.isMutating)
                    Text("Modalità Debug esplicita, solo API loopback con ARRIVAU_DEMO=1. Identità pubbliche e posizione simulata nei test; nessuna sessione pilota viene letta o salvata.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif
}
