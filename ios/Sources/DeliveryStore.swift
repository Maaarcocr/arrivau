import Foundation
import Combine

@MainActor
final class DeliveryStore: ObservableObject {
    @Published private(set) var role: UserRole?
    var availableRoles: [UserRole] { principal?.availableRoles ?? [] }
    var canSwitchRole: Bool { availableRoles.count > 1 }
    /// Dual accounts receive the team's dispatcher data; their driver screen shows only their work.
    var deliveries: [Delivery] {
        role == .driver ? availableDeliveries.filter { $0.driverId == principal?.id } : availableDeliveries
    }
    @Published private(set) var pendingInvite: InviteLink?
    @Published private(set) var inviteOutcomeUncertain = false
    @Published private(set) var inviteErrorMessage: String?
    @Published private(set) var isRedeemingInvite = false
    @Published private(set) var principal: Principal?
    var canDeleteAccount: Bool { !isDemo && principal?.canDeleteAccount == true }
    @Published private(set) var isReviewingAccountDeletion = false
    @Published private(set) var isLoadingAccountDeletion = false
    @Published private(set) var isDeletingAccount = false
    @Published private(set) var accountDeletionReview: AccountDeletionReview?
    @Published private(set) var accountDeletionError: String?
    @Published var accountDeletionNotice: String?
    private var accountDeletionReadId = UUID()
    @Published private var availableDeliveries: [Delivery] = []
    @Published private(set) var restaurants: [Restaurant] = []
    @Published private(set) var pendingRestaurant: PendingRestaurant?
    @Published private(set) var loadingRestaurants = false
    @Published private(set) var restaurantLoadError: String?
    private var restaurantReadId = UUID()
    @Published private(set) var drivers: [Driver] = []
    @Published private(set) var currentDriver: Driver?
    @Published private(set) var route: DriverRoute?
    @Published private(set) var pendingCreation: PendingCreation?
    @Published private(set) var legacyPendingCreation: PendingCreation?
    var legacyCreationNeedsReview: Bool { legacyPendingCreation != nil }
    @Published private(set) var createOutcomeUncertain = false
    @Published private(set) var isMutating = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var canRetryRestore = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var locationSharing = false
    @Published private(set) var backgroundLocationSharing = false
    @Published var errorMessage: String?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var locationErrorMessage: String?
    @Published var apiURL: String
    var privacyPolicyURL: URL? {
        let origin = client?.baseURL.absoluteString ?? apiURL
        return (try? APIConfiguration.validatedURL(origin, mode: mode))?.appendingPathComponent("privacy")
    }
    let location: LocationReporter
    let isUITesting: Bool
    let mode: ConnectionMode
    var isDemo: Bool {
        #if DEBUG
        mode == .demo
        #else
        false
        #endif
    }
    private var client: APIClient?
    private let urlSession: URLSession
    private let storage: SessionStorage
    private var sessionExpiresAt: Int?
    private var didAttemptRestore = false
    private var creationScope: String?
    private var foreground = false
    private var pollTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    // Never persisted. A stop or consent change invalidates a pending start’s location grant.
    private var locationConsentId = UUID()
    private var expiryTask: Task<Void, Never>?
    private var revocationTasks: [UUID: Task<Void, Never>] = [:]
    // Never persisted: interrupted redemptions use normal login recovery.
    private var uncertainInviteTokens: Set<String> = []
    private var sessionId = UUID()
    private var refreshId = UUID()
    private var viewId = UUID()
    private enum ActionKind: Equatable { case assignment(String), status(DeliveryStatus), readiness(ReadinessUpdate) }
    private struct PendingAction {
        let kind: ActionKind
        let key: String
    }
    private var pendingActions: [String: PendingAction] = [:]
    private var readinessNeedsRefresh: Set<String> = []

    func pendingReadiness(for deliveryId: String) -> ReadinessUpdate? {
        guard case .readiness(let update) = pendingActions[deliveryId]?.kind else { return nil }
        return update
    }

    /// Immutable confirmation context: an old sheet cannot clear another session/team's recovery.
    struct LegacyCreationReview {
        fileprivate let sessionId: UUID
        fileprivate let viewId: UUID
        fileprivate let currentScope: String
        fileprivate let legacyScope: String
        let pending: PendingCreation
    }

    /// Bound to one session and one displayed snapshot. Cancel/reopen invalidates it.
    struct AccountDeletionReview: Equatable {
        fileprivate let sessionId: UUID
        let id: UUID
        let preview: AccountDeletionPreview
    }

    func beginAccountDeletionReview() async {
        guard validateSession(), canDeleteAccount, !isMutating, !isReviewingAccountDeletion else { return }
        isReviewingAccountDeletion = true
        await loadAccountDeletionReview()
    }

    func cancelAccountDeletionReview() {
        guard !isDeletingAccount else { return }
        resetAccountDeletionReview()
    }

    private func resetAccountDeletionReview() {
        accountDeletionReadId = UUID()
        isReviewingAccountDeletion = false
        isLoadingAccountDeletion = false
        isDeletingAccount = false
        accountDeletionReview = nil
        accountDeletionError = nil
    }

    func loadAccountDeletionReview(preservingError: Bool = false) async {
        guard validateSession(), canDeleteAccount, isReviewingAccountDeletion,
              !isMutating, !isLoadingAccountDeletion, let api = client else { return }
        let session = sessionId
        let request = UUID()
        accountDeletionReadId = request
        accountDeletionReview = nil
        isLoadingAccountDeletion = true
        if !preservingError { accountDeletionError = nil }
        defer { if session == sessionId, request == accountDeletionReadId { isLoadingAccountDeletion = false } }
        do {
            let preview = try await api.accountDeletionPreview()
            guard session == sessionId, request == accountDeletionReadId, isReviewingAccountDeletion,
                  !Task.isCancelled else { return }
            accountDeletionReview = AccountDeletionReview(sessionId: session, id: request, preview: preview)
        } catch {
            guard session == sessionId, request == accountDeletionReadId, !Task.isCancelled else { return }
            if !handleUnauthorized(error) {
                accountDeletionError = "Impossibile verificare i dati da eliminare. \(ItalianPresentation.errorMessage(error))"
            }
        }
    }

