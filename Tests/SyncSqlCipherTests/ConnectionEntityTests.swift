import Foundation
import Testing

@testable import SyncSqlCipher

// MARK: - Fixtures

private enum WidgetSchema {
    static let table = TableName("widgets")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column("id", .integer, .primaryKey)
            .column("name", .text, .notNull)
            .column("price", .real, .notNull)
    }
}

private enum NoteSchema {
    static let table = TableName("notes")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column("id", .integer, .autoIncrement)
            .column("title", .text, .notNull)
            .column("body", .text, .notNull)
    }
}

private enum CatalogSchema {
    static let table = TableName("catalogs")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column("id", .integer, .primaryKey)
            .column("name", .text, .notNull)
            .column("tags", .text, .notNull)  // JSON array
    }
}

private struct Widget: Entity, Equatable {
    typealias ID = Int
    static let tableName = WidgetSchema.table
    static let primaryKey: WritableKeyPath<Widget, Int> & Sendable = \.id
    var id: Int
    var name: String
    var price: Double
}

private struct Note: Entity, Equatable {
    typealias ID = Int?
    static let tableName = NoteSchema.table
    static let primaryKey: WritableKeyPath<Note, Int?> & Sendable = \.id
    var id: Int?
    var title: String
    var body: String
}

private struct Catalog: Entity, Equatable {
    typealias ID = Int
    static let tableName = CatalogSchema.table
    static let primaryKey: WritableKeyPath<Catalog, Int> & Sendable = \.id
    var id: Int
    var name: String
    var tags: [String]
}

private func makeDB() throws -> Database {
    try Database(path: tempDBPath(), key: "testkey")
}

// MARK: - Save

@Suite("Connection.save – caller-supplied PK")
struct ConnectionSaveCallerPKTests {

    @Test("save inserts a record")
    func insertsRecord() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        try db.withConnection { conn in
            try conn.save(Widget(id: 1, name: "Bolt", price: 0.99))
        }

        let rows = try db.query("SELECT name FROM widgets")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Bolt"))
    }

    @Test("save upserts an existing record")
    func upserts() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        try db.withConnection { conn in
            try conn.save(Widget(id: 1, name: "Bolt", price: 0.99))
            try conn.save(Widget(id: 1, name: "Bolt Pro", price: 1.49))
        }

        let rows = try db.query("SELECT name, price FROM widgets")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Bolt Pro"))
    }

    @Test("save returns record unchanged for non-autoincrement PK")
    func returnsUnchanged() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let w = Widget(id: 7, name: "Nut", price: 0.25)
        let saved = try db.withConnection { conn in
            try conn.save(w)
        }
        #expect(saved == w)
    }
}

@Suite("Connection.save – auto-increment PK")
struct ConnectionSaveAutoIncrementTests {

    @Test("save assigns rowid and returns it in the copy")
    func assignsRowid() throws {
        let db = try makeDB()
        try db.execute(NoteSchema.createTable())

        let note = try db.withConnection { conn in
            try conn.save(Note(id: nil, title: "Hello", body: "World"))
        }
        #expect(note.id == 1)
    }

    @Test("successive saves assign incrementing rowids")
    func incrementingRowids() throws {
        let db = try makeDB()
        try db.execute(NoteSchema.createTable())

        let (n1, n2) = try db.withConnection { conn -> (Note, Note) in
            let n1 = try conn.save(Note(id: nil, title: "A", body: ""))
            let n2 = try conn.save(Note(id: nil, title: "B", body: ""))
            return (n1, n2)
        }
        #expect(n1.id == 1)
        #expect(n2.id == 2)
    }
}

@Suite("Connection.save – batch")
struct ConnectionSaveBatchTests {

    @Test("batch save persists all records")
    func batchPersistsAll() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        try db.withConnection { conn in
            try conn.save([
                Widget(id: 1, name: "A", price: 1.0),
                Widget(id: 2, name: "B", price: 2.0),
                Widget(id: 3, name: "C", price: 3.0),
            ])
        }

