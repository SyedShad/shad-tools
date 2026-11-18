import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension ClipboardEntry {
    var historyTitle: String {
        guard kind == .image, title == "Image", let pixelWidth, let pixelHeight else { return title }
        return "Image (\(pixelWidth) × \(pixelHeight))"
    }
}

extension ClipboardKind {
    var historyLabel: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .files: return "Files"
        case .link: return "Link"
        case .email: return "Email"
        case .color: return "Color"
        }
    }

    var historySymbol: String {
        switch self {
        case .text: return "doc"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .link: return "link"
        case .email: return "envelope"
        case .color: return "paintpalette"
        }
    }

    var historyTint: Color {
        switch self {
        case .text: return .secondary
        case .image: return .mint
        case .files: return .blue
        case .link: return .cyan
        case .email: return .purple
        case .color: return .orange
        }
    }
}

struct ClipboardProperty: Identifiable {
    let name: String
    let value: String
    var id: String { name }

    init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

struct ClipboardGroupSummary {
    let count: Int
    let textCount: Int
    let imageCount: Int
    let fileCount: Int
    let otherCount: Int
    let firstPreviewIndex: Int
    let canAnnotate: Bool

    init?(_ members: [ClipboardMember]) {
        guard members.count > 1 else { return nil }
        var texts = 0, images = 0, files = 0, other = 0
        var supportedFiles = true
        var first: Int?
        for (index, member) in members.enumerated() {
            switch member {
            case .content(.text): texts += 1
            case .content(.image): images += 1
            case .content(.files(let urls)):
                files += 1
                supportedFiles = supportedFiles && urls.allSatisfy { url in
                    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                    return type.conforms(to: .image) || type.conforms(to: .pdf)
                }
            case .representation: other += 1; continue
            }
            if first == nil { first = index }
        }
        count = members.count
        textCount = texts
        imageCount = images
        fileCount = files
        otherCount = other
        firstPreviewIndex = first ?? 0
        canAnnotate = images + files == count && supportedFiles
    }

    var previewsOneItem: Bool { textCount != count && fileCount != count }
    var previewLabel: String {
        if textCount == count { return "Combined text from \(count) items" }
        if fileCount == count { return "\(count) files" }
        return "Previewing item \(firstPreviewIndex + 1) of \(count)"
    }
    var description: String {
        [(textCount, "text item", "text items"), (imageCount, "image", "images"),
         (fileCount, "file", "files"), (otherCount, "other item", "other items")]
            .filter { $0.0 > 0 }.map { "\($0.0) " + ($0.0 == 1 ? $0.1 : $0.2) }.joined(separator: ", ")
    }
}

struct ClipboardInspection {
    var preview: HistoryPreview = .loading
    var properties: [ClipboardProperty] = []
    var group: ClipboardGroupSummary?

    static func inspect(_ content: ClipboardContent) -> ClipboardInspection {
        switch content {
        case .text(let text):
            var words = 0
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, stop in
                if Task.isCancelled { stop = true; return }
                words += 1
            }
            guard !Task.isCancelled else { return ClipboardInspection() }
            let lines = text.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
            return ClipboardInspection(preview: .text(text), properties: [
                ClipboardProperty("Characters", text.count.formatted()), ClipboardProperty("Words", words.formatted()),
                ClipboardProperty("Lines", lines.formatted())
            ])
        case .image(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return ClipboardInspection(preview: .unavailable) }
            let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var rows: [ClipboardProperty] = []
            if let width = meta?[kCGImagePropertyPixelWidth] as? Int, let height = meta?[kCGImagePropertyPixelHeight] as? Int {
                rows.append(ClipboardProperty("Dimensions", "\(width) × \(height)"))
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1500,
                kCGImageSourceShouldCacheImmediately: true]
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            return ClipboardInspection(preview: image.map(HistoryPreview.image) ?? .unavailable, properties: rows)
        case .files(let urls):
            var rows = [ClipboardProperty("Files", urls.count.formatted())]
            if let url = urls.first, urls.count == 1 {
                if let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isRegularFileKey]) {
                    if let kind = values.localizedTypeDescription { rows.append(ClipboardProperty("Kind", kind)) }
                    if values.isRegularFile == true, let size = values.fileSize {
                        rows.append(ClipboardProperty("File size", bytes(size)))
                    }
                }
                rows.append(ClipboardProperty("Location", url.deletingLastPathComponent().path))
            }
            return ClipboardInspection(preview: .files(urls), properties: rows)
        }
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

