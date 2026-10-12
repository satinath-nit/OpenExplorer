import Foundation
import OpenExplorerCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

var history = BrowserHistory(initialURL: URL(fileURLWithPath: "/one"))
history.visit(URL(fileURLWithPath: "/two"))
history.visit(URL(fileURLWithPath: "/three"))
require(history.back()?.path == "/two", "Back navigation should return /two")
require(history.canGoForward, "Forward navigation should be available")
history.visit(URL(fileURLWithPath: "/four"))
require(history.current.path == "/four", "New visit should become current")
require(!history.canGoForward, "A new visit should drop the forward branch")
require(history.entries.map(\.path) == ["/one", "/two", "/four"], "History branch should be replaced")

require(FileTextFormatter.byteCount(1_024, isDirectory: false).contains("KB"), "File size should be human readable")
require(FileTextFormatter.byteCount(1_024, isDirectory: true) == "—", "Folders should not show a byte size")
require(FileTextFormatter.kind(for: URL(fileURLWithPath: "/tmp/report.pdf"), isDirectory: false) == "PDF file", "Extensions should format as file kinds")
require(FileTextFormatter.kind(for: URL(fileURLWithPath: "/tmp/docs"), isDirectory: true) == "Folder", "Directories should format as folders")

let olderFolder = FileSortEntry(
    identifier: "folder",
    name: "Archive",
    isDirectory: true,
    modified: Date(timeIntervalSince1970: 100),
    created: Date(timeIntervalSince1970: 100),
    kind: "Folder",
    size: 0
)
let newestDownload = FileSortEntry(
    identifier: "newest",
    name: "new-download.png",
    isDirectory: false,
    modified: Date(timeIntervalSince1970: 300),
    created: Date(timeIntervalSince1970: 300),
    kind: "PNG image",
    size: 10
)
let middleFile = FileSortEntry(
    identifier: "middle",
    name: "notes.txt",
    isDirectory: false,
    modified: Date(timeIntervalSince1970: 200),
    created: Date(timeIntervalSince1970: 200),
    kind: "Text file",
    size: 20
)
let mixedEntries = [olderFolder, middleFile, newestDownload]
require(FileItemSorter.defaultKey == .modified, "Date Modified should be the default sort")
require(!FileItemSorter.defaultAscending, "Default Date Modified sorting should put newest items first")
require(
    FileItemSorter.sorted(mixedEntries, by: .created, ascending: false).map(\.name) == ["new-download.png", "notes.txt", "Archive"],
    "Newest downloaded file should appear first when Date Created is descending"
)
require(
    FileItemSorter.sorted(mixedEntries, by: .modified, ascending: false).map(\.name) == ["new-download.png", "notes.txt", "Archive"],
    "Newest downloaded file should appear first when Date Modified is descending"
)
require(
    FileItemSorter.sorted(mixedEntries, by: .name, ascending: true).first?.name == "Archive",
    "Name sorting should continue to group folders first"
)

let creationTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("OpenExplorerCoreChecks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: creationTestDirectory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: creationTestDirectory) }
let blankFile = try BlankFileCreator.create(named: "example.json", in: creationTestDirectory)
require(FileManager.default.fileExists(atPath: blankFile.path), "Blank file creation should create the requested file type")
let blankFileContents = try Data(contentsOf: blankFile)
require(blankFileContents.isEmpty, "A new blank file should contain no data")
do {
    _ = try BlankFileCreator.create(named: "example.json", in: creationTestDirectory)
    require(false, "Blank file creation should not overwrite an existing item")
} catch BlankFileCreator.CreationError.itemAlreadyExists {
    // Expected.
}
do {
    _ = try BlankFileCreator.create(named: "../outside.txt", in: creationTestDirectory)
    require(false, "Blank file creation should reject paths outside the current folder")
} catch BlankFileCreator.CreationError.invalidName {
    // Expected.
}

let liveRefreshDirectory = creationTestDirectory.appendingPathComponent("live-refresh", isDirectory: true)
try FileManager.default.createDirectory(at: liveRefreshDirectory, withIntermediateDirectories: false)
let changeObserved = DispatchSemaphore(value: 0)
let directoryMonitor = try DirectoryMonitor(url: liveRefreshDirectory) {
    changeObserved.signal()
}
directoryMonitor.start()
try FileManager.default.createDirectory(
    at: liveRefreshDirectory.appendingPathComponent("externally-created-folder", isDirectory: true),
    withIntermediateDirectories: false
)
require(
    changeObserved.wait(timeout: .now() + 2) == .success,
    "External folder creation should notify OpenExplorer without a manual refresh"
)
directoryMonitor.stop()

let zipSource = creationTestDirectory.appendingPathComponent("zip-source", isDirectory: true)
try FileManager.default.createDirectory(at: zipSource, withIntermediateDirectories: false)
try Data("OpenExplorer ZIP check".utf8).write(to: zipSource.appendingPathComponent("payload.txt"))
let zipArchive = creationTestDirectory.appendingPathComponent("sample.zip")
let createArchive = Process()
createArchive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
createArchive.arguments = ["-c", "-k", "--keepParent", zipSource.path, zipArchive.path]
try createArchive.run()
createArchive.waitUntilExit()
require(createArchive.terminationStatus == 0, "ZIP test fixture should be created")
let extractedFolder = try ZipExtractor.extract(zipArchive)
require(
    FileManager.default.fileExists(atPath: extractedFolder.appendingPathComponent("zip-source/payload.txt").path),
    "ZIP extraction should create a visible neighboring folder without Finder"
)
require(
    ZipExtractor.uniqueDestination(for: zipArchive).lastPathComponent == "sample 2",
    "Repeated ZIP extraction should choose a non-destructive folder name"
)

print("OpenExplorerCore checks passed")
