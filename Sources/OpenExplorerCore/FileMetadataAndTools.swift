import CryptoKit
import Foundation

// MARK: - Checksums & File Hashing

public struct FileHashes: Sendable, Equatable {
    public let sha256: String
    public let sha1: String
    public let md5: String

    public init(sha256: String, sha1: String, md5: String) {
        self.sha256 = sha256
        self.sha1 = sha1
        self.md5 = md5
    }
}

public enum FileHashCalculator {
    public static func computeHashes(for fileURL: URL) throws -> FileHashes {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var sha256Hasher = SHA256()
        var sha1Hasher = Insecure.SHA1()
        var md5Hasher = Insecure.MD5()

        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
            guard !chunk.isEmpty else { return false }
            sha256Hasher.update(data: chunk)
            sha1Hasher.update(data: chunk)
            md5Hasher.update(data: chunk)
            return true
        }) {}

        let sha256 = sha256Hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let sha1 = sha1Hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let md5 = md5Hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileHashes(sha256: sha256, sha1: sha1, md5: md5)
    }
}

// MARK: - Git & Developer Project Detection

public enum ProjectBadgeKind: String, Sendable {
    case git = "Git Repo"
    case swiftPackage = "Swift Package"
    case xcodeProject = "Xcode Project"
    case nodePackage = "Node.js Project"
    case pythonProject = "Python Project"
    case rustProject = "Rust Crate"

    public var symbolName: String {
        switch self {
        case .git: "arrow.triangle.branch"
        case .swiftPackage: "swift"
        case .xcodeProject: "hammer.fill"
        case .nodePackage: "shippingbox.fill"
        case .pythonProject: "terminal.fill"
        case .rustProject: "gearshape.2.fill"
        }
    }
}

public enum GitFileState: String, Sendable {
    case modified = "M"
    case staged = "A"
    case untracked = "U"
    case conflict = "!"
}

public struct GitDirectorySummary: Sendable {
    public let repositoryRoot: URL
    public let branchName: String
    public let fileStates: [String: GitFileState]
    public let ignoredPaths: Set<String>

    public init(
        repositoryRoot: URL,
        branchName: String,
        fileStates: [String: GitFileState],
        ignoredPaths: Set<String> = []
    ) {
        self.repositoryRoot = repositoryRoot
        self.branchName = branchName
        self.fileStates = fileStates
        self.ignoredPaths = ignoredPaths
    }
}

// MARK: - .gitignore Parser & Matcher

public struct GitIgnoreRule: Sendable, Equatable {
    public let baseDirectoryPath: String
    public let pattern: String
    public let isNegated: Bool
    public let directoryOnly: Bool
    public let isAnchoredToBase: Bool

    public init(
        baseDirectoryPath: String,
        pattern: String,
        isNegated: Bool,
        directoryOnly: Bool,
        isAnchoredToBase: Bool
    ) {
        self.baseDirectoryPath = baseDirectoryPath
        self.pattern = pattern
        self.isNegated = isNegated
        self.directoryOnly = directoryOnly
        self.isAnchoredToBase = isAnchoredToBase
    }
}

public struct GitIgnoreMatcher: Sendable {
    /// Common heavy build/dependency artifact directories that developers expect dimmed & excluded by default.
    public static let defaultIgnoredDirectoryNames: Set<String> = [
        "node_modules", ".build", "dist", "target", "DerivedData",
        ".swiftpm", "__pycache__", ".venv", ".next", ".nuxt",
        ".turbo", "coverage", ".pytest_cache", ".gradle"
    ]

    public let rootURL: URL
    public let rules: [GitIgnoreRule]
    public let gitIgnoredPaths: Set<String>
    public let includeDefaultArtifactDirectories: Bool

    public init(
        directory: URL,
        gitIgnoredPaths: Set<String> = [],
        includeDefaultArtifactDirectories: Bool = true,
        fileManager: FileManager = .default
    ) {
        let stdDir = directory.standardizedFileURL
        let repoRoot = GitRepositoryInspector.findGitRoot(startingAt: stdDir, fileManager: fileManager)
        let effectiveRoot = repoRoot ?? stdDir
        self.rootURL = effectiveRoot
        self.gitIgnoredPaths = gitIgnoredPaths
        self.includeDefaultArtifactDirectories = includeDefaultArtifactDirectories
        self.rules = Self.collectRules(fromRoot: effectiveRoot, downTo: stdDir, fileManager: fileManager)
    }

