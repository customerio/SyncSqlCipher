// MARK: - Database: QueryBuilder overloads
//
// Overloads for ``BuiltQuery``, ``Select``, ``Insert``, ``Update``,
// and DDL builders (``CreateTable``, ``AlterTable``, etc.).

extension Database {

    // MARK: - BuiltQuery

    /// Executes a pre-built query that produces no result rows.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ query: BuiltQuery) throws -> Int {
        try withConnection { try $0.execute(query) }
    }

    /// Executes a pre-built query and returns all matching rows.
    public func query(_ query: BuiltQuery) throws -> [Row] {
        try withConnection { try $0.query(query) }
    }

    /// Executes a pre-built query and returns the first column of the first row.
    public func scalarQuery<T: SQLConvertible>(
        _ query: BuiltQuery,
        as type: T.Type = T.self
    ) throws -> T? {
        try withConnection { try $0.scalarQuery(query, as: T.self) }
    }

    // MARK: - Select: execute

    /// Builds and executes a ``Select`` with variadic ``ParamBinding`` values.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ select: Select, _ params: ParamBinding...) throws -> Int {
        let q = select.build(params: params)
        return try withConnection { try $0.execute(q) }
    }

    /// Builds and executes a ``Select`` with a bindings dictionary.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ select: Select, params: [String: any SQLConvertible]) throws -> Int {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0.execute(q) }
    }

    // MARK: - Select: query

    /// Builds and queries a ``Select`` with variadic ``ParamBinding`` values.
    public func query(_ select: Select, _ params: ParamBinding...) throws -> [Row] {
        let q = select.build(params: params)
        return try withConnection { try $0.query(q) }
    }

    /// Builds and queries a ``Select`` with a bindings dictionary.
    public func query(_ select: Select, params: [String: any SQLConvertible]) throws -> [Row] {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0.query(q) }
    }

    // MARK: - Select: scalarQuery

    /// Builds a ``Select`` query and returns its first column as `T`.
    public func scalarQuery<T: SQLConvertible>(
        _ select: Select,
        _ params: ParamBinding...,
        as type: T.Type = T.self
    ) throws -> T? {
        let q = select.build(params: params)
        return try withConnection { try $0.scalarQuery(q, as: T.self) }
    }

    /// Builds a ``Select`` query (dict params) and returns its first column as `T`.
    public func scalarQuery<T: SQLConvertible>(
        _ select: Select,
        params: [String: any SQLConvertible],
        as type: T.Type = T.self
    ) throws -> T? {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0.scalarQuery(q, as: T.self) }
    }

    // MARK: - Insert

    /// Builds and executes an ``Insert`` with variadic ``ParamBinding`` values.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ insert: Insert, _ params: ParamBinding...) throws -> Int {
        try withConnection { try $0.execute(insert.build(params: params)) }
    }

    // MARK: - Update

    /// Builds and executes an ``Update`` with variadic ``ParamBinding`` values.
    ///
    /// - Returns: The number of rows affected by the statement.
    @discardableResult
    public func execute(_ update: Update, _ params: ParamBinding...) throws -> Int {
        try withConnection { try $0.execute(update.build(params: params)) }
    }

    // MARK: - DDL

    /// Builds and executes a ``CreateTable`` statement.
    @discardableResult
    public func execute(_ create: CreateTable) throws -> Int {
        try withConnection { try $0.execute(create.build()) }
    }

    /// Builds and executes an ``AlterTable`` statement.
    @discardableResult
    public func execute(_ alter: AlterTable) throws -> Int {
        try withConnection { try $0.execute(alter.build()) }
    }

    /// Builds and executes a ``DropTable`` statement.
    @discardableResult
    public func execute(_ drop: DropTable) throws -> Int {
        try withConnection { try $0.execute(drop.build()) }
    }

    /// Builds and executes a ``CreateIndex`` statement.
    @discardableResult
    public func execute(_ create: CreateIndex) throws -> Int {
        try withConnection { try $0.execute(create.build()) }
    }

    /// Builds and executes a ``DropIndex`` statement.
    @discardableResult
    public func execute(_ drop: DropIndex) throws -> Int {
        try withConnection { try $0.execute(drop.build()) }
    }
}
