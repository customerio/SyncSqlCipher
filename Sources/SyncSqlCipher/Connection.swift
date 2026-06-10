internal import CSqlCipher
import Foundation

// MARK: - StatementCache

/// An LRU cache of compiled SQLite prepared statements, keyed by SQL text.
///
/// Cached statements are reset and have their bindings cleared before each
/// reuse, so they are always in a clean state when handed out.
///
/// Statements that are not safe to cache are excluded:
/// - `CREATE` / `ALTER` / `DROP` — DDL that modifies the schema
/// - `PRAGMA` — configuration commands whose results are not repeatable
///
/// On a schema change (`SQLITE_SCHEMA`) callers should call ``evict(_:)`` so
/// the stale compiled plan is discarded and the next prepare is fresh.
final class StatementCache {

    // MARK: - Configuration

    static let defaultCapacity = 64

    // MARK: - Storage

    private let db: OpaquePointer
    private let capacity: Int
    private var cache: [String: OpaquePointer] = [:]
    private var order: [String] = []

    // MARK: - Init / deinit

    init(db: OpaquePointer, capacity: Int = StatementCache.defaultCapacity) {
        self.db = db
        self.capacity = capacity
        cache.reserveCapacity(capacity)
        order.reserveCapacity(capacity)
    }

    deinit {
        for handle in cache.values { sqlite3_finalize(handle) }
    }

    // MARK: - Public interface

    /// Returns a reset, binding-cleared prepared statement from the cache, or
    /// `nil` when `sql` is not cacheable (DDL / PRAGMA).
    ///
    /// - Throws: ``SqlCipherError/prepareFailed(sql:message:)`` if a new
    ///   statement cannot be compiled.
    func cachedStatement(for sql: String) throws -> OpaquePointer? {
        guard isCacheable(sql) else { return nil }

        if let existing = cache[sql] {
            touch(sql)
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return existing
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw SqlCipherError.prepareFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        insert(sql, handle: s)
        return s
    }

    /// Removes and finalizes the cached statement for `sql`, if present.
    ///
    /// Call this when `sqlite3_step` returns `SQLITE_SCHEMA` so the next
    /// prepare compiles a fresh plan against the updated schema.
    func evict(_ sql: String) {
        guard let handle = cache.removeValue(forKey: sql) else { return }
        order.removeAll { $0 == sql }
        sqlite3_finalize(handle)
    }

    // MARK: - Private

    private func touch(_ sql: String) {
        order.removeAll { $0 == sql }
        order.append(sql)
    }

    private func insert(_ sql: String, handle: OpaquePointer) {
        if cache.count >= capacity, let lru = order.first {
            if let evicted = cache.removeValue(forKey: lru) { sqlite3_finalize(evicted) }
            order.removeFirst()
        }
        cache[sql] = handle
        order.append(sql)
    }

    private func isCacheable(_ sql: String) -> Bool {
        let prefix = sql.drop(while: \.isWhitespace).prefix(7).uppercased()
        return !prefix.hasPrefix("PRAGMA")
            && !prefix.hasPrefix("CREATE")
            && !prefix.hasPrefix("ALTER")
            && !prefix.hasPrefix("DROP")
    }
}

// MARK: - StatementHandle

private enum StatementHandle {
    case cached(OpaquePointer)
    case owned(OpaquePointer)

    var pointer: OpaquePointer {
        switch self {
        case .cached(let p), .owned(let p): return p
        }
    }

    var isCached: Bool {
        if case .cached = self { return true }
        return false
    }

    func done() {
        switch self {
        case .owned(let p): sqlite3_finalize(p)
        case .cached(let p):
            sqlite3_reset(p)
            sqlite3_clear_bindings(p)
        }
    }

    static func prepare(sql: String, db: OpaquePointer, cache: StatementCache) throws
        -> StatementHandle {
        if let p = try cache.cachedStatement(for: sql) { return .cached(p) }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw SqlCipherError.prepareFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        return .owned(s)
    }
}

// MARK: - Connection

/// A synchronous view of an open database, scoped to a ``Database/withConnection(_:)`` call.
///
/// `Connection` is always obtained through ``Database/withConnection(_:)`` and
/// is expired immediately after that closure returns.  Any attempt to call
/// methods on a stored `Connection` after its scope ends throws
/// ``SqlCipherError/connectionExpired``.
///
/// All methods execute synchronously; the surrounding ``Database`` serialises
/// access via a private dispatch queue.
public final class Connection {

    // MARK: - Storage

    /// The raw `sqlite3 *` handle, owned by the surrounding ``Database``.
    let db: OpaquePointer
    /// Shared statement cache, owned by the surrounding ``Database``.
    let cache: StatementCache

