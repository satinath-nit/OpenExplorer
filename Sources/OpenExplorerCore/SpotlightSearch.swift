import Foundation

public enum SpotlightSearch {
    public static func find(
        named text: String,
        under root: URL,
        limit: Int = 500,
        excludeGitIgnored: Bool = true
    ) throws -> [URL] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let standardizedRoot = root.standardizedFileURL
        var ignoreMatcher = excludeGitIgnored
            ? GitIgnoreMatcher(directory: standardizedRoot)
            : nil

        let escaped = term.replacingOccurrences(of: "'", with: "\\'")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "-onlyin", standardizedRoot.path, "kMDItemFSName == '*\(escaped)*'cd"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rawSpotlightResults = data.split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .map { URL(fileURLWithPath: $0) }
        let spotlightResults = rawSpotlightResults.filter { candidate in
            guard let matcher = ignoreMatcher else { return true }
            return !matcher.isIgnored(candidate)
        }.prefix(max(1, limit)).map { $0 }

        // Spotlight can lag behind newly created or externally extracted files.
        // A bounded filesystem fallback keeps search correct while metadata catches up.
        guard let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return spotlightResults
        }
        var combined = spotlightResults
        var seen = Set(spotlightResults.map { $0.standardizedFileURL.path })
        var scanned = 0
        while let candidate = enumerator.nextObject() as? URL, combined.count < max(1, limit), scanned < 25_000 {
            scanned += 1
            let stdCandidate = candidate.standardizedFileURL
            let isDir = (try? stdCandidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if let matcher = ignoreMatcher {
                if matcher.isIgnored(stdCandidate, isDirectory: isDir) {
                    if isDir {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if isDir {
                    ignoreMatcher = matcher.extending(withSubdirectory: stdCandidate)
                }
            }
            if stdCandidate.lastPathComponent.localizedCaseInsensitiveContains(term),
               seen.insert(stdCandidate.path).inserted {
                combined.append(stdCandidate)
            }
        }
        return combined
    }
}
