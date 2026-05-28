import Foundation
import Testing

@testable import SyncSqlCipher

// MARK: - Shared test helpers

func tempDBPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("syncsqlcipher-test-\(UUID().uuidString).db")
        .path
}