    /// Only the explicit destructive confirmation calls this. Nothing is persisted or retried.
    @discardableResult
    func deleteAccount(password: String, review: AccountDeletionReview) async -> Bool {
        guard validateSession(), canDeleteAccount, isReviewingAccountDeletion,
              !isMutating, !isLoadingAccountDeletion, !Task.isCancelled,
              !password.isEmpty, password.utf8.count <= 1024,
              review.sessionId == sessionId, accountDeletionReview == review,
              let api = client else { return false }
        let session = sessionId
        isMutating = true
        isDeletingAccount = true
        accountDeletionError = nil
        // Do not let an old refresh or location upload repopulate the account during deletion.
        refreshId = UUID(); isRefreshing = false
        setLocationSharing(false)
        do {
            try await api.deleteAccount(password: password, confirmation: review.preview.confirmation)
            guard session == sessionId else { return false }
            finishAccountDeletionLocally(message: "Account eliminato definitivamente. Le consegne collegate e i dati dell’account sono stati rimossi. La condivisione della posizione è ferma.")
            return true
        } catch {
            guard session == sessionId else { return false }
            if handleUnauthorized(error) { return false }
            let failure = error as? APIError
            let uncertain = error is URLError || error is CancellationError
                || failure?.mutationOutcomeUncertain == true || (300..<400).contains(failure?.statusCode ?? 0)
            if uncertain {
                finishAccountDeletionLocally(message: "Non è possibile confermare se l’account è stato eliminato. Sei uscito da questo iPhone e la condivisione della posizione è ferma. La richiesta non verrà ripetuta automaticamente. Prova ad accedere per verificare se l’account esiste ancora; se non riesci, chiedi al responsabile di verificarlo.")
                return false
            }
            isMutating = false
            isDeletingAccount = false
            if failure?.statusCode == 409 {
                accountDeletionReview = nil
                accountDeletionError = "Le consegne collegate sono cambiate. Rileggi il riepilogo aggiornato, reinserisci la password e conferma di nuovo."
                await loadAccountDeletionReview(preservingError: true)
            } else if failure?.statusCode == 429 {
                accountDeletionError = "Troppi tentativi di eliminazione. Attendi qualche minuto e reinserisci la password prima di riprovare."
            } else {
                accountDeletionError = ItalianPresentation.errorMessage(error)
            }
            return false
        }
    }

    private func finishAccountDeletionLocally(message: String) {
        var recoveryCleared = true
        if let user = principal, let api = client {
            let scopes = Set([CreationScope.current(endpoint: api.baseURL.absoluteString, user: user),
                              CreationScope.legacy(endpoint: api.baseURL.absoluteString, accountId: user.id)])
            for scope in scopes {
                do { try storage.clearCreation(scope: scope) } catch { recoveryCleared = false }
                do { try storage.clearRestaurant(scope: scope) } catch { recoveryCleared = false }
            }
        }
        uncertainInviteTokens = []
        inviteOutcomeUncertain = false
        invalidateSession(message: nil)
        let cleanupWarning = errorMessage
        errorMessage = nil
        accountDeletionNotice = message
        if !recoveryCleared || cleanupWarning != nil {
            accountDeletionNotice = message + " Non è stato possibile rimuovere tutti i dati protetti da questo iPhone. Sblocca il dispositivo e chiedi assistenza per la pulizia locale."
        }
    }


