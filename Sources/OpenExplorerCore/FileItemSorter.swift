import Foundation

public enum FileSortKey: String, Sendable {
    case name
    case modified
    case created
    case kind
    case size
}

public struct FileSortEntry {
    public let identifier: String
    public let name: String
    public let isDirectory: Bool
    public let modified: Date?
    public let created: Date?
    public let kind: String
    public let size: Int64

    public init(identifier: String, name: String, isDirectory: Bool, modified: Date?, created: Date?, kind: String, size: Int64) {
        self.identifier = identifier
        self.name = name
        self.isDirectory = isDirectory
        self.modified = modified
        self.created = created
        self.kind = kind
        self.size = size
    }
}

public enum FileItemSorter {
    public static let defaultKey: FileSortKey = .modified
    public static let defaultAscending = false

    public static func sorted(_ entries: [FileSortEntry], by key: FileSortKey, ascending: Bool) -> [FileSortEntry] {
        entries.sorted { left, right in
            // Explorer-style folder grouping is useful for a name sort, but it
            // must not override date/size/type sorting. A newly downloaded file
            // should therefore lead an explicitly descending date sort.
            if key == .name, left.isDirectory != right.isDirectory { return left.isDirectory }
            let order: ComparisonResult
            switch key {
            case .modified:
                order = (left.modified ?? .distantPast).compare(right.modified ?? .distantPast)
            case .created:
                order = (left.created ?? .distantPast).compare(right.created ?? .distantPast)
            case .kind:
                order = left.kind.localizedStandardCompare(right.kind)
            case .size:
                order = left.size == right.size ? .orderedSame : (left.size < right.size ? .orderedAscending : .orderedDescending)
            case .name:
                order = left.name.localizedStandardCompare(right.name)
            }
            if order == .orderedSame {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
