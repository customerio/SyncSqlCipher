# SyncSqlCipher

A synchronous, DispatchQueue-based [SQLCipher](https://www.zetetic.net/sqlcipher/) wrapper for Swift.

SyncSqlCipher gives you full-strength AES-256 encrypted SQLite with a plain synchronous API — no `async`/`await`, no actors, no structured concurrency required. All database work serialises on a private dispatch queue; nested calls (including from within migrations) are safe via reentrancy detection.

## Requirements

| Platform | Minimum version |
|----------|----------------|
| iOS      | 13.0           |
| macOS    | 10.15          |
| visionOS | 1.0 (SPM only) |

- Swift 5.10+
- Xcode 16+ (required for Swift Testing in the test suite)

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/customerio/SyncSqlCipher.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["SyncSqlCipher"]),
]
```

Or add it in Xcode via **File › Add Package Dependencies**.

### CocoaPods

```ruby
pod 'SyncSqlCipher', '~> 1.0'
```

The pod compiles CSqlCipher and the Swift layer into a single framework — no separate `CSqlCipher` pod or `SQLite3` system library is needed.

## Quick start

```swift
import SyncSqlCipher

// Open or create an encrypted database
let db = try Database(path: "/path/to/store.db", key: "my-passphrase")

// DDL
try db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

// Write
try db.execute("INSERT INTO users (name) VALUES (?)", "Alice")

// Read
let rows  = try db.query("SELECT * FROM users")
let count = try db.scalarQuery("SELECT COUNT(*) FROM users", as: Int.self)
```

## Transactions and multi-statement blocks

Use `withConnection` to group related statements. The `Connection` passed to the closure is expired immediately after the closure returns — using it afterwards throws `SqlCipherError.connectionExpired`.

```swift
let insertedID: Int64? = try db.withConnection { conn in
    try conn.execute("BEGIN")
    try conn.execute("INSERT INTO users (name) VALUES (?)", "Bob")
    let id = try conn.scalarQuery("SELECT last_insert_rowid()", as: Int64.self)
    try conn.execute("COMMIT")
    return id
}
```

## Migrations

Define migrations by conforming to the `Migration` protocol and call `db.migrate(_:)` once at startup. Each migration runs in its own transaction; already-applied migrations are skipped automatically.

```swift
struct CreateUsers: Migration {
    let id = "001_create_users"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            CreateTable("users") {
                ColumnDefinition("id",   .integer, primaryKey: true)
                ColumnDefinition("name", .text,    notNull: true)
            }
        )
    }
}

struct AddEmail: Migration {
    let id = "002_add_email"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(AlterTable("users").addColumn("email", .text))
    }
}

try db.migrate([CreateUsers(), AddEmail()])
```

## Entity persistence

Conform any `Codable` struct to `Entity` for one-line save and fetch:

```swift
struct User: Entity, Equatable {
    typealias ID = Int?
    static let tableName  = TableName("users")
    static let primaryKey: WritableKeyPath<User, Int?> & Sendable = \.id

    var id:    Int?
    var name:  String
    var email: String
}

// Insert — SQLite assigns the id; the returned copy has it filled in
var user = User(id: nil, name: "Alice", email: "alice@example.com")
user = try db.save(user)   // user.id is now Optional(1)

// Update
user.name = "Alicia"
try db.save(user)

// Fetch all
let users: [User] = try db.fetchAll(User.self)

// Fetch by primary key
let found: User? = try db.fetch(User.self, id: 1)
```

## Query builder

The `Select`, `Insert`, `Update`, and DDL builders provide a type-safe layer over raw SQL:

```swift
let table = TableName("users")
let nameCol = ColumnRef("name", in: table)

let query = Select(from: table)
    .where(nameCol.like("%Alice%"))
    .orderBy(nameCol)
    .limit(10)

let rows = try db.query(query)
```

## Codable decoding

Decode result rows directly into `Decodable` types:

```swift
struct UserRecord: Decodable {
    let id: Int
    let name: String
}

let users: [UserRecord] = try db.query(
    "SELECT id, name FROM users ORDER BY name",
    as: UserRecord.self
)
```

## Rekeying

Change the database encryption key at runtime:

```swift
try db.rekey("new-passphrase")
```

## Thread safety

`Database` is thread-safe. All public methods dispatch synchronously onto a private serial queue. Reentrancy is safe — nested calls on the same queue execute directly without deadlocking. `Connection` objects are not thread-safe and must not be used outside the `withConnection` closure.

## License

SyncSqlCipher is released under the [MIT License](LICENSE).

SQLCipher is Copyright © 2008-2012 Zetetic LLC and is released under a [BSD-style license](https://www.zetetic.net/sqlcipher/license/).
