import Foundation

// MARK: - Connection: Entity persistence

extension Connection {

    // MARK: - Save

    /// Saves a single `Entity` to the database and returns the (possibly updated) record.
    ///
    /// The exact SQL depends on the primary key value at the time of the call:
    ///
    /// **Non-null PK — upsert in place:**
    /// ```sql
    /// INSERT INTO "tableName" ("col1", "col2", …)
    /// VALUES (?, ?, …)
    /// ON CONFLICT("pkCol") DO UPDATE SET
    ///     "col1" = excluded."col1",
    ///     "col2" = excluded."col2", …
    /// ```
    ///
    /// **Null PK (`Int?` auto-increment) — plain insert:**
    /// ```sql
    /// INSERT INTO "tableName" ("col1", "col2", …) VALUES (?, ?, …)
    /// ```
    /// After a successful insert the assigned rowid is written back to the
    /// returned copy via the `WritableKeyPath`.
    ///
    /// - Parameters:
    ///   - record:                The record to save.
    ///   - complexColumnStrategy: How to encode properties that cannot be stored
    ///     as a scalar SQL value.  Defaults to ``ComplexColumnStrategy/json``.
    /// - Returns: A copy of `record` with its primary key set to the assigned
    ///   value (relevant only for auto-increment `Int?` PKs; otherwise
    ///   identical to the input).
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(
        _ record: T,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws -> T {
        let encoder = RowEncoder()
        encoder.complexColumnStrategy = complexColumnStrategy
        let columns = try encoder.encode(record)
        guard !columns.isEmpty else { throw EntityError.noColumnsToInsert }
        let pkName = T.primaryKeyName
        switch record[keyPath: T.primaryKey].sqlValue {
        case .null:
            return try insertAutoIncrement(record, columns: columns, pkName: pkName)
        default:
            return try upsert(record, columns: columns, pkName: pkName)
        }
    }

    /// Saves an array of `Entity` values inside a single transaction.
    ///
    /// All records are saved atomically: if any one fails the entire batch is
    /// rolled back.  The returned array has the same order as the input, with
    /// auto-increment primary keys filled in where applicable.
    ///
    /// - Parameters:
    ///   - records:               The records to save.
    ///   - complexColumnStrategy: How to encode properties that cannot be stored
    ///     as a scalar SQL value.  Defaults to ``ComplexColumnStrategy/json``.
    /// - Returns: A copy of `records` with primary keys updated as needed.
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(
        _ records: [T],
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws -> [T] {
        guard !records.isEmpty else { return [] }
        try execute("BEGIN")
        var results: [T] = []
        results.reserveCapacity(records.count)
        do {
            for record in records {
                results.append(try save(record, complexColumnStrategy: complexColumnStrategy))
            }
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
        return results
    }

    // MARK: - Fetch

    /// Fetches all rows from `T`'s table, decoded as `[T]`.
    ///
    /// - Parameters:
    ///   - type:                  The `Entity` type to fetch.  Can be inferred from context.
    ///   - complexColumnStrategy: How to decode properties stored as non-scalar SQL values.
    ///     Defaults to ``ComplexColumnStrategy/json``.
    public func fetch<T: Entity>(
        _ type: T.Type = T.self,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws -> [T] {
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        let rows = try query(Select(.all).from(T.tableName).build())
        return try decoder.decode(T.self, from: rows)
    }

    /// Fetches rows matching `predicate` from `T`'s table.
    ///
    /// - Parameters:
    ///   - type:                  The `Entity` type to fetch.
    ///   - predicate:             A WHERE ``Expression`` built with ``col(_:)`` and expression operators.
    ///   - params:                ``ParamBinding`` values for any ``Param`` references in `predicate`.
    ///   - complexColumnStrategy: How to decode properties stored as non-scalar SQL values.
    ///     Defaults to ``ComplexColumnStrategy/json``.
    public func fetch<T: Entity>(
        _ type: T.Type = T.self,
        where predicate: Expression,
        params: [ParamBinding] = [],
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws -> [T] {
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        let rows = try query(Select(.all).from(T.tableName).where(predicate).build(params: params))
        return try decoder.decode(T.self, from: rows)
    }

    /// Fetches the single row whose primary key equals `id`, or `nil` if absent.
    ///
    /// - Parameters:
    ///   - type:                  The `Entity` type to fetch.  Can be inferred from context.
    ///   - id:                    The primary key value to look up.
    ///   - complexColumnStrategy: How to decode properties stored as non-scalar SQL values.
    ///     Defaults to ``ComplexColumnStrategy/json``.
    public func fetchOne<T: Entity>(
        _ type: T.Type = T.self,
        id: T.ID,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws -> T? {
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        let predicate = Expression.compare(ColumnRef(T.primaryKeyName), .eq, .literal(id))
        let rows = try query(Select(.all).from(T.tableName).where(predicate).limit(1).build())
        return try decoder.decode(T.self, from: rows).first
    }

    // MARK: - Delete

    /// Deletes the row whose primary key equals `id` from `T`'s table.
    ///
    /// - Parameters:
    ///   - type: The `Entity` type to delete from.  Can be inferred from context.
    ///   - id:   The primary key value of the row to remove.
    /// - Returns: `true` if a row was deleted, `false` if no row matched.
    @discardableResult
    public func delete<T: Entity>(from type: T.Type = T.self, id: T.ID) throws -> Bool {
        let sql = "DELETE FROM \"\(T.tableName.name)\" WHERE \"\(T.primaryKeyName)\" = ?"
        return try execute(sql, bindings: [id as any SQLConvertible]) > 0
    }

    /// Deletes all rows whose primary key is in `ids` from `T`'s table.
    ///
    /// - Parameters:
    ///   - type: The `Entity` type to delete from.  Can be inferred from context.
    ///   - ids:  The primary key values to remove.
    /// - Returns: The number of rows actually deleted.
    @discardableResult
    public func delete<T: Entity>(from type: T.Type = T.self, ids: [T.ID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql =
            "DELETE FROM \"\(T.tableName.name)\" WHERE \"\(T.primaryKeyName)\" IN (\(placeholders))"
        return try execute(sql, bindings: ids.map { $0 as any SQLConvertible })
    }

    /// Deletes the row corresponding to `record` from its table.
    ///
    /// Returns `false` without touching the database if `record`'s primary key
    /// is `nil` (i.e. the record was never persisted).
    ///
    /// - Parameter record: The entity whose row should be removed.
    /// - Returns: `true` if a row was deleted, `false` if no row matched or the record was unpersisted.
    @discardableResult
    public func delete<T: Entity>(_ record: T) throws -> Bool {
        let id = record[keyPath: T.primaryKey]
        guard id.sqlValue != .null else { return false }
        return try delete(from: T.self, id: id)
    }

    /// Deletes all rows corresponding to `records` from their table.
    ///
    /// Records with a `nil` primary key are skipped.  All deletes are issued
    /// in a single `IN` statement.
    ///
    /// - Parameter records: The entities whose rows should be removed.
    /// - Returns: The number of rows actually deleted.
    @discardableResult
    public func delete<T: Entity>(_ records: [T]) throws -> Int {
        let ids: [T.ID] = records.compactMap { record -> T.ID? in
            let id = record[keyPath: T.primaryKey]
            return id.sqlValue == .null ? nil : id
        }
        return try delete(from: T.self, ids: ids)
    }

    // MARK: - Private core

    private func insertAutoIncrement<T: Entity>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let insertCols = columns.filter { $0.key != pkName }
        guard !insertCols.isEmpty else { throw EntityError.noColumnsToInsert }
        let colList = insertCols.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: insertCols.count).joined(separator: ", ")
        let sql = "INSERT INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        try execute(sql, bindings: insertCols.map { $0.value as any SQLConvertible })
        var copy = record
        if let rowid = try scalarQuery("SELECT last_insert_rowid()", bindings: [], as: Int64.self),
            let assigned = T.ID.from(sqlValue: .integer(rowid))
        {
            copy[keyPath: T.primaryKey] = assigned
        }
        return copy
    }

    private func upsert<T: Entity>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let updateCols = columns.filter { $0.key != pkName }
        let colList = columns.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let bindings = columns.map { $0.value as any SQLConvertible }
        let sql: String
        if updateCols.isEmpty {
            // Only a PK column — treat as idempotent insert.
            sql =
                "INSERT OR IGNORE INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        } else {
            let setClause =
                updateCols
                .map { "\"\($0.key)\" = excluded.\"\($0.key)\"" }
                .joined(separator: ",\n    ")
            sql = """
                INSERT INTO "\(T.tableName.name)" (\(colList))
                VALUES (\(placeholders))
                ON CONFLICT("\(pkName)") DO UPDATE SET
                    \(setClause)
                """
        }
        try execute(sql, bindings: bindings)
        return record
    }
}
