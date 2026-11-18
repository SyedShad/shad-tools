import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case image(Data) // PNG, including alpha
}

enum ClipboardKind: String, Codable, Sendable {
    case text, image
}

struct ClipboardEntry: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ClipboardKind
    let title: String
    let copiedAt: Date
    let byteCount: Int
    var thumbnail: Data? = nil
}

private struct ClipboardStoreError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Each operation gets its own SQLite connection. A transaction applies the pause
// check, deduplication, and both limits together, including across running editions.
final class ClipboardStore: Sendable {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shad Tools/Clipboard", isDirectory: true)
    static let maximumItemBytes = 16 * 1024 * 1024

    private let directory: URL
    private let maxEntries: Int
    private let maxBytes: Int
    private let maxItemBytes: Int

    init(directory: URL = ClipboardStore.defaultDirectory, maxEntries: Int = 200, maxBytes: Int = 100 * 1024 * 1024,
         maxItemBytes: Int = ClipboardStore.maximumItemBytes) {
        self.directory = directory
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.maxItemBytes = maxItemBytes
    }

    func entries(matching query: String = "") throws -> [ClipboardEntry] {
        // Only search text payloads. Image thumbnails and separate titles suffice for browsing.
        let searchable = query.isEmpty ? "NULL" : "CASE WHEN kind='text' THEN payload END"
        let sql = "SELECT id, kind, title, copied, bytes, thumbnail, " + searchable
            + " FROM entries ORDER BY copied DESC, rowid DESC"
        return try withDatabase { db in
            try statement(db, sql) { stmt in
                var entries: [ClipboardEntry] = []
                while try step(stmt) == SQLITE_ROW {
                    guard let kind = ClipboardKind(rawValue: string(stmt, 1)) else { continue }
                    let title = string(stmt, 2)
                    if !query.isEmpty, !title.localizedCaseInsensitiveContains(query),
                       !(kind == .text && string(stmt, 6).localizedCaseInsensitiveContains(query)) { continue }
                    entries.append(ClipboardEntry(id: string(stmt, 0), kind: kind, title: title,
                                                  copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                                  byteCount: Int(sqlite3_column_int64(stmt, 4)), thumbnail: data(stmt, 5)))
                }
                return entries
            }
        }
    }

    func content(for id: String) throws -> ClipboardContent? {
        try withDatabase { db in
            try statement(db, "SELECT kind, payload FROM entries WHERE id=?") { stmt in
                try bind(id, at: 1, to: stmt)
                guard try step(stmt) == SQLITE_ROW, let kind = ClipboardKind(rawValue: string(stmt, 0)) else { return nil }
                switch kind {
                case .text: return .text(string(stmt, 1))
                case .image: return data(stmt, 1).map(ClipboardContent.image)
                }
            }
        }
    }

    private struct Item {
        let id: String
        let kind: ClipboardKind
        let payload: Data
        let title: String
        let thumbnail: Data?
    }

    private func prepare(_ content: ClipboardContent) -> Item? {
        let kind: ClipboardKind
        let payload: Data
        let title: String
        let thumbnail: Data?
        let limit = min(maxItemBytes, maxBytes)
        guard maxEntries > 0 else { return nil }
        switch content {
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= limit else { return nil }
            kind = .text
            payload = Data(text.utf8)
            let preview = text.prefix(150).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            title = preview.isEmpty ? "Whitespace" : preview
            thumbnail = nil
        case .image(let png):
            guard !png.isEmpty, png.count <= limit, let preview = Self.thumbnail(png) else { return nil }
            kind = .image
            payload = png
            title = "Image"
            thumbnail = preview
        }
        let id = kind.rawValue + "." + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return Item(id: id, kind: kind, payload: payload, title: title, thumbnail: thumbnail)
    }

    @discardableResult
    func record(_ content: ClipboardContent, at date: Date = Date()) throws -> Bool {
        try record([content], token: nil, at: date)
    }

    @discardableResult
    func record(_ contents: [ClipboardContent], observing changeToken: String, at date: Date) throws -> Bool {
        try record(contents, token: changeToken, at: date)
    }

