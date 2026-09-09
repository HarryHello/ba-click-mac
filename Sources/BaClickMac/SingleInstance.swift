import Darwin
import Foundation

/// One instance at a time, via an exclusive `flock` on a lock file. The
/// kernel releases the lock when the process dies, so a crashed run can
/// never leave a stale lock behind. Without this, a second instance (open
/// the .app twice, or run.sh next to the installed app) would stack another
/// global mouse monitor + overlay on top of the first: double-drawn effects
/// and racing settings writes.
enum SingleInstance {
    /// Lock file next to the other per-user dotfiles (settings.json).
    static var defaultLockURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ba-click-mac.lock")
    }

    /// Descriptors holding our locks; keeping them open holds the lock.
    private static var heldDescriptors: [Int32] = []

    /// Try to become the single instance. Returns false when the lock is
    /// already held (the caller should exit). Acquiring the same path twice
    /// — even within one process — fails, since flock is per open file
    /// description; that is what the unit test relies on.
    @discardableResult
    static func acquire(lockURL: URL = SingleInstance.defaultLockURL) -> Bool {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Can't verify (unwritable HOME etc.) — prefer running.
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        heldDescriptors.append(fd)
        return true
    }
}
