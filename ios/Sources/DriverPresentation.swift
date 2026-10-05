import Foundation

/// Driver-only summaries. Server values and dispatcher diagnostics stay unchanged.
enum DriverPresentation {
    static let shiftConsent = "La centrale vede la tua posizione durante il turno, anche a schermo bloccato. iOS mostra l’indicatore. Puoi fermarla quando vuoi."

    static func nextStopTitle(_ stop: RouteStop, delivery: Delivery) -> String {
        let name = delivery.shopName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some saved shops use the street address as their name. Do not repeat it twice.
        let repeatsAddress = stop.address.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || stop.address.range(of: name + ",", options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        return name.isEmpty || repeatsAddress ? stop.title : "\(stop.title) · \(name)"
    }

    static func readiness(_ delivery: Delivery) -> String {
        switch delivery.readinessState {
        case .unknown: return "Disponibilità da confermare"
        case .estimated: return "Pronta alle \(delivery.readyAt.epochDate.italianTime) · stima"
        case .ready: return "Pronta dalle \(delivery.readyAt.epochDate.italianTime)"
        }
    }

    static func timing(_ stop: RouteStop, delivery: Delivery, route: DriverRoute) -> String? {
        var parts: [String] = []
        if route.estimatesAvailable { parts.append("Arrivo \(stop.arrivalAt.epochDate.italianTime)") }
        if stop.kind == .pickup, let target = delivery.pickupTargetAt {
            parts.append("ritiro entro \(target.epochDate.italianTime)")
        } else if stop.kind == .dropoff {
            let limit = min(delivery.deadlineAt, delivery.onboardDeadlineAt ?? delivery.deadlineAt)
            parts.append("consegna entro \(limit.epochDate.italianTime)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func travelSummary(_ route: DriverRoute) -> String? {
        guard route.estimatesAvailable else { return nil }
        let estimate = route.travelEstimate ?? .legacy
        if estimate.mode == "approximate_fallback" { return "Strade non disponibili: stime in linea d’aria, senza traffico" }
        if estimate.approximate { return "Stime in linea d’aria · senza traffico" }
        return "Tempi stradali stimati · senza traffico"
    }

    /// One visible warning per actionable issue; repeated UUID-specific warnings are details.
    static func alerts(_ route: DriverRoute) -> [String] {
        var messages: [String] = []
        func add(_ text: String) { if !messages.contains(text) { messages.append(text) } }
        if !route.estimatesAvailable { add(route.unavailableEstimateMessage) }
        for warning in route.warnings {
            switch warning {
            case "Driver location is unavailable":
                if route.estimatesAvailable { add("Posizione non disponibile: verifica gli orari") }
            case "Driver location is older than 5 minutes; estimates may be inaccurate":
                add("GPS oltre 5 minuti: stime imprecise")
            case "Driver is not on shift": add("Fuori turno: avvia il turno per proseguire")
            case "Onboard load exceeds capacity": add("Carico da verificare con la centrale")
            default:
                if warning.hasPrefix("Destination location unavailable for ") {
                    add("Indirizzo da aggiornare: contatta la centrale")
                } else if warning.hasPrefix("Percorso stradale non raggiungibile per ") {
                    add("Percorso da verificare con la centrale")
                } else if warning.hasPrefix("Deadline missed for ") {
                    add("Consegna in ritardo: avvisa la centrale")
                } else if warning.hasPrefix("Maximum ride time exceeded for ") || warning.hasPrefix("Onboard delivery delay exceeded for ") {
                    add("Tempo di trasporto superato: avvisa la centrale")
                } else if warning.hasPrefix("Readiness is unknown for ") {
                    add("Disponibilità da verificare con la centrale")
                } else if warning.hasPrefix("Capacity exceeded at pickup ") {
                    add("Carico da verificare con la centrale")
                } else {
                    add("Percorso da verificare con la centrale")
                }
            }
        }
        for notice in route.notices {
            add(notice.hasPrefix("Pickup target missed for ")
                ? "Ritiro oltre obiettivo: avvisa la centrale"
                : "Orario di ritiro da verificare con la centrale")
        }
        if !route.feasible, messages.isEmpty { add("Percorso da verificare con la centrale") }
        return messages
    }
}
