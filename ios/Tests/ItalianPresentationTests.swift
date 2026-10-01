import XCTest
@testable import Arrivau

final class ItalianPresentationTests: XCTestCase {
    func testItalianTitlesPreserveWireValuesAndDemoCredentials() throws {
        XCTAssertEqual(DeliveryStatus.allCases.map(\.title), ["Da assegnare", "Assegnata", "In consegna", "Consegnata"])
        XCTAssertEqual(DeliveryStatus.allCases.map(\.rawValue), ["pending", "assigned", "picked_up", "delivered"])
        XCTAssertEqual(String(decoding: try APIClient.encoder().encode(DeliveryStatus.pickedUp), as: UTF8.self), #""picked_up""#)
        XCTAssertEqual(DemoRole.allCases.map(\.title), ["Centrale", "Corriere 1", "Corriere 2"])
        XCTAssertEqual(DemoRole.allCases.map(\.rawValue), ["dispatcher", "driver1", "driver2"])
        XCTAssertEqual(DemoRole.allCases.map(\.token), ["demo-dispatcher", "demo-driver-1", "demo-driver-2"])
        XCTAssertEqual(DemoRole.driver1.driverId, "driver-1")
        XCTAssertEqual(DemoRole.driver2.driverId, "driver-2")
        XCTAssertEqual(StopKind.pickup.rawValue, "pickup")
        XCTAssertEqual(StopKind.dropoff.rawValue, "dropoff")
        XCTAssertEqual(StopKind.pickup.title, "Ritiro")
        XCTAssertEqual(StopKind.dropoff.title, "Consegna")
        let route = try APIClient.decoder().decode(DriverRoute.self, from: Fixtures.route)
        XCTAssertEqual(route.stops[0].title, "Ritiro")
        XCTAssertEqual(route.stops[0].id, "delivery-1-pickup")
    }

    func testOnlyExactSeededIdentityNamesAreTranslated() throws {
        let principal = Principal(id: "dispatcher-1", name: "Dispatcher", role: "dispatcher")
        XCTAssertEqual(principal.displayName, "Centrale")
        XCTAssertEqual(principal.name, "Dispatcher")
        XCTAssertEqual(principal.role, "dispatcher")
        XCTAssertEqual(principal.roleTitle, "Centrale")
        for index in 1...2 {
            let driver = Driver(id: "driver-\(index)", name: "Driver \(index)", active: true, capacity: 2, location: nil, locationUpdatedAt: nil)
            XCTAssertEqual(driver.displayName, "Corriere \(index)")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(driver)) as? [String: Any])
            XCTAssertEqual(body["name"] as? String, "Driver \(index)")
            XCTAssertNil(body["display_name"])
        }
        XCTAssertEqual(Principal(id: "driver-1", name: "Driver 1", role: "driver").roleTitle, "Corriere")
        XCTAssertEqual(Principal(id: "driver-1", name: "Mario", role: "future_role").roleTitle, "Ruolo non riconosciuto")
        XCTAssertEqual(ItalianPresentation.demoName(id: "custom-id", name: "Driver 1"), "Driver 1")
        XCTAssertEqual(ItalianPresentation.demoName(id: "driver-1", name: "Driver 1 Pizzeria"), "Driver 1 Pizzeria")
        XCTAssertEqual(ItalianPresentation.demoName(id: "driver-1", name: "Mario"), "Mario")
        XCTAssertEqual(ItalianPresentation.demoName(id: "shop-1", name: "Dispatcher"), "Dispatcher")
    }

    func testKnownRouteWarningsAreLocalizedAndRetainOpaqueIdentifiers() throws {
        let exactWarnings = [
            ("Driver is not on shift", "Il corriere non è in turno."),
            ("Driver location is unavailable", "La posizione del corriere non è disponibile."),
            ("Driver location is older than 5 minutes; estimates may be inaccurate", "La posizione del corriere risale a più di 5 minuti fa. Le stime potrebbero essere imprecise."),
            ("Onboard load exceeds capacity", "Il carico a bordo supera la capacità.")
        ]
        let prefixes = [
            ("Duplicate stop for ", "Tappa duplicata per la consegna "),
            ("Invalid route reference ", "Riferimento non valido nel percorso: "),
            ("Duplicate pickup for ", "Ritiro duplicato per la consegna "),
            ("Capacity exceeded at pickup ", "Capacità superata al ritiro della consegna "),
            ("Maximum ride time exceeded for ", "Tempo massimo di trasporto superato per la consegna "),
            ("Dropoff precedes pickup for ", "La consegna precede il ritiro per "),
            ("Deadline missed for ", "Termine di consegna superato per "),
            ("Missing Pickup stop for ", "Manca la tappa di ritiro per la consegna "),
            ("Missing Dropoff stop for ", "Manca la tappa di consegna per ")
        ]
        let identifier = "6c9e0838-e98b-44fc-8fd2-3dfdd8ba0880"
        let cases = exactWarnings + prefixes.map { ($0.0 + identifier, $0.1 + identifier) }
        for (raw, expected) in cases { XCTAssertEqual(ItalianPresentation.routeWarning(raw), expected, raw) }
        let route = DriverRoute(driverId: "driver-1", stops: [], travelSeconds: 0, finishAt: 0, feasible: false, warnings: cases.map { $0.0 })
        XCTAssertEqual(route.localizedWarnings, cases.map { $0.1 })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(route)) as? [String: Any])
        XCTAssertEqual(body["warnings"] as? [String], cases.map { $0.0 })
        XCTAssertNil(body["localized_warnings"])
    }

    func testUnknownOrMalformedWarningsCannotEchoEnglishOrUserText() {
        for warning in ["New English warning", "Duplicate stop for ", "Deadline missed for A user's shop name", "Missing Pickup stop for id\nEnglish detail", "Invalid route reference <script>"] {
            XCTAssertEqual(ItalianPresentation.routeWarning(warning), ItalianPresentation.unknownRouteWarning)
        }
        XCTAssertEqual(ItalianPresentation.routeWarning("Deadline missed for delivery-1"), "Termine di consegna superato per delivery-1")
    }

    func testKnownBackendErrorsHaveSpecificItalianTranslations() {
        let cases = [
            ("A valid bearer token is required", "Accesso non valido. Seleziona di nuovo un ruolo demo."),
            ("dispatcher role required", "Questa operazione richiede il ruolo Centrale."),
            ("driver role required", "Questa operazione richiede il ruolo Corriere."),
            ("Path must contain a valid UTF-8 identifier", "L’identificativo della richiesta non è valido."),
            ("JSON body exceeds the 16 KiB limit", "I dati della richiesta superano il limite di 16 KiB."),
            ("Request must contain valid JSON matching the endpoint schema", "I dati inviati non sono validi per questa operazione."),
            ("Endpoint not found", "L’operazione richiesta non è disponibile sul server."),
            ("Method not allowed", "Questo tipo di richiesta non è consentito."),
            ("Driver not found", "Corriere non trovato."),
            ("Delivery not found", "Consegna non trovata."),
            ("An internal storage error occurred", "Si è verificato un errore nel salvataggio dei dati sul server."),
            ("Names and addresses must contain 1–240 characters", "Nomi e indirizzi devono contenere da 1 a 240 caratteri."),
            ("Coordinates must be finite latitude/longitude values", "Le coordinate devono contenere valori validi di latitudine e longitudine."),
            ("Timestamps must be Unix seconds between 1970 and 3000", "Le date devono essere comprese tra il 1970 e il 3000."),
            ("Deadline must be at or after readiness", "Il termine di consegna non può precedere l’orario di disponibilità."),
            ("Load must be between 1 and 8 units", "Il carico deve essere compreso tra 1 e 8 unità."),
            ("Maximum ride time must be between 60 and 7200 seconds", "Il tempo massimo di trasporto deve essere compreso tra 1 e 120 minuti."),
            ("Capacity must be between 1 and 8", "La capacità deve essere compresa tra 1 e 8 unità."),
            ("Complete or reassign outstanding work before ending the shift", "Completa o riassegna le consegne in corso prima di terminare il turno."),
            ("Capacity is too small for the committed route", "La capacità è insufficiente per il percorso assegnato."),
            ("Start a shift before reporting location", "Inizia un turno prima di condividere la posizione."),
            ("Picked-up and delivered jobs cannot be reassigned", "Le consegne già ritirate o completate non possono essere riassegnate."),
            ("Driver must be on shift with a reported location", "Il corriere deve essere in turno e aver condiviso la posizione."),
            ("Driver location is older than 5 minutes; request an update", "La posizione del corriere risale a più di 5 minuti fa. Richiedi un aggiornamento."),
            ("Driver route limit reached (32 outstanding stops)", "Il corriere ha raggiunto il limite di 32 tappe da completare."),
            ("No feasible insertion: check capacity, readiness, deadline, and maximum ride time", "Non è possibile aggiungere la consegna al percorso. Controlla capacità, disponibilità, termine di consegna e tempo massimo di trasporto."),
            ("Reassignment introduces a new constraint violation in the previous driver's remaining route", "La riassegnazione rende incompatibile con i vincoli il percorso rimanente del corriere precedente."),
            ("Status must be picked_up or delivered", "La consegna può essere aggiornata solo a «In consegna» o «Consegnata»."),
            ("Delivery is not assigned to this driver", "La consegna non è assegnata a questo corriere."),
            ("Driver must be on shift", "Il corriere deve essere in turno."),
            ("Invalid delivery status transition", "Questo cambio di stato della consegna non è consentito."),
            ("Complete the suggested next stop first", "Completa prima la prossima tappa indicata."),
            ("Pickup is not the next route stop", "Il ritiro non è la prossima tappa del percorso."),
            ("Delivery is not ready for pickup", "La consegna non è ancora pronta per il ritiro."),
            ("Pickup would exceed driver capacity", "Il ritiro supererebbe la capacità del corriere."),
            ("Suggestions are only available before pickup", "I suggerimenti sono disponibili solo prima del ritiro.")
        ]
        for (raw, expected) in cases { XCTAssertEqual(ItalianPresentation.serverError(raw, statusCode: 409), expected, raw) }
    }

    func testUnknownServerAndSystemErrorsUseItalianFallbacks() {
        for message in [nil, "", "Unknown English server detail", "Driver not found: user data"] as [String?] {
            XCTAssertEqual(ItalianPresentation.serverError(message, statusCode: 500), "La richiesta al server non è riuscita (HTTP 500). Riprova.")
        }
        let unknown = NSError(domain: "Unexpected", code: 1, userInfo: [NSLocalizedDescriptionKey: "Raw English error"])
        XCTAssertEqual(ItalianPresentation.errorMessage(unknown), ItalianPresentation.unknownError)
        XCTAssertEqual(ItalianPresentation.errorMessage(URLError(.unknown)), "Errore di connessione. Controlla la rete e riprova.")
        XCTAssertEqual(ItalianPresentation.errorMessage(URLError(.timedOut)), "Il server non ha risposto in tempo. Controlla la connessione e riprova.")
        XCTAssertEqual(ItalianPresentation.errorMessage(URLError(.notConnectedToInternet)), "Connessione Internet non disponibile. Controlla la rete e riprova.")
        XCTAssertEqual(ItalianPresentation.errorMessage(URLError(.cannotConnectToHost)), "Impossibile raggiungere il server. Controlla che l’API sia avviata e che l’indirizzo sia corretto.")
        XCTAssertEqual(ItalianPresentation.errorMessage(URLError(.serverCertificateUntrusted)), "Impossibile stabilire una connessione sicura con il server. Controlla la configurazione HTTPS.")
        XCTAssertEqual(ItalianPresentation.errorMessage(CancellationError()), "Richiesta annullata.")
        let context = DecodingError.Context(codingPath: [], debugDescription: "Raw English decoding error")
        XCTAssertEqual(ItalianPresentation.errorMessage(DecodingError.dataCorrupted(context)), "La risposta del server contiene dati non validi o non compatibili con questa demo.")
    }

    func testMutationUncertaintyDefaultsToFalseAndNeverDependsOnErrorText() {
        XCTAssertFalse(APIError(message: "invalid response did not match").mutationOutcomeUncertain)
        XCTAssertTrue(APIError(message: "Messaggio italiano", mutationOutcomeUncertain: true).mutationOutcomeUncertain)
    }

    func testDateFormattingExplicitlyUsesItalianAnd24HourTime() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T15:04:05Z"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(ItalianPresentation.locale.identifier, "it_IT")
        XCTAssertEqual(ItalianPresentation.time(date, timeZone: utc), "15:04")
        XCTAssertEqual(ItalianPresentation.time(date, timeZone: utc, includesSeconds: true), "15:04:05")
        let fullDate = ItalianPresentation.dateTime(date, timeZone: utc)
        XCTAssertTrue(fullDate.contains("ott"), fullDate)
        XCTAssertTrue(fullDate.contains("2026"), fullDate)
        XCTAssertTrue(fullDate.contains("15:04"), fullDate)
        XCTAssertFalse(fullDate.contains("PM"), fullDate)
        XCTAssertFalse(fullDate.contains("Oct"), fullDate)
        XCTAssertEqual(date.italianTime, ItalianPresentation.time(date))
        XCTAssertEqual(date.italianTimeWithSeconds, ItalianPresentation.time(date, includesSeconds: true))
        XCTAssertEqual(date.italianDateTime, ItalianPresentation.dateTime(date))
    }

    func testValidationMessagesAreItalian() {
        func draft(name: String = "Pizzeria", pickup: Coordinate = .pachino, ready: Int = 1, deadline: Int = 2, load: Int = 1, ride: Int = 60) -> NewDelivery {
            NewDelivery(shopName: name, pickupAddress: "A", pickup: pickup, dropoffAddress: "B", dropoff: .pachino, readyAt: ready, deadlineAt: deadline, loadUnits: load, maxRideSeconds: ride)
        }
        XCTAssertEqual(draft(name: " ").validationError, "Inserisci il nome del negozio ed entrambi gli indirizzi.")
        XCTAssertEqual(draft(pickup: Coordinate(lat: .nan, lng: 0)).validationError, "Inserisci valori validi di latitudine e longitudine.")
        XCTAssertEqual(draft(ready: 3).validationError, "Il termine di consegna non può precedere l’orario di disponibilità.")
        XCTAssertEqual(draft(load: 0).validationError, "Il carico deve essere compreso tra 1 e 8 unità.")
        XCTAssertEqual(draft(ride: 59).validationError, "Il tempo massimo di trasporto deve essere compreso tra 1 e 120 minuti.")
        XCTAssertNil(draft(ready: 2, deadline: 2).validationError)
    }
}
