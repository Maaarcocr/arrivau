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
    @State private var showingAccount = false
    @State private var showingInviteEntry = false

    private var isPresentingInvite: Bool {
        !store.isRestoringSession && !store.canRetryRestore
            && (showingInviteEntry || store.pendingInvite != nil)
    }

    var body: some View {
        Group {
            if let role = store.role {
                VStack(spacing: 0) {
                    if store.canSwitchRole {
                        VStack(spacing: 8) {
                            Picker("Vista", selection: Binding(
                                get: { store.role ?? role },
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
                        }.padding(.horizontal).padding(.vertical, 8)
                    }
                    NavigationStack {
                        Group {
                            if role == .dispatcher { DispatcherView() }
                            else { DriverView() }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { showingAccount = true } label: {
                                    Label("Account", systemImage: "person.crop.circle")
                                }
                                // Keep the established profile-button identifier for UI automation.
                                .accessibilityIdentifier("switch_role")
                                .disabled(store.isDemo && store.isMutating)
                            }
                        }
                    }
                    // Discard old navigation/sheets, never the shared session or driver state.
                    .id(role)
                }
            } else {
                LoginView { showingInviteEntry = true }
            }
        }
        .sheet(isPresented: $showingAccount, onDismiss: {
            store.cancelAccountDeletionReview()
        }) { AccountView() }
        .sheet(isPresented: Binding(
            get: { isPresentingInvite },
            set: { presented in
                if !presented {
                    showingInviteEntry = false
                    if !store.isRestoringSession { store.dismissInvite() }
                }
            }
        )) {
            // Entry and signup share one presentation. A valid pasted link replaces
            // the entry form; a deep link opens signup directly, without stacking sheets.
            if let invitation = store.pendingInvite {
                InviteSignupView().id(invitation.id)
            } else {
                InviteEntryView { showingInviteEntry = false }
            }
        }
        .onChange(of: store.pendingInvite?.id) { _, invitation in
            if invitation != nil { showingInviteEntry = false }
        }
        .onChange(of: store.principal?.id) { _, _ in
            showingAccount = false
            showingInviteEntry = false
        }
        .alert("Operazione non riuscita", isPresented: Binding(
            get: { !isPresentingInvite && store.errorMessage != nil },
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
            Label(store.locationErrorMessage ?? location.compactMessage,
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
    let showInviteEntry: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Arrivau", systemImage: "bicycle.circle.fill")
                            .font(.largeTitle.bold()).foregroundStyle(.orange)
                        if store.isDemo {
                            Text("Demo locale · Debug")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
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
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
        .onDisappear { password = "" }
        .onChange(of: store.pendingInvite?.id) { _, invitation in
            if invitation != nil { password = "" }
        }
    }

    private var pilotLogin: some View {
        Group {
            Section {
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
            Section {
                Button("Hai un invito?") { password = ""; showInviteEntry() }
                    .frame(maxWidth: .infinity)
                    .disabled(store.isMutating || store.canRetryRestore)
                    .accessibilityIdentifier("show_invite_entry")
            }
            .listRowBackground(Color.clear)
            #if DEBUG
            if DeveloperServerOverride.isEnabled {
                DeveloperServerOverride(identifier: "api_url")
            }
            #endif
            Section {
                PrivacyPolicyLink().font(.footnote).frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
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

#if DEBUG
/// Only explicitly enabled development builds can override the bundled endpoint.
/// Release users always use the configured HTTPS service or their saved session.
struct DeveloperServerOverride: View {
    @EnvironmentObject private var store: DeliveryStore
    let identifier: String
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--developer-settings") }

    var body: some View {
        Section("Sviluppo · Debug") {
            TextField("Override server HTTPS", text: $store.apiURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .accessibilityIdentifier(identifier)
                .disabled(store.isMutating || store.inviteOutcomeUncertain)
        }
    }
}
#endif