struct ClipboardInspector: View {
    @ObservedObject var browser: HistoryBrowser
    let entry: ClipboardEntry

    private var rows: [ClipboardProperty] {
        var values = [ClipboardProperty("Source", entry.sourceName ?? entry.sourceBundleID ?? "Not recorded"),
                      ClipboardProperty("Type", entry.itemCount > 1 ? "Clipboard group" : entry.kind.historyLabel)]
        if let group = browser.inspection.group { values.append(ClipboardProperty("Contents", group.description)) }
        if browser.inspection.group?.previewsOneItem == true {
            values += browser.inspection.properties.map { ClipboardProperty("Preview " + $0.name.lowercased(), $0.value) }
        } else { values += browser.inspection.properties }
        let sizeLabel = entry.kind == .files ? "Clipboard size" : "Size"
        let previewOnly = browser.inspection.group?.previewsOneItem == true
        values.append(ClipboardProperty(previewOnly ? "Preview size" : sizeLabel, ClipboardInspection.bytes(entry.byteCount)))
        if entry.itemCount > 1 { values.append(ClipboardProperty("Clipboard items", entry.itemCount.formatted())) }
        if entry.isSnippet { values.append(ClipboardProperty("Saved", timestamp(entry.copiedAt))) }
        else {
            values.append(ClipboardProperty("Times copied", entry.copyCount.formatted()))
            if entry.copyCount > 1 {
                values.append(ClipboardProperty("Last copied", timestamp(entry.copiedAt)))
                values.append(ClipboardProperty("First copied", timestamp(entry.firstCopiedAt)))
            } else { values.append(ClipboardProperty("Copied", timestamp(entry.copiedAt))) }
        }
        let formats = entry.itemCount > 1 ? entry.formatTypes : browser.formats
        if !formats.isEmpty {
            let names = formats.map(ClipboardPasteboard.formatName)
            values.append(ClipboardProperty("Formats", names.joined(separator: ", ")))
        }
        return values
    }

    private func timestamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .standard) }

    var body: some View {
        GeometryReader { box in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let group = browser.inspection.group {
                        Label(group.previewLabel, systemImage: "square.stack")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 8)
                    }
                    preview.frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: max(96, min(220, box.size.height * 0.41)))
                        .padding(.bottom, 16)
                    Text("Information").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.bottom, 7)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, property in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(property.name).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if property.name == "Source", let app = entry.sourceBundleID,
                               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                                    .padding(.trailing, -9)
                            }
                            Text(property.value).multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 12.5)).padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.036) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(property.name).accessibilityValue(property.value)
                    }
                    if let recognized = entry.recognizedText, !recognized.isEmpty {
                        Text(browser.inspection.group.map { $0.imageCount > 1 ? "Text in images" : "Text in image" } ?? "Text in image").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.top, 15).padding(.bottom, 5)
                        Text(recognized).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 17).padding(.vertical, 15)
            }.id(entry.id)
        }
    }

    @ViewBuilder private var preview: some View {
        switch browser.preview {
        case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable: Text("Preview unavailable").foregroundStyle(.secondary)
        case .text(let value):
            if entry.kind == .color, let color = ClipboardColor(css: value) {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: color.nsColor))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))
                    Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            } else if entry.kind == .link || entry.kind == .email {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: entry.kind.historySymbol).font(.system(size: 22)).foregroundStyle(entry.kind.historyTint)
                    if entry.kind == .link, let host = URL(string: value)?.host {
                        Text(host).font(.headline).lineLimit(2)
                    }
                    Text(value).font(.system(size: 14)).lineLimit(5).textSelection(.enabled)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ClipboardTextPreview(id: entry.id, text: value)
            }
        case .image(let image):
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement().accessibilityLabel("Image preview")
        case .files(let urls):
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 27, height: 27)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }.help(url.path)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