    /// Returns a new matcher that appends any `.gitignore` rules found in `subdirectory`.
    public func extending(withSubdirectory subdirectory: URL, fileManager: FileManager = .default) -> GitIgnoreMatcher {
        let stdSub = subdirectory.standardizedFileURL
        let gitignoreURL = stdSub.appendingPathComponent(".gitignore")
        guard fileManager.fileExists(atPath: gitignoreURL.path) else { return self }
        let extra = Self.parseRules(in: gitignoreURL, baseDirectoryPath: stdSub.path)
        guard !extra.isEmpty else { return self }
        return GitIgnoreMatcher(
            rootURL: rootURL,
            rules: rules + extra,
            gitIgnoredPaths: gitIgnoredPaths,
            includeDefaultArtifactDirectories: includeDefaultArtifactDirectories
        )
    }

    private init(
        rootURL: URL,
        rules: [GitIgnoreRule],
        gitIgnoredPaths: Set<String>,
        includeDefaultArtifactDirectories: Bool
    ) {
        self.rootURL = rootURL
        self.rules = rules
        self.gitIgnoredPaths = gitIgnoredPaths
        self.includeDefaultArtifactDirectories = includeDefaultArtifactDirectories
    }

    public func isIgnored(_ url: URL, isDirectory: Bool? = nil) -> Bool {
        let stdURL = url.standardizedFileURL
        let path = stdURL.path
        let name = stdURL.lastPathComponent
        if name == ".git" { return true }

        let resolvedIsDir = isDirectory ?? ((try? stdURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)

        if gitIgnoredPaths.contains(path) {
            return true
        }
        for ignoredPath in gitIgnoredPaths where path.hasPrefix(ignoredPath + "/") {
            return true
        }

        // Check if any ancestor component or current component is a default ignored directory
        var matched = false
        if includeDefaultArtifactDirectories {
            let rootComponentsCount = rootURL.standardizedFileURL.pathComponents.count
            let urlComponents = stdURL.pathComponents
            if urlComponents.count > rootComponentsCount {
                let relComponents = urlComponents.dropFirst(rootComponentsCount)
                for (idx, component) in relComponents.enumerated() {
                    let isLast = idx == relComponents.count - 1
                    let compIsDir = isLast ? resolvedIsDir : true
                    if compIsDir && Self.defaultIgnoredDirectoryNames.contains(component) {
                        matched = true
                        break
                    }
                }
            } else if resolvedIsDir && Self.defaultIgnoredDirectoryNames.contains(name) {
                matched = true
            }
        }

        for rule in rules {
            guard path == rule.baseDirectoryPath || path.hasPrefix(rule.baseDirectoryPath + "/") else {
                continue
            }
            let relativePath = path == rule.baseDirectoryPath
                ? name
                : String(path.dropFirst(rule.baseDirectoryPath.count + 1))
            if Self.matches(rule: rule, relativePath: relativePath, itemName: name, isDirectory: resolvedIsDir) {
                matched = !rule.isNegated
            }
        }

        return matched
    }

    public static func parseRules(from contents: String, baseDirectoryPath: String) -> [GitIgnoreRule] {
        var parsed: [GitIgnoreRule] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var isNegated = false
            if line.hasPrefix("!") {
                isNegated = true
                line.removeFirst()
            }

            // Strip leading **/
            if line.hasPrefix("**/") {
                line = String(line.dropFirst(3))
            }

            var directoryOnly = false
            if line.hasSuffix("/") && line.count > 1 {
                directoryOnly = true
                line.removeLast()
            }

            var isAnchored = false
            if line.hasPrefix("/") {
                isAnchored = true
                line.removeFirst()
            } else if line.contains("/") {
                isAnchored = true
            }

            guard !line.isEmpty else { continue }
            parsed.append(
                GitIgnoreRule(
                    baseDirectoryPath: baseDirectoryPath,
                    pattern: line,
                    isNegated: isNegated,
                    directoryOnly: directoryOnly,
                    isAnchoredToBase: isAnchored
                )
            )
        }
        return parsed
    }

    private static func parseRules(in gitignoreFile: URL, baseDirectoryPath: String) -> [GitIgnoreRule] {
        guard let contents = try? String(contentsOf: gitignoreFile, encoding: .utf8) else { return [] }
        return parseRules(from: contents, baseDirectoryPath: baseDirectoryPath)
    }

    private static func collectRules(fromRoot root: URL, downTo target: URL, fileManager: FileManager) -> [GitIgnoreRule] {
        let rootStd = root.standardizedFileURL
        let targetStd = target.standardizedFileURL
        var directoriesToCheck: [URL] = []

        if targetStd.path == rootStd.path || targetStd.path.hasPrefix(rootStd.path + "/") {
            var cursor = targetStd
            while true {
                directoriesToCheck.append(cursor)
                if cursor.path == rootStd.path || cursor.path == "/" { break }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path { break }
                cursor = parent
            }
            directoriesToCheck.reverse()
        } else {
            directoriesToCheck = [targetStd]
        }

        var collected: [GitIgnoreRule] = []
        for dir in directoriesToCheck {
            let gitignore = dir.appendingPathComponent(".gitignore")
            if fileManager.fileExists(atPath: gitignore.path) {
                collected.append(contentsOf: parseRules(in: gitignore, baseDirectoryPath: dir.path))
            }
        }
        return collected
    }

