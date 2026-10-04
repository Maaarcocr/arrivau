import Foundation

/// A bearer secret carried only in memory and in an explicitly shared link.
/// Match our canonical grammar rather than accepting ambiguous or extended URLs.
/// In particular, an invitation can never select the API endpoint for credentials.
struct InviteLink: Identifiable, Equatable {
    let token: String
    var id: String { token }
    var url: URL { URL(string: "arrivau://invite?token=\(token)")! }

    init?(input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "arrivau://invite?token="
        let candidate = value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        guard candidate.utf8.count == 64,
              candidate.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        token = candidate
    }
}

struct DriverInvite: Decodable, Identifiable {
    let id: String
    let token: String
    let expiresAt: Int
    let name: String
    let role: String
    let teamId: String
    let teamName: String
    var link: InviteLink? {
        guard let value = InviteLink(input: token), value.token == token else { return nil }
        return value
    }
}

enum InviteCredentials {
    static func validationError(username: String, password: String) -> String? {
        let bytes = Array(username.utf8)
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (97...122).contains($0) }
        guard (1...64).contains(bytes.count), let first = bytes.first, alphanumeric(first),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }) else {
            return "Scegli un nome utente di 1–64 caratteri: lettere minuscole, numeri, punti, trattini o underscore. Inizia con una lettera o un numero."
        }
        guard (12...1024).contains(password.utf8.count) else {
            return "Scegli una password più lunga (almeno 12 caratteri semplici) e non oltre 1024 byte."
        }
        return nil
    }

    static func nameValidationError(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 240,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return "Inserisci il nome del corriere, senza caratteri di controllo e non oltre 240 byte."
        }
        return nil
    }

    static let recoveryMessage = "L’account potrebbe essere già stato creato. Torna ad Accedi e usa lo stesso nome utente e la stessa password sullo stesso server. Se non riesci, chiedi aiuto al responsabile prima di usare un altro invito."
}

/// Invitations require explicit team identity even though older login servers remain compatible.
enum InviteTeamIdentity {
    static func isValid(id: String?, name: String?) -> Bool {
        guard let id, let name else { return false }
        let bytes = Array(id.utf8)
        let alphanumeric: (UInt8) -> Bool = {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
        guard (1...64).contains(bytes.count), let first = bytes.first, alphanumeric(first),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 240, name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return true
    }
}
