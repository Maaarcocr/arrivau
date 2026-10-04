import Foundation

/// A read-only server snapshot, never a client-selected account or delivery list.
struct AccountDeletionPreview: Decodable, Equatable {
    let deliveryCount: Int
    let activeDeliveryCount: Int
    let confirmation: String

    private enum CodingKeys: String, CodingKey { case deliveryCount, activeDeliveryCount, confirmation }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deliveryCount = try values.decode(Int.self, forKey: .deliveryCount)
        activeDeliveryCount = try values.decode(Int.self, forKey: .activeDeliveryCount)
        confirmation = try values.decode(String.self, forKey: .confirmation)
        guard deliveryCount >= 0, activeDeliveryCount >= 0, activeDeliveryCount <= deliveryCount,
              confirmation.utf8.count == 64,
              confirmation.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .confirmation, in: values, debugDescription: "Invalid deletion preview")
        }
    }

    var warning: String {
        "Eliminerai definitivamente l’account, le credenziali, le sessioni, la posizione e tutte le \(deliveryCount) consegne assegnate a te, inclusa la cronologia completata. Le consegne ancora attive da eliminare sono \(activeDeliveryCount). La squadra e i ristoranti condivisi resteranno. L’operazione non può essere annullata."
    }
}