    private static func matches(rule: GitIgnoreRule, relativePath: String, itemName: String, isDirectory: Bool) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        if rule.isAnchoredToBase {
            if globMatch(pattern: rule.pattern, candidate: relativePath) {
                return !rule.directoryOnly || isDirectory
            }
            // If an ancestor directory matched a directory rule, everything inside is also ignored
            if components.count > 1 {
                var prefix = ""
                for idx in 0..<(components.count - 1) {
                    prefix = prefix.isEmpty ? components[idx] : "\(prefix)/\(components[idx])"
                    if globMatch(pattern: rule.pattern, candidate: prefix) {
                        return true
                    }
                }
            }
            return false
        } else {
            // Unanchored pattern: can match itemName or any ancestor directory component
            if (!rule.directoryOnly || isDirectory) && globMatch(pattern: rule.pattern, candidate: itemName) {
                return true
            }
            if components.count > 1 {
                for idx in 0..<(components.count - 1) {
                    if globMatch(pattern: rule.pattern, candidate: components[idx]) {
                        return true
                    }
                }
            }
            return false
        }
    }

    private static func globMatch(pattern: String, candidate: String) -> Bool {
        let normalizedPattern = pattern.replacingOccurrences(of: "**", with: "*")
        return normalizedPattern.withCString { patPtr in
            candidate.withCString { candPtr in
                fnmatch(patPtr, candPtr, FNM_PATHNAME) == 0 || fnmatch(patPtr, candPtr, 0) == 0
            }
        }
    }
}

