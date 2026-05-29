@_implementationOnly import CSqlCipher
import Foundation

// MARK: - Database

/// A thread-safe, synchronous encrypted SQLite database.
///
/// `Database` is the primary entry point for SyncSqlCipher.  Obtain one by
/// supplying a file path and an encryption key:
///
/// ```swift
/// let db = try Database(path: "/path/to/store.db", key: "my-passphrase")
/// ```
///
/// ### Convenience methods (simple statements)
///
/// For straightforward, one-shot operations use the database's methods directly:
///
/// ```swift
/// try db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)")
/// try db.execute("INSERT INTO users VALUES (?, ?)", 1, "Alice")
///
/// let rows  = try db.query("SELECT * FROM users")
/// let count = try db.scalarQuery("SELECT COUNT(*) FROM users", as: Int.self)
/// ```
///
/// ### withConnection (multi-statement / transactions)
///
/// Group related statements into a single `withConnection` closure.  The
/// ``Connection`` object passed to the closure is expired immediately after
/// the closure returns — any attempt to use it afterwards throws
/// ``SqlCipherError/connectionExpired``.
///
/// ```swift
/// let insertedID: Int64? = try db.withConnection { conn in
///     try conn.execute("BEGIN")
///     try conn.execute("INSERT INTO users VALUES (NULL, ?)", "Bob")
///     let id = try conn.scalarQuery("SELECT last_insert_rowid()", as: Int64.self)
///     try conn.execute("COMMIT")
///     return id
/// }
/// ```
///
/// All statements execute synchronously on a private serial `DispatchQueue`,
/// forming a natural serialisation barrier.  Nested `withConnection` calls
/// (including from within migrations) are safe — reentrancy is detected and
/// the inner call executes directly on the already-held queue.
///
/// Convenience overloads are provided in focused extension files:
/// - Raw SQL: `Database+RawSQL.swift`
/// - QueryBuilder (`Select`, `Insert`, `Update`, `BuiltQuery`): `Database+QueryBuilder.swift`
/// - Codable decoding: `Database+Codable.swift`
/// - Migrations: `Database+Migrations.swift`
public final class Database: @unchecked Sendable {

    // MARK: - Storage

    private let handle: OpaquePointer
    private let statementCache: StatementCache
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<String>()
    private let queueID: String

    // MARK: - Entity configuration

    /// Strategy used to encode and decode complex Swift properties —
    /// arrays, dictionaries, and nested `Codable` structs — that cannot be
    /// stored as a single scalar SQL value.
    ///
    /// Defaults to ``ComplexColumnStrategy/json``, which stores them as UTF-8
    /// JSON text.  Pass `nil` at initialisation to make the encoder throw
    /// loudly when it encounters an unencodable property, which can help
    /// surface schema bugs early in development.
    public let complexColumnStrategy: ComplexColumnStrategy?

    // MARK: - Initialisation

    /// Opens or creates an encrypted database at `path`.
    ///
    /// - Parameters:
    ///   - path:                  Filesystem path for the database file.
    ///   - key:                   Passphrase passed through PBKDF2-HMAC-SHA512 (SqlCipher default).
    ///   - walMode:               When `true` (the default), sets `PRAGMA journal_mode=WAL`
    ///                            immediately after opening.
    ///   - complexColumnStrategy: How to encode and decode properties that cannot be stored
    ///                            as a scalar SQL value.  Defaults to ``ComplexColumnStrategy/json``.
    ///
    /// - Throws: ``SqlCipherError/openFailed(message:)`` when the file cannot
    ///   be opened, or ``SqlCipherError/keyFailed(code:)`` when the key is
    ///   rejected.
    public init(
        path: String,
        key: String,
        walMode: Bool = true,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws {
        self.complexColumnStrategy = complexColumnStrategy

        let uuid = UUID().uuidString
        self.queueID = uuid
        let q = DispatchQueue(label: "io.Customer.SyncSqlCipher.\(uuid)")
        self.queue = q
        q.setSpecific(key: queueKey, value: uuid)

        var db: OpaquePointer?
        let openRC = sqlite3_open(path, &db)
        guard openRC == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SqlCipherError.openFailed(message: msg)
        }

        let keyRC = sqlite3_key(opened, key, Int32(key.utf8.count))
        guard keyRC == SQLITE_OK else {
            sqlite3_close(opened)
            throw SqlCipherError.keyFailed(code: keyRC)
        }

        // Eagerly validate the key by reading the first database page.
        var validationStmt: OpaquePointer?
        let validationRC = sqlite3_prepare_v2(
            opened, "SELECT count(*) FROM sqlite_master", -1, &validationStmt, nil
        )
        if let s = validationStmt { sqlite3_finalize(s) }
        guard validationRC == SQLITE_OK else {
            sqlite3_close(opened)
            throw SqlCipherError.keyFailed(code: validationRC)
        }

        if walMode {
            var walStmt: OpaquePointer?
            if sqlite3_prepare_v2(opened, "PRAGMA journal_mode=WAL", -1, &walStmt, nil) == SQLITE_OK
            {
                sqlite3_step(walStmt)
            }
            if let s = walStmt { sqlite3_finalize(s) }
        }

        self.handle = opened
        self.statementCache = StatementCache(db: opened)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - withConnection

    /// Provides synchronous, scoped access to the raw database connection.
    ///
    /// The ``Connection`` passed to `body` is expired immediately after `body`
    /// returns.  Any attempt to call methods on it after that point throws
    /// ``SqlCipherError/connectionExpired``.
    ///
    /// - Parameter body: A closure that receives an active ``Connection``.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Any error thrown by `body`.
    @discardableResult
    public func withConnection<R>(_ body: (Connection) throws -> R) throws -> R {
        try onQueue {
            let conn = Connection(db: handle, cache: statementCache)
            defer { conn.isExpired = true }
            return try body(conn)
        }
    }

    // MARK: - Key management

    /// Re-encrypts the database with a new passphrase.
    ///
    /// - Parameter newKey: The replacement passphrase.
    /// - Throws: ``SqlCipherError/keyFailed(code:)`` if the rekey fails.
    public func rekey(_ newKey: String) throws {
        try onQueue {
            let rc = sqlite3_rekey(handle, newKey, Int32(newKey.utf8.count))
            guard rc == SQLITE_OK else {
                throw SqlCipherError.keyFailed(code: rc)
            }
        }
    }

    // MARK: - Private

    /// Executes `work` on the database queue, detecting and allowing reentrancy.
    ///
    /// If the calling thread is already on the database queue (e.g. a nested
    /// `withConnection` call from within a migration), `work` is executed
    /// directly to avoid a deadlock on the serial queue.
    func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            return try work()
        }
        return try queue.sync(execute: work)
    }
}
