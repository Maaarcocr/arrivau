import SwiftUI

struct AccountDeletionView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var password = ""
    @State private var confirmationReview: DeliveryStore.AccountDeletionReview?
    @State private var showingConfirmation = false
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            Form {
                if let account = store.principal {
                    Section("Il tuo account") {
                        Text(account.displayName)
                        if let team = account.teamTitle { Text("Squadra: \(team)").foregroundStyle(.secondary) }
                    }
                }
                Section("Elimina account") {
                    if let review = store.accountDeletionReview {
                        Text(review.preview.warning)
                            .accessibilityIdentifier("account_deletion_warning")
                        if review.preview.activeDeliveryCount > 0 {
                            Label("Attenzione: verranno eliminate anche \(review.preview.activeDeliveryCount) consegne ancora attive.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).accessibilityIdentifier("account_deletion_active_warning")
                        }
                    } else if store.isLoadingAccountDeletion {
                        ProgressView("Verifica dei dati da eliminare…")
                    } else {
                        Text("Il riepilogo deve essere verificato prima di eliminare l’account.")
                        Button("Riprova la verifica") { Task { await store.loadAccountDeletionReview() } }
                            .accessibilityIdentifier("retry_account_deletion_preview")
                    }
                }
                if let error = store.accountDeletionError {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("account_deletion_error")
                    }
                }
                if store.accountDeletionReview != nil {
                    Section("Conferma la tua identità") {
                        SecureField("Password attuale", text: $password)
                            .textContentType(.password).privacySensitive()
                            .accessibilityIdentifier("account_deletion_password")
                        Text("La password serve solo per questa operazione. La condivisione della posizione si fermerà quando confermi l’eliminazione.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(submitted || store.isMutating || store.isLoadingAccountDeletion)
                    Section {
                        Button("Elimina account", role: .destructive) {
                            guard !submitted, let review = store.accountDeletionReview else { return }
                            confirmationReview = review
                            showingConfirmation = true
                        }
                        .disabled(submitted || store.isMutating || store.isLoadingAccountDeletion || password.isEmpty || password.utf8.count > 1024)
                        .accessibilityIdentifier("account_deletion_review")
                        if store.isDeletingAccount { ProgressView("Eliminazione in corso…") }
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        password = ""
                        confirmationReview = nil
                        store.cancelAccountDeletionReview()
                    }
                    .disabled(submitted || store.isDeletingAccount)
                    .accessibilityIdentifier("cancel_account_deletion")
                }
            }
        }
        .interactiveDismissDisabled(submitted || store.isDeletingAccount)
        .confirmationDialog("Eliminare definitivamente l’account?", isPresented: $showingConfirmation,
                            titleVisibility: .visible, presenting: confirmationReview) { review in
            Button("Elimina definitivamente", role: .destructive) {
                guard !submitted else { return }
                submitted = true
                let enteredPassword = password
                password = ""
                confirmationReview = nil
                Task {
                    await store.deleteAccount(password: enteredPassword, review: review)
                    submitted = false
                }
            }.accessibilityIdentifier("confirm_account_deletion")
            Button("Annulla", role: .cancel) { password = ""; confirmationReview = nil }
        } message: { review in Text(review.preview.warning) }
        .onChange(of: store.accountDeletionReview?.id) { _, _ in
            password = ""
            confirmationReview = nil
            showingConfirmation = false
        }
        .onDisappear { password = ""; confirmationReview = nil }
    }
}
