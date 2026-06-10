import Foundation

// MARK: - Database: Entity persistence

extension Database {

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
    /// - Parameter record: The record to save.
    /// - Returns: A copy of `record` with its primary key set to the assigned
    ///   value (relevant only for auto-increment `Int?` PKs; otherwise
    ///   identical to the input).
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(_ record: T) throws -> T {
        try withConnection { try $0.save(record, complexColumnStrategy: complexColumnStrategy) }
    }

    /// Saves an array of `Entity` values inside a single transaction.
    ///
    /// All records are saved atomically: if any one fails the entire batch is
    /// rolled back.  The returned array has the same order as the input, with
    /// auto-increment primary keys filled in where applicable.
    ///
    /// ```swift
    /// let saved = try db.save([alice, bob, carol])
    /// ```
    ///
    /// - Parameter records: The records to save.
    /// - Returns: A copy of `records` with primary keys updated as needed.
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(_ records: [T]) throws -> [T] {
        try withConnection { try $0.save(records, complexColumnStrategy: complexColumnStrategy) }
    }

    // MARK: - Fetch

    /// Fetches all rows from `T`'s table, decoded as `[T]`.
    ///
    /// ```swift
    /// let allWidgets = try db.fetch(Widget.self)
    /// ```
    ///
    /// - Parameter type: The `Entity` type to fetch.  Can be inferred from context.
    public func fetch<T: Entity>(_ type: T.Type = T.self) throws -> [T] {
        try withConnection { try $0.fetch(T.self, complexColumnStrategy: complexColumnStrategy) }
    }

    /// Fetches rows matching `predicate` from `T`'s table.
    ///
    /// Use ``col(_:)`` and the expression operators to build the predicate, and
    /// ``Param`` for values you want to supply at the call site rather than
    /// baking into the query template:
    ///
    /// ```swift
    /// // Literal values
    /// let cheap = try db.fetch(Widget.self, where: col("price") < 5.0)
    ///
    /// // Named param — same SQL template, different values
    /// let minPrice = Param<Double>("minPrice")
    /// let template = col("price") >= minPrice
    /// let expensive = try db.fetch(Widget.self, where: template, minPrice.set(100.0))
    /// ```
    ///
    /// - Parameters:
    ///   - type:      The `Entity` type to fetch.
    ///   - predicate: A WHERE ``Expression`` built with ``col(_:)`` and expression operators.
    ///   - params:    Variadic ``ParamBinding`` values for any ``Param`` references in `predicate`.
    public func fetch<T: Entity>(
        _ type: T.Type = T.self,
        where predicate: Expression,
        _ params: ParamBinding...
    ) throws -> [T] {
        try withConnection {
            try $0.fetch(
                T.self,
                where: predicate,
                params: params,
                complexColumnStrategy: complexColumnStrategy
            )
        }
    }

    /// Fetches the single row whose primary key equals `id`, or `nil` if absent.
    ///
    /// ```swift
    /// if let widget = try db.fetchOne(Widget.self, id: 42) {
    ///     print(widget.name)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - type: The `Entity` type to fetch.  Can be inferred from context.
    ///   - id:   The primary key value to look up.
    public func fetchOne<T: Entity>(_ type: T.Type = T.self, id: T.ID) throws -> T? {
        try withConnection {
            try $0.fetchOne(T.self, id: id, complexColumnStrategy: complexColumnStrategy)
        }
    }

    // MARK: - Delete

    /// Deletes the row whose primary key equals `id` from `T`'s table.
    ///
    /// ```swift
    /// let removed = try db.delete(from: Widget.self, id: 42)
    /// ```
    ///
    /// - Parameters:
    ///   - type: The `Entity` type to delete from.  Can be inferred from context.
    ///   - id:   The primary key value of the row to remove.
    /// - Returns: `true` if a row was deleted, `false` if no row matched.
    @discardableResult
    public func delete<T: Entity>(from type: T.Type = T.self, id: T.ID) throws -> Bool {
        try withConnection { try $0.delete(from: T.self, id: id) }
    }

    /// Deletes all rows whose primary key is in `ids` from `T`'s table.
    ///
    /// ```swift
    /// let count = try db.delete(from: Widget.self, ids: [1, 2, 3])
    /// ```
    ///
    /// - Parameters:
    ///   - type: The `Entity` type to delete from.  Can be inferred from context.
    ///   - ids:  The primary key values to remove.
    /// - Returns: The number of rows actually deleted.
    @discardableResult
    public func delete<T: Entity>(from type: T.Type = T.self, ids: [T.ID]) throws -> Int {
        try withConnection { try $0.delete(from: T.self, ids: ids) }
    }

    /// Deletes the row corresponding to `record` from its table.
    ///
    /// Returns `false` without touching the database if `record`'s primary key
    /// is `nil` (i.e. the record was never persisted).
    ///
    /// ```swift
    /// let removed = try db.delete(widget)
    /// ```
    ///
    /// - Parameter record: The entity whose row should be removed.
    /// - Returns: `true` if a row was deleted, `false` if no row matched or the record was unpersisted.
    @discardableResult
    public func delete<T: Entity>(_ record: T) throws -> Bool {
        try withConnection { try $0.delete(record) }
    }

    /// Deletes all rows corresponding to `records` from their table.
    ///
    /// Records with a `nil` primary key are skipped.  All deletes are issued
    /// in a single `IN` statement.
    ///
    /// ```swift
    /// let count = try db.delete([alice, bob, carol])
    /// ```
    ///
    /// - Parameter records: The entities whose rows should be removed.
    /// - Returns: The number of rows actually deleted.
    @discardableResult
    public func delete<T: Entity>(_ records: [T]) throws -> Int {
        try withConnection { try $0.delete(records) }
    }
}
