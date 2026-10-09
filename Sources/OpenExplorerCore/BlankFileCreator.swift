import Foundation

public enum BlankFileCreator {
    public enum CreationError: LocalizedError {
        case invalidName
        case itemAlreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Enter a file name without slashes, such as notes.txt or page.html."
            case .itemAlreadyExists(let name):
                return "An item named “\(name)” already exists in this folder."
            }
        }
    }

    @discardableResult
    public static func create(named proposedName: String, in directory: URL) throws -> URL {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw CreationError.invalidName
        }

        let destination = directory.appendingPathComponent(name, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CreationError.itemAlreadyExists(name)
        }
        try Data().write(to: destination, options: .withoutOverwriting)
        return destination
    }
}
