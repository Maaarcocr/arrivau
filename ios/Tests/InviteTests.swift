import XCTest
@testable import Arrivau

/// Invite parsing never supplies an API origin, role, identity, or stored credential.
final class InviteModelTests: XCTestCase {
    private let token = String(repeating: "a1", count: 32)

    func testRawTokenAndCanonicalLinkHaveTheSameIdentityAndRoundTrip() throws {
        let raw = try XCTUnwrap(InviteLink(input: token))
        let linked = try XCTUnwrap(InviteLink(input: "arrivau://invite?token=\(token)"))
        XCTAssertEqual(raw, linked)
        XCTAssertEqual(raw.id, linked.id)
        XCTAssertEqual(raw.token, token)
        XCTAssertEqual(raw.url.absoluteString, "arrivau://invite?token=\(token)")
        XCTAssertEqual(InviteLink(input: raw.url.absoluteString), raw)
        XCTAssertEqual(InviteLink(input: " \n" + token + "\t "), raw)
        XCTAssertEqual(InviteLink(input: " \n" + raw.url.absoluteString + "\t "), raw)
    }

    func testRejectsMalformedTokensRatherThanNormalizingSecrets() {
        let invalid = ["", String(token.dropLast()), token + "0", token.uppercased(),
                       String(repeating: "g", count: 64), "a " + String(token.dropFirst(2)), "a\n" + String(token.dropFirst(2)),
                       String(repeating: "é", count: 64), String(repeating: "０", count: 64)]
        for input in invalid { XCTAssertNil(InviteLink(input: input), "Accepted malformed token: \(input)") }
    }

    func testRejectsLinkAmbiguityDestinationOverridesAndEncodedTokens() {
        let invalid = [
            "https://invite?token=\(token)",
            "arrivau://other?token=\(token)",
            "ARRIVAU://invite?token=\(token)",
            "arrivau://INVITE?token=\(token)",
            "arrivau:invite?token=\(token)",
            "arrivau:///invite?token=\(token)",
            "arrivau://invite/?token=\(token)",
            "arrivau://invite/path?token=\(token)",
            "arrivau://name@invite?token=\(token)",
            "arrivau://name:secret@invite?token=\(token)",
            "arrivau://invite:443?token=\(token)",
            "arrivau://invite?token=\(token)#fragment",
            "arrivau://invite?token=\(token)#",
            "arrivau://invite?token=\(token)&server=https://evil.example",
            "arrivau://invite?server=https://evil.example&token=\(token)",
            "arrivau://invite?token=\(token)&role=dispatcher",
            "arrivau://invite?token=\(token)&token=\(token)",
            "arrivau://invite?token=\(token)&",
            "arrivau://invite?Token=\(token)",
            "arrivau://invite?token=",
            "arrivau://invite?token",
            "arrivau://invite?%74oken=\(token)",
            "arrivau://invite?token=%61\(token.dropFirst())",
            "arrivau://invite?token=\(token)%00",
            "arrivau://invite ?token=\(token)",
            "arrivau://invite?token=\(token.prefix(32)) \(token.suffix(32))"
        ]
        for input in invalid { XCTAssertNil(InviteLink(input: input), "Accepted ambiguous link: \(input)") }
    }

    func testCredentialsEnforceASCIIUsernameBoundaries() {
        for username in ["a", "0", "rider.a_1-2", String(repeating: "a", count: 64)] {
            XCTAssertNil(InviteCredentials.validationError(username: username, password: "test-only-password"))
        }
        for username in ["", "Rider", "rider name", " rider", "rider ", "rider\n", ".rider", "_rider", "-rider",
                         "rider@home", "rider/name", "rìder", "ｒider", String(repeating: "a", count: 65)] {
            XCTAssertNotNil(InviteCredentials.validationError(username: username, password: "test-only-password"), username)
        }
    }

    func testPasswordLimitsCountUTF8BytesAndNeverTrimSecrets() {
        for password in [String(repeating: "p", count: 12), String(repeating: "p", count: 1024),
                         String(repeating: "é", count: 6), String(repeating: "é", count: 512),
                         " 1234567890 "] {
            XCTAssertNil(InviteCredentials.validationError(username: "rider", password: password))
        }
        for password in ["", String(repeating: "p", count: 11), String(repeating: "p", count: 1025),
                         String(repeating: "é", count: 5), String(repeating: "é", count: 513)] {
            XCTAssertNotNil(InviteCredentials.validationError(username: "rider", password: password))
        }
    }

    func testInviteNameLimitsCountUTF8BytesAndRejectInternalControls() {
        for name in ["Mario", " Mario Rossi ", String(repeating: "a", count: 240), String(repeating: "é", count: 120)] {
            XCTAssertNil(InviteCredentials.nameValidationError(name))
        }
        for name in ["", " \n\t ", String(repeating: "a", count: 241), String(repeating: "é", count: 121),
                     "Mario\nRossi", "Mario\tRossi", "Mario\u{0000}Rossi", "Mario\u{007F}Rossi"] {
            XCTAssertNotNil(InviteCredentials.nameValidationError(name))
        }
    }

    func testTeamIdentityRequiresExplicitBoundedASCIIIdentifierAndSafeName() {
        for identifier in ["a", "0", "Pachino-1", "TEAM_1.2", String(repeating: "A", count: 64)] {
            XCTAssertTrue(InviteTeamIdentity.isValid(id: identifier, name: "Centrale Pachino"), identifier)
        }
        let invalidIDs: [String?] = [nil, "", " ", ".team", "_team", "-team", "team/id", "team id", "tèam",
                                     "ｔeam", "team\n", String(repeating: "A", count: 65)]
        for identifier in invalidIDs {
            XCTAssertFalse(InviteTeamIdentity.isValid(id: identifier, name: "Centrale Pachino"))
        }
        for name in ["Centrale", " Centrale Pachino ", String(repeating: "a", count: 240), String(repeating: "é", count: 120)] {
            XCTAssertTrue(InviteTeamIdentity.isValid(id: "Pachino-1", name: name))
        }
        let invalidNames: [String?] = [nil, "", " \n\t ", "Centrale\nPachino", "Centrale\tPachino",
                                       "Centrale\u{0000}Pachino", "Centrale\u{007F}Pachino",
                                       String(repeating: "a", count: 241), String(repeating: "é", count: 121)]
        for name in invalidNames { XCTAssertFalse(InviteTeamIdentity.isValid(id: "Pachino-1", name: name)) }
    }

