import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLogout = false

    private var hasActiveShift: Bool { store.currentDriver?.active == true || store.locationSharing }
    private var shiftStatusUnknown: Bool {
        store.principal?.supports(.driver) == true && store.currentDriver == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let account = store.principal {
                    Section {
                        Text(account.displayName).font(.headline)
                        if let team = account.teamTitle {
                            Text("Squadra: \(team)").foregroundStyle(.secondary)
                                .accessibilityIdentifier("team_identity")
                        }
                        Text(account.availableRoles.map(\.title).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    PrivacyPolicyLink()
                    Button("Esci", role: .destructive) {
                        if hasActiveShift || shiftStatusUnknown { confirmingLogout = true }
                        else { store.logout() }
                    }
                    .disabled(store.isDemo && store.isMutating)
                    .accessibilityIdentifier("account_logout")
                    if store.canDeleteAccount {
                        Button("Elimina account", role: .destructive) {
                            Task { await store.beginAccountDeletionReview() }
                        }
                        .disabled(store.isMutating)
                        .accessibilityIdentifier("account_settings")
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                        .accessibilityIdentifier("close_account")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: Binding(
            get: { store.isReviewingAccountDeletion },
            set: { if !$0 { store.cancelAccountDeletionReview() } }
        )) { AccountDeletionView() }
        .alert(hasActiveShift ? "Uscire con un turno attivo?" : "Uscire dall’account?",
               isPresented: $confirmingLogout) {
            Button("Esci", role: .destructive) { store.logout() }
                .accessibilityIdentifier("confirm_logout")
            Button("Annulla", role: .cancel) { }
                .accessibilityIdentifier("cancel_logout")
        } message: {
            Text(hasActiveShift
                 ? "La condivisione della posizione su questo iPhone si ferma. Il turno e le consegne restano attivi."
                 : "La condivisione della posizione su questo iPhone si ferma. Eventuali turni e consegne in corso restano attivi.")
        }
    }
}
