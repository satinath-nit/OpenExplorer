import Foundation

public final class FileOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}
    public func cancel() { lock.withLock { value = true } }
    public var isCancelled: Bool { lock.withLock { value } }
}

public enum FileConflictResolution: Sendable {
    case replace
    case keepBoth
    case skip
    case cancel
}

public enum FileTransferKind: Sendable {
    case copy
    case move
}

public struct FileTransferRecord: Sendable {
    public let source: URL
    public let destination: URL
    public let kind: FileTransferKind
    public let replacedItemBackup: URL?

    public init(source: URL, destination: URL, kind: FileTransferKind, replacedItemBackup: URL? = nil) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.replacedItemBackup = replacedItemBackup
    }
}

public struct FileTransferResult: Sendable {
    public var completed: [FileTransferRecord] = []
    public var skipped: [URL] = []
    public var failures: [(URL, String)] = []
    public var wasCancelled = false

    public init() {}
}

/// Performs complete top-level file operations behind one small interface.
/// Callers decide conflicts; naming, partial-failure capture and undo records stay local.
public final class FileOperationEngine: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func transfer(
        _ sources: [URL],
        to directory: URL,
        kind: FileTransferKind,
        cancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        resolveConflict: @Sendable (_ source: URL, _ destination: URL) -> FileConflictResolution
    ) -> FileTransferResult {
        var result = FileTransferResult()
        for source in sources {
            if cancelled() {
                result.wasCancelled = true
                break
            }

            var destination = directory.appendingPathComponent(source.lastPathComponent)
            var replacedItemBackup: URL?
            if destination.standardizedFileURL == source.standardizedFileURL {
                switch kind {
                case .copy:
                    destination = availableDestination(for: destination)
                case .move:
                    result.skipped.append(source)
                    progress(result.completed.count + result.skipped.count + result.failures.count, sources.count)
                    continue
                }
            }

            if fileManager.fileExists(atPath: destination.path) {
                switch resolveConflict(source, destination) {
                case .replace:
                    do {
                        let backup = directory.appendingPathComponent(".OpenExplorer-Replaced-\(UUID().uuidString)")
                        try fileManager.moveItem(at: destination, to: backup)
                        replacedItemBackup = backup
                    }
                    catch {
                        result.failures.append((source, error.localizedDescription))
                        continue
                    }
                case .keepBoth:
                    destination = availableDestination(for: destination)
                case .skip:
                    result.skipped.append(source)
                    continue
                case .cancel:
                    result.wasCancelled = true
                    return result
                }
            }

            do {
                switch kind {
                case .copy: try fileManager.copyItem(at: source, to: destination)
                case .move: try fileManager.moveItem(at: source, to: destination)
                }
                result.completed.append(FileTransferRecord(source: source, destination: destination, kind: kind, replacedItemBackup: replacedItemBackup))
            } catch {
                if let backup = replacedItemBackup {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                result.failures.append((source, error.localizedDescription))
            }
            progress(result.completed.count + result.skipped.count + result.failures.count, sources.count)
        }
        return result
    }

    public func undo(_ records: [FileTransferRecord]) -> [(URL, String)] {
        var failures: [(URL, String)] = []
        for record in records.reversed() {
            do {
                switch record.kind {
                case .copy:
                    if fileManager.fileExists(atPath: record.destination.path) {
                        try fileManager.removeItem(at: record.destination)
                    }
                case .move:
                    guard fileManager.fileExists(atPath: record.destination.path) else { continue }
                    if fileManager.fileExists(atPath: record.source.path) {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    try fileManager.moveItem(at: record.destination, to: record.source)
                }
                if let backup = record.replacedItemBackup, fileManager.fileExists(atPath: backup.path) {
                    try fileManager.moveItem(at: backup, to: record.destination)
                }
            } catch {
                failures.append((record.destination, error.localizedDescription))
            }
        }
        return failures
    }

    public func discardUndo(_ records: [FileTransferRecord]) {
        for backup in records.compactMap(\.replacedItemBackup) {
            try? fileManager.removeItem(at: backup)
        }
    }

    public func availableDestination(for requested: URL) -> URL {
        guard fileManager.fileExists(atPath: requested.path) else { return requested }
        let directory = requested.deletingLastPathComponent()
        let extensionPart = requested.pathExtension
        let base = extensionPart.isEmpty ? requested.lastPathComponent : requested.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let name = extensionPart.isEmpty ? base + suffix : base + suffix + "." + extensionPart
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }
}
