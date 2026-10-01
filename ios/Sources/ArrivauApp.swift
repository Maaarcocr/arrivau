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
                            Button { store.logout() } label: {
                                Label("Switch role", systemImage: "person.crop.circle")
                            }
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
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Arrivau", systemImage: "bicycle.circle.fill")
                            .font(.largeTitle.bold()).foregroundStyle(.orange)
                        Text("Deliveries, one step at a time.").font(.title3)
                        Text("Local demo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                Section("What are you doing today?") {
                    ForEach(DemoRole.allCases) { role in
                        Button {
                            Task { await store.login(as: role) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: role == .dispatcher ? "list.clipboard" : "bicycle")
                                    .font(.title2).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(role == .dispatcher ? "Dispatch deliveries" : "Deliver as \(role.title)")
                                        .font(.headline)
                                    Text(role == .dispatcher ? "Create deliveries and assign a driver" : "See your next stop and get moving")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }.padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("login_\(role.rawValue)")
                        .disabled(store.isMutating)
                    }
                    if store.isMutating { ProgressView("Connecting…") }
                }
                Section {
                    ExpandableDetails("Demo setup & limitations", identifier: "demo_settings") {
                        TextField("API URL", text: $store.apiURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("api_url")
                            .disabled(store.isMutating)
                        Text("Use the iOS Simulator on the Mac running the Rust API with ARRIVAU_DEMO=1. HTTP is restricted to loopback in Debug builds.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Public demo identities only. No production authentication, payments, customer contact details, push notifications or force-quit recovery. Background location is a separate opt-in and needs device validation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
