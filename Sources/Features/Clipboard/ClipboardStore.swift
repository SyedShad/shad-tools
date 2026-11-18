import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

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

    private let snippetPrefix = "snippet."

    func entries(matching query: String = "") throws -> [ClipboardEntry] {
        let searchable = query.isEmpty ? "NULL" : "CASE WHEN kind <> 'image' THEN payload END"
        let sql = """
            SELECT id,kind,coalesce(custom_title,title),copied,bytes,thumbnail,
                   coalesce(first_copied,copied),copies,source_id,source_name,pinned,
                   formats,item_count,ocr,width,height,\(searchable)
            FROM entries ORDER BY pinned DESC, copied DESC, rowid DESC
            """
        return try withDatabase { db in
            try expireHistory(db)
            return try statement(db, sql) { stmt in
                var result: [ClipboardEntry] = []
                while try step(stmt) == SQLITE_ROW {
                    guard let kind = ClipboardKind(rawValue: string(stmt, 1)) else { continue }
                    let title = string(stmt, 2)
                    let sourceName = optionalString(stmt, 9)
                    let recognizedText = optionalString(stmt, 13)
                    if !query.isEmpty {
                        let body: String
                        if kind == .files, let bytes = data(stmt, 16) {
                            body = try fileURLs(bytes).map(\.path).joined(separator: "\n")
                        } else { body = string(stmt, 16) }
                        let fields = [title, sourceName ?? "", recognizedText ?? "", body]
                        if !fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { continue }
                    }
                    let formats = try data(stmt, 11).map { try PropertyListDecoder().decode([String].self, from: $0) }
                    result.append(ClipboardEntry(id: string(stmt, 0), kind: kind, title: title,
                        copiedAt: date(stmt, 3), byteCount: Int(sqlite3_column_int64(stmt, 4)), thumbnail: data(stmt, 5),
                        firstCopiedAt: date(stmt, 6), copyCount: Int(sqlite3_column_int64(stmt, 7)),
                        sourceBundleID: optionalString(stmt, 8), sourceName: sourceName,
                        isPinned: sqlite3_column_int(stmt, 10) != 0, formatTypes: formats ?? defaultFormats(kind),
                        itemCount: Int(sqlite3_column_int(stmt, 12)), recognizedText: recognizedText,
                        pixelWidth: optionalInt(stmt, 14), pixelHeight: optionalInt(stmt, 15)))
                }
                return result
            }
        }
    }

    private func defaultFormats(_ kind: ClipboardKind) -> [String] {
        switch kind {
        case .image: return ["public.png"]
        case .files: return ["public.file-url"]
        default: return ["public.utf8-plain-text"]
        }
    }

    private func fileURLs(_ bytes: Data) throws -> [URL] {
        try PropertyListDecoder().decode([String].self, from: bytes).map { URL(fileURLWithPath: $0) }
    }

    private func content(_ kind: ClipboardKind, _ bytes: Data) throws -> ClipboardContent {
        switch kind {
        case .image: return .image(bytes)
        case .files: return .files(try fileURLs(bytes))
        default: return .text(String(decoding: bytes, as: UTF8.self))
        }
    }

    func content(for id: String) throws -> ClipboardContent? {
        try withDatabase { db in
            try expireHistory(db)
            if id.hasPrefix(snippetPrefix) { return try snippetContent(id, db) }
            return try statement(db, "SELECT kind,payload FROM entries WHERE id=?") { stmt in
                try bind(id, at: 1, to: stmt)
                guard try step(stmt) == SQLITE_ROW, let kind = ClipboardKind(rawValue: string(stmt, 0)),
                      let bytes = data(stmt, 1) else { return nil }
                return try content(kind, bytes)
            }
        }
    }

    // Standard representations often contain precisely the canonical text or PNG.
    // Store a reference to that payload instead of charging and saving it twice.
    private struct StoredRepresentation: Codable {
        let type: String
        let data: Data?
    }

    func capture(for id: String) throws -> ClipboardCapture? {
        try withDatabase { db in
            try expireHistory(db)
            return try readCapture(for: id, db: db)
        }
    }

    private func readCapture(for id: String, db: OpaquePointer) throws -> ClipboardCapture? {
        if id.hasPrefix(snippetPrefix) {
            return try snippetContent(id, db).map { ClipboardCapture(content: $0) }
        }
        return try statement(db, "SELECT kind,payload,representations,source_id,source_name FROM entries WHERE id=?") { stmt in
            try bind(id, at: 1, to: stmt)
            guard try step(stmt) == SQLITE_ROW, let kind = ClipboardKind(rawValue: string(stmt, 0)),
                  let bytes = data(stmt, 1) else { return nil }
            let archived = try data(stmt, 2).map { try PropertyListDecoder().decode([[StoredRepresentation]].self, from: $0) } ?? []
            let items = archived.map { $0.map { ClipboardRepresentation(type: $0.type, data: $0.data ?? bytes) } }
            return ClipboardCapture(content: try content(kind, bytes), items: items,
                                    sourceBundleID: optionalString(stmt, 3), sourceName: optionalString(stmt, 4))
        }
    }

    // Serializes writes to a row's working copies with deletion and edits, across both editions.
    func withPreviewCopies<T>(for id: String, _ action: (ClipboardCapture, URL) throws -> T) throws -> T {
        try withDatabase { db in
            try transaction(db) {
                try expireHistory(db)
                guard let capture = try readCapture(for: id, db: db) else {
                    throw ClipboardStoreError("This clipboard entry is no longer available.")
                }
                return try action(capture, previewFolder(for: id))
            }
        }
    }

    private var previewRoot: URL { directory.appendingPathComponent("Working Copies", isDirectory: true) }

    private func previewFolder(for id: String) -> URL {
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return previewRoot.appendingPathComponent(name, isDirectory: true)
    }

    // 0.5 used the hash of the materialized bytes as its directory name. Recover
    // edits for retained entries before removing the old unowned working copies.
    func migratePreviewCopies(from legacy: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        try withDatabase { db in
            try transaction(db) {
                guard fm.fileExists(atPath: legacy.path) else { return }
                let entries = try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                let folders = entries.filter { url in
                    let name = url.lastPathComponent
                    return name.utf8.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) }
                }
                let byHash = Dictionary(uniqueKeysWithValues: folders.map { ($0.lastPathComponent, $0) })
                guard !byHash.isEmpty else { return }
                try statement(db, "SELECT id FROM entries UNION ALL SELECT id FROM snippets") { stmt in
                    while try step(stmt) == SQLITE_ROW {
                        let id = string(stmt, 0)
                        guard let capture = try readCapture(for: id, db: db) else { continue }
                        for member in ClipboardPasteboard.members(of: capture) {
                            let data: Data
                            switch member {
                            case .content(.text(let text)): data = Data(text.utf8)
                            case .content(.image(let bytes)): data = bytes
                            case .representation(let rep): data = rep.data
                            case .content(.files): continue
                            }
                            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                            guard let old = byHash[hash] else { continue }
                            let parent = previewFolder(for: id)
                            let dest = parent.appendingPathComponent(hash)
                            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            if !fm.fileExists(atPath: dest.path) {
                                let stage = parent.appendingPathComponent("." + UUID().uuidString)
                                defer { try? fm.removeItem(at: stage) }
                                try fm.copyItem(at: old, to: stage)
                                try fm.moveItem(at: stage, to: dest)
                            }
                        }
                    }
                }
                for folder in folders { try fm.removeItem(at: folder) }
                if try fm.contentsOfDirectory(atPath: legacy.path).isEmpty { try fm.removeItem(at: legacy) }
            }
        }
    }

    private func prunePreviewCopies(_ db: OpaquePointer) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: previewRoot.path) else { return }
        let retained = try statement(db, "SELECT id FROM entries UNION ALL SELECT id FROM snippets") { stmt in
            var names = Set<String>()
            while try step(stmt) == SQLITE_ROW { names.insert(previewFolder(for: string(stmt, 0)).lastPathComponent) }
            return names
        }
        for folder in try manager.contentsOfDirectory(at: previewRoot, includingPropertiesForKeys: nil)
            where !retained.contains(folder.lastPathComponent) {
            try manager.removeItem(at: folder)
        }
    }

    private func discardPreviewCopies(for id: String) throws {
        let folder = previewFolder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func snippetContent(_ id: String, _ db: OpaquePointer) throws -> ClipboardContent? {
        try statement(db, "SELECT body FROM snippets WHERE id=?") { stmt in
            try bind(id, at: 1, to: stmt)
            return try step(stmt) == SQLITE_ROW ? .text(string(stmt, 0)) : nil
        }
    }

    func snippets(matching query: String = "") throws -> [ClipboardEntry] {
        try withDatabase { db in
            try statement(db, "SELECT id,name,body,created,source_id,source_name FROM snippets ORDER BY created DESC,rowid DESC") { stmt in
                var result: [ClipboardEntry] = []
                while try step(stmt) == SQLITE_ROW {
                    let name = string(stmt, 1), text = string(stmt, 2)
                    guard query.isEmpty || name.localizedCaseInsensitiveContains(query) || text.localizedCaseInsensitiveContains(query) else { continue }
                    let created = date(stmt, 3)
                    result.append(ClipboardEntry(id: string(stmt, 0), kind: .classify(text), title: name,
                        copiedAt: created, byteCount: text.utf8.count, firstCopiedAt: created,
                        sourceBundleID: optionalString(stmt, 4), sourceName: optionalString(stmt, 5),
                        isSnippet: true, formatTypes: defaultFormats(.text)))
                }
                return result
            }
        }
    }

    private struct Item {
        let fingerprint: String
        let kind: ClipboardKind
        let payload: Data
        let title: String
        let thumbnail: Data?
        let width: Int?
        let height: Int?
        let formatList: Data
        let representations: Data?
        let itemCount: Int
        let storageBytes: Int
        let sourceID: String?
        let sourceName: String?
    }

    private func prepare(_ capture: ClipboardCapture) throws -> Item? {
        let kind: ClipboardKind
        let payload: Data
        let title: String
        var thumbnail: Data?
        var width: Int?, height: Int?
        let limit = min(maxItemBytes, maxBytes)
        guard maxEntries > 0, capture.items.count <= 200 else { return nil }
        switch capture.content {
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= limit else { return nil }
            kind = .classify(text)
            payload = Data(text.utf8)
            let preview = text.prefix(150).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            title = preview.isEmpty ? "Whitespace" : preview
        case .image(let png):
            guard !png.isEmpty, png.count <= limit, let image = Self.thumbnail(png) else { return nil }
            kind = .image
            payload = png
            thumbnail = image.thumbnail
            width = image.width
            height = image.height
            title = "Image"
        case .files(let urls):
            guard !urls.isEmpty, urls.count <= 200, urls.allSatisfy(\.isFileURL) else { return nil }
            kind = .files
            payload = try PropertyListEncoder().encode(urls.map(\.path))
            guard payload.count <= limit else { return nil }
            title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Files · \(urls[0].lastPathComponent)"
        }

        let baseKind = kind == .image || kind == .files ? kind : .text
        let defaultType = defaultFormats(kind)[0]
        var hash = SHA256()
        hash.update(data: payload)
        var archived = [[StoredRepresentation]]()
        var types = [String]()
        var seen = Set<String>()
        let simple = capture.items.count == 1 && capture.items[0].count == 1
            && capture.items[0][0].type == defaultType && capture.items[0][0].data == payload
        var storageBytes = payload.count
        if !capture.items.isEmpty && !simple {
            // Length framing distinguishes item boundaries, representation names and bytes.
            // Sorting the identifiers for the hash handles apps that offer formats in a
            // different order on repeated copies. The archive retains their original order.
            addLength(payload.count, to: &hash)
            addLength(capture.items.count, to: &hash)
        }
        for item in capture.items {
            guard !item.isEmpty, item.count <= 128 else { return nil }
            var stored = [StoredRepresentation]()
            for rep in item {
                guard !rep.type.isEmpty, rep.type.utf8.count <= 1024 else { return nil }
                let shared = rep.data == payload
                if !shared {
                    guard rep.data.count <= limit - storageBytes else { return nil }
                    storageBytes += rep.data.count
                }
                if seen.insert(rep.type).inserted { types.append(rep.type) }
                stored.append(StoredRepresentation(type: rep.type, data: shared ? nil : rep.data))
            }
            if !simple {
                addLength(item.count, to: &hash)
                for rep in item.sorted(by: { $0.type < $1.type }) {
                    let key = Data(rep.type.utf8)
                    addLength(key.count, to: &hash)
                    hash.update(data: key)
                    addLength(rep.data.count, to: &hash)
                    hash.update(data: rep.data)
                }
            }
            archived.append(stored)
        }

        let fingerprint = baseKind.rawValue + "." + hash.finalize().map { String(format: "%02x", $0) }.joined()
        let inferredCount: Int
        if case .files(let urls) = capture.content { inferredCount = urls.count } else { inferredCount = 1 }
        let formatList = try PropertyListEncoder().encode(types.isEmpty ? defaultFormats(kind) : types)
        let representations = archived.isEmpty ? nil : try PropertyListEncoder().encode(archived)
        return Item(fingerprint: fingerprint, kind: kind, payload: payload, title: title, thumbnail: thumbnail,
                    width: width, height: height, formatList: formatList, representations: representations,
                    itemCount: max(capture.items.count, inferredCount), storageBytes: storageBytes,
                    sourceID: capture.sourceBundleID, sourceName: capture.sourceName)
    }

    private func addLength(_ count: Int, to hash: inout SHA256) {
        var size = UInt64(count).bigEndian
        withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
    }

    @discardableResult
    func record(_ content: ClipboardContent, at date: Date = Date()) throws -> Bool {
        try record([ClipboardCapture(content: content)], token: nil, at: date)
    }

    @discardableResult
    func record(_ contents: [ClipboardContent], observing changeToken: String, at date: Date) throws -> Bool {
        try record(contents.map { ClipboardCapture(content: $0) }, token: changeToken, at: date)
    }

    @discardableResult
    func record(_ capture: ClipboardCapture, observing changeToken: String, at date: Date) throws -> Bool {
        try record([capture], token: changeToken, at: date)
    }

    private func record(_ captures: [ClipboardCapture], token: String?, at date: Date) throws -> Bool {
        let items = try captures.compactMap(prepare)
        guard !items.isEmpty else { return false }
        return try withDatabase { db in
            try transaction(db) {
                if let token, try !claim(token, in: db) { return false }
                guard try !paused(db) else { return false }
                let privacy = try privacySettings(db)
                let origins = captures.flatMap { $0.observedBundleIDs + [$0.sourceBundleID].compactMap { $0 } }
                guard !origins.contains(where: privacy.excludes) else { return false }
                try expireHistory(db, retention: privacy.retention)
                var changed = false
                for item in items.reversed() {
                    if try insert(item, in: db, at: date, observed: token != nil) { changed = true }
                }
                try trim(db)
                return changed
            }
        }
    }

    private func trim(_ db: OpaquePointer) throws {
        try statement(db, """
            DELETE FROM entries WHERE id IN (
                SELECT id FROM (
                    SELECT id,pinned,row_number() OVER recent AS position,
                           sum(coalesce(storage_bytes,bytes)) OVER recent AS total
                    FROM entries WINDOW recent AS (ORDER BY pinned DESC,copied DESC,rowid DESC ROWS UNBOUNDED PRECEDING)
                ) WHERE pinned=0 AND (position > ? OR total > ?)
            )
            """) { stmt in
            try check(sqlite3_bind_int64(stmt, 1, Int64(maxEntries)))
            try check(sqlite3_bind_int64(stmt, 2, Int64(maxBytes)))
            try step(stmt)
        }
        if sqlite3_changes(db) > 0 { try prunePreviewCopies(db) }
    }

    private func transaction<T>(_ db: OpaquePointer, _ action: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute(db, "COMMIT")
            return result
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
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

    private func insert(_ item: Item, in db: OpaquePointer, at date: Date, observed: Bool) throws -> Bool {
        let previousID: String? = try statement(db, """
            SELECT id FROM entries WHERE fingerprint=? OR (fingerprint IS NULL AND id=?)
            ORDER BY copied DESC,rowid DESC LIMIT 1
            """) { stmt in
            try bind(item.fingerprint, at: 1, to: stmt)
            try bind(item.fingerprint, at: 2, to: stmt)
            return try step(stmt) == SQLITE_ROW ? string(stmt, 0) : nil
        }
        if let previousID {
            // A distinct, claimed change token counts even if two processes observed
            // different generations out of order. Source and ordering follow the latest.
            return try statement(db, """
                UPDATE entries SET
                    source_id=CASE WHEN ? >= copied THEN ? ELSE source_id END,
                    source_name=CASE WHEN ? >= copied THEN ? ELSE source_name END,
                    first_copied=min(coalesce(first_copied,copied),?),
                    rowid=CASE WHEN ? >= copied THEN (SELECT max(rowid)+1 FROM entries) ELSE rowid END,
                    copies=copies+1,copied=max(copied,?) WHERE id=? AND (? OR ? > copied)
                """) { stmt in
                let stamp = date.timeIntervalSince1970
                for i: Int32 in [1,3,5,6,7,10] { try check(sqlite3_bind_double(stmt, i, stamp)) }
                try bind(item.sourceID, at: 2, to: stmt)
                try bind(item.sourceName, at: 4, to: stmt)
                try bind(previousID, at: 8, to: stmt)
                try check(sqlite3_bind_int(stmt, 9, observed ? 1 : 0))
                try step(stmt)
                return sqlite3_changes(db) > 0
            }
        }
        // Editing preserves the selected row's identity. An old content-based ID
        // can therefore already belong to a different, edited item.
        let occupied = try statement(db, "SELECT 1 FROM entries WHERE id=?") { stmt in
            try bind(item.fingerprint, at: 1, to: stmt)
            return try step(stmt) == SQLITE_ROW
        }
        let id = occupied ? UUID().uuidString : item.fingerprint
        return try statement(db, """
            INSERT INTO entries(id,fingerprint,kind,title,copied,first_copied,bytes,payload,thumbnail,
                                width,height,formats,representations,item_count,storage_bytes,source_id,source_name)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """) { stmt in
            try bind(id, at: 1, to: stmt)
            try bind(item.fingerprint, at: 2, to: stmt)
            try bind(item.kind.rawValue, at: 3, to: stmt)
            try bind(item.title, at: 4, to: stmt)
            for i: Int32 in [5,6] { try check(sqlite3_bind_double(stmt, i, date.timeIntervalSince1970)) }
            try check(sqlite3_bind_int64(stmt, 7, Int64(item.payload.count)))
            try bind(item.payload, at: 8, to: stmt)
            if let thumbnail = item.thumbnail { try bind(thumbnail, at: 9, to: stmt) }
            if let width = item.width { try check(sqlite3_bind_int64(stmt, 10, Int64(width))) }
            if let height = item.height { try check(sqlite3_bind_int64(stmt, 11, Int64(height))) }
            try bind(item.formatList, at: 12, to: stmt)
            if let archive = item.representations { try bind(archive, at: 13, to: stmt) }
            try check(sqlite3_bind_int64(stmt, 14, Int64(item.itemCount)))
            try check(sqlite3_bind_int64(stmt, 15, Int64(item.storageBytes)))
            try bind(item.sourceID, at: 16, to: stmt)
            try bind(item.sourceName, at: 17, to: stmt)
            try step(stmt)
            return sqlite3_changes(db) > 0
        }
    }

    func rename(_ id: String, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ClipboardStoreError("Enter a name for this item.") }
        let sql = id.hasPrefix(snippetPrefix) ? "UPDATE snippets SET name=? WHERE id=?" : "UPDATE entries SET custom_title=? WHERE id=?"
        try withDatabase { db in
            try statement(db, sql) { stmt in
                try bind(title, at: 1, to: stmt)
                try bind(id, at: 2, to: stmt)
                try step(stmt)
            }
        }
    }

    func setPinned(_ id: String, _ value: Bool) throws {
        try withDatabase { db in
            try transaction(db) {
                if value { try expireHistory(db) }
                try statement(db, "UPDATE entries SET pinned=? WHERE id=?") { stmt in
                    try check(sqlite3_bind_int(stmt, 1, value ? 1 : 0))
                    try bind(id, at: 2, to: stmt)
                    try step(stmt)
                }
                if !value { try expireHistory(db) }
            }
        }
    }

    func saveSnippet(_ id: String, named name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ClipboardStoreError("Enter a name for the snippet.") }
        let saved = try withDatabase { db in
            try transaction(db) {
                try expireHistory(db)
                return try statement(db, """
                    INSERT INTO snippets(id,name,body,created,source_id,source_name)
                    SELECT ?,?,payload,?,source_id,source_name FROM entries WHERE id=? AND kind NOT IN ('image','files')
                    """) { stmt in
                    try bind(snippetPrefix + UUID().uuidString, at: 1, to: stmt)
                    try bind(title, at: 2, to: stmt)
                    try check(sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970))
                    try bind(id, at: 4, to: stmt)
                    try step(stmt)
                    return sqlite3_changes(db) == 1
                }
            }
        }
        guard saved else { throw ClipboardStoreError("This text is no longer available to save.") }
    }

    func edit(_ id: String, text: String) throws {
        guard let item = try prepare(ClipboardCapture(content: .text(text))) else {
            throw ClipboardStoreError("Enter text within the clipboard item size limit.")
        }
        try withDatabase { db in
            try transaction(db) {
                try discardPreviewCopies(for: id)
                if id.hasPrefix(snippetPrefix) {
                    try statement(db, "UPDATE snippets SET body=? WHERE id=?") { stmt in
                        try bind(item.payload, at: 1, to: stmt)
                        try bind(id, at: 2, to: stmt)
                        try step(stmt)
                    }
                    return
                }
                try statement(db, """
                    UPDATE entries SET fingerprint=?,kind=?,title=?,payload=?,bytes=?,storage_bytes=?,formats=?,
                        representations=NULL,ocr=NULL,item_count=1
                    WHERE id=? AND kind NOT IN ('image','files')
                    """) { stmt in
                    try bind(item.fingerprint, at: 1, to: stmt)
                    try bind(item.kind.rawValue, at: 2, to: stmt)
                    try bind(item.title, at: 3, to: stmt)
                    try bind(item.payload, at: 4, to: stmt)
                    for i: Int32 in [5,6] { try check(sqlite3_bind_int64(stmt, i, Int64(item.payload.count))) }
                    try bind(item.formatList, at: 7, to: stmt)
                    try bind(id, at: 8, to: stmt)
                    try step(stmt)
                    guard sqlite3_changes(db) == 1 else { throw ClipboardStoreError("This item cannot be edited.") }
                }
                try trim(db)
                let retained = try statement(db, "SELECT 1 FROM entries WHERE id=?") { stmt in
                    try bind(id, at: 1, to: stmt)
                    return try step(stmt) == SQLITE_ROW
                }
                guard retained else { throw ClipboardStoreError("There is not enough room to keep this edit.") }
            }
        }
    }

    func setRecognizedText(_ text: String, for id: String) throws {
        try withDatabase { db in
            // A group can lead with text and also contain images. An edit collapses
            // it to one text item, which should reject a late result from that group.
            try statement(db, "UPDATE entries SET ocr=? WHERE id=? AND (kind='image' OR item_count>1)") { stmt in
                try bind(text, at: 1, to: stmt)
                try bind(id, at: 2, to: stmt)
                try step(stmt)
            }
        }
    }

    func remove(_ id: String) throws {
        let sql = id.hasPrefix(snippetPrefix) ? "DELETE FROM snippets WHERE id=?" : "DELETE FROM entries WHERE id=?"
        try withDatabase { db in
            try transaction(db) {
                try statement(db, sql) { stmt in
                    try bind(id, at: 1, to: stmt)
                    try step(stmt)
                }
                try discardPreviewCopies(for: id)
            }
        }
    }

    func clear(since cutoff: Date, includingPinned: Bool = false) throws {
        try withDatabase { db in
            try transaction(db) {
                try statement(db, "DELETE FROM entries WHERE copied >= ? AND (? OR pinned=0)") { stmt in
                    try check(sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970))
                    try check(sqlite3_bind_int(stmt, 2, includingPinned ? 1 : 0))
                    try step(stmt)
                }
                try prunePreviewCopies(db)
            }
        }
    }

    func clear() throws {
        try withDatabase { db in
            try transaction(db) {
                try execute(db, "DELETE FROM entries")
                try prunePreviewCopies(db)
            }
        }
    }

    func setPaused(_ value: Bool) throws {
        try withDatabase { try execute($0, value ? "INSERT OR IGNORE INTO settings VALUES ('paused')" : "DELETE FROM settings WHERE name='paused'") }
    }

    func isPaused() throws -> Bool { try withDatabase(paused) }

    private func paused(_ db: OpaquePointer) throws -> Bool {
        try statement(db, "SELECT 1 FROM settings WHERE name='paused'") { try step($0) == SQLITE_ROW }
    }

    func privacySettings() throws -> ClipboardPrivacy { try withDatabase(privacySettings) }

    private func privacySettings(_ db: OpaquePointer) throws -> ClipboardPrivacy {
        let retention = try retentionPeriod(db)
        let apps = try statement(db, "SELECT bundle_id, name FROM excluded_apps ORDER BY name COLLATE NOCASE, bundle_id") { stmt in
            var apps: [ClipboardExcludedApp] = []
            while try step(stmt) == SQLITE_ROW {
                apps.append(ClipboardExcludedApp(id: string(stmt, 0), name: string(stmt, 1)))
            }
            return apps
        }
        return ClipboardPrivacy(retention: retention, excludedApps: apps)
    }

    private func retentionPeriod(_ db: OpaquePointer) throws -> ClipboardRetention {
        try statement(db, "SELECT days FROM history_retention WHERE id=1") { stmt in
            guard try step(stmt) == SQLITE_ROW else { return .noAgeLimit }
            guard let period = ClipboardRetention(rawValue: Int(sqlite3_column_int64(stmt, 0))) else {
                throw ClipboardStoreError("Unknown clipboard retention setting.")
            }
            return period
        }
    }

    func setRetention(_ period: ClipboardRetention) throws {
        try withDatabase { db in
            try transaction(db) {
                // Extending the period must not revive history that already aged out.
                try expireHistory(db)
                try statement(db, "INSERT OR REPLACE INTO history_retention(id,days) VALUES (1,?)") { stmt in
                    try check(sqlite3_bind_int64(stmt, 1, Int64(period.rawValue)))
                    try step(stmt)
                }
                try expireHistory(db, retention: period)
            }
        }
    }

    private func expireHistory(_ db: OpaquePointer, retention: ClipboardRetention? = nil) throws {
        let period = try retention ?? retentionPeriod(db)
        guard let cutoff = period.cutoff(at: Date()) else { return }
        // Keep the working-copy cleanup and the committed list of surviving entries in sync.
        if sqlite3_get_autocommit(db) != 0 {
            return try transaction(db) { try expireHistory(db) }
        }
        try statement(db, "DELETE FROM entries WHERE pinned=0 AND copied <= ?") { stmt in
            try check(sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970))
            try step(stmt)
        }
        if sqlite3_changes(db) > 0 { try prunePreviewCopies(db) }
    }

    func exclude(_ apps: [ClipboardExcludedApp]) throws {
        try withDatabase { db in
            try transaction(db) {
                for app in apps {
                    let id = app.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !id.isEmpty else { throw ClipboardStoreError("The application has no bundle identifier.") }
                    try statement(db, "INSERT OR REPLACE INTO excluded_apps(bundle_id,name) VALUES (?,?)") { stmt in
                        try bind(id, at: 1, to: stmt)
                        try bind(app.name, at: 2, to: stmt)
                        try step(stmt)
                    }
                }
            }
        }
    }

    func removeExclusion(_ id: String) throws {
        try withDatabase { db in
            try statement(db, "DELETE FROM excluded_apps WHERE bundle_id=?") { stmt in
                try bind(id.lowercased(), at: 1, to: stmt)
                try step(stmt)
            }
        }
    }

    func discardObservation(_ token: String) throws {
        try withDatabase { db in
            try transaction(db) { _ = try claim(token, in: db) }
        }
    }

    private func date(_ stmt: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, column))
    }

    private func optionalString(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : string(stmt, column)
    }

    private func optionalInt(_ stmt: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, column))
    }

    private func bind(_ value: String?, at column: Int32, to stmt: OpaquePointer) throws {
        if let value { try bind(value, at: column, to: stmt) }
        else { try check(sqlite3_bind_null(stmt, column)) }
    }
    private static func thumbnail(_ png: Data) -> (thumbnail: Data, width: Int, height: Int)? {
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
        return CGImageDestinationFinalize(destination) ? (buffer as Data, w, h) : nil
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let handle = open(directory.path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(handle) }
        try requirePrivate(handle, type: S_IFDIR, permissions: 0o700)
        // System-provided paths such as /var/folders may have symlinked ancestors.
        // Resolve the containing directory, while keeping the database itself no-follow.
        guard let resolved = realpath(directory.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        let path = String(cString: resolved) + "/history.sqlite3"
        let fd = openat(handle, "history.sqlite3", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try requirePrivate(fd, type: S_IFREG, permissions: 0o600)
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let connection { sqlite3_close(connection) } }
        try check(status)
        guard let db = connection else { throw ClipboardStoreError("Couldn’t open clipboard history.") }
        try check(sqlite3_busy_timeout(db, 5_000))
        try execute(db, "PRAGMA secure_delete=ON")
        try migrate(db)
        return try body(db)
    }

    private func requirePrivate(_ fd: Int32, type: mode_t, permissions: mode_t) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == type,
              type != S_IFREG || info.st_nlink == 1 else {
            throw ClipboardStoreError("Clipboard storage must be owned by the current user.")
        }
        if info.st_mode & 0o7777 != permissions, fchmod(fd, permissions) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
    }
    private func migrate(_ db: OpaquePointer) throws {
        let version = try schemaVersion(db)
        guard version < 2 else { return }
        if version == 0 { try migrateLegacyEntries(db) }
        try transaction(db) {
            guard try schemaVersion(db) < 2 else { return }
            try execute(db, """
                CREATE TABLE history_retention(id INTEGER PRIMARY KEY CHECK(id=1), days INTEGER NOT NULL);
                CREATE TABLE excluded_apps(bundle_id TEXT PRIMARY KEY, name TEXT NOT NULL);
                PRAGMA user_version=2;
                """)
        }
    }

    private func schemaVersion(_ db: OpaquePointer) throws -> Int32 {
        try statement(db, "PRAGMA user_version") { stmt in
            try step(stmt)
            return sqlite3_column_int(stmt, 0)
        }
    }

    private func migrateLegacyEntries(_ db: OpaquePointer) throws {
        try transaction(db) {
            // A second edition can finish upgrading while this connection waits for the lock.
            guard try schemaVersion(db) == 0 else { return }
            try execute(db, """
                CREATE TABLE IF NOT EXISTS entries (
                    id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, title TEXT NOT NULL, copied REAL NOT NULL,
                    bytes INTEGER NOT NULL, thumbnail BLOB, payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS settings(name TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS observations(token TEXT NOT NULL UNIQUE);
                ALTER TABLE entries ADD COLUMN fingerprint TEXT;
                ALTER TABLE entries ADD COLUMN first_copied REAL;
                ALTER TABLE entries ADD COLUMN copies INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE entries ADD COLUMN source_id TEXT;
                ALTER TABLE entries ADD COLUMN source_name TEXT;
                ALTER TABLE entries ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE entries ADD COLUMN custom_title TEXT;
                ALTER TABLE entries ADD COLUMN formats BLOB;
                ALTER TABLE entries ADD COLUMN representations BLOB;
                ALTER TABLE entries ADD COLUMN item_count INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE entries ADD COLUMN storage_bytes INTEGER;
                ALTER TABLE entries ADD COLUMN ocr TEXT;
                ALTER TABLE entries ADD COLUMN width INTEGER;
                ALTER TABLE entries ADD COLUMN height INTEGER;
                UPDATE entries SET fingerprint=id, first_copied=copied, storage_bytes=bytes;
                CREATE INDEX entry_fingerprint ON entries(fingerprint);
                CREATE TABLE snippets(id TEXT PRIMARY KEY, name TEXT NOT NULL, body BLOB NOT NULL, created REAL NOT NULL,
                                      source_id TEXT, source_name TEXT);
                """)
            // Reconstruct only metadata present in the older payloads. The old
            // schema did not capture source application, earlier times or copy count.
            try statement(db, "SELECT id,kind,payload FROM entries") { stmt in
                while try step(stmt) == SQLITE_ROW {
                    let id = string(stmt, 0)
                    if string(stmt, 1) == "text" {
                        let kind = ClipboardKind.classify(string(stmt, 2))
                        if kind != .text {
                            try statement(db, "UPDATE entries SET kind=? WHERE id=?") { update in
                                try bind(kind.rawValue, at: 1, to: update)
                                try bind(id, at: 2, to: update)
                                try step(update)
                            }
                        }
                    } else if let bytes = data(stmt, 2),
                              let src = CGImageSourceCreateWithData(bytes as CFData, nil),
                              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
                        try statement(db, "UPDATE entries SET width=?, height=? WHERE id=?") { update in
                            try check(sqlite3_bind_int64(update, 1, Int64(width)))
                            try check(sqlite3_bind_int64(update, 2, Int64(height)))
                            try bind(id, at: 3, to: update)
                            try step(update)
                        }
                    }
                }
            }
            try execute(db, "PRAGMA user_version=1")
        }
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
