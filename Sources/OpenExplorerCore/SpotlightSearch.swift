import Foundation

public enum SpotlightSearch {
    public static func find(named text: String, under root: URL, limit: Int = 500) throws -> [URL] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let escaped = term.replacingOccurrences(of: "'", with: "\\'")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "-onlyin", root.path, "kMDItemFSName == '*\(escaped)*'cd"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let spotlightResults = data.split(separator: 0, omittingEmptySubsequences: true)
            .prefix(max(1, limit))
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .map { URL(fileURLWithPath: $0) }
        // Spotlight can lag behind newly created or externally extracted files.
        // A bounded filesystem fallback keeps search correct while metadata catches up.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return spotlightResults }
        var combined = spotlightResults
        var seen = Set(spotlightResults.map { $0.standardizedFileURL.path })
        var scanned = 0
        while let relativePath = enumerator.nextObject() as? String, combined.count < max(1, limit), scanned < 25_000 {
            scanned += 1
            let candidate = root.appendingPathComponent(relativePath)
            if candidate.lastPathComponent.localizedCaseInsensitiveContains(term), seen.insert(candidate.standardizedFileURL.path).inserted {
                combined.append(candidate)
            }
        }
        return combined
    }
}
