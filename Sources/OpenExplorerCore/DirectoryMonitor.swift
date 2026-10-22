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
    private let pollInterval: DispatchTimeInterval
    private let nativeEventsEnabled: Bool
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var lastEntryNames: [String]?
    private var isRunning = false

    public init(
        url: URL,
        pollInterval: DispatchTimeInterval = .seconds(2),
        nativeEventsEnabled: Bool = true,
        changeHandler: @escaping @Sendable () -> Void
    ) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw MonitorError.notDirectory(url) }
        self.url = url.standardizedFileURL
        self.pollInterval = pollInterval
        self.nativeEventsEnabled = nativeEventsEnabled
        self.changeHandler = changeHandler
        self.queue = DispatchQueue(label: "local.openexplorer.directory-monitor.\(UUID().uuidString)", qos: .utility)
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true
        lastEntryNames = currentEntryNames()

        if nativeEventsEnabled {
            let descriptor = open(url.path, O_EVTONLY)
            if descriptor >= 0 {
                let newSource = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                    queue: queue
                )
                newSource.setEventHandler { [weak self] in self?.nativeChangeObserved() }
                newSource.setCancelHandler { close(descriptor) }
                source = newSource
                newSource.resume()
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pollForChanges() }
        pollTimer = timer
        timer.resume()
    }

    public func stop() {
        lock.lock()
        let oldSource = source
        let oldTimer = pollTimer
        source = nil
        pollTimer = nil
        lastEntryNames = nil
        isRunning = false
        lock.unlock()
        oldSource?.cancel()
        oldTimer?.cancel()
    }

    private func currentEntryNames() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func nativeChangeObserved() {
        let snapshot = currentEntryNames()
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        if let snapshot { lastEntryNames = snapshot }
        lock.unlock()
        changeHandler()
    }

    private func pollForChanges() {
        guard let snapshot = currentEntryNames() else { return }
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        let changed = lastEntryNames != snapshot
        lastEntryNames = snapshot
        lock.unlock()
        if changed { changeHandler() }
    }

    deinit { stop() }
}
