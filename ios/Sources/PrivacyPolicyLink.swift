import SwiftUI

/// Uses the selected server before login and the authenticated origin afterwards.
/// The browser opens a public URL without the app's credentials or session token.
struct PrivacyPolicyLink: View {
    @EnvironmentObject private var store: DeliveryStore

    var body: some View {
        if let url = store.privacyPolicyURL {
            Link(destination: url) {
                Label("Informativa privacy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("privacy_policy")
        } else {
            Label("Informativa privacy", systemImage: "hand.raised")
                .foregroundStyle(.secondary)
                .accessibilityHint("Servizio non configurato. Contatta il responsabile.")
        }
    }
}
