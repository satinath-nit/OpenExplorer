import Foundation

public enum BatchRenameRule: Sendable {
    case findAndReplace(find: String, replace: String, useRegex: Bool, caseInsensitive: Bool)
    case addAffix(prefix: String, suffix: String)
    case sequentialNumbering(baseName: String, startNumber: Int, paddingDigits: Int, separator: String)
}

public struct BatchRenamePlanItem: Sendable, Equatable {
    public let source: URL
    public let originalName: String
    public let proposedName: String
    public let destination: URL
    public let hasConflict: Bool

    public init(source: URL, originalName: String, proposedName: String, destination: URL, hasConflict: Bool) {
        self.source = source
        self.originalName = originalName
        self.proposedName = proposedName
        self.destination = destination
        self.hasConflict = hasConflict
    }

    public var isChanged: Bool { originalName != proposedName }
}

public enum BatchRenameEngine {
    public static func preview(
        for urls: [URL],
        rule: BatchRenameRule,
        fileManager: FileManager = .default
    ) -> [BatchRenamePlanItem] {
        let sourceSet = Set(urls.map { $0.standardizedFileURL.path })
        var seenDestinations = Set<String>()
        var plan: [BatchRenamePlanItem] = []

        for (index, url) in urls.enumerated() {
            let originalName = url.lastPathComponent
            let ext = url.pathExtension
            let stem = ext.isEmpty ? originalName : url.deletingPathExtension().lastPathComponent
            let proposedStem: String

            switch rule {
            case let .findAndReplace(find, replace, useRegex, caseInsensitive):
                guard !find.isEmpty else {
                    proposedStem = stem
                    break
                }
                if useRegex {
                    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
                    if let regex = try? NSRegularExpression(pattern: find, options: options) {
                        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
                        proposedStem = regex.stringByReplacingMatches(in: stem, options: [], range: range, withTemplate: replace)
                    } else {
                        proposedStem = stem
                    }
                } else {
                    let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
                    proposedStem = stem.replacingOccurrences(of: find, with: replace, options: options)
                }

            case let .addAffix(prefix, suffix):
                proposedStem = "\(prefix)\(stem)\(suffix)"

            case let .sequentialNumbering(baseName, startNumber, paddingDigits, separator):
                let effectiveBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stem : baseName.trimmingCharacters(in: .whitespacesAndNewlines)
                let number = max(0, startNumber + index)
                let formattedNumber = String(format: "%0\(max(1, paddingDigits))d", number)
                proposedStem = "\(effectiveBase)\(separator)\(formattedNumber)"
            }

            let sanitizedStem = proposedStem
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finalStem = sanitizedStem.isEmpty ? stem : sanitizedStem
            let proposedName = ext.isEmpty ? finalStem : "\(finalStem).\(ext)"
            let destination = url.deletingLastPathComponent().appendingPathComponent(proposedName)
            let destPath = destination.standardizedFileURL.path

            let collidesWithDisk = destPath != url.standardizedFileURL.path
                && !sourceSet.contains(destPath)
                && fileManager.fileExists(atPath: destPath)
            let collidesWithBatch = !seenDestinations.insert(destPath).inserted
            let hasConflict = collidesWithDisk || collidesWithBatch

            plan.append(
                BatchRenamePlanItem(
                    source: url,
                    originalName: originalName,
                    proposedName: proposedName,
                    destination: destination,
                    hasConflict: hasConflict
                )
            )
        }
        return plan
    }

    public static func apply(
        _ plan: [BatchRenamePlanItem],
        fileManager: FileManager = .default
    ) throws -> [FileTransferRecord] {
        let changed = plan.filter { $0.isChanged && !$0.hasConflict }
        guard !changed.isEmpty else { return [] }

        // Use two-phase staging if any destination overlaps a source in the same batch
        var staged: [(temp: URL, item: BatchRenamePlanItem)] = []
        for item in changed {
            let tempURL = item.source.deletingLastPathComponent()
                .appendingPathComponent(".OpenExplorer-RenameTmp-\(UUID().uuidString)-\(item.proposedName)")
            try fileManager.moveItem(at: item.source, to: tempURL)
            staged.append((tempURL, item))
        }

        var completed: [FileTransferRecord] = []
        do {
            for entry in staged {
                try fileManager.moveItem(at: entry.temp, to: entry.item.destination)
                completed.append(FileTransferRecord(source: entry.item.source, destination: entry.item.destination, kind: .move))
            }
        } catch {
            // Rollback if unexpected error occurs
            for record in completed.reversed() {
                try? fileManager.moveItem(at: record.destination, to: record.source)
            }
            for entry in staged where fileManager.fileExists(atPath: entry.temp.path) {
                try? fileManager.moveItem(at: entry.temp, to: entry.item.source)
            }
            throw error
        }
        return completed
    }
}