    /// `true` once the enclosing ``Database/withConnection(_:)`` call has returned.
    ///
    /// Set by ``Database`` immediately after the closure exits.  All public
    /// methods check this flag and throw ``SqlCipherError/connectionExpired``
    /// if it is `true`, preventing use-after-scope bugs.
    public internal(set) var isExpired: Bool = false

    init(db: OpaquePointer, cache: StatementCache) {
        self.db = db
        self.cache = cache
    }

    // MARK: - Execute (write / DDL)

    /// Executes an SQL statement that produces no result rows (INSERT, UPDATE,
    /// DELETE, CREATE, …).
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ sql: String, _ bindings: any SQLConvertible...) throws -> Int {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        return try execute(sql, bindings: bindings)
    }

    // MARK: - Query (read)

    /// Executes a SELECT and returns all matching rows.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: An array containing one ``Row`` per result row (empty if no
    ///            rows matched).
    public func query(_ sql: String, _ bindings: any SQLConvertible...) throws -> [Row] {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        return try query(sql, bindings: bindings)
    }

    // MARK: - Scalar query

    /// Executes a SELECT and returns the first column of the first result row
    /// converted to `T`.
    ///
    /// Returns `nil` when the result set is empty or the column holds `NULL`.
    ///
    /// - Parameters:
    ///   - sql:      A SELECT that returns at least one column.
    ///   - bindings: Values to bind to each `?` in order.
    ///   - type:     The Swift type to decode the first column into.
    public func scalarQuery<T: SQLConvertible>(
        _ sql: String,
        _ bindings: any SQLConvertible...,
        as type: T.Type = T.self
    ) throws -> T? {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        return try scalarQuery(sql, bindings: bindings, as: T.self)
    }

    // MARK: - Array-binding overloads

    /// Executes an SQL statement using a pre-collected bindings array.
    ///
    /// Identical to ``execute(_:_:...)`` but accepts `[any SQLConvertible]`
    /// instead of a variadic list — used internally where bindings are already
    /// collected into an array.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    func execute(_ sql: String, bindings: [any SQLConvertible]) throws -> Int {
        let stmt = try StatementHandle.prepare(sql: sql, db: db, cache: cache)
        defer { stmt.done() }
        try bind(stmt.pointer, bindings)
        let rc = sqlite3_step(stmt.pointer)
        if rc == SQLITE_SCHEMA, stmt.isCached {
            cache.evict(sql)
        }
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SqlCipherError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    /// Executes a SELECT using a pre-collected bindings array, returning all rows.
    ///
    /// Identical to ``query(_:_:...)`` but accepts `[any SQLConvertible]`
    /// instead of a variadic list — used internally where bindings are already
    /// collected into an array.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: An array containing one ``Row`` per result row (empty if no rows matched).
    func query(_ sql: String, bindings: [any SQLConvertible]) throws -> [Row] {
        let stmt = try StatementHandle.prepare(sql: sql, db: db, cache: cache)
        defer { stmt.done() }
        try bind(stmt.pointer, bindings)
        return try collectRows(stmt.pointer, sql: sql)
    }

    /// Executes a scalar SELECT using a pre-collected bindings array.
    ///
    /// Identical to ``scalarQuery(_:_:...:as:)`` but accepts `[any SQLConvertible]`
    /// instead of a variadic list — used internally where bindings are already
    /// collected into an array.
    ///
    /// - Parameters:
    ///   - sql:      A SELECT that returns at least one column.
    ///   - bindings: Values to bind to each `?` in order.
    ///   - type:     The Swift type to decode the first column into.
    func scalarQuery<T: SQLConvertible>(
        _ sql: String,
        bindings: [any SQLConvertible],
        as type: T.Type = T.self
    ) throws -> T? {
        let stmt = try StatementHandle.prepare(sql: sql, db: db, cache: cache)
        defer { stmt.done() }
        try bind(stmt.pointer, bindings)
        let rc = sqlite3_step(stmt.pointer)
        if rc == SQLITE_SCHEMA, stmt.isCached { cache.evict(sql) }
        if rc != SQLITE_ROW && rc != SQLITE_DONE {
            throw SqlCipherError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        guard rc == SQLITE_ROW else { return nil }
        return T.from(sqlValue: readValue(stmt.pointer, column: 0))
    }
}

// MARK: - BuiltQuery overloads

extension Connection {

    // MARK: Execute