    func testDriverInviteRequiresBothExplicitTeamFields() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: InviteTestBackend.inviteData()) as? [String: Any])
        for missingKey in ["team_id", "team_name"] {
            var body = original
            body.removeValue(forKey: missingKey)
            let data = try JSONSerialization.data(withJSONObject: body)
            XCTAssertThrowsError(try APIClient.decoder().decode(DriverInvite.self, from: data))
        }
    }

    func testDriverInviteDecodesServerFieldsAndOnlyBuildsValidLinks() throws {
        let invite = try APIClient.decoder().decode(DriverInvite.self, from: InviteTestBackend.inviteData())
        XCTAssertEqual(invite.id, InviteTestBackend.inviteID)
        XCTAssertEqual(invite.name, "Nuovo corriere")
        XCTAssertEqual(invite.role, "driver")
        XCTAssertEqual(invite.teamId, InviteTestBackend.teamID)
        XCTAssertEqual(invite.teamName, InviteTestBackend.teamName)
        XCTAssertEqual(invite.token, InviteTestBackend.inviteToken)
        XCTAssertEqual(invite.expiresAt, 2_000_000_000)
        XCTAssertEqual(invite.link?.token, invite.token)
        for token in ["not-a-valid-token", " " + InviteTestBackend.inviteToken + " ",
                      "arrivau://invite?token=\(InviteTestBackend.inviteToken)"] {
            let malformed = try APIClient.decoder().decode(DriverInvite.self, from: InviteTestBackend.inviteData(token: token))
            XCTAssertNil(malformed.link, "Server token fields must contain only the exact raw secret")
        }
    }
}

/// Uses only an injected transport and a SessionStorage spy; never touches real Keychain or network.
@MainActor
final class InviteTests: XCTestCase {
    private let endpoint = "https://pilot.arrivau.example"
    private let password = " exact-test-password "
    private var session: URLSession!
    private var backend: InviteTestBackend!
    private var storage: InviteTestStorage!
    private var store: DeliveryStore!
    private var stores: [DeliveryStore] = []

    override func setUp() async throws {
        try await super.setUp()
        backend = InviteTestBackend()
        InviteTestURLProtocol.backend = backend
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InviteTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        storage = InviteTestStorage()
        store = makeStore()
    }

    override func tearDown() async throws {
        stores.forEach { $0.logout() }
        for value in stores { await value.awaitPendingRevocations() }
        stores.removeAll()
        store = nil
        session.invalidateAndCancel()
        InviteTestURLProtocol.backend = nil
        backend = nil
        storage = nil
        try await super.tearDown()
    }

    private var client: APIClient {
        APIClient(baseURL: URL(string: endpoint)!, token: "dispatcher-session", session: session)
    }

    private func makeStore(storage supplied: InviteTestStorage? = nil) -> DeliveryStore {
        let result = DeliveryStore(session: session, deterministicLocation: true, mode: .pilot,
                                   storage: supplied ?? storage)
        result.apiURL = endpoint
        stores.append(result)
        return result
    }

    private func receiveInvite(in candidate: DeliveryStore? = nil) {
        (candidate ?? store).receiveInvite("arrivau://invite?token=\(InviteTestBackend.inviteToken)")
    }

    private func redemptions() -> [InviteTestBackend.RequestRecord] {
        backend.withState { $0.requests.filter { $0.method == "POST" && $0.path == "/v1/invites/redeem" } }
    }

    private func assertSignedOut(_ candidate: DeliveryStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(candidate.principal, file: file, line: line)
        XCTAssertNil(candidate.role, file: file, line: line)
        XCTAssertNil(candidate.currentDriver, file: file, line: line)
        XCTAssertNil(candidate.route, file: file, line: line)
        XCTAssertTrue(candidate.deliveries.isEmpty, file: file, line: line)
        XCTAssertTrue(candidate.drivers.isEmpty, file: file, line: line)
        XCTAssertTrue(candidate.availableRoles.isEmpty, file: file, line: line)
        XCTAssertTrue(candidate.restaurants.isEmpty, file: file, line: line)
        XCTAssertNil(candidate.pendingCreation, file: file, line: line)
        XCTAssertNil(candidate.pendingRestaurant, file: file, line: line)
        XCTAssertFalse(candidate.locationSharing, file: file, line: line)
        XCTAssertFalse(candidate.backgroundLocationSharing, file: file, line: line)
        XCTAssertNil(storage.savedSession, file: file, line: line)
    }

    func testCreateInvitePostsOnlyNameWithDispatcherBearer() async throws {
        let result = try await client.createInvite(name: "Nuovo corriere")
        let request = try XCTUnwrap(backend.withState { $0.requests.first })
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/invites")
        XCTAssertEqual(request.origin, endpoint)
        XCTAssertEqual(request.authorization, "Bearer dispatcher-session")
        XCTAssertEqual(request.contentType, "application/json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.body) as? [String: String], ["name": "Nuovo corriere"])
        XCTAssertEqual(result.id, InviteTestBackend.inviteID)
        XCTAssertEqual(result.link?.token, InviteTestBackend.inviteToken)
    }

    func testRevokeInviteUsesOnlyUUIDPathAndBearerAndAccepts204() async throws {
        try await client.revokeInvite(id: InviteTestBackend.inviteID)
        let request = try XCTUnwrap(backend.withState { $0.requests.first })
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/v1/invites/\(InviteTestBackend.inviteID)")
        XCTAssertEqual(request.authorization, "Bearer dispatcher-session")
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertNil(request.query)
    }

    func testRevokeInviteRejectsMalformedOrPathLikeIdentifiersBeforeTransmission() async {
        for identifier in ["", "../session", "driver-id", "\(InviteTestBackend.inviteID)/../session", "https://evil.example"] {
            do { try await client.revokeInvite(id: identifier); XCTFail("Expected invalid UUID rejection") }
            catch { XCTAssertFalse((error as? APIError)?.mutationOutcomeUncertain ?? false) }
        }
        XCTAssertTrue(backend.withState { $0.requests.isEmpty })
    }

    func testRedeemIsPublicAtConfiguredOriginAndPostsOnlyExactCredentials() async throws {
        // Even a caller holding a bearer must not attach it to the public redemption request.
        let result = try await client.redeemInvite(token: InviteTestBackend.inviteToken, username: "mario", password: password)
        let request = try XCTUnwrap(redemptions().first)
        XCTAssertEqual(request.origin, endpoint)
        XCTAssertEqual(request.path, "/v1/invites/redeem")
        XCTAssertNil(request.authorization)
        XCTAssertNil(request.query)
        XCTAssertNil(request.idempotencyKey)
        XCTAssertFalse(request.handlesCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.body) as? [String: String],
                       ["token": InviteTestBackend.inviteToken, "username": "mario", "password": password])
        XCTAssertEqual(result.token, "redeemed-session-1")
        XCTAssertEqual(result.user.serverRole, .driver)
        XCTAssertEqual(result.user.role, "driver")
        XCTAssertEqual(result.user.roles, ["driver"])
        XCTAssertEqual(result.user.teamId, InviteTestBackend.teamID)
        XCTAssertEqual(result.user.teamName, InviteTestBackend.teamName)
        XCTAssertEqual(redemptions().count, 1)
    }

