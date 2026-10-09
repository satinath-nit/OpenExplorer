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

print("OpenExplorerCore checks passed")
