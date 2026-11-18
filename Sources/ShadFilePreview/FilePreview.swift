import AppKit
import Quartz

@MainActor package final class FilePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    package static let shared = FilePreview()
    private var urls: [URL] = []

    package func show(_ files: [URL]) throws {
        guard !files.isEmpty, let panel = QLPreviewPanel.shared() else { throw CocoaError(.featureUnsupported) }
        urls = files
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    nonisolated package func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated package func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
