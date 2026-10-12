import Foundation

public enum ZipExtractor {
    public enum ExtractionError: LocalizedError {
        case unsupportedArchive(URL)
        case extractionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedArchive(let url):
                return "“\(url.lastPathComponent)” is not a ZIP archive."
            case .extractionFailed(let detail):
                return detail.isEmpty ? "The ZIP archive could not be extracted." : detail
            }
        }
    }

    /// Extracts a ZIP into a new, uniquely named neighboring folder without
    /// launching Archive Utility or Finder.
    public static func extract(_ archiveURL: URL, fileManager: FileManager = .default) throws -> URL {
        guard archiveURL.pathExtension.lowercased() == "zip" else {
            throw ExtractionError.unsupportedArchive(archiveURL)
        }
        let destination = uniqueDestination(for: archiveURL, fileManager: fileManager)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--sequesterRsrc", "--rsrc", archiveURL.path, destination.path]
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

    public static func uniqueDestination(for archiveURL: URL, fileManager: FileManager = .default) -> URL {
        let parent = archiveURL.deletingLastPathComponent()
        let baseName = archiveURL.deletingPathExtension().lastPathComponent
        var destination = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return destination
    }
}
