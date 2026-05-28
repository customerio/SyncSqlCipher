import Foundation
import Testing

@testable import SyncSqlCipher

@Suite("withConnection / Transactions")
struct TransactionTests {

    @Test("Runs a multi-statement transaction")
    func transaction() throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try db.execute("CREATE TABLE ledger (amount REAL NOT NULL)")

        let total: Double? = try db.withConnection { conn in
            try conn.execute("BEGIN")
            try conn.execute("INSERT INTO ledger VALUES (?)", 100.0)
            try conn.execute("INSERT INTO ledger VALUES (?)", 50.0)
            try conn.execute("COMMIT")
            return try conn.scalarQuery("SELECT SUM(amount) FROM ledger", as: Double.self)
        }

        #expect(total == 150.0)
    }

    @Test("Rolls back incomplete transaction on error")
    func rollback() throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try db.execute("CREATE TABLE t (v INTEGER NOT NULL)")

        do {
            try db.withConnection { conn in
                try conn.execute("BEGIN")
                try conn.execute("INSERT INTO t VALUES (?)", 1)
                // Force an error by violating NOT NULL
                try conn.execute("INSERT INTO t VALUES (?)", Value.null)
            }
            Issue.record("Expected an error from NOT NULL constraint")
        } catch {
            // Roll back manually (real usage would handle this in the error path)
            try db.execute("ROLLBACK")
        }

        let count = try db.scalarQuery("SELECT COUNT(*) FROM t", as: Int.self)
        #expect(count == 0)
    }

    @Test("Stored connection is expired after withConnection returns")
    func connectionExpiredAfterBlock() throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try db.execute("CREATE TABLE t (v INTEGER)")

        var escapedConn: Connection?
        try db.withConnection { conn in
            escapedConn = conn
        }

        let conn = try #require(escapedConn)
        #expect(conn.isExpired)
        #expect(throws: SqlCipherError.self) {
            try conn.execute("SELECT 1")
        }
    }
}