public enum GitRepositoryInspector {
    public static func projectBadge(for directoryURL: URL, fileManager: FileManager = .default) -> ProjectBadgeKind? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return nil }
        let set = Set(names)
        if set.contains("Package.swift") { return .swiftPackage }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return .xcodeProject }
        if set.contains("package.json") { return .nodePackage }
        if set.contains("Cargo.toml") { return .rustProject }
        if set.contains("pyproject.toml") || set.contains("requirements.txt") { return .pythonProject }
        if set.contains(".git") { return .git }
        return nil
    }

    public static func inspect(directory: URL, fileManager: FileManager = .default) -> GitDirectorySummary? {
        guard let root = findGitRoot(startingAt: directory, fileManager: fileManager) else { return nil }
        let branch = readGitBranch(at: root) ?? "HEAD"

        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "status", "--porcelain", "-uall", "--ignored=matching"]
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return GitDirectorySummary(repositoryRoot: root, branchName: branch, fileStates: [:], ignoredPaths: [])
            }
            var states: [String: GitFileState] = [:]
            var ignored: Set<String> = []
            for rawLine in output.split(separator: "\n") where rawLine.count >= 4 {
                let statusPrefix = String(rawLine.prefix(2))
                var relativePath = String(rawLine.dropFirst(3))
                if let arrowRange = relativePath.range(of: " -> ") {
                    relativePath = String(relativePath[arrowRange.upperBound...])
                }
                relativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if relativePath.hasSuffix("/") && relativePath.count > 1 {
                    relativePath.removeLast()
                }
                let fullURL = root.appendingPathComponent(relativePath).standardizedFileURL
                if statusPrefix == "!!" {
                    ignored.insert(fullURL.path)
                    continue
                }
                let state: GitFileState
                if statusPrefix.contains("U") || statusPrefix == "AA" || statusPrefix == "DD" {
                    state = .conflict
                } else if statusPrefix == "??" {
                    state = .untracked
                } else if statusPrefix.first != " " && statusPrefix.first != "?" {
                    state = .staged
                } else {
                    state = .modified
                }
                states[fullURL.path] = state
                // Propagate status to parent directories inside the repo so folders also show modified badge
                var parent = fullURL.deletingLastPathComponent().standardizedFileURL
                while parent.path.hasPrefix(root.standardizedFileURL.path) && parent.path != root.standardizedFileURL.path {
                    if states[parent.path] == nil {
                        states[parent.path] = state
                    }
                    parent = parent.deletingLastPathComponent().standardizedFileURL
                }
            }
            return GitDirectorySummary(repositoryRoot: root, branchName: branch, fileStates: states, ignoredPaths: ignored)
        } catch {
            return GitDirectorySummary(repositoryRoot: root, branchName: branch, fileStates: [:], ignoredPaths: [])
        }
    }

    public static func findGitRoot(startingAt directory: URL, fileManager: FileManager = .default) -> URL? {
        var current = directory.standardizedFileURL
        while current.path != "/" {
            let gitEntry = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitEntry.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private static func readGitBranch(at repoRoot: URL) -> String? {
        let headFile = repoRoot.appendingPathComponent(".git/HEAD")
        guard let contents = try? String(contentsOf: headFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if contents.hasPrefix("ref: refs/heads/") {
            return String(contents.dropFirst("ref: refs/heads/".count))
        }
        return String(contents.prefix(7))
    }
}

// MARK: - Cloud Storage & FileProvider Awareness

public enum CloudItemStatus: String, Sendable {
    case local = "Local"
    case downloaded = "Downloaded"
    case downloading = "Downloading"
    case cloudOnly = "Cloud Only"

    public var symbolName: String {
        switch self {
        case .local: ""
        case .downloaded: "checkmark.icloud"
        case .downloading: "arrow.down.icloud"
        case .cloudOnly: "icloud.and.arrow.down"
        }
    }
}

public enum CloudStorageInspector {
    public static func status(for url: URL) -> CloudItemStatus {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true {
            switch values.ubiquitousItemDownloadingStatus {
            case .current: return .downloaded
            case .downloaded: return .downloaded
            case .notDownloaded: return .cloudOnly
            default: return .downloading
            }
        }
        // Check if file is an unmaterialized iCloud placeholder (.filename.icloud)
        let name = url.lastPathComponent
        if name.hasPrefix(".") && name.hasSuffix(".icloud") {
            return .cloudOnly
        }
        let path = url.path
        if path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") {
            return .downloaded
        }
        return .local
    }

    public static func discoveredCloudRoots(fileManager: FileManager = .default) -> [(name: String, symbol: String, url: URL)] {
        var results: [(String, String, URL)] = []
        let home = fileManager.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: iCloud.path) {
            results.append(("iCloud Drive", "icloud", iCloud))
        }
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let providers = try? fileManager.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for provider in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let rawName = provider.lastPathComponent
                let displayName: String
                let symbol: String
                if rawName.lowercased().hasPrefix("onedrive") {
                    displayName = "OneDrive"
                    symbol = "cloud"
                } else if rawName.lowercased().hasPrefix("google") {
                    displayName = "Google Drive"
                    symbol = "externaldrive.badge.icloud"
                } else if rawName.lowercased().hasPrefix("dropbox") {
                    displayName = "Dropbox"
                    symbol = "shippingbox"
                } else {
                    displayName = rawName
                    symbol = "cloud"
                }
                results.append((displayName, symbol, provider))
            }
        }
        let legacyDropbox = home.appendingPathComponent("Dropbox", isDirectory: true)
        if fileManager.fileExists(atPath: legacyDropbox.path),
           !results.contains(where: { $0.0 == "Dropbox" }) {
            results.append(("Dropbox", "shippingbox", legacyDropbox))
        }
        return results
    }

    public static func downloadItem(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.startDownloadingUbiquitousItem(at: url)
    }

    public static func evictItem(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.evictUbiquitousItem(at: url)
    }
}

// MARK: - macOS Finder Tags & Color Labels

public enum FinderColorTag: String, CaseIterable, Sendable {
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case gray = "Gray"
}

public enum FinderTagManager {
    public static func tags(for url: URL) -> [String] {
        ((try? (url as NSURL).resourceValues(forKeys: [.tagNamesKey]))?[.tagNamesKey] as? [String]) ?? []
    }

    public static func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    public static func toggleTag(_ tag: String, for urls: [URL]) throws {
        for url in urls {
            var current = tags(for: url)
            if let idx = current.firstIndex(of: tag) {
                current.remove(at: idx)
            } else {
                current.append(tag)
            }
            try setTags(current, for: url)
        }
    }
}

// MARK: - Folder Size Service

public final class FolderSizeCache: @unchecked Sendable {
    public static let shared = FolderSizeCache()
    private let lock = NSLock()
    private var cache: [String: (modificationDate: Date?, size: Int64)] = [:]

    public init() {}

    public func cachedSize(for directory: URL) -> Int64? {
        let key = directory.standardizedFileURL.path
        let modDate = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key], entry.modificationDate == modDate else { return nil }
        return entry.size
    }

    public func calculateSize(for directory: URL, maxFiles: Int = 40_000) -> Int64 {
        if let cached = cachedSize(for: directory) {
            return cached
        }
        let fileManager = FileManager.default
        var total: Int64 = 0
        var count = 0
        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) {
            while let fileURL = enumerator.nextObject() as? URL, count < maxFiles {
                count += 1
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        let modDate = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        cache[directory.standardizedFileURL.path] = (modDate, total)
        lock.unlock()
        return total
    }

    public func invalidate(for directory: URL) {
        lock.lock()
        cache.removeValue(forKey: directory.standardizedFileURL.path)
        lock.unlock()
    }
}

