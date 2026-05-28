import Foundation
import Testing

@testable import SyncSqlCipher

@Suite("Database Lifecycle")
struct DatabaseLifecycleTests {

    @Test("Opens and closes a new encrypted database")
    func opensNewDatabase() throws {
        let path = tempDBPath()
        let db = try Database(path: path, key: "testkey")
        try db.execute("SELECT 1")
    }

    @Test("Enables WAL mode by default")
    func walModeDefault() throws {
        let db = try Database(path: tempDBPath(), key: "testkey")
        let mode = try db.scalarQuery("PRAGMA journal_mode", as: String.self)
        #expect(mode == "wal")
    }

    @Test("Respects walMode: false")
    func walModeDisabled() throws {
        let db = try Database(path: tempDBPath(), key: "testkey", walMode: false)
        let mode = try db.scalarQuery("PRAGMA journal_mode", as: String.self)
        #expect(mode == "delete")
    }

    @Test("Rejects the wrong key for an existing database")
    func rejectsWrongKey() throws {
        let path = tempDBPath()

        // Create a database with a known key, then let the connection close.
        do {
            let db = try Database(path: path, key: "correct-key")
            try db.execute("CREATE TABLE t (x INTEGER)")
        }  // `db` deallocates here → sqlite3_close_v2 is called

        // Attempting to open the same file with the wrong key should throw
        // once the eager validation query fires.
        #expect(throws: SqlCipherError.self) {
            _ = try Database(path: path, key: "wrong-key")
        }
    }
}
