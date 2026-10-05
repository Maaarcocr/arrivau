import SwiftUI
import UIKit
import GoogleMaps
import GoogleNavigation

struct DriverNavigationView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var session: DriverNavigationSession
    @State private var showingLicenses = false
    private let testing: Bool

    init(destination: NavigationDestination, isUITesting: Bool) {
        #if DEBUG
        testing = isUITesting
        let engine: any DriverNavigationEngine = isUITesting ? TestNavigationEngine() : GoogleNavigationController()
        #else
        testing = false
        let engine: any DriverNavigationEngine = GoogleNavigationController()
        #endif
        _session = StateObject(wrappedValue: DriverNavigationSession(destination: destination, engine: engine))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.destination.address).font(.headline)
                    Text("Percorso in auto · Google Maps").font(.caption).foregroundStyle(.secondary)
                    if testing {
                        Text("NAVIGAZIONE SIMULATA · TEST").font(.caption.bold()).foregroundStyle(.orange)
                            .accessibilityIdentifier("navigation_test_mode")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                if let controller = session.engine as? GoogleNavigationController {
                    GoogleNavigationSurface(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Percorso di test", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                controls.padding().background(.regularMaterial)
            }
            .navigationTitle(session.destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") { close() }.accessibilityIdentifier("close_navigation")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingLicenses = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Informazioni Google Maps")
                }
            }
            .sheet(isPresented: $showingLicenses) { GoogleNavigationLicenses() }
        }
        .accessibilityIdentifier("google_navigation_screen")
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Text("Arrivau").font(.largeTitle.bold()).foregroundStyle(.orange)
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            session.validate(current: store.navigationDestination)
            session.setForeground(scenePhase != .background)
            session.start()
        }
        .onChange(of: store.navigationDestination) { _, current in session.validate(current: current) }
        .onChange(of: scenePhase) { _, phase in session.setForeground(phase != .background) }
        .onDisappear { session.stop() }
    }
    private var controls: some View {
        VStack(spacing: 12) {
            Text(session.state.message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("navigation_status")
            if session.state == .arrived || session.state == .failed(.destinationChanged) {
                Button("Torna alla tappa") { close() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("return_to_stop")
            } else {
                if session.state.canRetry {
                    HStack {
                        Button("Riprova") { session.start() }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("retry_navigation")
                        if case .failed(let failure) = session.state, failure.needsSettings {
                            Button("Apri Impostazioni") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                }
                if session.state == .navigating || session.state == .navigatingOffline || session.state == .paused {
                    HStack {
                        Button { session.setMuted(!session.muted) } label: {
                            Label(session.muted ? "Voce spenta" : "Voce attiva", systemImage: session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }.accessibilityIdentifier("navigation_voice")
                        Spacer()
                        Toggle("Schermo bloccato", isOn: Binding(get: { session.backgroundAllowed }, set: { session.setBackgroundAllowed($0) }))
                            .font(.caption).fixedSize().accessibilityIdentifier("navigation_background")
                    }
                }
            }
            #if DEBUG
            if testing, let engine = session.engine as? TestNavigationEngine, session.state == .navigating {
                Button("Simula arrivo (test)") { engine.simulateArrival() }.accessibilityIdentifier("simulate_navigation_arrival")
            }
            #endif
        }
    }
    private func close() { session.stop(); dismiss() }
}

private struct GoogleNavigationSurface: UIViewControllerRepresentable {
    let controller: GoogleNavigationController
    func makeUIViewController(context: Context) -> GoogleNavigationController { controller }
    func updateUIViewController(_ uiViewController: GoogleNavigationController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: GoogleNavigationController, coordinator: ()) { uiViewController.stop() }
}

private struct GoogleNavigationLicenses: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Durante la navigazione Google riceve la posizione e la destinazione per indicazioni vocali e ricalcolo. La condivisione con la centrale resta controllata separatamente nel turno. Chiudi la navigazione per interrompere Google; questo non termina il turno.")
                    Text("Attiva Schermo bloccato solo se vuoi continuare posizione e voce in background. Non riparte dopo una chiusura forzata. Imposta il percorso da fermo e rispetta sempre la segnaletica stradale.")
                    Link("Condizioni Google Maps", destination: URL(string: "https://maps.google.com/help/terms_maps/")!)
                    Link("Privacy Google", destination: URL(string: "https://policies.google.com/privacy")!)
                    Text(GMSNavigationServices.openSourceLicenseInfo()).font(.caption)
                    Text(GMSServices.openSourceLicenseInfo()).font(.caption)
                }.padding()
            }
            .navigationTitle("Google Maps")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
    }
}

#if DEBUG
/// UI-contract fixture only: no SDK, keys, real GPS, Google requests or automatic backend writes.
@MainActor
final class TestNavigationEngine: DriverNavigationEngine {
    private var event: ((DriverNavigationState) -> Void)?
    private var foreground = true
    private var background = false
    private var arrived = false
    func start(to destination: NavigationDestination, event: @escaping (DriverNavigationState) -> Void) {
        self.event = event
        arrived = false
        publish()
    }
    func stop() { event = nil }
    func setForeground(_ foreground: Bool) { self.foreground = foreground; publish() }
    func setBackgroundAllowed(_ allowed: Bool) { background = allowed; publish() }
    func setMuted(_ muted: Bool) {}
    func simulateArrival() { arrived = true; publish() }
    private func publish() { event?(arrived ? .arrived : (foreground || background ? .navigating : .paused)) }
}
#endif