    private func record(_ contents: [ClipboardContent], token: String?, at date: Date) throws -> Bool {
        let items = contents.compactMap(prepare)
        guard !items.isEmpty else { return false }
        return try withDatabase { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                if let token, try !claim(token, in: db) {
                    try execute(db, "COMMIT")
                    return false
                }
                if try paused(db) {
                    try execute(db, "COMMIT")
                    return false
                }
                var changed = false
                for item in items.reversed() {
                    if try insert(item, in: db, at: date) { changed = true }
                }
                try statement(db, """
                    DELETE FROM entries WHERE id IN (
                        SELECT id FROM (
                            SELECT id, row_number() OVER recent AS position, sum(bytes) OVER recent AS total
                            FROM entries WINDOW recent AS (ORDER BY copied DESC, rowid DESC ROWS UNBOUNDED PRECEDING)
                        ) WHERE position > ? OR total > ?
                    )
                    """) { stmt in
                        try check(sqlite3_bind_int64(stmt, 1, Int64(maxEntries)))
                        try check(sqlite3_bind_int64(stmt, 2, Int64(maxBytes)))
                        try step(stmt)
                    }
                try execute(db, "COMMIT")
                return changed
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    // Two editions can observe the same pasteboard revision at different times.
    // Retain recent opaque generation tokens across deletions so a late observer
    // cannot restore an item the user just removed. The tokens contain no content.
    private func claim(_ token: String, in db: OpaquePointer) throws -> Bool {
        let fresh = try statement(db, "INSERT OR IGNORE INTO observations(token) VALUES(?)") { stmt in
            try bind(token, at: 1, to: stmt)
            try step(stmt)
            return sqlite3_changes(db) > 0
        }
        if fresh {
            try execute(db, """
                DELETE FROM observations WHERE rowid <= (
                    SELECT rowid FROM observations ORDER BY rowid DESC LIMIT 1 OFFSET 256
                )
                """)
        }
        return fresh
    }

    private func insert(_ item: Item, in db: OpaquePointer, at date: Date) throws -> Bool {
        // Keep the newest observation time and retain the original bytes.
        // A new rowid breaks ties between items in one multi-item copy.
        try statement(db, """
            INSERT INTO entries(id,kind,title,copied,bytes,thumbnail,payload) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET copied=excluded.copied, rowid=(SELECT max(rowid)+1 FROM entries)
                WHERE excluded.copied > entries.copied
            """) { stmt in
                try bind(item.id, at: 1, to: stmt)
                try bind(item.kind.rawValue, at: 2, to: stmt)
                try bind(item.title, at: 3, to: stmt)
                try check(sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970))
                try check(sqlite3_bind_int64(stmt, 5, Int64(item.payload.count)))
                if let thumb = item.thumbnail { try bind(thumb, at: 6, to: stmt) }
                try bind(item.payload, at: 7, to: stmt)
                try step(stmt)
                return sqlite3_changes(db) > 0
            }
    }

    func remove(_ id: String) throws {
        try withDatabase { db in
            try statement(db, "DELETE FROM entries WHERE id=?") { stmt in
                try bind(id, at: 1, to: stmt)
                try step(stmt)
            }
        }
    }

    func clear() throws { try withDatabase { try execute($0, "DELETE FROM entries") } }

    func setPaused(_ value: Bool) throws {
        try withDatabase { try execute($0, value ? "INSERT OR IGNORE INTO settings VALUES ('paused')" : "DELETE FROM settings WHERE name='paused'") }
    }

    func isPaused() throws -> Bool { try withDatabase(paused) }

    private func paused(_ db: OpaquePointer) throws -> Bool {
        try statement(db, "SELECT 1 FROM settings WHERE name='paused'") { try step($0) == SQLITE_ROW }
    }

    private static func thumbnail(_ png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 128_000_000 / h else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 80, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? buffer as Data : nil
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // System-provided paths such as /var/folders may have symlinked ancestors.
        // Resolve the containing directory, while keeping the database itself no-follow.
        guard let resolved = realpath(directory.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        let path = String(cString: resolved) + "/history.sqlite3"
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let connection { sqlite3_close(connection) } }
        try check(status)
        guard let db = connection else { throw ClipboardStoreError("Couldn’t open clipboard history.") }
        try check(sqlite3_busy_timeout(db, 5_000))
        try execute(db, "PRAGMA secure_delete=ON")
        try execute(db, """
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, title TEXT NOT NULL, copied REAL NOT NULL,
                bytes INTEGER NOT NULL, thumbnail BLOB, payload BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settings(name TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS observations(token TEXT NOT NULL UNIQUE);
            """)
        return try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ use: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        guard let stmt else { throw ClipboardStoreError("Couldn’t read clipboard history.") }
        defer { sqlite3_finalize(stmt) }
        return try use(stmt)
    }

    private func bind(_ value: String, at column: Int32, to stmt: OpaquePointer) throws {
        try check(sqlite3_bind_text(stmt, column, value, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
    }

    private func bind(_ bytes: Data, at column: Int32, to stmt: OpaquePointer) throws {
        try bytes.withUnsafeBytes {
            try check(sqlite3_bind_blob(stmt, column, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
    }

    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(stmt, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, column))), as: UTF8.self)
    }

    private func data(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    @discardableResult
    private func step(_ stmt: OpaquePointer) throws -> Int32 {
        let status = sqlite3_step(stmt)
        if status != SQLITE_ROW && status != SQLITE_DONE { try check(status) }
        return status
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw ClipboardStoreError("Clipboard storage: " + String(cString: sqlite3_errstr(code))) }
    }
}
