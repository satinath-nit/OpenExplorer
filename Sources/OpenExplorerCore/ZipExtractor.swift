import Foundation

public enum ZipCompressionMode: String, CaseIterable, Sendable {
    case macOSNative = "macOS Native ZIP (Preserves Resource Forks)"
    case cleanCrossPlatform = "Clean ZIP for Windows/Linux (No .DS_Store / __MACOSX)"
}

public struct ArchiveEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let uncompressedSize: Int64

    public init(path: String, name: String, isDirectory: Bool, uncompressedSize: Int64) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.uncompressedSize = uncompressedSize
    }
}

public enum ZipExtractor {
    public enum ExtractionError: LocalizedError {
        case unsupportedArchive(URL)
        case extractionFailed(String)
        case compressionFailed(String)
        case emptySelection

        public var errorDescription: String? {
            switch self {
            case .unsupportedArchive(let url):
                return "“\(url.lastPathComponent)” is not a supported archive."
            case .extractionFailed(let detail):
                return detail.isEmpty ? "The archive could not be extracted." : detail
            case .compressionFailed(let detail):
                return detail.isEmpty ? "The selected items could not be compressed." : detail
            case .emptySelection:
                return "Select at least one file or folder to compress."
            }
        }
    }

    public static let supportedArchiveExtensions: Set<String> = [
        "zip", "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "7z"
    ]

    public static func isSupportedArchive(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") {
            return true
        }
        return supportedArchiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// Extracts an archive (.zip, .tar.gz, .tgz, .tar.bz2, .tar) into a new, uniquely named neighboring folder without
    /// launching Archive Utility or Finder.
    public static func extract(_ archiveURL: URL, fileManager: FileManager = .default) throws -> URL {
        guard isSupportedArchive(archiveURL) else {
            throw ExtractionError.unsupportedArchive(archiveURL)
        }
        let destination = uniqueDestination(for: archiveURL, fileManager: fileManager)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)

        let lowerName = archiveURL.lastPathComponent.lowercased()
        let ext = archiveURL.pathExtension.lowercased()

