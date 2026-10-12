import Dispatch
import Foundation
import Darwin

/// Watches one directory for changes made by this process or by other apps.
/// A new monitor should be created whenever navigation changes the current URL.
public final class DirectoryMonitor: @unchecked Sendable {
    public enum MonitorError: LocalizedError {
        case notDirectory(URL)

        public var errorDescription: String? {
            switch self {
            case .notDirectory(let url):
                return "The monitored location is not a directory: \(url.path)"
            }
        }
    }

    private let url: URL
    private let changeHandler: @Sendable () -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    public init(url: URL, changeHandler: @escaping @Sendable () -> Void) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw MonitorError.notDirectory(url) }
        self.url = url.standardizedFileURL
        self.changeHandler = changeHandler
        self.queue = DispatchQueue(label: "local.openexplorer.directory-monitor.\(UUID().uuidString)", qos: .utility)
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        let handler = changeHandler
        newSource.setEventHandler(handler: handler)
        newSource.setCancelHandler { close(descriptor) }
        source = newSource
        newSource.resume()
    }

    public func stop() {
        lock.lock()
        let oldSource = source
        source = nil
        lock.unlock()
        oldSource?.cancel()
    }

    deinit { stop() }
}
