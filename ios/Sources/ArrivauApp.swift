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
                .onOpenURL { store.receiveInvite($0.absoluteString) }
                .onChange(of: scenePhase) { _, phase in store.setForeground(phase == .active) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: DeliveryStore
    var body: some View {
        Group {
            if let role = store.role {
                VStack(spacing: 0) {
                    if store.principal?.teamTitle != nil || store.canSwitchRole {
                        VStack(spacing: 8) {
                            if let team = store.principal?.teamTitle {
                                Text("Squadra: \(team)").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("team_identity")
                            }
                            if store.canSwitchRole {
                                Picker("Vista", selection: Binding(
                                    get: { role },
                                    set: { selected in
                                        if store.switchRole(to: selected) { Task { await store.refresh(force: true) } }
                                    }
                                )) {
                                    ForEach(store.availableRoles, id: \.self) { option in Text(option.title).tag(option) }
                                }
                                .pickerStyle(.segmented).accessibilityIdentifier("role_picker")
                                .disabled(store.isMutating)
                                if store.locationSharing {
                                    AccountLocationSharingNotice(location: store.location)
                                }
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                    }
                    NavigationStack {
                        Group {
                            if role == .dispatcher { DispatcherView() }
                            else { DriverView() }
                        }
                        .toolbar {
                            if store.canDeleteAccount {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button { Task { await store.beginAccountDeletionReview() } } label: {
                                        Label("Account", systemImage: "gearshape")
                                    }
                                    .accessibilityIdentifier("account_settings")
                                    .disabled(store.isMutating)
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { store.logout() } label: {
                                    Label(store.isDemo ? "Cambia account" : "Esci", systemImage: "person.crop.circle")
                                }
                                    .accessibilityIdentifier("switch_role")
                                    .disabled(store.isDemo && store.isMutating)
                            }
                        }
                    }
                    // Discard old navigation/sheets, never the shared session or driver state.
                    .id(role)
                }
            } else { LoginView() }
        }
        .sheet(item: Binding(
            get: { store.isRestoringSession || store.canRetryRestore ? nil : store.pendingInvite },
            set: { if $0 == nil && !store.isRestoringSession { store.dismissInvite() } }
        )) { invitation in InviteSignupView().id(invitation.id) }
        .sheet(isPresented: Binding(
            get: { store.isReviewingAccountDeletion },
            set: { if !$0 { store.cancelAccountDeletionReview() } }
        )) { AccountDeletionView() }
        .alert("Operazione non riuscita", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Riprova.") }
    }
}

/// Observe sensor/permission state directly so Centrale never claims a failed upload succeeded.
private struct AccountLocationSharingNotice: View {
    @EnvironmentObject private var store: DeliveryStore
    @ObservedObject var location: LocationReporter
    var body: some View {
        HStack {
            Label(store.locationErrorMessage ?? location.message,
                  systemImage: location.permissionDenied || store.locationErrorMessage != nil ? "location.slash" : "location.fill")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("account_location_sharing")
            Spacer()
            Button("Ferma") { store.setLocationSharing(false) }
                .font(.caption.weight(.semibold))
                .accessibilityLabel("Ferma condivisione posizione")
                .accessibilityIdentifier("stop_account_location")
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var username = ""
    @State private var password = ""
    @State private var pastedInvite = ""

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
                if let notice = store.accountDeletionNotice {
                    Section("Eliminazione account") {
                        Text(notice).accessibilityIdentifier("account_deletion_notice")
                        Button("Ho capito") { store.accountDeletionNotice = nil }
                    }
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
        .onDisappear { password = ""; pastedInvite = "" }
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
            Section("Hai ricevuto un invito?") {
                TextField("Incolla il link o il codice", text: $pastedInvite)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive().accessibilityIdentifier("invite_input")
                    .disabled(store.isMutating)
                Button("Apri invito") {
                    let input = pastedInvite
                    pastedInvite = ""
                    store.receiveInvite(input)
                }
                .disabled(store.isMutating || pastedInvite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("open_invite")
            }
            Section("Server della prova") {
                TextField("https://api.esempio.it", text: $store.apiURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("api_url").disabled(store.isMutating)
                Text("Usa l’indirizzo HTTPS e le credenziali forniti dal responsabile. Il server assegna la squadra e le funzioni disponibili per il tuo account.")
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
                            Image(systemName: role == .driver1 || role == .driver2 ? "bicycle" : "list.clipboard")
                                .font(.title2).frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(role == .dual ? "Centrale e corriere" : (role == .dispatcher ? "Gestisci le consegne" : "Consegna come \(role.title)")).font(.headline)
                                Text(role == .dual ? "Un account, una squadra di revisione isolata" : (role == .dispatcher ? "Crea le consegne e scegli un corriere" : "Vedi la prossima tappa e parti"))
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