    /// Executes a pre-built query that produces no result rows.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ query: BuiltQuery) throws -> Int {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        let stmt = try StatementHandle.prepare(sql: query.sql, db: db, cache: cache)
        defer { stmt.done() }
        try bindNamed(stmt.pointer, query.bindings)
        let rc = sqlite3_step(stmt.pointer)
        if rc == SQLITE_SCHEMA, stmt.isCached { cache.evict(query.sql) }
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SqlCipherError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: Query

    /// Executes a pre-built query and returns all matching rows.
    public func query(_ query: BuiltQuery) throws -> [Row] {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        let stmt = try StatementHandle.prepare(sql: query.sql, db: db, cache: cache)
        defer { stmt.done() }
        try bindNamed(stmt.pointer, query.bindings)
        return try collectRows(stmt.pointer, sql: query.sql)
    }

    // MARK: Scalar

    /// Executes a pre-built query and returns the first column of the first row.
    public func scalarQuery<T: SQLConvertible>(_ query: BuiltQuery, as type: T.Type = T.self) throws
        -> T? {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        let stmt = try StatementHandle.prepare(sql: query.sql, db: db, cache: cache)
        defer { stmt.done() }
        try bindNamed(stmt.pointer, query.bindings)
        let rc = sqlite3_step(stmt.pointer)
        if rc == SQLITE_SCHEMA, stmt.isCached { cache.evict(query.sql) }
        if rc != SQLITE_ROW && rc != SQLITE_DONE {
            throw SqlCipherError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        guard rc == SQLITE_ROW else { return nil }
        return T.from(sqlValue: readValue(stmt.pointer, column: 0))
    }
}

// MARK: - DDL / DML convenience overloads

extension Connection {

    // MARK: Insert

    /// Builds and executes an ``Insert`` statement with variadic ``ParamBinding`` values.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ insert: Insert, _ params: ParamBinding...) throws -> Int {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        return try execute(insert.build(params: params))
    }

    // MARK: Update

    /// Builds and executes an ``Update`` statement with variadic ``ParamBinding`` values.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ update: Update, _ params: ParamBinding...) throws -> Int {
        guard !isExpired else { throw SqlCipherError.connectionExpired }
        return try execute(update.build(params: params))
    }
}

// MARK: - Private helpers

extension Connection {
    private func bind(_ stmt: OpaquePointer, _ values: [any SQLConvertible]) throws {
        for (i, val) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch val.sqlValue {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .integer(let n):
                rc = sqlite3_bind_int64(stmt, idx, n)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_SHIM)
            case .blob(let d):
                rc = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(
                        stmt, idx, ptr.baseAddress, Int32(ptr.count), SQLITE_TRANSIENT_SHIM)
                }
            }
            guard rc == SQLITE_OK else {
                throw SqlCipherError.bindFailed(index: idx, code: rc)
            }
        }
    }

    func bindNamed(_ stmt: OpaquePointer, _ values: [String: any SQLConvertible]) throws {
        for (name, val) in values {
            let idx = sqlite3_bind_parameter_index(stmt, ":\(name)")
            guard idx != 0 else { continue }
            let rc: Int32
            switch val.sqlValue {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .integer(let n):
                rc = sqlite3_bind_int64(stmt, idx, n)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_SHIM)
            case .blob(let d):
                rc = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(
                        stmt, idx, ptr.baseAddress, Int32(ptr.count), SQLITE_TRANSIENT_SHIM)
                }
            }
            guard rc == SQLITE_OK else {
                throw SqlCipherError.bindFailed(index: idx, code: rc)
            }
        }
    }

    private func collectRows(_ stmt: OpaquePointer, sql: String) throws -> [Row] {
        let colCount = Int(sqlite3_column_count(stmt))
        var columnIndex: [String: Int] = [:]
        for i in 0..<colCount {
            if let name = sqlite3_column_name(stmt, Int32(i)) {
                columnIndex[String(cString: name)] = i
            }
        }

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let values = (0..<colCount).map { readValue(stmt, column: Int32($0)) }
                rows.append(Row(columnIndex: columnIndex, values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                if rc == SQLITE_SCHEMA { cache.evict(sql) }
                throw SqlCipherError.stepFailed(
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
        return rows
    }

    private func readValue(_ stmt: OpaquePointer, column: Int32) -> Value {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, column))
        case SQLITE_TEXT:
            let ptr = sqlite3_column_text(stmt, column)!
            return .text(String(cString: ptr))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, column))
            if count == 0 { return .blob(Data()) }
            let ptr = sqlite3_column_blob(stmt, column)!
            return .blob(Data(bytes: ptr, count: count))
        default:
            return .null
        }
    }
}

// MARK: - SQLITE_TRANSIENT shim

private let SQLITE_TRANSIENT_SHIM = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