        let count: Int? = try db.scalarQuery("SELECT COUNT(*) FROM widgets", as: Int.self)
        #expect(count == 3)
    }

    @Test("batch save rolls back all records on error")
    func rollsBackOnError() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.execute("CREATE UNIQUE INDEX widgets_name ON widgets (name)")

        #expect(throws: (any Error).self) {
            try db.withConnection { conn in
                try conn.save([
                    Widget(id: 1, name: "Clash", price: 1.0),
                    Widget(id: 2, name: "Clash", price: 2.0),
                ])
            }
        }

        let count: Int? = try db.scalarQuery("SELECT COUNT(*) FROM widgets", as: Int.self)
        #expect(count == 0)
    }
}

// MARK: - Fetch

@Suite("Connection.fetch – all rows")
struct ConnectionFetchAllTests {

    @Test("fetch returns all rows")
    func fetchAll() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.save([
            Widget(id: 1, name: "Bolt", price: 0.99),
            Widget(id: 2, name: "Nut", price: 0.49),
        ])

        let widgets = try db.withConnection { conn in
            try conn.fetch(Widget.self)
        }
        #expect(widgets.count == 2)
    }

    @Test("fetch returns empty array when table is empty")
    func fetchEmpty() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let widgets = try db.withConnection { conn -> [Widget] in
            try conn.fetch(Widget.self)
        }
        #expect(widgets.isEmpty)
    }
}

@Suite("Connection.fetch – WHERE predicate")
struct ConnectionFetchWhereTests {

    @Test("fetch with predicate filters rows")
    func filtersByPredicate() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.save([
            Widget(id: 1, name: "Cheap", price: 0.10),
            Widget(id: 2, name: "Mid", price: 0.99),
            Widget(id: 3, name: "Pricey", price: 9.99),
        ])

        let cheap = try db.withConnection { conn in
            try conn.fetch(Widget.self, where: col("price") < 1.0)
        }
        #expect(cheap.count == 2)
        #expect(cheap.allSatisfy { $0.price < 1.0 })
    }

    @Test("fetch with Param binding")
    func fetchWithParam() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.save([
            Widget(id: 1, name: "A", price: 1.0),
            Widget(id: 2, name: "B", price: 5.0),
        ])

        let minPrice = Param<Double>("minPrice")
        let results = try db.withConnection { conn in
            try conn.fetch(
                Widget.self,
                where: col("price") >= minPrice,
                params: [minPrice.set(4.0)]
            )
        }
        #expect(results.count == 1)
        #expect(results[0].name == "B")
    }
}

@Suite("Connection.fetchOne – by primary key")
struct ConnectionFetchOneTests {

    @Test("fetchOne returns the matching record")
    func found() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.save(Widget(id: 42, name: "Target", price: 3.14))

        let widget = try db.withConnection { conn in
            try conn.fetchOne(Widget.self, id: 42)
        }
        #expect(widget?.name == "Target")
    }

    @Test("fetchOne returns nil when id is absent")
    func notFound() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let widget = try db.withConnection { conn -> Widget? in
            try conn.fetchOne(Widget.self, id: 99)
        }
        #expect(widget == nil)
    }
}

// MARK: - Delete

@Suite("Connection.delete – by ID")
struct ConnectionDeleteByIDTests {

    @Test("delete(from:id:) returns true when row existed")
    func deletesExisting() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.save(Widget(id: 1, name: "Gone", price: 0.0))

        let removed = try db.withConnection { conn in
            try conn.delete(from: Widget.self, id: 1)
        }
        #expect(removed == true)
        let count: Int? = try db.scalarQuery("SELECT COUNT(*) FROM widgets", as: Int.self)
        #expect(count == 0)
    }

    @Test("delete(from:id:) returns false when row is absent")
    func deleteMissing() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let removed = try db.withConnection { conn in
            try conn.delete(from: Widget.self, id: 99)
        }
        #expect(removed == false)
    }

    @Test("delete(from:ids:) returns count of deleted rows")
    func deletesByIDs() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        try db.save([
            Widget(id: 1, name: "A", price: 1.0),
            Widget(id: 2, name: "B", price: 2.0),
            Widget(id: 3, name: "C", price: 3.0),
        ])

        let count = try db.withConnection { conn in
            try conn.delete(from: Widget.self, ids: [1, 3])
        }
        #expect(count == 2)
        let remaining: Int? = try db.scalarQuery(
            "SELECT COUNT(*) FROM widgets", as: Int.self)
        #expect(remaining == 1)
    }

    @Test("delete(from:ids:) returns 0 for empty array without hitting DB")
    func deleteEmptyIDs() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let count = try db.withConnection { conn in
            try conn.delete(from: Widget.self, ids: [])
        }
        #expect(count == 0)
    }
}

