import Foundation

// Editions use the same per-user lock when a system-wide input stream needs one owner.
// The kernel releases the descriptor even if the owner exits unexpectedly.
package final class FeatureLease {
    private let url: URL
    private var descriptor: Int32 = -1
    package var held: Bool { descriptor >= 0 }

    package init(url: URL) { self.url = url }

    package func acquire() -> Bool {
        if held { return true }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }

    package func release() {
        guard held else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
