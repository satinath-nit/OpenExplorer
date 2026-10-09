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

print("OpenExplorerCore checks passed")
