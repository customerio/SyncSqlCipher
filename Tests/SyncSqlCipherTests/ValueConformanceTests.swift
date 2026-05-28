import Foundation
import Testing

@testable import SyncSqlCipher

@Suite("SQLConvertible Conformances")
struct ValueConformanceTests {

    @Test("Bool round-trips")
    func boolRoundTrip() throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try db.execute("CREATE TABLE flags (active INTEGER)")
        try db.execute("INSERT INTO flags VALUES (?)", true)
        let v = try db.scalarQuery("SELECT active FROM flags", as: Bool.self)
        #expect(v == true)
    }

    @Test("Data round-trips")
    func dataRoundTrip() throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try db.execute("CREATE TABLE blobs (raw BLOB)")
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try db.execute("INSERT INTO blobs VALUES (?)", original)
        let result = try db.scalarQuery("SELECT raw FROM blobs", as: Data.self)
        #expect(result == original)
    }
}
