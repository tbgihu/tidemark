import AppKit

/// Makes sure only one Tidemark runs. The first takes an exclusive lock on a file in the per-user temporary folder and
/// holds it for its lifetime; the kernel releases it on exit, crash included, so a stale lock can't block a launch
/// and two launches at the same moment can't both win. A later launch asks the running one, by a distributed
/// notification, to show its panel, then exits before creating a status item.
enum Instance {
    private static let notification = Notification.Name("io.github.tbgihu.tidemark.show")
    nonisolated(unsafe) private static var descriptor: Int32 = -1
    @MainActor static var onHandOff: (() -> Void)? {
        didSet { observe() }
    }

    static func claim() -> Bool {
        let folder = FileManager.default.temporaryDirectory.appending(path: Paths.identifier, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appending(path: "instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }                    // without a lock file, still start
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd                                       // kept open: the lock lasts as long as this process
        return true
    }

    static func handOff() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: Paths.identifier,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    @MainActor private static func observe() {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: Paths.identifier, queue: .main) { _ in
            MainActor.assumeIsolated { onHandOff?() }
        }
    }
}