        let process = Process()
        let errorPipe = Pipe()
        if ext == "zip" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", "--sequesterRsrc", "--rsrc", archiveURL.path, destination.path]
        } else if lowerName.hasSuffix(".tar.gz") || lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tar.xz")
                    || ["tar", "tgz", "tbz", "tbz2", "gz", "bz2", "xz"].contains(ext) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archiveURL.path, "-C", destination.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        }
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? fileManager.removeItem(at: destination)
            throw ExtractionError.extractionFailed(detail)
        }
        return destination
    }

    /// Compresses one or more files/folders into a collision-safe `.zip` archive in `destinationDirectory`.
    /// Supports both macOS Native ZIP (`ditto`) and Clean Cross-Platform ZIP (`zip -r -X` stripping `.DS_Store` and `__MACOSX`).
    public static func compress(
        _ sources: [URL],
        in destinationDirectory: URL? = nil,
        preferredName: String? = nil,
        mode: ZipCompressionMode = .macOSNative,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !sources.isEmpty else {
            throw ExtractionError.emptySelection
        }
        let targetDir = destinationDirectory ?? sources[0].deletingLastPathComponent()
        let defaultBaseName: String
        if let preferredName, !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
            defaultBaseName = cleaned.lowercased().hasSuffix(".zip")
                ? String(cleaned.dropLast(4))
                : cleaned
        } else if sources.count == 1 {
            let first = sources[0]
            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: first.path, isDirectory: &isDir)
            defaultBaseName = isDir.boolValue ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        } else {
            defaultBaseName = "Archive"
        }

        let archiveURL = uniqueArchiveDestination(baseName: defaultBaseName, in: targetDir, fileManager: fileManager)
        let tempArchiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenExplorer-Archive-\(UUID().uuidString).zip", isDirectory: false)
        defer { try? fileManager.removeItem(at: tempArchiveURL) }

        switch mode {
        case .macOSNative:
            if sources.count == 1 {
                try runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0].path, tempArchiveURL.path],
                    currentDirectory: targetDir,
                    cleanupOnFailure: tempArchiveURL,
                    fileManager: fileManager
                )
            } else {
                let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("OpenExplorer-ZipStage-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: stagingDir) }
                for source in sources {
                    let stagedItem = stagingDir.appendingPathComponent(source.lastPathComponent)
                    try copyForStaging(from: source, to: stagedItem, fileManager: fileManager)
                }
                try runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: ["-c", "-k", "--sequesterRsrc", stagingDir.path, tempArchiveURL.path],
                    currentDirectory: targetDir,
                    cleanupOnFailure: tempArchiveURL,
                    fileManager: fileManager
                )
            }

        case .cleanCrossPlatform:
            if sources.count == 1 {
                try runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", sources[0].path, tempArchiveURL.path],
                    currentDirectory: targetDir,
                    cleanupOnFailure: tempArchiveURL,
                    fileManager: fileManager
                )
            } else {
                let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("OpenExplorer-CleanZipStage-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: stagingDir) }
                for source in sources {
                    let stagedItem = stagingDir.appendingPathComponent(source.lastPathComponent)
                    try copyForStaging(from: source, to: stagedItem, fileManager: fileManager)
                }
                try runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: ["-c", "-k", "--norsrc", "--noextattr", stagingDir.path, tempArchiveURL.path],
                    currentDirectory: stagingDir,
                    cleanupOnFailure: tempArchiveURL,
                    fileManager: fileManager
                )
            }
            stripMacOSMetadataEntries(from: tempArchiveURL)
        }

        if fileManager.fileExists(atPath: archiveURL.path) {
            try? fileManager.removeItem(at: archiveURL)
        }
        try fileManager.moveItem(at: tempArchiveURL, to: archiveURL)
        return archiveURL
    }

    /// Lists entries inside a `.zip` or `.tar` archive without extracting it to disk.
    public static func listEntries(in archiveURL: URL) throws -> [ArchiveEntry] {
        guard isSupportedArchive(archiveURL) else {
            throw ExtractionError.unsupportedArchive(archiveURL)
        }
        let ext = archiveURL.pathExtension.lowercased()
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        if ext == "zip" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
            process.arguments = ["-l", archiveURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-tvf", archiveURL.path]
        }
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExtractionError.extractionFailed(detail)
        }
        let text = String(data: outputData, encoding: .utf8) ?? ""
        var entries: [ArchiveEntry] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if ext == "zip" {
                if line.hasPrefix("Archive:") || line.contains("bytes in") && line.contains("files") { continue }
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 9, let perms = parts.first, perms.count >= 7 else { continue }
                let firstChar = perms.first
                guard firstChar == "-" || firstChar == "d" || firstChar == "l" else { continue }
                let size = Int64(parts[3]) ?? 0
                let entryPath = parts.dropFirst(8).joined(separator: " ")
                guard !entryPath.hasPrefix("__MACOSX/") else { continue }
                let isDir = entryPath.hasSuffix("/") || firstChar == "d"
                let trimmedPath = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let name = (trimmedPath as NSString).lastPathComponent
                entries.append(ArchiveEntry(path: entryPath, name: name.isEmpty ? entryPath : name, isDirectory: isDir, uncompressedSize: size))
            } else {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 9, let perms = parts.first else { continue }
                let isDir = perms.first == "d"
                let size = Int64(parts[4]) ?? 0
                let entryPath = parts.dropFirst(8).joined(separator: " ")
                let trimmedPath = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let name = (trimmedPath as NSString).lastPathComponent
                entries.append(ArchiveEntry(path: entryPath, name: name.isEmpty ? entryPath : name, isDirectory: isDir, uncompressedSize: size))
            }
        }
        return entries
    }

    /// Extracts a single entry from an archive into `destinationDirectory`.
    public static func extractEntry(
        _ entryPath: String,
        from archiveURL: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("OpenExplorer-SingleExtract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let ext = archiveURL.pathExtension.lowercased()
        if ext == "zip" {
            let pattern = entryPath.hasSuffix("/") ? "\(entryPath)*" : entryPath
            try runProcess(
                executable: "/usr/bin/unzip",
                arguments: ["-q", archiveURL.path, pattern, "-d", tempDir.path],
                currentDirectory: tempDir,
                cleanupOnFailure: nil,
                fileManager: fileManager
            )
        } else {
            try runProcess(
                executable: "/usr/bin/tar",
                arguments: ["-xf", archiveURL.path, "-C", tempDir.path, entryPath],
                currentDirectory: tempDir,
                cleanupOnFailure: nil,
                fileManager: fileManager
            )
        }

        let cleanRelative = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let extractedItem = tempDir.appendingPathComponent(cleanRelative)
        let targetName = (cleanRelative as NSString).lastPathComponent
        var finalDestination = destinationDirectory.appendingPathComponent(targetName)
        var suffix = 2
        let base = finalDestination.deletingPathExtension().lastPathComponent
        let fileExt = finalDestination.pathExtension
        while fileManager.fileExists(atPath: finalDestination.path) {
            let candidateName = fileExt.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(fileExt)"
            finalDestination = destinationDirectory.appendingPathComponent(candidateName)
            suffix += 1
        }
        try fileManager.moveItem(at: extractedItem, to: finalDestination)
        return finalDestination
    }

    public static func uniqueArchiveDestination(
        baseName: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let sanitized = baseName.isEmpty ? "Archive" : baseName
        var destination = directory.appendingPathComponent("\(sanitized).zip", isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(sanitized) \(suffix).zip", isDirectory: false)
            suffix += 1
        }
        return destination
    }

    public static func uniqueDestination(for archiveURL: URL, fileManager: FileManager = .default) -> URL {
        let parent = archiveURL.deletingLastPathComponent()
        var baseName = archiveURL.deletingPathExtension().lastPathComponent
        if baseName.lowercased().hasSuffix(".tar") {
            baseName = String(baseName.dropLast(4))
        }
        var destination = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return destination
    }

    private static func copyForStaging(from source: URL, to destination: URL, fileManager: FileManager) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func stripMacOSMetadataEntries(from archiveURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-d", archiveURL.path, "*.DS_Store", "*/.DS_Store", "__MACOSX/*", "*/._*"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        cleanupOnFailure: URL?,
        fileManager: FileManager
    ) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            if let cleanupOnFailure { try? fileManager.removeItem(at: cleanupOnFailure) }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outString = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = !errString.isEmpty ? errString : outString
            if let cleanupOnFailure { try? fileManager.removeItem(at: cleanupOnFailure) }
            throw ExtractionError.compressionFailed(detail)
        }
    }
}