    func testRedeemConflictsRateLimitsAndInvalidInvitesAreDefiniteAndNeverAutoRetried() async {
        for status in [400, 409, 410, 429] {
            backend.withState { $0.redemptionStatus = status }
            do {
                _ = try await client.redeemInvite(token: InviteTestBackend.inviteToken, username: "mario", password: password)
                XCTFail("Expected HTTP \(status)")
            } catch {
                XCTAssertEqual((error as? APIError)?.statusCode, status)
                XCTAssertFalse((error as? APIError)?.mutationOutcomeUncertain ?? true)
                XCTAssertFalse(error.localizedDescription.contains("private-server-detail"))
            }
        }
        XCTAssertEqual(redemptions().count, 4)
    }

    func testRedeemInvalidInviteAndUnavailableUsernameUseExactItalianMessages() async {
        let failures: [(Int, String, String)] = [
            (400, "Invite is invalid, expired or already used", "Invito non valido, scaduto o già utilizzato. Se hai già creato l’account, torna ad Accedi; altrimenti chiedi un nuovo invito al responsabile."),
            (409, "Username is unavailable", "Questo nome utente non è disponibile. Scegline un altro.")
        ]
        for (status, wireMessage, expectedMessage) in failures {
            backend.withState { $0.redemptionStatus = status; $0.redemptionError = wireMessage }
            do {
                _ = try await client.redeemInvite(token: InviteTestBackend.inviteToken, username: "mario", password: password)
                XCTFail("Expected HTTP \(status)")
            } catch {
                XCTAssertEqual((error as? APIError)?.statusCode, status)
                XCTAssertFalse((error as? APIError)?.mutationOutcomeUncertain ?? true)
                XCTAssertEqual(error.localizedDescription, expectedMessage)
            }
        }
        XCTAssertEqual(redemptions().count, 2)
    }

    func testRedeemServerFailureAndUnreadableSuccessAreUncertainAndNeverAutoRetried() async {
        for malformedSuccess in [false, true] {
            backend.withState {
                $0.redemptionStatus = malformedSuccess ? 201 : 503
                $0.malformedRedemption = malformedSuccess
            }
            do {
                _ = try await client.redeemInvite(token: InviteTestBackend.inviteToken, username: "mario", password: password)
                XCTFail("Expected uncertain response")
            } catch { XCTAssertTrue((error as? APIError)?.mutationOutcomeUncertain ?? false) }
        }
        XCTAssertEqual(redemptions().count, 2)
    }

    func testReceivingInviteIsMemoryOnlyAndCannotOverrideConfiguredServer() {
        receiveInvite()
        XCTAssertEqual(store.pendingInvite?.token, InviteTestBackend.inviteToken)
        XCTAssertEqual(store.apiURL, endpoint)
        XCTAssertTrue(backend.withState { $0.requests.isEmpty })
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertTrue(storage.creationWrites.isEmpty)
        XCTAssertTrue(storage.restaurantWrites.isEmpty)
        store.dismissInvite()
        XCTAssertNil(store.pendingInvite)
        store.receiveInvite("arrivau://invite?token=\(InviteTestBackend.inviteToken)&server=https://evil.example")
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(store.apiURL, endpoint)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(backend.withState { $0.requests.isEmpty })
    }

    func testMissingInviteInvalidCredentialsAndInsecureEndpointNeverReachNetwork() async {
        let missing = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(missing)
        receiveInvite()
        let badUsername = await store.redeemInvite(username: " mario ", password: password)
        let badPassword = await store.redeemInvite(username: "mario", password: "short")
        XCTAssertFalse(badUsername)
        XCTAssertFalse(badPassword)
        store.apiURL = "http://evil.example"
        let insecure = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(insecure)
        XCTAssertTrue(backend.withState { $0.requests.isEmpty })
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertFalse(store.inviteOutcomeUncertain)
    }

