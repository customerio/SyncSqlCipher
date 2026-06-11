// MARK: - Delete

/// Builds a `DELETE FROM` statement with a mandatory WHERE predicate.
///
/// The `where:` parameter is required at construction time — it is a
/// compile-time error to create a `Delete` without a predicate, preventing
/// accidental full-table deletions.
///
/// ```swift
/// let widgets = TableName("widgets")
///
/// // Literal value
/// try db.execute(Delete(from: widgets, where: col("id") == 42))
///
/// // Named param — reusable template
/// let idParam = Param<Int>("id")
/// let del = Delete(from: widgets, where: col("id") == idParam)
/// try db.execute(del, idParam.set(1))
/// try db.execute(del, idParam.set(2))
/// ```
public struct Delete: Sendable {

    // MARK: - Storage

    private let table: TableName
    private let whereExpr: Expression

    // MARK: - Initialiser

    /// Creates a DELETE statement targeting `table`, filtering with `expr`.
    ///
    /// - Parameters:
    ///   - table: The table to delete from.
    ///   - expr:  A WHERE ``Expression`` — required to prevent accidental
    ///     full-table deletions.
    public init(from table: TableName, where expr: Expression) {
        self.table = table
        self.whereExpr = expr
    }

    // MARK: - Build

    /// Builds the statement, merging any caller-supplied ``ParamBinding`` values.
    public func build(params: ParamBinding...) -> BuiltQuery {
        build(params: params)
    }

    /// Array-based build (used internally and by ``Database``).
    public func build(params: [ParamBinding] = []) -> BuiltQuery {
        var ctx = RenderContext()
        let parts = [
            "DELETE FROM \(table.name)",
            "WHERE \(whereExpr.render(into: &ctx))",
        ]
        var bindings = ctx.bindings
        for pb in params { bindings[pb.name] = pb.value }
        return BuiltQuery(sql: parts.joined(separator: "\n"), bindings: bindings)
    }
}