// MARK: - Developer Templates & External IDE / Terminal Discovery

public struct FileTemplate: Sendable, Equatable {
    public let title: String
    public let defaultFileName: String
    public let contents: String

    public init(title: String, defaultFileName: String, contents: String) {
        self.title = title
        self.defaultFileName = defaultFileName
        self.contents = contents
    }
}

public struct ExternalDeveloperApp: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let url: URL
    public let symbolName: String

    public init(name: String, bundleIdentifier: String, url: URL, symbolName: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.symbolName = symbolName
    }
}

public enum DeveloperToolsManager {
    public static let builtInTemplates: [FileTemplate] = [
        FileTemplate(title: "Markdown Document (.md)", defaultFileName: "Notes.md", contents: "# Notes\n\n"),
        FileTemplate(title: "Plain Text (.txt)", defaultFileName: "Notes.txt", contents: ""),
        FileTemplate(title: "JSON File (.json)", defaultFileName: "config.json", contents: "{\n  \n}\n"),
        FileTemplate(title: "Shell Script (.sh)", defaultFileName: "script.sh", contents: "#!/usr/bin/env zsh\nset -euo pipefail\n\n"),
        FileTemplate(title: "Python Script (.py)", defaultFileName: "main.py", contents: "#!/usr/bin/env python3\n\ndef main() -> None:\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n"),
        FileTemplate(title: "Swift File (.swift)", defaultFileName: "File.swift", contents: "import Foundation\n\n"),
        FileTemplate(title: "HTML Page (.html)", defaultFileName: "index.html", contents: "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>Document</title>\n</head>\n<body>\n\n</body>\n</html>\n")
    ]

    public static func createFromTemplate(
        _ template: FileTemplate,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseURL = directory.appendingPathComponent(template.defaultFileName)
        let ext = baseURL.pathExtension
        let stem = ext.isEmpty ? baseURL.lastPathComponent : baseURL.deletingPathExtension().lastPathComponent
        var candidate = baseURL
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        try Data(template.contents.utf8).write(to: candidate, options: .withoutOverwriting)
        if ext == "sh" || ext == "py" {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        }
        return candidate
    }