    func testSuccessfulRedemptionInstallsServerIdentityAndPersistsOnlySession() async throws {
        receiveInvite()
        let success = await store.redeemInvite(username: "mario", password: password)
        XCTAssertTrue(success)
        XCTAssertEqual(store.role, .driver)
        XCTAssertEqual(store.principal?.id, "invited-driver")
        XCTAssertEqual(store.principal?.name, "Corriere invitato")
        XCTAssertEqual(store.principal?.role, "driver")
        XCTAssertEqual(store.principal?.roles, ["driver"])
        XCTAssertEqual(store.principal?.teamId, InviteTestBackend.teamID)
        XCTAssertEqual(store.principal?.teamName, InviteTestBackend.teamName)
        XCTAssertEqual(store.availableRoles, [.driver])
        XCTAssertFalse(store.canSwitchRole)
        XCTAssertEqual(store.currentDriver?.id, "invited-driver")
        XCTAssertNil(store.pendingInvite)
        XCTAssertNil(store.inviteErrorMessage)
        XCTAssertFalse(store.inviteOutcomeUncertain)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertFalse(store.isMutating)
        let saved = try XCTUnwrap(storage.savedSession)
        XCTAssertEqual(saved.endpoint, endpoint)
        XCTAssertEqual(saved.token, "redeemed-session-1")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["endpoint", "token", "expiresAt"]))
        XCTAssertEqual(storage.sessionWrites.count, 1)
        XCTAssertTrue(storage.creationWrites.isEmpty)
        XCTAssertTrue(storage.restaurantWrites.isEmpty)
        for write in storage.sessionWrites {
            let text = String(decoding: write, as: UTF8.self)
            XCTAssertFalse(text.contains(InviteTestBackend.inviteToken))
            XCTAssertFalse(text.contains(password))
            XCTAssertFalse(text.contains("mario"))
        }
        let request = try XCTUnwrap(redemptions().first)
        XCTAssertNil(request.authorization)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.body) as? [String: String],
                       ["token": InviteTestBackend.inviteToken, "username": "mario", "password": password])
        XCTAssertTrue(backend.withState {
            $0.requests.filter { $0.method == "GET" }.allSatisfy { $0.authorization == "Bearer redeemed-session-1" }
        })
    }

    func testAlreadySignedInInviteCannotReplaceIdentitySessionOrServer() async throws {
        await store.login(username: "existing", password: password)
        let existing = try XCTUnwrap(store.principal)
        let saved = try XCTUnwrap(storage.savedSession)
        let requests = backend.withState { $0.requests.count }
        receiveInvite()
        XCTAssertNil(store.pendingInvite)
        XCTAssertNotNil(store.errorMessage)
        let success = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(success)
        XCTAssertEqual(store.principal, existing)
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertEqual(store.apiURL, endpoint)
        XCTAssertEqual(backend.withState { $0.requests.count }, requests)
        XCTAssertTrue(redemptions().isEmpty)
    }

    func testConcurrentSubmissionIsIgnoredUntilFirstRedemptionCompletes() async {
        receiveInvite()
        let started = expectation(description: "First redemption reaches server")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onRedemption = { started.fulfill() }; $0.redemptionGate = release }
        let first = Task { await store.redeemInvite(username: "mario", password: password) }
        await fulfillment(of: [started], timeout: 5)
        let second = await store.redeemInvite(username: "different", password: password)
        XCTAssertFalse(second)
        XCTAssertEqual(redemptions().count, 1)
        release.signal()
        let success = await first.value
        XCTAssertTrue(success)
        XCTAssertEqual(redemptions().count, 1)
        XCTAssertEqual(storage.sessionWrites.count, 1)
    }

    func testLostResponseBlocksReplayUntilExplicitLoginRecovery() async {
        backend.withState { $0.loseRedemptionResponse = true }
        receiveInvite()
        let first = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(first)
        assertSignedOut(store)
        XCTAssertTrue(store.inviteOutcomeUncertain)
        XCTAssertNotNil(store.inviteErrorMessage)
        let repeated = await store.redeemInvite(username: "mario", password: password)
        let changed = await store.redeemInvite(username: "another", password: password)
        XCTAssertFalse(repeated)
        XCTAssertFalse(changed)
        XCTAssertEqual(redemptions().count, 1, "A one-time invite must not be replayed after a lost response")
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        store.dismissInvite()
        receiveInvite()
        XCTAssertTrue(store.inviteOutcomeUncertain, "Reopening the same link cannot bypass the in-memory replay guard")
        let reopened = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(reopened)
        XCTAssertEqual(redemptions().count, 1)
        store.dismissInvite()
        await store.login(username: "mario", password: password)
        XCTAssertEqual(store.principal?.id, "invited-driver")
        XCTAssertEqual(storage.savedSession?.token, "login-session")
        XCTAssertEqual(redemptions().count, 1, "Recovery uses ordinary login, never invitation replay")
    }

    func testUnreadableSuccessfulRedemptionBlocksRepeatWithoutStoringInviteOrPassword() async {
        backend.withState { $0.malformedRedemption = true }
        receiveInvite()
        let first = await store.redeemInvite(username: "mario", password: password)
        let repeated = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(first)
        XCTAssertFalse(repeated)
        XCTAssertTrue(store.inviteOutcomeUncertain)
        XCTAssertEqual(redemptions().count, 1)
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertTrue(storage.creationWrites.isEmpty)
        XCTAssertTrue(storage.restaurantWrites.isEmpty)
        assertSignedOut(store)
    }

    func testServerFailureBlocksRedemptionReplayEvenAfterServiceRecovers() async {
        backend.withState { $0.redemptionStatus = 503 }
        receiveInvite()
        let first = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(first)
        XCTAssertTrue(store.inviteOutcomeUncertain)
        XCTAssertNotNil(store.pendingInvite)
        XCTAssertNotNil(store.inviteErrorMessage)
        backend.withState { $0.redemptionStatus = 201 }
        let repeated = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(repeated)
        XCTAssertEqual(redemptions().count, 1)
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        assertSignedOut(store)
    }

    func testDefiniteConflictAndRateLimitPermitOnlyExplicitRetry() async {
        receiveInvite()
        backend.withState { $0.redemptionStatus = 409 }
        let conflict = await store.redeemInvite(username: "taken", password: password)
        XCTAssertFalse(conflict)
        assertSignedOut(store)
        XCTAssertNotNil(store.pendingInvite)
        XCTAssertNil(storage.savedSession)
        XCTAssertFalse(store.inviteOutcomeUncertain)
        XCTAssertNotNil(store.inviteErrorMessage)
        XCTAssertEqual(redemptions().count, 1)
        backend.withState { $0.redemptionStatus = 429 }
        let rateLimited = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(rateLimited)
        XCTAssertFalse(store.inviteOutcomeUncertain)
        XCTAssertNotNil(store.inviteErrorMessage)
        XCTAssertEqual(redemptions().count, 2)
        backend.withState { $0.redemptionStatus = 201 }
        let success = await store.redeemInvite(username: "mario", password: password)
        XCTAssertTrue(success)
        XCTAssertEqual(redemptions().count, 3)
    }

    func testDismissedRedemptionCannotInstallLateSessionAndRevokesIssuedToken() async {
        receiveInvite()
        let started = expectation(description: "Redemption begins before dismissal")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onRedemption = { started.fulfill() }; $0.redemptionGate = release }
        let pending = Task { await store.redeemInvite(username: "mario", password: password) }
        await fulfillment(of: [started], timeout: 5)
        store.dismissInvite()
        XCTAssertNil(store.pendingInvite)
        XCTAssertFalse(store.isMutating)
        release.signal()
        let success = await pending.value
        XCTAssertFalse(success)
        assertSignedOut(store)
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer redeemed-session-1"])
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "GET" } })
    }

    func testLogoutDuringRedemptionCannotInstallLateSessionAndRevokesIssuedToken() async {
        receiveInvite()
        let started = expectation(description: "Redemption begins before logout")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onRedemption = { started.fulfill() }; $0.redemptionGate = release }
        let pending = Task { await store.redeemInvite(username: "mario", password: password) }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        assertSignedOut(store)
        release.signal()
        let success = await pending.value
        XCTAssertFalse(success)
        assertSignedOut(store)
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer redeemed-session-1"])
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "GET" } })
    }

    func testDismissedOldRedemptionCannotOverwriteNewerSuccessfulLogin() async throws {
        receiveInvite()
        let started = expectation(description: "Old redemption is waiting for its response")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onRedemption = { started.fulfill() }; $0.redemptionGate = release }
        let oldRedemption = Task { await store.redeemInvite(username: "mario", password: password) }
        await fulfillment(of: [started], timeout: 5)
        store.dismissInvite()
        backend.withState { $0.user = Principal(id: "existing-driver", name: "Account esistente", role: "driver", roles: ["driver"],
                                             teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName) }
        await store.login(username: "existing", password: password)
        let saved = try XCTUnwrap(storage.savedSession)
        XCTAssertEqual(store.principal?.id, "existing-driver")
        XCTAssertEqual(saved.token, "login-session")
        release.signal()
        let oldSuccess = await oldRedemption.value
        XCTAssertFalse(oldSuccess)
        XCTAssertEqual(store.principal?.id, "existing-driver")
        XCTAssertEqual(store.currentDriver?.id, "existing-driver")
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertEqual(storage.sessionWrites.count, 1, "The old response must never reach protected storage")
        XCTAssertNil(store.pendingInvite)
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer redeemed-session-1"])
    }

    func testCancelledRedemptionCannotInstallOrPersistSession() async {
        receiveInvite()
        let started = expectation(description: "Redemption begins before task cancellation")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onRedemption = { started.fulfill() }; $0.redemptionGate = release }
        let pending = Task { await store.redeemInvite(username: "mario", password: password) }
        await fulfillment(of: [started], timeout: 5)
        pending.cancel()
        release.signal()
        let success = await pending.value
        XCTAssertFalse(success)
        assertSignedOut(store)
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertFalse(store.isMutating)
    }

    func testInviteReceivedDuringRestoreQueuesThenClearsOnSuccessfulRestore() async {
        storage.savedSession = SavedSession(endpoint: endpoint, token: "saved-session", expiresAt: backend.withState { $0.expiresAt })
        let started = expectation(description: "Saved session validation is pending")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onIdentity = { started.fulfill() }; $0.identityGate = release }
        let restoring = Task { await store.restoreSession() }
        await fulfillment(of: [started], timeout: 5)
        receiveInvite()
        XCTAssertEqual(store.pendingInvite?.token, InviteTestBackend.inviteToken)
        let redemption = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(redemption)
        XCTAssertTrue(redemptions().isEmpty)
        release.signal()
        await restoring.value
        XCTAssertNotNil(store.principal)
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(storage.savedSession?.token, "saved-session")
        XCTAssertTrue(redemptions().isEmpty)
    }

    func testInviteReceivedDuringRevokedSessionRestoreRemainsAvailableForRedemption() async {
        storage.savedSession = SavedSession(endpoint: endpoint, token: "revoked-session", expiresAt: backend.withState { $0.expiresAt })
        let started = expectation(description: "Revoked saved session validation is pending")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.identityStatus = 401
            $0.onIdentity = { started.fulfill() }
            $0.identityGate = release
        }
        let restoring = Task { await store.restoreSession() }
        await fulfillment(of: [started], timeout: 5)
        receiveInvite()
        XCTAssertEqual(store.pendingInvite?.token, InviteTestBackend.inviteToken)
        release.signal()
        await restoring.value
        assertSignedOut(store)
        XCTAssertFalse(store.canRetryRestore)
        XCTAssertFalse(store.isRestoringSession)
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(store.pendingInvite?.token, InviteTestBackend.inviteToken,
                       "Invalidating the old session must not discard the separately received invite")
        XCTAssertTrue(redemptions().isEmpty)
        let redeemed = await store.redeemInvite(username: "mario", password: password)
        XCTAssertTrue(redeemed)
        XCTAssertEqual(store.principal?.id, "invited-driver")
        XCTAssertEqual(storage.savedSession?.token, "redeemed-session-1")
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(redemptions().count, 1)
    }

    func testQueuedInviteSurvivesAlreadyExpiredSavedSessionAndCanBeRedeemed() async {
        storage.savedSession = SavedSession(endpoint: endpoint, token: "expired-session",
                                            expiresAt: Int(Date().timeIntervalSince1970) - 1)
        receiveInvite()
        await store.restoreSession()
        assertSignedOut(store)
        XCTAssertFalse(store.canRetryRestore)
        XCTAssertFalse(store.isRestoringSession)
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(store.pendingInvite?.token, InviteTestBackend.inviteToken)
        XCTAssertTrue(backend.withState { $0.requests.isEmpty }, "Expired sessions need no network validation")
        let redeemed = await store.redeemInvite(username: "mario", password: password)
        XCTAssertTrue(redeemed)
        XCTAssertEqual(store.principal?.id, "invited-driver")
        XCTAssertEqual(storage.savedSession?.token, "redeemed-session-1")
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(redemptions().count, 1)
    }

    func testQueuedInviteCannotRedeemWhileSavedSessionStillNeedsVerification() async {
        storage.savedSession = SavedSession(endpoint: endpoint, token: "saved-session", expiresAt: backend.withState { $0.expiresAt })
        backend.withState { $0.identityStatus = 503 }
        receiveInvite()
        await store.restoreSession()
        XCTAssertTrue(store.canRetryRestore)
        XCTAssertNil(store.principal)
        XCTAssertEqual(storage.savedSession?.token, "saved-session")
        XCTAssertEqual(store.pendingInvite?.token, InviteTestBackend.inviteToken)
        let redeemed = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(redeemed)
        XCTAssertTrue(redemptions().isEmpty)
        backend.withState { $0.identityStatus = 200 }
        await store.restoreSession(retry: true)
        XCTAssertNotNil(store.principal)
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(storage.savedSession?.token, "saved-session")
        XCTAssertTrue(redemptions().isEmpty)
    }

    func testFailedSessionInstallationClearsStoredSessionAndRevokesIssuedToken() async {
        storage.failSessionSave = true
        receiveInvite()
        let success = await store.redeemInvite(username: "mario", password: password)
        XCTAssertFalse(success)
        assertSignedOut(store)
        XCTAssertNotNil(store.inviteErrorMessage)
        XCTAssertTrue(storage.sessionWrites.isEmpty)
        XCTAssertTrue(storage.creationLoads.isEmpty)
        XCTAssertTrue(storage.restaurantLoads.isEmpty)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer redeemed-session-1"])
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "GET" } })
    }

    func testInvalidReturnedSessionNeverGrantsAuthority() async {
        for invalidCase in 0..<2 {
            let candidateStorage = InviteTestStorage()
            let candidate = makeStore(storage: candidateStorage)
            backend.withState {
                $0.user = Principal(id: "invited-driver", name: "Corriere invitato",
                                    role: "driver",
                                    teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
                $0.emptyRedemptionToken = invalidCase == 0
                $0.expiresAt = Int(Date().timeIntervalSince1970) + (invalidCase == 1 ? -1 : 3600)
            }
            receiveInvite(in: candidate)
            let success = await candidate.redeemInvite(username: "mario", password: password)
            XCTAssertFalse(success)
            XCTAssertNil(candidate.principal)
            XCTAssertNil(candidateStorage.savedSession)
            XCTAssertTrue(candidateStorage.sessionWrites.isEmpty)
            XCTAssertFalse(candidate.locationSharing)
            XCTAssertNotNil(candidate.inviteErrorMessage)
        }
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "GET" } })
    }

    func testDriverCannotCreateOrRevokeInvite() async throws {
        await store.login(username: "mario", password: password)
        XCTAssertEqual(store.role, .driver)
        let invite = try APIClient.decoder().decode(DriverInvite.self, from: InviteTestBackend.inviteData())
        let created = await store.createInvite(name: "Unauthorized invite")
        let revoked = await store.revokeInvite(invite)
        XCTAssertNil(created)
        XCTAssertFalse(revoked)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path.hasPrefix("/v1/invites") } })
    }

    func testDispatcherCanCreateAndRevokeInviteWithoutChangingOwnSession() async throws {
        backend.withState { $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: "dispatcher", roles: ["dispatcher"],
                                             teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName) }
        await store.login(username: "dispatcher", password: password)
        let saved = try XCTUnwrap(storage.savedSession)
        let created = await store.createInvite(name: "Nuovo corriere")
        let invite = try XCTUnwrap(created)
        let revoked = await store.revokeInvite(invite)
        XCTAssertTrue(revoked)
        XCTAssertEqual(store.role, .dispatcher)
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertNil(store.pendingInvite)
        let requests = backend.withState { $0.requests.filter { $0.path.hasPrefix("/v1/invites") } }
        XCTAssertEqual(requests.map { $0.method }, ["POST", "DELETE"])
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer login-session" })
    }

    func testSuccessfulRedemptionTrustsServerRolesAndDismissesInvite() async throws {
        let returnedRoles: [(String, [String])] = [
            ("driver", ["driver"]),
            ("dispatcher", ["dispatcher"]),
            ("dispatcher", ["dispatcher", "driver"]),
            ("operator", ["driver"])
        ]
        for (primary, capabilities) in returnedRoles {
            let candidateStorage = InviteTestStorage()
            let candidate = makeStore(storage: candidateStorage)
            let user = Principal(id: "invited-account", name: "Account invitato", role: primary, roles: capabilities,
                                 teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
            backend.withState { $0.user = user }
            receiveInvite(in: candidate)
            let redeemed = await candidate.redeemInvite(username: "mario", password: password)
            XCTAssertTrue(redeemed, "Rejected server role \(primary) with capabilities \(capabilities)")
            XCTAssertEqual(candidate.principal, user)
            XCTAssertEqual(candidate.role, user.serverRole)
            XCTAssertEqual(candidate.availableRoles, user.availableRoles)
            XCTAssertNil(candidate.pendingInvite)
            XCTAssertNil(candidate.inviteErrorMessage)
            XCTAssertNil(candidate.errorMessage)
            XCTAssertFalse(candidate.inviteOutcomeUncertain)
            XCTAssertFalse(candidate.isRedeemingInvite)
            XCTAssertFalse(candidate.isMutating)
            XCTAssertFalse(candidate.locationSharing)
            let saved = try XCTUnwrap(candidateStorage.savedSession)
            XCTAssertEqual(saved.token, "redeemed-session-\(redemptions().count)")
            XCTAssertEqual(candidateStorage.sessionWrites.count, 1)
        }
        XCTAssertEqual(redemptions().count, returnedRoles.count)
        XCTAssertTrue(backend.withState { $0.revokedTokens.isEmpty })
    }

    func testRedemptionRejectsMissingOrMalformedTeamDespiteDriverOnlyAuthority() async {
        let invalidTeams: [(String?, String?)] = [
            (nil, InviteTestBackend.teamName), (InviteTestBackend.teamID, nil), (nil, nil),
            ("bad/team", InviteTestBackend.teamName), (String(repeating: "a", count: 65), InviteTestBackend.teamName),
            ("tèam", InviteTestBackend.teamName), (InviteTestBackend.teamID, " "),
            (InviteTestBackend.teamID, "Centrale\nPachino"),
            (InviteTestBackend.teamID, String(repeating: "é", count: 121))
        ]
        for (teamId, teamName) in invalidTeams {
            let candidateStorage = InviteTestStorage()
            let candidate = makeStore(storage: candidateStorage)
            backend.withState {
                $0.user = Principal(id: "invited-driver", name: "Corriere invitato", role: "driver", roles: ["driver"],
                                    teamId: teamId, teamName: teamName)
            }
            receiveInvite(in: candidate)
            let redeemed = await candidate.redeemInvite(username: "mario", password: password)
            XCTAssertFalse(redeemed)
            XCTAssertNil(candidate.principal)
            XCTAssertNil(candidate.role)
            XCTAssertNil(candidateStorage.savedSession)
            XCTAssertTrue(candidateStorage.sessionWrites.isEmpty)
            XCTAssertTrue(candidateStorage.creationLoads.isEmpty)
            XCTAssertTrue(candidateStorage.restaurantLoads.isEmpty)
            XCTAssertNotNil(candidate.inviteErrorMessage)
        }
        XCTAssertEqual(redemptions().count, invalidTeams.count)
        XCTAssertEqual(backend.withState { $0.revokedTokens.count }, invalidTeams.count)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "GET" } })
    }

    func testDriverRedemptionDoesNotLoadOrChangeDispatcherRecovery() async throws {
        storage.failCreationLoad = true
        storage.failRestaurantLoad = true
        receiveInvite()
        let redeemed = await store.redeemInvite(username: "mario", password: password)
        XCTAssertTrue(redeemed)
        XCTAssertEqual(store.principal?.teamId, InviteTestBackend.teamID)
        XCTAssertEqual(store.role, .driver)
        XCTAssertNotNil(storage.savedSession)
        XCTAssertTrue(storage.creationLoads.isEmpty)
        XCTAssertTrue(storage.restaurantLoads.isEmpty)
        XCTAssertTrue(storage.creationWrites.isEmpty)
        XCTAssertTrue(storage.restaurantWrites.isEmpty)
        XCTAssertTrue(storage.creationClears.isEmpty)
        XCTAssertTrue(storage.restaurantClears.isEmpty)
        XCTAssertNil(store.pendingCreation)
        XCTAssertNil(store.pendingRestaurant)
    }

    func testDispatcherWithoutValidatedTeamCannotCreateOrRevokeInvite() async throws {
        let invalidTeams: [(String?, String?)] = [
            (nil, nil), (InviteTestBackend.teamID, nil), (nil, InviteTestBackend.teamName),
            ("bad/team", InviteTestBackend.teamName), (InviteTestBackend.teamID, "Centrale\nPachino")
        ]
        let invite = try APIClient.decoder().decode(DriverInvite.self, from: InviteTestBackend.inviteData())
        for (teamId, teamName) in invalidTeams {
            let candidateStorage = InviteTestStorage()
            let candidate = makeStore(storage: candidateStorage)
            backend.withState {
                $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: "dispatcher", roles: ["dispatcher"],
                                    teamId: teamId, teamName: teamName)
            }
            await candidate.login(username: "dispatcher", password: password)
            XCTAssertEqual(candidate.role, .dispatcher)
            let saved = try XCTUnwrap(candidateStorage.savedSession)
            let created = await candidate.createInvite(name: "Nuovo corriere")
            let revoked = await candidate.revokeInvite(invite)
            XCTAssertNil(created)
            XCTAssertFalse(revoked)
            XCTAssertEqual(candidateStorage.savedSession, saved)
        }
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path.hasPrefix("/v1/invites") } })
    }

    func testIssuerRejectsAndRevokesInviteWhoseTeamDoesNotExactlyMatchBeforeSharing() async throws {
        backend.withState {
            $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: "dispatcher", roles: ["dispatcher"],
                                teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
        }
        await store.login(username: "dispatcher", password: password)
        let saved = try XCTUnwrap(storage.savedSession)
        let principal = try XCTUnwrap(store.principal)
        let mismatches = [
            ("Other-2", InviteTestBackend.teamName),
            (InviteTestBackend.teamID, "Altra centrale"),
            (InviteTestBackend.teamID.lowercased(), InviteTestBackend.teamName),
            (InviteTestBackend.teamID, " " + InviteTestBackend.teamName + " ")
        ]
        for (teamId, teamName) in mismatches {
            backend.withState { $0.inviteTeamID = teamId; $0.inviteTeamName = teamName }
            let created = await store.createInvite(name: "Nuovo corriere")
            XCTAssertNil(created, "A mismatched-team secret must never reach the share sheet")
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.principal, principal)
            XCTAssertEqual(storage.savedSession, saved)
        }
        let requests = backend.withState { $0.requests.filter { $0.path.hasPrefix("/v1/invites") } }
        XCTAssertEqual(requests.map { $0.method }, Array(repeating: ["POST", "DELETE"], count: mismatches.count).flatMap { $0 })
        XCTAssertTrue(requests.filter { $0.method == "DELETE" }.allSatisfy { $0.path.lowercased() == "/v1/invites/\(InviteTestBackend.inviteID)" })
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer login-session" })
    }

    func testDispatcherCannotRevokeInviteFromDifferentTeam() async throws {
        backend.withState {
            $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: "dispatcher", roles: ["dispatcher"],
                                teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
        }
        await store.login(username: "dispatcher", password: password)
        for teamId in ["Other-2", InviteTestBackend.teamID.lowercased()] {
            let invite = try APIClient.decoder().decode(DriverInvite.self, from: InviteTestBackend.inviteData(teamId: teamId))
            let revoked = await store.revokeInvite(invite)
            XCTAssertFalse(revoked)
        }
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path.hasPrefix("/v1/invites") } })
    }

    func testDualDispatcherCanIssueInviteButDriverViewCannotIssueOrRevoke() async throws {
        backend.withState {
            $0.user = Principal(id: "dual-a", name: "Centrale e corriere", role: "dispatcher", roles: ["dispatcher", "driver"],
                                teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
        }
        await store.login(username: "dual", password: password)
        let saved = try XCTUnwrap(storage.savedSession)
        let principal = try XCTUnwrap(store.principal)
        XCTAssertEqual(store.role, .dispatcher)
        XCTAssertTrue(store.canSwitchRole)
        let created = await store.createInvite(name: "Nuovo corriere")
        let invite = try XCTUnwrap(created)
        XCTAssertEqual(invite.teamId, principal.teamId)
        XCTAssertEqual(invite.teamName, principal.teamName)
        XCTAssertTrue(store.switchRole(to: .driver))
        let deniedCreate = await store.createInvite(name: "Non autorizzato in questa vista")
        let deniedRevoke = await store.revokeInvite(invite)
        XCTAssertNil(deniedCreate)
        XCTAssertFalse(deniedRevoke)
        XCTAssertEqual(backend.withState { $0.requests.filter { $0.path.hasPrefix("/v1/invites") }.map { $0.method } }, ["POST"])
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        let revoked = await store.revokeInvite(invite)
        XCTAssertTrue(revoked)
        XCTAssertEqual(store.principal, principal)
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertEqual(backend.withState { $0.requests.filter { $0.path.hasPrefix("/v1/invites") }.map { $0.method } }, ["POST", "DELETE"])
    }

    func testInviteIssuanceAndRoleSwitchesPreserveTeamScopedCreationAndRestaurantRecovery() async throws {
        let user = Principal(id: "dual-a", name: "Centrale e corriere", role: "dispatcher", roles: ["dispatcher", "driver"],
                             teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
        let otherTeam = Principal(id: user.id, name: user.name, role: user.role, roles: user.roles,
                                  teamId: "Other-2", teamName: "Altra centrale")
        let scope = CreationScope.current(endpoint: endpoint, user: user)
        let otherScope = CreationScope.current(endpoint: endpoint, user: otherTeam)
        let legacyScope = CreationScope.legacy(endpoint: endpoint, accountId: user.id)
        let delivery = NewDelivery(shopName: "Ristorante", pickupAddress: "Via Roma 1", pickup: .pachino,
                                   dropoffAddress: "Via Roma 2", dropoff: .pachino, readyAt: nil,
                                   deadlineAt: 2_000_000_000, loadUnits: 1, maxRideSeconds: 1800)
        let pending = PendingCreation(idempotencyKey: "team-delivery-key", delivery: delivery)
        let foreignPending = PendingCreation(idempotencyKey: "other-team-delivery-key", delivery: delivery)
        let legacyPending = PendingCreation(idempotencyKey: "legacy-delivery-key", delivery: delivery)
        let restaurant = NewRestaurant(name: "Ristorante", address: "Via Roma 1", coordinate: .pachino)
        let pendingRestaurant = PendingRestaurant(idempotencyKey: "team-restaurant-key", restaurant: restaurant)
        let foreignRestaurant = PendingRestaurant(idempotencyKey: "other-team-restaurant-key", restaurant: restaurant)
        storage.creations = [scope: pending, otherScope: foreignPending, legacyScope: legacyPending]
        storage.pendingRestaurants = [scope: pendingRestaurant, otherScope: foreignRestaurant]
        let existingCreations = storage.creations
        let existingRestaurants = storage.pendingRestaurants
        backend.withState { $0.user = user }
        await store.login(username: "dual", password: password)
        let saved = try XCTUnwrap(storage.savedSession)
        XCTAssertEqual(store.pendingCreation, pending)
        XCTAssertEqual(store.pendingRestaurant, pendingRestaurant)
        XCTAssertEqual(store.legacyPendingCreation, legacyPending)
        XCTAssertEqual(storage.creationLoads, [scope, legacyScope])
        XCTAssertEqual(storage.restaurantLoads, [scope])
        let created = await store.createInvite(name: "Nuovo corriere")
        let invite = try XCTUnwrap(created)
        let revoked = await store.revokeInvite(invite)
        XCTAssertTrue(revoked)
        XCTAssertTrue(store.switchRole(to: .driver))
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        XCTAssertEqual(store.principal, user)
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertEqual(store.pendingCreation, pending)
        XCTAssertEqual(store.pendingRestaurant, pendingRestaurant)
        XCTAssertEqual(store.legacyPendingCreation, legacyPending)
        XCTAssertTrue(store.legacyCreationNeedsReview)
        XCTAssertTrue(store.createOutcomeUncertain)
        XCTAssertEqual(storage.creations, existingCreations)
        XCTAssertEqual(storage.pendingRestaurants, existingRestaurants)
        XCTAssertTrue(storage.creationWrites.isEmpty)
        XCTAssertTrue(storage.restaurantWrites.isEmpty)
        XCTAssertTrue(storage.creationClears.isEmpty)
        XCTAssertTrue(storage.restaurantClears.isEmpty)
        XCTAssertEqual(storage.sessionWrites.count, 1)
        XCTAssertFalse(backend.withState {
            $0.requests.contains { $0.method == "POST" && ["/v1/deliveries", "/v1/restaurants"].contains($0.path) }
        }, "Issuing an invite must never replay either recovery request")
    }

}

private final class InviteTestStorage: SessionStorage {
    var savedSession: SavedSession?
    var sessionWrites: [Data] = []
    var creationWrites: [Data] = []
    var restaurantWrites: [Data] = []
    var creations: [String: PendingCreation] = [:]
    var pendingRestaurants: [String: PendingRestaurant] = [:]
    var creationLoads: [String] = []
    var restaurantLoads: [String] = []
    var creationClears: [String] = []
    var restaurantClears: [String] = []
    var failSessionSave = false
    var failCreationLoad = false
    var failRestaurantLoad = false
    func loadSession() throws -> SavedSession? { savedSession }
    func saveSession(_ value: SavedSession) throws {
        if failSessionSave { throw APIError(message: "Impossibile salvare i dati protetti del dispositivo.") }
        sessionWrites.append(try JSONEncoder().encode(value))
        savedSession = value
    }
    func clearSession() throws { savedSession = nil }
    func loadCreation(scope: String) throws -> PendingCreation? {
        creationLoads.append(scope)
        if failCreationLoad { throw APIError(message: "Impossibile leggere i dati protetti del dispositivo.") }
        return creations[scope]
    }
    func saveCreation(_ value: PendingCreation, scope: String) throws {
        creationWrites.append(try JSONEncoder().encode(value))
        creations[scope] = value
    }
    func clearCreation(scope: String) throws {
        creationClears.append(scope)
        creations[scope] = nil
    }
    func loadRestaurant(scope: String) throws -> PendingRestaurant? {
        restaurantLoads.append(scope)
        if failRestaurantLoad { throw APIError(message: "Impossibile leggere i ristoranti protetti del dispositivo.") }
        return pendingRestaurants[scope]
    }
    func saveRestaurant(_ value: PendingRestaurant, scope: String) throws {
        restaurantWrites.append(try JSONEncoder().encode(value))
        pendingRestaurants[scope] = value
    }
    func clearRestaurant(scope: String) throws {
        restaurantClears.append(scope)
        pendingRestaurants[scope] = nil
    }
}

private final class InviteTestURLProtocol: URLProtocol {
    static var backend: InviteTestBackend?
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Capture this test's backend before dispatch, so cancelled requests cannot reach a later test.
        guard let backend = Self.backend else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        DispatchQueue.global().async { [self] in
            let result = Result { try backend.respond(to: request) }
            stateLock.lock(); let cancelled = stopped; stateLock.unlock()
            guard !cancelled else { return }
            switch result {
            case .success(let (status, data)):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

private final class InviteTestBackend {
    static let inviteID = "c55a19de-32bf-4375-91cd-a37779c5ff88"
    static let inviteToken = String(repeating: "ab12", count: 16)
    static let teamID = "Pachino-1"
    static let teamName = "Centrale Pachino"
    struct RequestRecord {
        let method: String
        let path: String
        let origin: String
        let query: String?
        let authorization: String?
        let contentType: String?
        let idempotencyKey: String?
        let handlesCookies: Bool
        let cachePolicy: URLRequest.CachePolicy
        let body: Data
    }
    private let lock = NSLock()
    var requests: [RequestRecord] = []
    var revokedTokens: [String] = []
    var user = Principal(id: "invited-driver", name: "Corriere invitato", role: "driver", roles: ["driver"],
                         teamId: InviteTestBackend.teamID, teamName: InviteTestBackend.teamName)
    var inviteTeamID = InviteTestBackend.teamID
    var inviteTeamName = InviteTestBackend.teamName
    var expiresAt = Int(Date().timeIntervalSince1970) + 3600
    var redemptionStatus = 201
    var redemptionError = "private-server-detail"
    var identityStatus = 200
    var malformedRedemption = false
    var loseRedemptionResponse = false
    var emptyRedemptionToken = false
    var onRedemption: (() -> Void)?
    var onIdentity: (() -> Void)?
    var redemptionGate: DispatchSemaphore?
    var identityGate: DispatchSemaphore?
    private var redemptionCount = 0

    func withState<T>(_ operation: (InviteTestBackend) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation(self)
    }

    static func inviteData(token: String = InviteTestBackend.inviteToken,
                           teamId: String = InviteTestBackend.teamID,
                           teamName: String = InviteTestBackend.teamName) throws -> Data {
        try json(["id": inviteID, "token": token, "expires_at": 2_000_000_000, "name": "Nuovo corriere", "role": "driver",
                  "team_id": teamId, "team_name": teamName])
    }

    func respond(to request: URLRequest) throws -> (Int, Data) {
        let body = try Self.body(of: request)
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        var origin = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        var gate: DispatchSemaphore?
        var received: (() -> Void)?
        var loseResponse = false
        // Never hold the lock while a test is deciding to release a delayed response.
        let response: (Int, Data) = try withState { state in
            state.requests.append(RequestRecord(method: method, path: path, origin: origin.string!, query: request.url?.query,
                authorization: authorization, contentType: request.value(forHTTPHeaderField: "Content-Type"),
                idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"), handlesCookies: request.httpShouldHandleCookies,
                cachePolicy: request.cachePolicy, body: body))
            if path == "/v1/invites/redeem" && method == "POST" {
                state.redemptionCount += 1
                gate = state.redemptionGate; received = state.onRedemption
                loseResponse = state.loseRedemptionResponse
                if state.redemptionStatus != 201 { return (state.redemptionStatus, try Self.json(["error": state.redemptionError])) }
                if state.malformedRedemption { return (201, Data(#"{"unexpected":"private-server-detail"}"#.utf8)) }
                return (201, try Self.json(["token": state.emptyRedemptionToken ? "" : "redeemed-session-\(state.redemptionCount)",
                                           "expires_at": state.expiresAt, "user": Self.userBody(state.user)]))
            }
            if path == "/v1/invites" && method == "POST" {
                return (201, try Self.inviteData(teamId: state.inviteTeamID, teamName: state.inviteTeamName))
            }
            if path.lowercased() == "/v1/invites/\(Self.inviteID)" && method == "DELETE" { return (204, Data()) }
            if path == "/v1/session" && method == "POST" {
                return (201, try Self.json(["token": "login-session", "expires_at": state.expiresAt, "user": Self.userBody(state.user)]))
            }
            if path == "/v1/session" && method == "GET" {
                gate = state.identityGate; received = state.onIdentity
                if state.identityStatus != 200 { return (state.identityStatus, Self.errorBody) }
                return (200, try Self.json(["expires_at": state.expiresAt, "user": Self.userBody(state.user)]))
            }
            if path == "/v1/session" && method == "DELETE" {
                state.revokedTokens.append(authorization ?? "")
                return (204, Data())
            }
            let driver = Driver(id: state.user.id, name: state.user.name, active: false, capacity: 2,
                                location: nil, locationUpdatedAt: nil)
            switch (method, path) {
            case ("GET", "/v1/drivers"): return (200, try APIClient.encoder().encode([driver]))
            case ("GET", "/v1/shift"): return (200, try APIClient.encoder().encode(driver))
            case ("GET", "/v1/deliveries"), ("GET", "/v1/restaurants"): return (200, Data("[]".utf8))
            case ("GET", "/v1/route"):
                let route = DriverRoute(driverId: state.user.id, stops: [], travelSeconds: 0, finishAt: 0, feasible: true, warnings: [])
                return (200, try APIClient.encoder().encode(route))
            default: return (404, Self.errorBody)
            }
        }
        received?()
        if let gate, gate.wait(timeout: .now() + 10) == .timedOut { throw URLError(.timedOut) }
        if loseResponse { throw URLError(.networkConnectionLost) }
        return response
    }

    private static let errorBody = Data(#"{"error":"private-server-detail"}"#.utf8)
    private static func userBody(_ user: Principal) -> [String: Any] {
        var body: [String: Any] = ["id": user.id, "name": user.name, "role": user.role, "roles": user.roles]
        if let teamId = user.teamId { body["team_id"] = teamId }
        if let teamName = user.teamName { body["team_name"] = teamName }
        return body
    }
    private static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