@Suite("Connection.delete – by Entity")
struct ConnectionDeleteByEntityTests {

    @Test("delete(_ record:) removes the row")
    func deletesRecord() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        let w = Widget(id: 1, name: "Del", price: 0.0)
        try db.save(w)

        let removed = try db.withConnection { conn in
            try conn.delete(w)
        }
        #expect(removed == true)
    }

    @Test("delete(_ record:) returns false for unpersisted record with nil PK")
    func deleteUnpersisted() throws {
        let db = try makeDB()
        try db.execute(NoteSchema.createTable())

        let note = Note(id: nil, title: "Never saved", body: "")
        let removed = try db.withConnection { conn in
            try conn.delete(note)
        }
        #expect(removed == false)
    }

    @Test("delete(_ records:) removes matched rows and returns count")
    func deletesRecords() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())
        let widgets = [
            Widget(id: 1, name: "A", price: 1.0),
            Widget(id: 2, name: "B", price: 2.0),
        ]
        try db.save(widgets)

        let count = try db.withConnection { conn in
            try conn.delete(widgets)
        }
        #expect(count == 2)
    }
}

// MARK: - Multi-operation composition

@Suite("Connection – ORM composition in one withConnection")
struct ConnectionORMCompositionTests {

    @Test("save then fetch in same connection")
    func saveAndFetch() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let fetched = try db.withConnection { conn -> [Widget] in
            try conn.save(Widget(id: 1, name: "One", price: 1.0))
            try conn.save(Widget(id: 2, name: "Two", price: 2.0))
            return try conn.fetch(Widget.self)
        }
        #expect(fetched.count == 2)
    }

    @Test("save, delete, and fetch all in one connection")
    func saveDeleteFetch() throws {
        let db = try makeDB()
        try db.execute(WidgetSchema.createTable())

        let remaining = try db.withConnection { conn -> [Widget] in
            try conn.save(Widget(id: 1, name: "Keep", price: 1.0))
            try conn.save(Widget(id: 2, name: "Remove", price: 2.0))
            try conn.delete(from: Widget.self, id: 2)
            return try conn.fetch(Widget.self)
        }
        #expect(remaining.count == 1)
        #expect(remaining[0].name == "Keep")
    }

    @Test("auto-increment rowid is immediately available via fetchOne in same connection")
    func autoIncrementAndFetchOne() throws {
        let db = try makeDB()
        try db.execute(NoteSchema.createTable())

        let note = try db.withConnection { conn -> Note? in
            let saved = try conn.save(Note(id: nil, title: "Instant", body: ""))
            return try conn.fetchOne(Note.self, id: saved.id)
        }
        #expect(note?.title == "Instant")
    }
}

// MARK: - complexColumnStrategy

@Suite("Connection – complexColumnStrategy parameter")
struct ConnectionComplexColumnStrategyTests {

    @Test("default .json strategy round-trips array column")
    func jsonStrategyRoundTrips() throws {
        let db = try makeDB()
        try db.execute(CatalogSchema.createTable())

        let original = Catalog(id: 1, name: "Tech", tags: ["swift", "sql"])
        try db.withConnection { conn in
            try conn.save(original)
        }
        let fetched = try db.withConnection { conn in
            try conn.fetchOne(Catalog.self, id: 1)
        }
        #expect(fetched == original)
    }

    @Test("nil strategy throws when encoding complex column")
    func nilStrategyThrowsOnSave() throws {
        let db = try makeDB()
        try db.execute(CatalogSchema.createTable())

        #expect(throws: (any Error).self) {
            try db.withConnection { conn in
                try conn.save(
                    Catalog(id: 1, name: "Fail", tags: ["a"]),
                    complexColumnStrategy: nil
                )
            }
        }
    }
}
