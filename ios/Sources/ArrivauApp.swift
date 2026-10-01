import SwiftUI

@main
struct ArrivauApp: App {
    @StateObject private var store = DeliveryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
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
                            Button("Switch role") { store.logout() }
                                .accessibilityIdentifier("switch_role")
                                .disabled(store.isMutating)
                        }
                    }
                }
            } else { LoginView() }
        }
        .alert("Couldn’t complete that", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Please try again.") }
    }
}

struct LoginView: View {
    @EnvironmentObject private var store: DeliveryStore
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Arrivau", systemImage: "bicycle.circle.fill")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.orange)
                    Text("A local dispatch & driver prototype")
                        .font(.headline)
                    Text("Public demo identities only. No production authentication, payments, customer contact details, push notifications or force-quit recovery. Background location is opt-in and needs device validation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Choose a demo role") {
                    ForEach(DemoRole.allCases) { role in
                        Button {
                            Task { await store.login(as: role) }
                        } label: {
                            Label(role.title, systemImage: role == .dispatcher ? "list.clipboard" : "bicycle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("login_\(role.rawValue)")
                        .disabled(store.isMutating)
                    }
                    if store.isMutating { ProgressView("Connecting…") }
                }
                Section {
                    TextField("API URL", text: $store.apiURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("api_url")
                    Text("Use the iOS Simulator on the same Mac as the Rust API. HTTP is restricted to loopback in Debug builds. Start the API with ARRIVAU_DEMO=1.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Local API") }
            }
            .navigationTitle("Local demo")
        }
    }
}