    public static func installedEditors(fileManager: FileManager = .default) -> [ExternalDeveloperApp] {
        let candidates: [(name: String, bundleID: String, paths: [String], symbol: String)] = [
            ("Visual Studio Code", "com.microsoft.VSCode", ["/Applications/Visual Studio Code.app", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/Visual Studio Code.app"], "chevron.left.forwardslash.chevron.right"),
            ("Cursor", "com.todesktop.230313mzl4w4u92", ["/Applications/Cursor.app", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/Cursor.app"], "cursorarrow.rays"),
            ("Zed", "dev.zed.Zed", ["/Applications/Zed.app", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/Zed.app"], "bolt.fill"),
            ("Xcode", "com.apple.dt.Xcode", ["/Applications/Xcode.app"], "hammer"),
            ("Sublime Text", "com.sublimetext.4", ["/Applications/Sublime Text.app"], "doc.text")
        ]
        return candidates.compactMap { entry in
            if let foundPath = entry.paths.first(where: { fileManager.fileExists(atPath: $0) }) {
                return ExternalDeveloperApp(name: entry.name, bundleIdentifier: entry.bundleID, url: URL(fileURLWithPath: foundPath), symbolName: entry.symbol)
            }
            return nil
        }
    }

    public static func installedTerminals(fileManager: FileManager = .default) -> [ExternalDeveloperApp] {
        let candidates: [(name: String, bundleID: String, paths: [String], symbol: String)] = [
            ("Terminal", "com.apple.Terminal", ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"], "terminal"),
            ("iTerm", "com.googlecode.iterm2", ["/Applications/iTerm.app", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/iTerm.app"], "terminal.fill"),
            ("Warp", "dev.warp.Warp-Stable", ["/Applications/Warp.app", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/Warp.app"], "bolt.horizontal.fill"),
            ("Ghostty", "com.mitchellh.ghostty", ["/Applications/Ghostty.app", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/Ghostty.app"], "sparkles.rectangle.stack")
        ]
        return candidates.compactMap { entry in
            if let foundPath = entry.paths.first(where: { fileManager.fileExists(atPath: $0) }) {
                return ExternalDeveloperApp(name: entry.name, bundleIdentifier: entry.bundleID, url: URL(fileURLWithPath: foundPath), symbolName: entry.symbol)
            }
            return nil
        }
    }
}

// MARK: - Group By Engine

public enum FileGroupMode: Int, CaseIterable, Sendable {
    case none = 0
    case dateModified = 1
    case kind = 2
    case size = 3

    public var title: String {
        switch self {
        case .none: "Group: None"
        case .dateModified: "Group: Date"
        case .kind: "Group: Type"
        case .size: "Group: Size"
        }
    }
}

public enum FileItemGrouper {
    public static func groupTitle(
        for entry: FileSortEntry,
        mode: FileGroupMode,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        switch mode {
        case .none:
            return ""
        case .dateModified:
            guard let date = entry.modified else { return "Older" }
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: referenceDate), date >= weekAgo {
                return "Earlier this week"
            }
            if let monthAgo = calendar.date(byAdding: .day, value: -30, to: referenceDate), date >= monthAgo {
                return "Earlier this month"
            }
            return "Older"
        case .kind:
            return entry.kind
        case .size:
            if entry.isDirectory { return "Folders" }
            if entry.size == 0 { return "Empty (0 KB)" }
            if entry.size < 100 * 1_024 { return "Tiny (0 – 100 KB)" }
            if entry.size < 5 * 1_024 * 1_024 { return "Small (100 KB – 5 MB)" }
            if entry.size < 100 * 1_024 * 1_024 { return "Medium (5 – 100 MB)" }
            return "Large (> 100 MB)"
        }
    }
}

// MARK: - Multi-Step Undo & Redo Stack

public enum UndoableFileOperation: Sendable {
    case transfer([FileTransferRecord])
    case createdItem(URL)

    public var summary: String {
        switch self {
        case .transfer(let records):
            return "\(records.count) file operation(s)"
        case .createdItem(let url):
            return "Create “\(url.lastPathComponent)”"
        }
    }
}

public final class FileUndoStack: @unchecked Sendable {
    private let lock = NSLock()
    private var undoEntries: [UndoableFileOperation] = []
    private var redoEntries: [UndoableFileOperation] = []
    private let engine: FileOperationEngine
    private let fileManager: FileManager

    public init(engine: FileOperationEngine = FileOperationEngine(), fileManager: FileManager = .default) {
        self.engine = engine
        self.fileManager = fileManager
    }

    public var canUndo: Bool { lock.withLock { !undoEntries.isEmpty } }
    public var canRedo: Bool { lock.withLock { !redoEntries.isEmpty } }

    public func record(_ operation: UndoableFileOperation) {
        lock.lock()
        for discarded in redoEntries {
            if case .transfer(let records) = discarded {
                engine.discardUndo(records)
            }
        }
        redoEntries.removeAll()
        undoEntries.append(operation)
        lock.unlock()
    }

    public func undoLast() -> (summary: String, failures: [(URL, String)])? {
        lock.lock()
        guard let op = undoEntries.popLast() else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        switch op {
        case .transfer(let records):
            let failures = engine.undo(records)
            if failures.isEmpty {
                lock.withLock { redoEntries.append(op) }
            }
            return (op.summary, failures)
        case .createdItem(let url):
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                return (op.summary, [])
            } catch {
                return (op.summary, [(url, error.localizedDescription)])
            }
        }
    }

    public func redoLast() -> (summary: String, failures: [(URL, String)])? {
        lock.lock()
        guard let op = redoEntries.popLast() else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        switch op {
        case .transfer(let records):
            var failures: [(URL, String)] = []
            var reapplied: [FileTransferRecord] = []
            for record in records {
                do {
                    switch record.kind {
                    case .copy:
                        try fileManager.copyItem(at: record.source, to: record.destination)
                    case .move:
                        try fileManager.moveItem(at: record.source, to: record.destination)
                    }
                    reapplied.append(record)
                } catch {
                    failures.append((record.destination, error.localizedDescription))
                }
            }
            if failures.isEmpty {
                lock.withLock { undoEntries.append(.transfer(reapplied)) }
            }
            return (op.summary, failures)
        case .createdItem:
            return nil
        }
    }
}

// MARK: - Path Autocomplete & Breadcrumb Siblings

public enum PathAutocompleteEngine {
    public static func expandPath(_ rawInput: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var result = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        for (key, value) in environment {
            result = result.replacingOccurrences(of: "$\(key)", with: value)
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return NSString(string: result).expandingTildeInPath
    }

    public static func completions(for partialInput: String, fileManager: FileManager = .default, limit: Int = 12) -> [URL] {
        let expanded = expandPath(partialInput)
        guard !expanded.isEmpty else { return [] }
        let isExplicitDirectory = expanded.hasSuffix("/")
        let url = URL(fileURLWithPath: expanded)
        let searchDir = isExplicitDirectory ? url : url.deletingLastPathComponent()
        let prefix = isExplicitDirectory ? "" : url.lastPathComponent.lowercased()

        guard let contents = try? fileManager.contentsOfDirectory(
            at: searchDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { candidate in
                guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                return prefix.isEmpty || candidate.lastPathComponent.lowercased().hasPrefix(prefix)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { $0 }
    }

    public static func siblingDirectories(of directory: URL, fileManager: FileManager = .default) -> [URL] {
        let parent = directory.standardizedFileURL.deletingLastPathComponent()
        guard parent.path != directory.standardizedFileURL.path,
              let contents = try? fileManager.contentsOfDirectory(
                  at: parent,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Default File Manager Registration (`NSFileViewer`)

public enum DefaultFileManagerRegistrar {
    public static let bundleIdentifier = "local.openexplorer.app"

    public static func isRegisteredAsDefaultFileViewer() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "-g", "NSFileViewer"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        } catch {
            return false
        }
    }

    public static func setAsDefaultFileViewer(_ enabled: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if enabled {
            process.arguments = ["write", "-g", "NSFileViewer", "-string", bundleIdentifier]
        } else {
            process.arguments = ["delete", "-g", "NSFileViewer"]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let lsProcess = Process()
        lsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if enabled {
            lsProcess.arguments = ["write", "com.apple.LaunchServices/com.apple.launchservices.secure", "NSFileViewer", "-string", bundleIdentifier]
        } else {
            lsProcess.arguments = ["delete", "com.apple.LaunchServices/com.apple.launchservices.secure", "NSFileViewer"]
        }
        lsProcess.standardOutput = Pipe()
        lsProcess.standardError = Pipe()
        try? lsProcess.run()
        lsProcess.waitUntilExit()
    }
}

// MARK: - Command Palette & Fuzzy Navigation Engine (`⌘K` / `⌘P`)

public enum CommandPaletteMode: Sendable, Equatable {
    case commands          // ⌘K — Command Palette (or when query starts with '>')
    case fuzzyNavigation   // ⌘P — Fuzzy Go to File / Folder
}

public enum CommandPaletteTarget: Sendable, Equatable {
    case command(String)
    case folder(URL)
    case file(URL)
}

public struct CommandPaletteItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: String
    public let symbolName: String
    public let shortcutHint: String
    public let keywords: [String]
    public let target: CommandPaletteTarget

    public init(
        id: String,
        title: String,
        subtitle: String,
        category: String,
        symbolName: String,
        shortcutHint: String = "",
        keywords: [String] = [],
        target: CommandPaletteTarget
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.symbolName = symbolName
        self.shortcutHint = shortcutHint
        self.keywords = keywords
        self.target = target
    }
}

public enum CommandPaletteEngine {
    private static let skippedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".swiftpm", "__pycache__", ".Trash"
    ]

    /// Scores a query against a candidate string using VS Code-style fuzzy subsequence & boundary matching.
    /// Returns `nil` when all characters of `query` do not appear in order within `candidate`.
    public static func fuzzyScore(query rawQuery: String, against candidate: String) -> Int? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return 1 }
        let target = candidate.lowercased()
        if target == query { return 1_200 }
        if target.hasPrefix(query) { return max(700, 1_000 - target.count) }
        if let range = target.range(of: query) {
            let offset = target.distance(from: target.startIndex, to: range.lowerBound)
            let boundaryBonus = (offset == 0 || isBoundary(in: target, before: range.lowerBound)) ? 140 : 0
            return max(420, 680 + boundaryBonus - offset * 3 - target.count)
        }

        // Multi-token support: every space-separated token must fuzzy-match
        let tokens = query.split(whereSeparator: \.isWhitespace)
        if tokens.count > 1 {
            var sum = 0
            for token in tokens {
                guard let tokenScore = fuzzyScore(query: String(token), against: candidate) else {
                    return nil
                }
                sum += tokenScore
            }
            return sum
        }

        // Character-by-character subsequence matching
        let queryChars = Array(query)
        let targetChars = Array(target)
        var qIdx = 0
        var score = 100
        var lastMatchIdx: Int?

        for (tIdx, char) in targetChars.enumerated() {
            guard qIdx < queryChars.count else { break }
            if char == queryChars[qIdx] {
                if let last = lastMatchIdx, tIdx == last + 1 {
                    score += 35 // consecutive character bonus
                }
                if tIdx == 0 || isWordBoundaryChar(targetChars[tIdx - 1]) {
                    score += 45 // word boundary bonus ('/', '-', '_', '.', ' ')
                }
                lastMatchIdx = tIdx
                qIdx += 1
            } else {
                score -= 1
            }
        }

        guard qIdx == queryChars.count else { return nil }
        return max(10, score)
    }

    /// Filters and ranks palette items for the given query and mode.
    public static func rank(
        items: [CommandPaletteItem],
        query rawQuery: String,
        mode: CommandPaletteMode,
        limit: Int = 80
    ) -> [CommandPaletteItem] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExplicitCommandPrefix = trimmed.hasPrefix(">")
        let effectiveMode: CommandPaletteMode = isExplicitCommandPrefix ? .commands : mode
        let searchQuery = isExplicitCommandPrefix
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed

        let pool: [CommandPaletteItem]
        if isExplicitCommandPrefix {
            pool = items.filter {
                if case .command = $0.target { return true }
                return false
            }
        } else {
            pool = items
        }

        if searchQuery.isEmpty {
            return Array(pool.sorted { lhs, rhs in
                let lPriority = categoryPriority(for: lhs, mode: effectiveMode)
                let rPriority = categoryPriority(for: rhs, mode: effectiveMode)
                if lPriority != rPriority { return lPriority < rPriority }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }.prefix(limit))
        }

        var scored: [(item: CommandPaletteItem, score: Int)] = []
        for item in pool {
            let titleScore = fuzzyScore(query: searchQuery, against: item.title) ?? 0
            let subtitleScore = (fuzzyScore(query: searchQuery, against: item.subtitle) ?? 0) * 3 / 4
            let categoryScore = (fuzzyScore(query: searchQuery, against: item.category) ?? 0) / 2
            let keywordScore = item.keywords.compactMap { fuzzyScore(query: searchQuery, against: $0) }.max() ?? 0
            let best = max(titleScore, subtitleScore, categoryScore, keywordScore)
            guard best > 0 else { continue }

            let modeBonus: Int
            switch (effectiveMode, item.target) {
            case (.commands, .command): modeBonus = 80
            case (.fuzzyNavigation, .folder), (.fuzzyNavigation, .file): modeBonus = 80
            default: modeBonus = 0
            }
            scored.append((item, best + modeBonus))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.item))
    }

    /// Discovers nested subdirectories and files up to `maxDepth` under `root` for fast `⌘P` fuzzy jumping.
    public static func discoverNestedItems(
        under root: URL,
        maxDepth: Int = 3,
        limit: Int = 350,
        includeHidden: Bool = false,
        excludeGitIgnored: Bool = true,
        fileManager: FileManager = .default
    ) -> [(url: URL, relativePath: String, isDirectory: Bool)] {
        let standardizedRoot = root.standardizedFileURL
        let rootComponentsCount = standardizedRoot.pathComponents.count
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: options
        ) else {
            return []
        }

        var ignoreMatcher = excludeGitIgnored
            ? GitIgnoreMatcher(directory: standardizedRoot, fileManager: fileManager)
            : nil

        var results: [(URL, String, Bool)] = []
        while let url = enumerator.nextObject() as? URL, results.count < limit {
            let stdURL = url.standardizedFileURL
            let depth = stdURL.pathComponents.count - rootComponentsCount
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = stdURL.lastPathComponent
            let isPackage = FileTextFormatter.isPackage(stdURL)
            let rawIsDir = (try? stdURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if rawIsDir && (skippedDirectoryNames.contains(name) || isPackage) {
                enumerator.skipDescendants()
                if !isPackage { continue }
            }
            let isDir = rawIsDir && !isPackage
            if let matcher = ignoreMatcher {
                if matcher.isIgnored(stdURL, isDirectory: isDir) {
                    if isDir { enumerator.skipDescendants() }
                    continue
                }
                if isDir {
                    ignoreMatcher = matcher.extending(withSubdirectory: stdURL, fileManager: fileManager)
                }
            }
            let relParts = stdURL.pathComponents.dropFirst(rootComponentsCount)
            let relPath = relParts.joined(separator: "/")
            results.append((stdURL, relPath, isDir))
        }
        return results
    }

    private static func categoryPriority(for item: CommandPaletteItem, mode: CommandPaletteMode) -> Int {
        switch (mode, item.target) {
        case (.commands, .command): return 0
        case (.commands, .folder): return 1
        case (.commands, .file): return 2
        case (.fuzzyNavigation, .folder): return 0
        case (.fuzzyNavigation, .file): return 1
        case (.fuzzyNavigation, .command): return 2
        }
    }

    private static func isBoundary(in string: String, before index: String.Index) -> Bool {
        guard index > string.startIndex else { return true }
        let prev = string[string.index(before: index)]
        return isWordBoundaryChar(prev)
    }

    private static func isWordBoundaryChar(_ char: Character) -> Bool {
        char == "/" || char == "-" || char == "_" || char == "." || char == " " || char == ":"
    }
}

