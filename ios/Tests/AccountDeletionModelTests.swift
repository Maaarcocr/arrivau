import XCTest
@testable import Arrivau

final class AccountDeletionModelTests: XCTestCase {
    func testOlderAndConfiguredAccountsNeverGainDeletionCapability() throws {
        let legacy = Data(#"{"id":"driver","name":"Test","role":"driver"}"#.utf8)
        XCTAssertFalse(try APIClient.decoder().decode(Principal.self, from: legacy).canDeleteAccount)
        XCTAssertFalse(Principal(id: "driver", name: "Test", role: "driver").canDeleteAccount)
        for field in ["false", "null"] {
            let data = Data("{\"id\":\"driver\",\"name\":\"Test\",\"role\":\"driver\",\"can_delete_account\":\(field)}".utf8)
            XCTAssertFalse(try APIClient.decoder().decode(Principal.self, from: data).canDeleteAccount)
        }
    }

    func testOnlyExplicitBooleanTrueGrantsDeletionCapability() throws {
        let data = Data(#"{"id":"driver","name":"Test","role":"driver","can_delete_account":true}"#.utf8)
        XCTAssertTrue(try APIClient.decoder().decode(Principal.self, from: data).canDeleteAccount)
        for field in ["1", "\"true\"", "[]", "{}"] {
            let invalid = Data("{\"id\":\"driver\",\"name\":\"Test\",\"role\":\"driver\",\"can_delete_account\":\(field)}".utf8)
            XCTAssertThrowsError(try APIClient.decoder().decode(Principal.self, from: invalid))
        }
    }

    func testPreviewMustContainValidCountsAndExactSnapshot() throws {
        let valid = ["delivery_count": 4, "active_delivery_count": 2, "confirmation": String(repeating: "a1", count: 32)] as [String: Any]
        let preview = try APIClient.decoder().decode(AccountDeletionPreview.self, from: JSONSerialization.data(withJSONObject: valid))
        XCTAssertEqual(preview.deliveryCount, 4)
        XCTAssertEqual(preview.activeDeliveryCount, 2)
        XCTAssertTrue(preview.warning.contains("cronologia completata"))
        XCTAssertTrue(preview.warning.contains("squadra e i ristoranti condivisi resteranno"))
        let invalid: [[String: Any]] = [
            ["delivery_count": -1, "active_delivery_count": 0],
            ["delivery_count": 1, "active_delivery_count": -1],
            ["delivery_count": 1, "active_delivery_count": 2],
            ["confirmation": ""], ["confirmation": String(repeating: "A", count: 64)],
            ["confirmation": String(repeating: "g", count: 64)], ["confirmation": String(repeating: "a", count: 63)]
        ]
        for overrides in invalid {
            let body = valid.merging(overrides) { _, replacement in replacement }
            XCTAssertThrowsError(try APIClient.decoder().decode(AccountDeletionPreview.self, from: JSONSerialization.data(withJSONObject: body)))
        }
        XCTAssertThrowsError(try APIClient.decoder().decode(AccountDeletionPreview.self, from: Data("{}".utf8)))
    }
}
