import Foundation

public struct BrowserHistory: Sendable {
    public private(set) var entries: [URL]
    public private(set) var index: Int

    public init(initialURL: URL) {
        self.entries = [initialURL.standardizedFileURL]
        self.index = 0
    }

    public var current: URL { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }

    @discardableResult
    public mutating func visit(_ url: URL) -> URL {
        let destination = url.standardizedFileURL
        if destination == current { return current }
        if canGoForward { entries.removeSubrange((index + 1)..<entries.count) }
        entries.append(destination)
        index = entries.count - 1
        return current
    }

    @discardableResult
    public mutating func back() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public mutating func forward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}

public enum FileTextFormatter {
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "prefpane", "qlgenerator", "appex", "xcodeproj", "xcworkspace", "playground"
    ]

    public static func isPackage(_ url: URL) -> Bool {
        if packageExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.isPackageKey, .isApplicationKey]) {
            return (values.isPackage == true) || (values.isApplication == true)
        }
        return false
    }

    public static func byteCount(_ value: Int64, isDirectory: Bool) -> String {
        guard !isDirectory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func kind(for url: URL, isDirectory: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "app" { return "Application" }
        if isDirectory { return "Folder" }
        if isPackage(url) { return "\(url.pathExtension.uppercased()) package" }
        return ext.isEmpty ? "File" : "\(url.pathExtension.uppercased()) file"
    }
}
