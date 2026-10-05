import SwiftUI

struct InviteSignupView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var username = ""
    @State private var password = ""
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Unisciti come corriere", systemImage: "bicycle")
                        .font(.title2.bold())
                    Text("Scegli un nome utente e una password per il tuo account.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Il tuo account") {
                    TextField("Nome utente", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("invite_username")
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword).accessibilityIdentifier("invite_password")
                    Text("Nome utente: lettere minuscole, numeri, punti o trattini. Usa una password di almeno 12 caratteri semplici.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(store.isMutating || store.inviteOutcomeUncertain)
                #if DEBUG
                if DeveloperServerOverride.isEnabled {
                    DeveloperServerOverride(identifier: "invite_api_url")
                }
                #endif
                if let message = store.inviteErrorMessage {
                    Section {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("invite_error")
                    }
                }
                Section {
                    if store.inviteOutcomeUncertain {
                        Button("Torna ad Accedi") { password = ""; store.dismissInvite() }
                            .accessibilityIdentifier("invite_recover_login")
                    } else {
                        Button {
                            guard !submitted else { return }
                            submitted = true
                            let enteredPassword = password
                            password = ""
                            Task {
                                _ = await store.redeemInvite(username: username, password: enteredPassword)
                                submitted = false
                            }
                        } label: {
                            if store.isRedeemingInvite { ProgressView("Creazione account…") }
                            else { Text("Crea account e accedi").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitted || store.isMutating || InviteCredentials.validationError(username: username, password: password) != nil)
                        .accessibilityIdentifier("invite_submit")
                    }
                    Text("Hai già creato l’account? Torna ad Accedi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Benvenuto in Arrivau")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PrivacyPolicyLink().labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { password = ""; store.dismissInvite() }
                        .accessibilityIdentifier("cancel_invite")
                }
            }
        }
        .interactiveDismissDisabled(store.isRedeemingInvite)
        .alert("Operazione non riuscita", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Riprova.") }
        .onDisappear { password = "" }
    }
}

struct CreateDriverInviteView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var invite: DriverInvite?
    @State private var submitted = false
    @State private var confirmRevoke = false
    @State private var revoked = false

    var body: some View {
        NavigationStack {
            Form {
                if let invite, let link = invite.link {
                    Section {
                        Label(revoked ? "Invito revocato" : "Invito per \(invite.name)", systemImage: revoked ? "checkmark.circle" : "bicycle")
                            .font(.title2.bold()).accessibilityIdentifier("created_invite")
                        LabeledContent("Squadra", value: invite.teamName)
                            .accessibilityIdentifier("invite_team")
                        if !revoked {
                            Text("Valido fino al \(invite.expiresAt.epochDate.italianDateTime). Si può usare una sola volta.")
                                .font(.subheadline)
                            ShareLink(item: link.url, subject: Text("Invito Arrivau"),
                                      message: Text("Apri questo invito nell’app Arrivau per creare il tuo account corriere. Scade entro 24 ore.")) {
                                Label("Condividi invito", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("share_invite")
                            .disabled(store.isMutating)
                            Text("Chi possiede il link può creare l’account. Invialo solo al corriere previsto, senza pubblicarlo. Condividilo prima di chiudere: qui non resta salvato.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !revoked {
                        Section {
                            Button("Revoca invito", role: .destructive) { confirmRevoke = true }
                                .disabled(store.isMutating).accessibilityIdentifier("revoke_invite")
                            Text("La revoca impedisce nuovi utilizzi. Non elimina un account già creato.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Chi vuoi invitare?") {
                        if let team = store.principal?.teamTitle {
                            LabeledContent("Squadra", value: team)
                                .accessibilityIdentifier("invite_target_team")
                        }
                        TextField("Nome del corriere", text: $name)
                            .textContentType(.name).accessibilityIdentifier("invite_name")
                            .disabled(store.isMutating)
                        Text("Il link crea solo un account Corriere, vale 24 ore ed è monouso.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            guard !submitted else { return }
                            submitted = true
                            Task { invite = await store.createInvite(name: name); submitted = false }
                        } label: {
                            if submitted { ProgressView("Creazione invito…") }
                            else { Text("Crea invito").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitted || store.isMutating || InviteCredentials.nameValidationError(name) != nil)
                        .accessibilityIdentifier("create_invite_submit")
                    }
                }
                if let message = store.errorMessage {
                    Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("create_invite_error") }
                }
            }
            .navigationTitle("Invita un corriere")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(invite == nil ? "Annulla" : "Fine") { dismiss() }
                        .disabled(store.isMutating).accessibilityIdentifier("close_create_invite")
                }
            }
            .confirmationDialog("Revocare questo invito?", isPresented: $confirmRevoke, titleVisibility: .visible) {
                Button("Revoca invito", role: .destructive) {
                    guard let invite else { return }
                    Task { revoked = await store.revokeInvite(invite) }
                }
                Button("Annulla", role: .cancel) { }
            }
        }
        .interactiveDismissDisabled(store.isMutating)
    }
}