    init(session: URLSession = APIClient.secureSession, deterministicLocation: Bool? = nil,
         mode: ConnectionMode? = nil, storage: SessionStorage? = nil) {
        urlSession = session
        #if DEBUG
        let pilotUITesting = ProcessInfo.processInfo.arguments.contains("--pilot-uitesting")
        isUITesting = deterministicLocation ?? (!pilotUITesting && ProcessInfo.processInfo.arguments.contains("--uitesting"))
        self.mode = mode ?? (pilotUITesting ? .pilot : ((isUITesting || ProcessInfo.processInfo.arguments.contains("--demo")) ? .demo : .pilot))
        if let storage { self.storage = storage }
        // Unsigned simulator UI tests exercise the real pilot screen and HTTPS policy,
        // but cannot depend on signing-dependent Keychain entitlements or persisted user state.
        else if self.mode == .demo || pilotUITesting { self.storage = MemorySessionStorage() }
        else { self.storage = KeychainSessionStorage() }
        let configuredURL = ProcessInfo.processInfo.environment["ARRIVAU_API_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "ARRIVAU_API_URL") as? String ?? ""
        apiURL = configuredURL.isEmpty ? (self.mode == .demo ? "http://localhost:8080" : "") : configuredURL
        #else
        isUITesting = false
        self.mode = .pilot
        self.storage = storage ?? KeychainSessionStorage()
        apiURL = Bundle.main.object(forInfoDictionaryKey: "ARRIVAU_API_URL") as? String ?? ""
        #endif
        location = LocationReporter(deterministic: isUITesting)
        location.onCoordinate = { [weak self] coordinate in self?.reportLocation(coordinate) }
    }

    func login(username: String, password: String) async {
        guard !isMutating, principal == nil, !isDemo else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { errorMessage = "Inserisci nome utente e password."; return }
        didAttemptRestore = true
        let attempt = UUID()
        sessionId = attempt
        isMutating = true
        errorMessage = nil
        defer { if sessionId == attempt { isMutating = false } }
        do {
            let endpoint = try APIConfiguration.validatedURL(apiURL, mode: .pilot)
            let anonymous = APIClient(baseURL: endpoint, token: "", session: urlSession)
            let result = try await anonymous.login(username: username, password: password)
            let api = APIClient(baseURL: endpoint, token: result.token, session: urlSession)
            guard sessionId == attempt, !Task.isCancelled else { try? await api.revokeSession(); return }
            guard !result.token.isEmpty, result.user.serverRole != nil, result.expiresAt > Int(Date().timeIntervalSince1970) else {
                try? await api.revokeSession()
                throw APIError(message: "Il server ha restituito una sessione non valida.")
            }
            do {
                try storage.saveSession(SavedSession(endpoint: endpoint.absoluteString, token: result.token, expiresAt: result.expiresAt))
                try install(api, user: result.user, expiresAt: result.expiresAt)
            } catch {
                try? storage.clearSession()
                try? await api.revokeSession()
                throw error
            }
            await refresh(force: true)
            startPolling()
        } catch {
            guard sessionId == attempt else { return }
            errorMessage = (error as? APIError)?.isUnauthorized == true
                ? "Nome utente o password non validi. Riprova con le credenziali fornite dal responsabile."
                : ItalianPresentation.errorMessage(error)
        }
    }

    /// Opening a link never changes the server or logs an existing user out.
    func receiveInvite(_ input: String) {
        guard !isDemo else { errorMessage = "Gli inviti sono disponibili solo nella prova pilota."; return }
        guard let invitation = InviteLink(input: input) else {
            errorMessage = "Invito non valido. Incolla il link Arrivau completo o il codice ricevuto dal responsabile."
            return
        }
        guard principal == nil else { errorMessage = Self.alreadySignedInInviteMessage; return }
        guard !canRetryRestore else {
            errorMessage = "Verifica o dimentica prima l’accesso salvato, poi riapri l’invito."
            return
        }
        guard !isMutating || isRestoringSession else {
            errorMessage = "Attendi la fine dell’accesso in corso, poi riapri l’invito."
            return
        }
        errorMessage = nil
        pendingInvite = invitation
        inviteOutcomeUncertain = uncertainInviteTokens.contains(invitation.token)
        inviteErrorMessage = inviteOutcomeUncertain ? InviteCredentials.recoveryMessage : nil
    }

    func dismissInvite() {
        if isRedeemingInvite, pendingInvite != nil {
            markInviteUncertain()
            // The HTTP request may have committed. Its late result is revoked, never installed.
            sessionId = UUID()
            isMutating = false
            isRedeemingInvite = false
            errorMessage = InviteCredentials.recoveryMessage
        }
        pendingInvite = nil
        inviteErrorMessage = nil
    }

    private static let alreadySignedInInviteMessage = "Hai già effettuato l’accesso. Per usare l’invito con un altro account, esci prima e riapri il link."

    private func markInviteUncertain() {
        if let pendingInvite { uncertainInviteTokens.insert(pendingInvite.token) }
        inviteOutcomeUncertain = true
        inviteErrorMessage = InviteCredentials.recoveryMessage
    }

    /// A redemption is sent only once at a time, and never automatically replayed.
    /// The account can exist even when its response, or local Keychain installation, fails.
    func redeemInvite(username: String, password: String) async -> Bool {
        guard !isDemo, !isMutating, principal == nil, !canRetryRestore,
              let invitation = pendingInvite, !inviteOutcomeUncertain else { return false }
        if let message = InviteCredentials.validationError(username: username, password: password) {
            inviteErrorMessage = message
            return false
        }
        let endpoint: URL
        do { endpoint = try APIConfiguration.validatedURL(apiURL, mode: .pilot) }
        catch { inviteErrorMessage = ItalianPresentation.errorMessage(error); return false }
        didAttemptRestore = true
        let attempt = UUID()
        sessionId = attempt
        isMutating = true
        isRedeemingInvite = true
        inviteErrorMessage = nil
        errorMessage = nil
        var dispatched = false
        var accountCreated = false
        defer { if sessionId == attempt { isMutating = false; isRedeemingInvite = false } }
        do {
            try Task.checkCancellation()
            let anonymous = APIClient(baseURL: endpoint, token: "", session: urlSession)
            dispatched = true
            let result = try await anonymous.redeemInvite(token: invitation.token, username: username, password: password)
            accountCreated = true
            let api = APIClient(baseURL: endpoint, token: result.token, session: urlSession)
            guard sessionId == attempt, !Task.isCancelled else {
                if sessionId == attempt { markInviteUncertain() }
                if !result.token.isEmpty { try? await api.revokeSession() }
                return false
            }
            guard !result.token.isEmpty, result.user.role == "driver", result.user.roles == ["driver"],
                  InviteTeamIdentity.isValid(id: result.user.teamId, name: result.user.teamName),
                  result.expiresAt > Int(Date().timeIntervalSince1970) else {
                if !result.token.isEmpty { try? await api.revokeSession() }
                throw APIError(message: "Il server ha restituito una sessione non valida.", mutationOutcomeUncertain: true)
            }
            do {
                try storage.saveSession(SavedSession(endpoint: endpoint.absoluteString, token: result.token, expiresAt: result.expiresAt))
                try install(api, user: result.user, expiresAt: result.expiresAt, redeemingInvite: true)
            } catch {
                try? storage.clearSession()
                try? await api.revokeSession()
                throw error
            }
            inviteOutcomeUncertain = false
            inviteErrorMessage = nil
            await refresh(force: true)
            guard sessionId == attempt else { return false }
            startPolling()
            return true
        } catch {
            guard sessionId == attempt else { return false }
            let failure = error as? APIError
            let unresolvedResponse = error is URLError || error is CancellationError
                || failure?.mutationOutcomeUncertain == true || (300..<400).contains(failure?.statusCode ?? 0)
            if accountCreated || (dispatched && unresolvedResponse) {
                markInviteUncertain()
            } else {
                inviteErrorMessage = ItalianPresentation.errorMessage(error)
            }
            return false
        }
    }

    func createInvite(name: String) async -> DriverInvite? {
        guard !isDemo, validateSession(), role == .dispatcher, let issuer = principal,
              issuer.supports(.dispatcher), let api = client, !isMutating else { return nil }
        guard InviteTeamIdentity.isValid(id: issuer.teamId, name: issuer.teamName) else {
            errorMessage = "La squadra dell’account non è valida. Accedi di nuovo prima di invitare un corriere."
            return nil
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = InviteCredentials.nameValidationError(name) { errorMessage = message; return nil }
        let session = sessionId
        isMutating = true
        errorMessage = nil
        defer { if session == sessionId { isMutating = false } }
        do {
            try Task.checkCancellation()
            let invite = try await api.createInvite(name: name)
            guard sessionId == session, !Task.isCancelled else {
                try? await api.revokeInvite(id: invite.id)
                return nil
            }
            guard invite.role == "driver", invite.link != nil, UUID(uuidString: invite.id) != nil,
                  InviteTeamIdentity.isValid(id: invite.teamId, name: invite.teamName),
                  invite.teamId == issuer.teamId, invite.teamName == issuer.teamName,
                  invite.expiresAt > Int(Date().timeIntervalSince1970) else {
                try? await api.revokeInvite(id: invite.id)
                throw APIError(message: "Il server ha restituito un invito non valido. Non condividerlo.")
            }
            return invite
        } catch {
            guard sessionId == session else { return nil }
            if !handleUnauthorized(error) {
                if error is URLError || error is CancellationError || (error as? APIError)?.mutationOutcomeUncertain == true {
                    errorMessage = "Creazione dell’invito non confermata. Nessun link disponibile da condividere; un eventuale invito non condiviso scadrà entro 24 ore. Riprova solo se vuoi creare un nuovo invito."
                } else { errorMessage = ItalianPresentation.errorMessage(error) }
            }
            return nil
        }
    }

    func revokeInvite(_ invite: DriverInvite) async -> Bool {
        guard !isDemo, validateSession(), role == .dispatcher, let issuer = principal,
              issuer.supports(.dispatcher), let api = client, !isMutating,
              InviteTeamIdentity.isValid(id: issuer.teamId, name: issuer.teamName),
              invite.teamId == issuer.teamId else { return false }
        let session = sessionId
        isMutating = true
        errorMessage = nil
        defer { if session == sessionId { isMutating = false } }
        do {
            try await api.revokeInvite(id: invite.id)
            return sessionId == session && !Task.isCancelled
        } catch {
            guard sessionId == session else { return false }
            if !handleUnauthorized(error) { errorMessage = "Revoca non confermata. \(ItalianPresentation.errorMessage(error))" }
            return false
        }
    }

    /// Restore authority only after the server validates the saved opaque session.
    /// Location sharing always needs a new explicit opt-in after app launch/login.
    func restoreSession(retry: Bool = false) async {
        guard !isDemo, principal == nil, !isMutating, retry || !didAttemptRestore else { return }
        didAttemptRestore = true
        let attempt = UUID()
        sessionId = attempt
        isRestoringSession = true
        isMutating = true
        canRetryRestore = false
        defer { if sessionId == attempt { isMutating = false; isRestoringSession = false } }
        do {
            guard let saved = try storage.loadSession() else { return }
            guard saved.expiresAt > Int(Date().timeIntervalSince1970), !saved.token.isEmpty else {
                invalidateSession(message: "Sessione scaduta. Accedi di nuovo.", preservingInvite: true)
                return
            }
            let endpoint = try APIConfiguration.validatedURL(saved.endpoint)
            apiURL = endpoint.absoluteString
            let api = APIClient(baseURL: endpoint, token: saved.token, session: urlSession)
            let identity = try await api.identity()
            guard sessionId == attempt, !Task.isCancelled else { return }
            guard let expiresAt = identity.expiresAt, expiresAt > Int(Date().timeIntervalSince1970), identity.user.serverRole != nil else {
                invalidateSession(message: "Sessione non valida. Accedi di nuovo.", preservingInvite: true)
                return
            }
            try storage.saveSession(SavedSession(endpoint: endpoint.absoluteString, token: saved.token, expiresAt: expiresAt))
            try install(api, user: identity.user, expiresAt: expiresAt)
            await refresh(force: true)
            startPolling()
        } catch {
            guard sessionId == attempt else { return }
            if handleUnauthorized(error, preservingInvite: true) { return }
            canRetryRestore = true
            errorMessage = "Accesso salvato non verificato. \(ItalianPresentation.errorMessage(error))"
        }
    }

    #if DEBUG
    func login(as selectedRole: DemoRole) async {
        guard isDemo, !isMutating else { return }
        let attempt = UUID()
        sessionId = attempt
        isMutating = true
        defer { if sessionId == attempt { isMutating = false } }
        do {
            let api = APIClient(baseURL: try APIConfiguration.validatedURL(apiURL, mode: .demo), token: selectedRole.token, session: urlSession)
            let user = try await api.me()
            guard sessionId == attempt, !Task.isCancelled else { return }
            let expectedRole: UserRole = selectedRole == .dispatcher || selectedRole == .dual ? .dispatcher : .driver
            guard user.supports(expectedRole),
                  selectedRole != .dual || user.supports(.driver),
                  selectedRole.driverId == nil || user.id == selectedRole.driverId else {
                throw APIError(message: "L’API ha restituito un’identità demo inattesa.")
            }
            try install(api, user: user, expiresAt: nil)
            await refresh(force: true)
            startPolling()
        } catch { if sessionId == attempt { errorMessage = ItalianPresentation.errorMessage(error) } }
    }
    #endif

    private func install(_ api: APIClient, user: Principal, expiresAt: Int?, redeemingInvite: Bool = false) throws {
        let scope = CreationScope.current(endpoint: api.baseURL.absoluteString, user: user)
        let pending = user.supports(.dispatcher) ? try storage.loadCreation(scope: scope) : nil
        let restaurantRecovery = user.supports(.dispatcher) ? try storage.loadRestaurant(scope: scope) : nil
        let legacyScope = CreationScope.legacy(endpoint: api.baseURL.absoluteString, accountId: user.id)
        let legacy = user.supports(.dispatcher) && user.teamId != nil ? try storage.loadCreation(scope: legacyScope) : nil
        client = api
        apiURL = api.baseURL.absoluteString
        principal = user
        resetAccountDeletionReview()
        accountDeletionNotice = nil
        role = user.serverRole
        viewId = UUID()
        creationScope = scope
        legacyPendingCreation = legacy
        pendingCreation = pending
        createOutcomeUncertain = pending != nil
        sessionExpiresAt = expiresAt
        errorMessage = nil
        canRetryRestore = false
        locationTask?.cancel(); locationTask = nil
        location.stop()
        locationSharing = false
        backgroundLocationSharing = false
        locationConsentId = UUID()
        restaurants = []; pendingRestaurant = restaurantRecovery; restaurantReadId = UUID(); loadingRestaurants = false; restaurantLoadError = nil
        availableDeliveries = []; drivers = []; currentDriver = nil; route = nil
        pendingActions = [:]; readinessNeedsRefresh = []; lastSyncedAt = nil; syncErrorMessage = nil; locationErrorMessage = nil
        scheduleExpiry()
        if pendingInvite != nil {
            pendingInvite = nil
            inviteErrorMessage = nil
            if !redeemingInvite { errorMessage = Self.alreadySignedInInviteMessage }
        }
    }

    /// Select an already authorized capability without changing account, team or bearer.
    /// View changes do not alter an explicit location opt-in, end the shift or discard the own-driver route.
    @discardableResult
    func switchRole(to selectedRole: UserRole) -> Bool {
        guard validateSession(), !isMutating, let principal, principal.supports(selectedRole),
              role != selectedRole else { return false }
        viewId = UUID()
        restaurantReadId = UUID(); loadingRestaurants = false
        refreshId = UUID()
        isRefreshing = false
        role = selectedRole
        errorMessage = nil; syncErrorMessage = nil; lastSyncedAt = nil
        return true
    }

    /// Local privacy controls stop immediately, even if server revocation cannot reach the network.
    func logout() {
        var previous = client
        if previous == nil, !isDemo, let saved = try? storage.loadSession(),
           let endpoint = try? APIConfiguration.validatedURL(saved.endpoint) {
            previous = APIClient(baseURL: endpoint, token: saved.token, session: urlSession)
        }
        let revoke = !isDemo
        invalidateSession(message: nil)
        let signedOut = sessionId
        guard revoke, let previous else { return }
        let revocationId = UUID()
        revocationTasks[revocationId] = Task { [weak self] in
            defer { self?.revocationTasks[revocationId] = nil }
            do { try await previous.revokeSession() }
            catch {
                guard (error as? APIError)?.isUnauthorized != true,
                      let self, self.sessionId == signedOut, self.principal == nil else { return }
                self.errorMessage = "Sei uscito da questo iPhone e la posizione è ferma. La revoca sul server non è confermata: chiedi al responsabile di revocare la sessione; altrimenti resterà valida fino alla scadenza."
            }
        }
    }

    /// Owners of an injected transport must join outstanding logout work before disposing it.
    /// Local sign-out remains synchronous so GPS and private views stop without waiting for network I/O.
    func awaitPendingRevocations() async {
        let pending = Array(revocationTasks.values)
        for task in pending { await task.value }
    }

    private func invalidateSession(message: String?, preservingInvite: Bool = false) {
        resetAccountDeletionReview()
        // A cold-launch invite survives rejection of an older saved session. Explicit logout,
        // cancellation and invalidation of an active account still discard the invitation.
        let queuedInvite = preservingInvite && !isRedeemingInvite ? pendingInvite : nil
        if isRedeemingInvite { markInviteUncertain() }
        pendingInvite = queuedInvite
        inviteErrorMessage = queuedInvite != nil && inviteOutcomeUncertain ? InviteCredentials.recoveryMessage : nil
        isRedeemingInvite = false
        sessionId = UUID()
        viewId = UUID()
        refreshId = UUID()
        pollTask?.cancel(); pollTask = nil
        locationTask?.cancel(); locationTask = nil
        expiryTask?.cancel(); expiryTask = nil
        location.stop()
        locationSharing = false
        backgroundLocationSharing = false
        locationConsentId = UUID()
        principal = nil; role = nil; client = nil; currentDriver = nil
        restaurants = []; pendingRestaurant = nil; restaurantReadId = UUID(); loadingRestaurants = false; restaurantLoadError = nil
        availableDeliveries = []; drivers = []; route = nil
        errorMessage = queuedInvite == nil ? message : nil; syncErrorMessage = nil; locationErrorMessage = nil
        pendingCreation = nil; creationScope = nil; pendingActions = [:]; readinessNeedsRefresh = []; legacyPendingCreation = nil
        createOutcomeUncertain = false
        sessionExpiresAt = nil
        lastSyncedAt = nil; isRefreshing = false; isMutating = false; isRestoringSession = false
        canRetryRestore = false
        do { try storage.clearSession() }
        catch {
            canRetryRestore = true
            errorMessage = "La posizione è ferma, ma non è stato possibile rimuovere la sessione protetta. Sblocca l’iPhone e riprova a dimenticare l’accesso."
        }
    }

    private func handleUnauthorized(_ error: Error, preservingInvite: Bool = false) -> Bool {
        guard (error as? APIError)?.isUnauthorized == true else { return false }
        invalidateSession(message: "Sessione scaduta o revocata. La condivisione della posizione è ferma. Accedi di nuovo.", preservingInvite: preservingInvite)
        return true
    }
    @discardableResult private func validateSession() -> Bool {
        if let expiry = sessionExpiresAt, expiry <= Int(Date().timeIntervalSince1970) {
            invalidateSession(message: "Sessione scaduta. La condivisione della posizione è ferma. Accedi di nuovo.")
            return false
        }
        return true
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiry = sessionExpiresAt else { return }
        let session = sessionId
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, Double(expiry) - Date().timeIntervalSince1970))) }
            catch { return }
            guard let self, self.sessionId == session else { return }
            self.validateSession()
        }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        guard validateSession() else { return }
        if value { startPolling() }
        else { pollTask?.cancel(); pollTask = nil }
        synchronizeLocation()
    }

    private func startPolling() {
        guard foreground, role != nil, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard validateSession(), !isDeletingAccount, let api = client, let selectedRole = role, force || (!isRefreshing && !isMutating) else { return }
        let session = sessionId
        let requestId = UUID()
        refreshId = requestId
        isRefreshing = true
        defer { if refreshId == requestId { isRefreshing = false } }
        do {
            async let jobs = api.deliveries()
            if selectedRole == .dispatcher {
                let people = try await api.drivers()
                let fetchedJobs = try await jobs
                guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
                drivers = people
                applyFetchedDeliveries(fetchedJobs)
                if principal?.supports(.driver) == true,
                   let ownDriver = people.first(where: { $0.id == principal?.id }) {
                    currentDriver = ownDriver
                    if !ownDriver.active { reconcileInactiveShiftLocation() }
                }
            } else {
                async let planned = api.route()
                let driver = try await api.shift()
                let (fetchedJobs, fetchedRoute) = try await (jobs, planned)
                guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
                guard driver.id == principal?.id, fetchedRoute.driverId == principal?.id else {
                    throw APIError(message: "Il server ha restituito un profilo corriere non valido per questo account.")
                }
                currentDriver = driver
                if !driver.active { reconcileInactiveShiftLocation() }
                applyFetchedDeliveries(fetchedJobs)
                route = fetchedRoute
                synchronizeLocation()
            }
            reconcilePendingActions()
            lastSyncedAt = Date()
            syncErrorMessage = nil
        } catch is CancellationError { }
        catch {
            guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
            if handleUnauthorized(error) { return }
            syncErrorMessage = ItalianPresentation.errorMessage(error)
        }
    }

    func loadRestaurants() async {
        guard validateSession(), role == .dispatcher, principal?.supports(.dispatcher) == true,
              let api = client else { return }
        let session = sessionId
        let view = viewId
        let request = UUID()
        restaurantReadId = request
        loadingRestaurants = true
        defer { if restaurantReadId == request { loadingRestaurants = false } }
        do {
            let fetched = try await api.restaurants()
            guard session == sessionId, view == viewId, restaurantReadId == request, !Task.isCancelled else { return }
            restaurants = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            restaurantLoadError = nil
        } catch {
            guard session == sessionId, view == viewId, restaurantReadId == request, !Task.isCancelled else { return }
            if handleUnauthorized(error) { return }
            restaurantLoadError = "Impossibile caricare i ristoranti. Riprova."
        }
    }

    func createRestaurant(_ restaurant: NewRestaurant) async -> Restaurant? {
        guard validateSession(), !isMutating, role == .dispatcher, principal?.supports(.dispatcher) == true,
              let scope = creationScope else { return nil }
        if let validation = restaurant.validationError { errorMessage = validation; return nil }
        if let pendingRestaurant, pendingRestaurant.restaurant != restaurant {
            errorMessage = "Verifica prima il salvataggio del ristorante in sospeso."
            return nil
        }
        let pending = pendingRestaurant ?? PendingRestaurant(idempotencyKey: UUID().uuidString, restaurant: restaurant)
        // Persist the exact snapshot and key before transmission, scoped to team/account/endpoint.
        do { try storage.saveRestaurant(pending, scope: scope) }
        catch { errorMessage = ItalianPresentation.errorMessage(error); return nil }
        pendingRestaurant = pending
        return await mutate({ try await $0.createRestaurant(pending.restaurant, idempotencyKey: pending.idempotencyKey) }, onFailure: { error in
            if error is URLError || error is CancellationError || (error as? APIError)?.mutationOutcomeUncertain == true {
                self.errorMessage = "Salvataggio non confermato. Riprova la stessa richiesta per evitare duplicati."
            } else { self.clearPendingRestaurant(scope: scope) }
        }) { result in
            self.restaurantReadId = UUID()
            self.loadingRestaurants = false
            self.clearPendingRestaurant(scope: scope)
            self.restaurants.removeAll { $0.id == result.id }
            self.restaurants.append(result)
            self.restaurants.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func clearPendingRestaurant(scope: String) {
        do { try storage.clearRestaurant(scope: scope); pendingRestaurant = nil }
        catch { errorMessage = "Ristorante verificato, ma il recupero locale non è stato aggiornato. Riprova lo stesso salvataggio." }
    }

    func create(_ delivery: NewDelivery) async -> Delivery? {
        guard validateSession(), !isMutating, role == .dispatcher, principal?.supports(.dispatcher) == true,
              !legacyCreationNeedsReview, let scope = creationScope else { return nil }
        if let validation = delivery.validationError { errorMessage = validation; return nil }
        if let pendingCreation, pendingCreation.delivery != delivery {
            errorMessage = "Verifica prima la creazione in sospeso. Riprovarla userà la stessa richiesta, senza duplicarla."
            return nil
        }
        let pending = pendingCreation ?? PendingCreation(idempotencyKey: UUID().uuidString, delivery: delivery)
        // Persist the exact body and key BEFORE transmission. Relaunch must not invent a new create.
        do { try storage.saveCreation(pending, scope: scope) }
        catch { errorMessage = ItalianPresentation.errorMessage(error); return nil }
        pendingCreation = pending
        createOutcomeUncertain = false
        return await mutate({ try await $0.create(pending.delivery, idempotencyKey: pending.idempotencyKey) }, onFailure: { error in
            if error is URLError || error is CancellationError || (error as? APIError)?.mutationOutcomeUncertain == true {
                self.createOutcomeUncertain = true
                self.errorMessage = "Creazione non confermata. Riprova la stessa richiesta: il server eviterà duplicati, anche se era già stata salvata."
            } else {
                self.clearPendingCreation(scope: scope)
            }
        }) { result in
            self.applyConfirmedDelivery(result)
            self.clearPendingCreation(scope: scope)
        }
    }
    func retryPendingCreation() async -> Delivery? {
        guard let pendingCreation else { return nil }
        return await create(pendingCreation.delivery)
    }
    private func clearPendingCreation(scope: String) {
        do {
            try storage.clearCreation(scope: scope)
            pendingCreation = nil
            createOutcomeUncertain = false
        } catch {
            // Keep the same key until local cleanup succeeds. A replay is safe.
            createOutcomeUncertain = true
            errorMessage = "Consegna verificata, ma il recupero locale non è stato aggiornato. Riprova la stessa richiesta per completare la verifica."
        }
    }
    func prepareLegacyCreationReview() -> LegacyCreationReview? {
        guard validateSession(), !isMutating, role == .dispatcher,
              let user = principal, user.supports(.dispatcher), user.teamId != nil,
              let currentScope = creationScope, let pending = legacyPendingCreation, let api = client else { return nil }
        return LegacyCreationReview(sessionId: sessionId, viewId: viewId, currentScope: currentScope,
            legacyScope: CreationScope.legacy(endpoint: api.baseURL.absoluteString, accountId: user.id), pending: pending)
    }

    /// Called only after the user explicitly confirms they checked the original server outcome.
    /// This deletes one local recovery record, never server-side work and never retries a creation.
    @discardableResult
    func clearLegacyCreationAfterReview(_ review: LegacyCreationReview) -> Bool {
        guard validateSession(), !isMutating, role == .dispatcher, principal?.supports(.dispatcher) == true,
              sessionId == review.sessionId, viewId == review.viewId, creationScope == review.currentScope,
              legacyPendingCreation == review.pending else { return false }
        do {
            guard try storage.loadCreation(scope: review.legacyScope) == review.pending else {
                errorMessage = "La richiesta salvata è cambiata. Esci e accedi di nuovo prima di verificarla; non è stato rimosso alcun dato."
                return false
            }
            try storage.clearCreation(scope: review.legacyScope)
            legacyPendingCreation = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "La richiesta precedente resta protetta e le nuove creazioni sono ancora sospese. Sblocca l’iPhone e riprova a rimuovere il recupero dopo averne verificato l’esito."
            return false
        }
    }

    /// Relative estimates are sent with the original revision/body/key until their outcome is known.
    /// A sheet captures its displayed revision so a stale tap cannot move a newer estimate.
    func setReadiness(deliveryId: String, readyInMinutes: Int, expectedRevision: UInt64) async -> Bool {
        guard validateSession(), !isMutating, role == .dispatcher, principal?.supports(.dispatcher) == true,
              (0...120).contains(readyInMinutes),
              let current = deliveries.first(where: { $0.id == deliveryId }), current.canChangeReadiness else { return false }
        guard !readinessNeedsRefresh.contains(deliveryId) else {
            errorMessage = "Aggiorna la consegna prima di modificare la disponibilità."
            return false
        }
        let update: ReadinessUpdate
        if let pending = pendingReadiness(for: deliveryId) {
            guard pending.readyInMinutes == readyInMinutes else {
                errorMessage = "La disponibilità precedente non è ancora verificata. Riprova la stessa modifica o aggiorna i dati."
                return false
            }
            update = pending
        } else {
            // A repeated ready-now tap is a no-op, even if its view predates the confirmation.
            if readyInMinutes == 0, current.readinessState == .ready { return true }
            guard current.readinessRevision == expectedRevision else {
                errorMessage = "La disponibilità è cambiata. Controlla l’orario aggiornato e riprova."
                return false
            }
            update = ReadinessUpdate(readyInMinutes: readyInMinutes, expectedRevision: expectedRevision)
        }
        guard let key = actionKey(for: deliveryId, kind: .readiness(update)) else { return false }
        let result: Delivery? = await mutate({ try await $0.readiness(deliveryId: deliveryId, update: update, idempotencyKey: key) }, onFailure: { error in
            self.releaseActionIfDefinitive(error, deliveryId: deliveryId)
            if (error as? APIError)?.statusCode == 409 {
                self.readinessNeedsRefresh.insert(deliveryId)
                self.errorMessage = "La disponibilità è cambiata. Aggiorna la consegna, controlla l’orario e riprova."
            } else if self.pendingReadiness(for: deliveryId) != nil {
                self.errorMessage = "Disponibilità non confermata. Riprova la stessa modifica: l’orario originale non verrà spostato."
            }
        }) { result in
            self.pendingActions[deliveryId] = nil
            self.readinessNeedsRefresh.remove(deliveryId)
            self.applyConfirmedDelivery(result)
        }
        return result != nil
    }

    func assign(deliveryId: String, driverId: String) async -> Bool {
        guard !isMutating, role == .dispatcher, principal?.supports(.dispatcher) == true,
              let current = deliveries.first(where: { $0.id == deliveryId }), current.hasKnownReadiness,
              !readinessNeedsRefresh.contains(deliveryId),
              current.status == .pending || current.status == .assigned else { return false }
        if current.status == .assigned && current.driverId == driverId { return true }
        guard let key = actionKey(for: deliveryId, kind: .assignment(driverId)) else { return false }
        let result: Delivery? = await mutate({ try await $0.assign(deliveryId: deliveryId, driverId: driverId, idempotencyKey: key) }, onFailure: { error in
            self.releaseActionIfDefinitive(error, deliveryId: deliveryId)
        }) { result in
            self.pendingActions[deliveryId] = nil
            self.applyConfirmedDelivery(result)
        }
        return result != nil
    }
    func completeNextStop(_ delivery: Delivery) async {
        // A second tap from an old view must never advance the following stop.
        guard !isMutating, role == .driver, principal?.supports(.driver) == true,
              let current = deliveries.first(where: { $0.id == delivery.id }),
              current.driverId == principal?.id,
              current.status == delivery.status else { return }
        guard let next = DeliveryAction.nextStatus(delivery: current, route: route, now: Int(Date().timeIntervalSince1970)) else {
            errorMessage = "Segui la prima tappa del percorso e attendi che la consegna sia pronta per il ritiro."
            return
        }
        guard let key = actionKey(for: current.id, kind: .status(next)) else { return }
        let _: Delivery? = await mutate({ try await $0.status(deliveryId: current.id, status: next, idempotencyKey: key) }, onFailure: { error in
            self.releaseActionIfDefinitive(error, deliveryId: current.id)
        }) { result in
            self.pendingActions[current.id] = nil
            self.applyConfirmedDelivery(result)
            // Only remove the stop the server confirmed. A later refresh replans the remainder.
            if let route = self.route, let stop = route.stops.first,
               stop.deliveryId == result.id,
               (stop.kind == .pickup && result.status == .pickedUp) || (stop.kind == .dropoff && result.status == .delivered) {
                self.route = DriverRoute(driverId: route.driverId, stops: Array(route.stops.dropFirst()),
                                         travelSeconds: route.travelSeconds, finishAt: route.finishAt,
                                         feasible: route.feasible, warnings: route.warnings, notices: route.notices, estimatesAvailable: route.estimatesAvailable, travelEstimate: route.travelEstimate)
            }
        }
    }
    /// While an outcome is unknown, repeat only that exact logical action with its original key.
    /// A fresh server read after relaunch is required before any route action is available.
    private func actionKey(for deliveryId: String, kind: ActionKind) -> String? {
        if let pending = pendingActions[deliveryId] {
            guard pending.kind == kind else {
                errorMessage = "La modifica precedente non è ancora verificata. Aggiorna i dati o riprova la stessa operazione prima di cambiarla."
                return nil
            }
            return pending.key
        }
        let key = UUID().uuidString
        pendingActions[deliveryId] = PendingAction(kind: kind, key: key)
        return key
    }
    private func releaseActionIfDefinitive(_ error: Error, deliveryId: String) {
        if !(error is URLError), !(error is CancellationError), (error as? APIError)?.mutationOutcomeUncertain != true {
            pendingActions[deliveryId] = nil
        }
    }
    private func reconcilePendingActions() {
        for delivery in deliveries {
            guard let pending = pendingActions[delivery.id] else { continue }
            switch pending.kind {
            case .assignment(let target):
                if delivery.driverId == target, delivery.status != .pending { pendingActions[delivery.id] = nil }
            case .status(let target):
                if delivery.status == target || delivery.status == .delivered { pendingActions[delivery.id] = nil }
            case .readiness(let update):
                if delivery.readinessRevision > update.expectedRevision || !delivery.canChangeReadiness {
                    pendingActions[delivery.id] = nil
                }
            }
        }
    }

    /// The new-shift screen explicitly discloses locked-screen sharing before this action.
    /// Existing/restored shifts and the separate resume control never receive this broader grant.
    func startShiftAndShareLocation() async {
        guard !isMutating, role == .driver, principal?.supports(.driver) == true,
              let driver = currentDriver, driver.id == principal?.id, !driver.active else { return }
        let consent = locationConsentId
        let _: Driver? = await mutate({ try await $0.shift(active: true, capacity: driver.capacity) }) { result in
            guard result.id == driver.id else { return }
            self.currentDriver = result
            guard result.active, !Task.isCancelled, consent == self.locationConsentId else { return }
            self.locationSharing = true
            self.backgroundLocationSharing = true
            self.synchronizeLocation()
        }
    }
    func setShift(active: Bool, capacity: Int) async {
        guard !isMutating, role == .driver, principal?.supports(.driver) == true,
              currentDriver?.id == principal?.id, currentDriver?.active != active else { return }
        let _: Driver? = await mutate({ try await $0.shift(active: active, capacity: capacity) }, onFailure: { error in
            if !active, error is URLError || error is CancellationError || (error as? APIError)?.mutationOutcomeUncertain == true {
                self.setLocationSharing(false)
                self.errorMessage = "Fine turno non confermata. La posizione è comunque ferma su questo iPhone: aggiorna i dati per verificare il turno."
            }
        }) { result in
            self.currentDriver = result
            if !result.active { self.setLocationSharing(false) }
            self.synchronizeLocation()
        }
    }
    private func applyConfirmedDelivery(_ delivery: Delivery) {
        if let index = availableDeliveries.firstIndex(where: { $0.id == delivery.id }) {
            guard delivery.readinessRevision >= availableDeliveries[index].readinessRevision,
                  delivery.status.progressRank >= availableDeliveries[index].status.progressRank else { return }
            availableDeliveries[index] = delivery
        } else { availableDeliveries.append(delivery) }
    }
    private func applyFetchedDeliveries(_ fetched: [Delivery]) {
        let previous = Dictionary(uniqueKeysWithValues: availableDeliveries.map { ($0.id, $0) })
        availableDeliveries = fetched.map { delivery in
            if let current = previous[delivery.id],
               current.readinessRevision > delivery.readinessRevision || current.status.progressRank > delivery.status.progressRank { return current }
            readinessNeedsRefresh.remove(delivery.id)
            return delivery
        }
    }
    func assignedRoute(for deliveryId: String) async -> DriverRoute? {
        guard validateSession(), role == .dispatcher, principal?.supports(.dispatcher) == true,
              let current = deliveries.first(where: { $0.id == deliveryId }), current.status != .delivered,
              let driverId = current.driverId, let api = client else { return nil }
        let session = sessionId
        let view = viewId
        do {
            let planned = try await api.route(driverId: driverId)
            guard session == sessionId, view == viewId, !Task.isCancelled, planned.driverId == driverId,
                  deliveries.first(where: { $0.id == deliveryId }) == current else { return nil }
            return planned
        } catch {
            guard session == sessionId, view == viewId, !Task.isCancelled else { return nil }
            if handleUnauthorized(error) { return nil }
            return nil
        }
    }

    func suggestions(for deliveryId: String) async -> [Suggestion]? {
        guard validateSession(), role == .dispatcher, principal?.supports(.dispatcher) == true,
              let current = deliveries.first(where: { $0.id == deliveryId }), current.hasKnownReadiness,
              current.canChangeReadiness, !readinessNeedsRefresh.contains(deliveryId),
              let api = client else { return nil }
        let session = sessionId
        let view = viewId
        do {
            let suggestions = try await api.suggestions(deliveryId: deliveryId)
            guard session == sessionId, view == viewId, !Task.isCancelled,
                  deliveries.first(where: { $0.id == deliveryId }) == current else { return nil }
            return suggestions
        } catch {
            let failure = error as NSError
            guard !(error is CancellationError), !Task.isCancelled,
                  !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return nil }
            if session == sessionId, view == viewId, !handleUnauthorized(error) { errorMessage = ItalianPresentation.errorMessage(error) }
            return nil
        }
    }
    /// An old off-shift read is not an explicit Stop. Do not revoke a pending new-start
    /// grant when sharing was already off; an actual active grant must still be cleared.
    private func reconcileInactiveShiftLocation() {
        if locationSharing || backgroundLocationSharing {
            setLocationSharing(false)
        } else {
            locationErrorMessage = nil
            synchronizeLocation()
        }
    }

    func setLocationSharing(_ value: Bool) {
        guard validateSession() else { return }
        locationConsentId = UUID()
        // Resuming is deliberately foreground-only unless background is explicitly re-enabled.
        locationSharing = value && !isDeletingAccount && role == .driver && principal?.supports(.driver) == true && currentDriver?.active == true
        if !locationSharing { backgroundLocationSharing = false; locationErrorMessage = nil }
        synchronizeLocation()
    }
    func setBackgroundLocationSharing(_ value: Bool) {
        guard validateSession() else { return }
        locationConsentId = UUID()
        backgroundLocationSharing = value && role == .driver && locationSharing && currentDriver?.active == true
        synchronizeLocation()
    }
    private var mayShareLocation: Bool {
        (foreground || backgroundLocationSharing) && locationSharing && principal?.supports(.driver) == true && currentDriver?.active == true
    }
    private func synchronizeLocation() {
        if !mayShareLocation { locationTask?.cancel(); locationTask = nil }
        location.configure(
            enabled: locationSharing && principal?.supports(.driver) == true && currentDriver?.active == true,
            foreground: foreground, allowBackground: backgroundLocationSharing
        )
    }
    private func reportLocation(_ coordinate: Coordinate) {
        guard validateSession(), mayShareLocation, let api = client else { return }
        locationTask?.cancel()
        let session = sessionId
        locationTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let driver = try await api.location(coordinate)
                guard let self, session == self.sessionId, self.mayShareLocation, !Task.isCancelled else { return }
                self.currentDriver = driver
                if !driver.active { self.setLocationSharing(false) }
                self.locationErrorMessage = nil
            } catch is CancellationError { }
            catch {
                guard let self, session == self.sessionId, self.mayShareLocation, !Task.isCancelled else { return }
                if self.handleUnauthorized(error) { return }
                if (error as? APIError)?.statusCode == 409 {
                    // Another device may have ended the shift while this app was backgrounded.
                    // Stop collection/transmission immediately rather than waiting for foreground polling.
                    self.setLocationSharing(false)
                    self.locationErrorMessage = "Il server non consente più la posizione per questo turno. La condivisione è ferma: aggiorna i dati prima di riprenderla."
                    return
                }
                self.locationErrorMessage = "Invio della posizione non riuscito: \(ItalianPresentation.errorMessage(error))"
            }
        }
    }
    private func mutate<T>(_ operation: (APIClient) async throws -> T, onFailure: (Error) -> Void = { _ in }, apply: (T) -> Void) async -> T? {
        guard validateSession(), let api = client, !isMutating else { return nil }
        let session = sessionId
        isMutating = true
        errorMessage = nil
        defer { if session == sessionId { isMutating = false } }
        do {
            let value = try await operation(api)
            guard session == sessionId else { return nil }
            // A refresh begun before this write may contain stale state. Ignore its result.
            refreshId = UUID()
            isRefreshing = false
            apply(value)
            await refresh(force: true)
            return session == sessionId ? value : nil
        } catch {
            guard session == sessionId else { return nil }
            if handleUnauthorized(error) { return nil }
            errorMessage = ItalianPresentation.errorMessage(error)
            onFailure(error)
            // A response can be lost after a committed write; reconcile before another action.
            await refresh(force: true)
            return nil
        }
    }
}

