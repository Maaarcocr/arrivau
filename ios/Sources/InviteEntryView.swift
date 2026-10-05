import SwiftUI

struct InviteEntryView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var pastedInvite = ""
    @FocusState private var inputFocused: Bool
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Incolla il link o il codice", text: $pastedInvite)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().focused($inputFocused)
                        .accessibilityIdentifier("invite_input")
                        .disabled(store.isMutating)
                    Button("Apri invito") {
                        inputFocused = false
                        let input = pastedInvite
                        store.receiveInvite(input)
                        if store.pendingInvite != nil { pastedInvite = "" }
                    }
                    .disabled(store.isMutating || pastedInvite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("open_invite")
                } footer: {
                    Text("Usa l’invito ricevuto dal responsabile della tua squadra.")
                }
            }
            .navigationTitle("Hai un invito?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { pastedInvite = ""; close() }
                        .accessibilityIdentifier("close_invite_entry")
                }
            }
        }
        .alert("Operazione non riuscita", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Riprova.") }
        .onDisappear { pastedInvite = "" }
    }
}
