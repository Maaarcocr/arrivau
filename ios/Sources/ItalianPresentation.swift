import Foundation

/// Presentation-only localization. Wire values, identifiers and user-entered text stay unchanged.
enum ItalianPresentation {
    static let locale = Locale(identifier: "it_IT")
    static let unknownError = "Si è verificato un errore imprevisto. Riprova."
    static let unknownRouteWarning = "Il percorso presenta un problema non riconosciuto. Aggiorna i dati prima di proseguire."

    static func demoName(id: String, name: String) -> String {
        switch (id, name) {
        case ("dispatcher-1", "Dispatcher"): return "Centrale"
        case ("driver-1", "Driver 1"): return "Corriere 1"
        case ("driver-2", "Driver 2"): return "Corriere 2"
        default: return name
        }
    }

    /// Never show arbitrary server, decoding or operating-system descriptions to the user.
    static func errorMessage(_ error: Error) -> String {
        if let error = error as? APIError { return error.message }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: failure.code) {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return "Connessione Internet non disponibile. Controlla la rete e riprova."
            case .timedOut:
                return "Il server non ha risposto in tempo. Controlla la connessione e riprova."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Impossibile raggiungere il server. Controlla che l’API sia avviata e che l’indirizzo sia corretto."
            case .networkConnectionLost:
                return "La connessione al server si è interrotta. Controlla la rete e riprova."
            case .cancelled:
                return "Richiesta annullata."
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                return "Impossibile stabilire una connessione sicura con il server. Controlla la configurazione HTTPS."
            default:
                return "Errore di connessione. Controlla la rete e riprova."
            }
        }
        if error is CancellationError { return "Richiesta annullata." }
        if error is DecodingError { return "La risposta del server contiene dati non validi o non compatibili con questa app." }
        if error is EncodingError { return "Impossibile preparare i dati da inviare. Controlla i valori inseriti." }
        return unknownError
    }

    static func readiness(_ delivery: Delivery) -> String {
        switch delivery.readinessState {
        case .unknown: return "Da definire"
        case .estimated: return "Prevista alle \(delivery.readyAt.epochDate.italianTime) (stima)"
        case .ready: return "Pronta dalle \(delivery.readyAt.epochDate.italianTime) (confermata)"
        }
    }

    static func routeNotice(_ notice: String) -> String {
        if notice.hasPrefix("Pickup target missed for ") {
            return "Ritiro previsto oltre l’obiettivo di 10 minuti dalla disponibilità."
        }
        return "Controlla con la centrale l’orario previsto per il ritiro."
    }

    static func serverError(_ message: String?, statusCode: Int) -> String {
        if statusCode == 401 { return "Sessione scaduta o revocata. Accedi di nuovo." }
        if statusCode == 429 { return "Troppi tentativi di accesso. Attendi qualche minuto e riprova." }
        if (300..<400).contains(statusCode) { return "Il server richiede un reindirizzamento non consentito. Chiedi al responsabile l’indirizzo HTTPS definitivo." }
        if let message, let translated = serverErrors[message] { return translated }
        return "La richiesta al server non è riuscita (HTTP \(statusCode)). Riprova."
    }

    /// Exact contract messages only: unknown text is not echoed or translated by substring.
    private static let serverErrors: [String: String] = [
        "A valid bearer token is required": "Accesso non valido. Accedi di nuovo.",
        "dispatcher role required": "Questa operazione richiede il ruolo Centrale.",
        "driver role required": "Questa operazione richiede il ruolo Corriere.",
        "Path must contain a valid UTF-8 identifier": "L’identificativo della richiesta non è valido.",
        "JSON body exceeds the 16 KiB limit": "I dati della richiesta superano il limite di 16 KiB.",
        "Request must contain valid JSON matching the endpoint schema": "I dati inviati non sono validi per questa operazione.",
        "Endpoint not found": "L’operazione richiesta non è disponibile sul server.",
        "Method not allowed": "Questo tipo di richiesta non è consentito.",
        "Driver not found": "Corriere non trovato.",
        "Delivery not found": "Consegna non trovata.",
        "An internal storage error occurred": "Si è verificato un errore nel salvataggio dei dati sul server.",
        "Names and addresses must contain 1–240 characters": "Nomi e indirizzi devono contenere da 1 a 240 caratteri.",
        "Coordinates must be finite latitude/longitude values": "Le coordinate devono contenere valori validi di latitudine e longitudine.",
        "Timestamps must be Unix seconds between 1970 and 3000": "Le date devono essere comprese tra il 1970 e il 3000.",
        "Deadline must be at or after readiness": "Il termine di consegna non può precedere l’orario di disponibilità.",
        "Load must be between 1 and 8 units": "Il carico deve essere compreso tra 1 e 8 unità.",
        "Maximum ride time must be between 60 and 7200 seconds": "Il tempo massimo di trasporto deve essere compreso tra 1 e 120 minuti.",
        "Capacity must be between 1 and 8": "La capacità deve essere compresa tra 1 e 8 unità.",
        "Complete or reassign outstanding work before ending the shift": "Completa o riassegna le consegne in corso prima di terminare il turno.",
        "Capacity is too small for the committed route": "La capacità è insufficiente per il percorso assegnato.",
        "Start a shift before reporting location": "Inizia un turno prima di condividere la posizione.",
        "Picked-up and delivered jobs cannot be reassigned": "Le consegne già ritirate o completate non possono essere riassegnate.",
        "Driver must be on shift with a reported location": "Il corriere deve essere in turno e aver condiviso la posizione.",
        "Driver location is older than 5 minutes; request an update": "La posizione del corriere risale a più di 5 minuti fa. Richiedi un aggiornamento.",
        "Driver route limit reached (32 outstanding stops)": "Il corriere ha raggiunto il limite di 32 tappe da completare.",
        "No feasible insertion: check capacity, readiness, deadline, and maximum ride time": "Non è possibile aggiungere la consegna al percorso. Controlla capacità, disponibilità, termine di consegna e tempo massimo di trasporto.",
        "Reassignment introduces a new constraint violation in the previous driver's remaining route": "La riassegnazione rende incompatibile con i vincoli il percorso rimanente del corriere precedente.",
        "Status must be picked_up or delivered": "La consegna può essere aggiornata solo a «In consegna» o «Consegnata».",
        "Delivery is not assigned to this driver": "La consegna non è assegnata a questo corriere.",
        "Driver must be on shift": "Il corriere deve essere in turno.",
        "Invalid delivery status transition": "Questo cambio di stato della consegna non è consentito.",
        "Complete the suggested next stop first": "Completa prima la prossima tappa indicata.",
        "Pickup is not the next route stop": "Il ritiro non è la prossima tappa del percorso.",
        "Delivery is not ready for pickup": "La consegna non è ancora pronta per il ritiro.",
        "Pickup would exceed driver capacity": "Il ritiro supererebbe la capacità del corriere.",
        "Ready-in minutes must be between 0 and 120": "Indica un numero di minuti compreso tra 0 e 120.",
        "Readiness cannot change after pickup": "La disponibilità non può cambiare dopo il ritiro.",
        "Readiness changed; refresh the delivery and try again": "La disponibilità è cambiata. Aggiorna la consegna e riprova.",
        "Planning state changed while calculating road times; refresh and retry": "Il percorso è cambiato durante il calcolo. Aggiorna i dati e riprova.",
        "Set readiness before choosing a driver": "Indica quando sarà pronta prima di scegliere un corriere.",
        "Suggestions are only available before pickup": "I suggerimenti sono disponibili solo prima del ritiro."
    ]

    static func routeWarning(_ warning: String) -> String {
        switch warning {
        case "Driver is not on shift": return "Il corriere non è in turno."
        case "Driver location is unavailable": return "La posizione del corriere non è disponibile."
        case "Driver location is older than 5 minutes; estimates may be inaccurate":
            return "La posizione del corriere risale a più di 5 minuti fa. Le stime potrebbero essere imprecise."
        case "Onboard load exceeds capacity": return "Il carico a bordo supera la capacità."
        default: break
        }
        let prefixes = [
            ("Percorso stradale non raggiungibile per ", "Percorso stradale non raggiungibile per la consegna "),
            ("Readiness is unknown for ", "Disponibilità da definire per la consegna "),
            ("Onboard delivery delay exceeded for ", "Tempo a bordo superato per la consegna "),
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
        for (prefix, translated) in prefixes where warning.hasPrefix(prefix) {
            let identifier = String(warning.dropFirst(prefix.count))
            // Current server IDs are UUIDs; allow opaque fixture IDs as well, never prose.
            guard !identifier.isEmpty, identifier.utf8.count <= 128,
                  identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                return unknownRouteWarning
            }
            return translated + identifier
        }
        return unknownRouteWarning
    }

    static func time(_ date: Date, timeZone: TimeZone = .current, includesSeconds: Bool = false) -> String {
        let formatter = makeFormatter(timeZone: timeZone)
        formatter.dateFormat = includesSeconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = makeFormatter(timeZone: timeZone)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func makeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        return formatter
    }
}

extension Date {
    var italianTime: String { ItalianPresentation.time(self) }
    var italianTimeWithSeconds: String { ItalianPresentation.time(self, includesSeconds: true) }
    var italianDateTime: String { ItalianPresentation.dateTime(self) }
}

