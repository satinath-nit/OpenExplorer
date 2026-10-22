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
require(FileTextFormatter.isPackage(URL(fileURLWithPath: "/Applications/Safari.app")), ".app bundles should be recognized as packages rather than plain folders")
require(FileTextFormatter.kind(for: URL(fileURLWithPath: "/Applications/Safari.app"), isDirectory: false) == "Application", ".app bundles should format as Application")

let cocoaPermissionError = NSError(
    domain: NSCocoaErrorDomain,
    code: CocoaError.fileReadNoPermission.rawValue
)
require(
    FolderAccessDiagnostics.isPermissionDenied(cocoaPermissionError),
    "Cocoa file-read permission failures should be recognized as protected-folder access denials"
)
let wrappedPermissionError = NSError(
    domain: NSCocoaErrorDomain,
    code: CocoaError.fileReadUnknown.rawValue,
    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]
)
require(
    FolderAccessDiagnostics.isPermissionDenied(wrappedPermissionError),
    "Wrapped POSIX access failures should be recognized as protected-folder access denials"
)
require(
    FolderAccessDiagnostics.fullDiskAccessSettingsURL.absoluteString.contains("Privacy_AllFiles"),
    "The recovery action should open macOS Full Disk Access settings"
)

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

let pollingRefreshDirectory = creationTestDirectory.appendingPathComponent("polling-refresh", isDirectory: true)
try FileManager.default.createDirectory(at: pollingRefreshDirectory, withIntermediateDirectories: false)
let pollingChangeObserved = DispatchSemaphore(value: 0)
let pollingDirectoryMonitor = try DirectoryMonitor(
    url: pollingRefreshDirectory,
    pollInterval: .milliseconds(50),
    nativeEventsEnabled: false
) {
    pollingChangeObserved.signal()
}
pollingDirectoryMonitor.start()
try Data("added while the folder remains open".utf8).write(
    to: pollingRefreshDirectory.appendingPathComponent("new-file.txt")
)
require(
    pollingChangeObserved.wait(timeout: .now() + 2) == .success,
    "An open folder should detect a newly added file even when native filesystem events are unavailable"
)
pollingDirectoryMonitor.stop()

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

let operationsRoot = creationTestDirectory.appendingPathComponent("operations", isDirectory: true)
let sourceRoot = operationsRoot.appendingPathComponent("source", isDirectory: true)
let destinationRoot = operationsRoot.appendingPathComponent("destination", isDirectory: true)
try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
let sourceFile = sourceRoot.appendingPathComponent("notes.txt")
try Data("original".utf8).write(to: sourceFile)
try Data("existing".utf8).write(to: destinationRoot.appendingPathComponent("notes.txt"))
let operationEngine = FileOperationEngine()
let copyResult = operationEngine.transfer([sourceFile], to: destinationRoot, kind: .copy) { _, _ in .keepBoth }
require(copyResult.failures.isEmpty, "Copy should complete without failures")
require(copyResult.completed.first?.destination.lastPathComponent == "notes copy.txt", "Keep Both should create a predictable unique name")
require(FileManager.default.fileExists(atPath: destinationRoot.appendingPathComponent("notes copy.txt").path), "Copied item should exist")
require(operationEngine.undo(copyResult.completed).isEmpty, "Undoing a copy should succeed")
require(!FileManager.default.fileExists(atPath: destinationRoot.appendingPathComponent("notes copy.txt").path), "Undo should remove the copied item")

let sameFolderCopy = operationEngine.transfer([sourceFile], to: sourceRoot, kind: .copy) { _, _ in .keepBoth }
require(sameFolderCopy.failures.isEmpty, "Copying an item in its own folder should not fail")
require(sameFolderCopy.completed.first?.destination.lastPathComponent == "notes copy.txt", "A same-folder copy should use a Keep Both name")
require(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("notes copy.txt").path), "A same-folder Keep Both copy should create a second item")
let repeatedSameFolderCopy = operationEngine.transfer([sourceFile], to: sourceRoot, kind: .copy) { _, _ in .keepBoth }
require(repeatedSameFolderCopy.completed.first?.destination.lastPathComponent == "notes copy 2.txt", "Repeated same-folder copies should use the next available name")
require(operationEngine.undo(repeatedSameFolderCopy.completed).isEmpty, "A repeated same-folder copy should be undoable")
require(operationEngine.undo(sameFolderCopy.completed).isEmpty, "A same-folder copy should be undoable")

let moveResult = operationEngine.transfer([sourceFile], to: destinationRoot, kind: .move) { _, _ in .replace }
require(moveResult.failures.isEmpty, "Move with Replace should complete")
require(!FileManager.default.fileExists(atPath: sourceFile.path), "Move should remove the source")
require(operationEngine.undo(moveResult.completed).isEmpty, "Undoing a move should succeed")
require(FileManager.default.fileExists(atPath: sourceFile.path), "Undo should move an item back to its original location")
let restoredExistingContents = try Data(contentsOf: destinationRoot.appendingPathComponent("notes.txt"))
require(String(data: restoredExistingContents, encoding: .utf8) == "existing", "Undo should restore an item replaced during a move")

let searchableFile = operationsRoot.appendingPathComponent("uniquely-searchable-openexplorer.txt")
try Data().write(to: searchableFile)
let recursiveSearchResults = try SpotlightSearch.find(named: "uniquely-searchable-openexplorer", under: operationsRoot)
require(
    recursiveSearchResults.map { $0.standardizedFileURL.path }.contains(searchableFile.standardizedFileURL.path),
    "Recursive search should find newly created files even before Spotlight finishes indexing"
)

// Test Right-Click ZIP Compression (macOS Native & Clean Cross-Platform) + Virtual Archive Inspection
let compressSource = creationTestDirectory.appendingPathComponent("ProjectFolder", isDirectory: true)
try FileManager.default.createDirectory(at: compressSource, withIntermediateDirectories: true)
try Data("hello world".utf8).write(to: compressSource.appendingPathComponent("readme.md"))
try Data("junk".utf8).write(to: compressSource.appendingPathComponent(".DS_Store"))

let cleanZip = try ZipExtractor.compress([compressSource], in: creationTestDirectory, mode: .cleanCrossPlatform)
require(cleanZip.lastPathComponent == "ProjectFolder.zip", "Single folder compression should be named after the folder")
let secondZip = try ZipExtractor.compress([compressSource], in: creationTestDirectory, mode: .macOSNative)
require(secondZip.lastPathComponent == "ProjectFolder 2.zip", "Repeated compression should use collision-safe naming")

let archiveEntries = try ZipExtractor.listEntries(in: cleanZip)
require(archiveEntries.contains(where: { $0.path.hasSuffix("readme.md") }), "Archive listing should include readme.md")
require(!archiveEntries.contains(where: { $0.path.contains(".DS_Store") }), "Clean Cross-Platform ZIP must exclude .DS_Store")

// Test compressing a folder with broken symlinks, empty folders, and into itself
let brokenSymlinkURL = compressSource.appendingPathComponent("dangling-link")
try FileManager.default.createSymbolicLink(atPath: brokenSymlinkURL.path, withDestinationPath: "/nonexistent/target/path")
let selfCompressedZip = try ZipExtractor.compress([compressSource], in: compressSource, mode: .cleanCrossPlatform)
require(FileManager.default.fileExists(atPath: selfCompressedZip.path), "Compressing a folder with a dangling symlink or into itself should succeed")

let emptyFolder = creationTestDirectory.appendingPathComponent("EmptyDir", isDirectory: true)
try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
let emptyZip = try ZipExtractor.compress([emptyFolder], in: creationTestDirectory, mode: .cleanCrossPlatform)
require(FileManager.default.fileExists(atPath: emptyZip.path), "Compressing an empty folder in Clean Cross-Platform mode should succeed")

let singleExtractDir = creationTestDirectory.appendingPathComponent("single-extract", isDirectory: true)
try FileManager.default.createDirectory(at: singleExtractDir, withIntermediateDirectories: true)
let extractedSingleFile = try ZipExtractor.extractEntry("ProjectFolder/readme.md", from: cleanZip, to: singleExtractDir)
require(FileManager.default.fileExists(atPath: extractedSingleFile.path), "Single entry extraction should materialize the requested file")

// Test Batch Rename Engine
let renameDir = creationTestDirectory.appendingPathComponent("batch-rename", isDirectory: true)
try FileManager.default.createDirectory(at: renameDir, withIntermediateDirectories: true)
let fileA = renameDir.appendingPathComponent("IMG_100.jpg")
let fileB = renameDir.appendingPathComponent("IMG_101.jpg")
try Data("a".utf8).write(to: fileA)
try Data("b".utf8).write(to: fileB)
let numberPlan = BatchRenameEngine.preview(
    for: [fileA, fileB],
    rule: .sequentialNumbering(baseName: "photo", startNumber: 1, paddingDigits: 3, separator: "_")
)
require(numberPlan.map(\.proposedName) == ["photo_001.jpg", "photo_002.jpg"], "Sequential numbering should pad numbers")
let renameRecords = try BatchRenameEngine.apply(numberPlan)
require(renameRecords.count == 2, "Batch rename should apply both renames")
require(FileManager.default.fileExists(atPath: renameDir.appendingPathComponent("photo_001.jpg").path), "Renamed file should exist")

// Test Multi-Step Undo & Redo Stack
let undoStack = FileUndoStack(engine: operationEngine)
undoStack.record(.transfer(renameRecords))
require(undoStack.canUndo, "Undo stack should have recorded batch rename")
let undoOutcome = undoStack.undoLast()
require(undoOutcome?.failures.isEmpty == true, "Undoing batch rename via FileUndoStack should succeed")
require(FileManager.default.fileExists(atPath: fileA.path), "Original filename should be restored after undo")
require(undoStack.canRedo, "Redo should be available after undo")
let redoOutcome = undoStack.redoLast()
require(redoOutcome?.failures.isEmpty == true, "Redoing batch rename should succeed")
require(FileManager.default.fileExists(atPath: renameDir.appendingPathComponent("photo_001.jpg").path), "Redo should reapply batch rename")

// Test Checksums & File Hashing
let hashFile = creationTestDirectory.appendingPathComponent("hash-test.txt")
try Data("OpenExplorer".utf8).write(to: hashFile)
let hashes = try FileHashCalculator.computeHashes(for: hashFile)
require(hashes.sha256.count == 64 && hashes.sha1.count == 40 && hashes.md5.count == 32, "SHA-256, SHA-1, and MD5 checksums should be valid hex digests")

// Test Developer Project Badge Detection & Templates
let swiftPkgDir = creationTestDirectory.appendingPathComponent("SamplePkg", isDirectory: true)
try FileManager.default.createDirectory(at: swiftPkgDir, withIntermediateDirectories: true)
try Data().write(to: swiftPkgDir.appendingPathComponent("Package.swift"))
require(GitRepositoryInspector.projectBadge(for: swiftPkgDir) == .swiftPackage, "Folders with Package.swift should be badged as Swift Package")

let createdTemplate = try DeveloperToolsManager.createFromTemplate(DeveloperToolsManager.builtInTemplates[0], in: swiftPkgDir)
require(FileManager.default.fileExists(atPath: createdTemplate.path), "Developer template file creation should succeed")

// Test Path Autocomplete & Sibling Folders
let expandedHome = PathAutocompleteEngine.expandPath("~/Documents")
require(expandedHome.hasPrefix("/"), "Tilde path should expand to an absolute path")
let siblings = PathAutocompleteEngine.siblingDirectories(of: swiftPkgDir)
require(siblings.contains(where: { $0.lastPathComponent == "SamplePkg" }), "Sibling directory discovery should list neighboring folders")

// Test Command Palette & Fuzzy Navigation Engine (⌘K / ⌘P)
require(CommandPaletteEngine.fuzzyScore(query: "clnzip", against: "Compress Clean ZIP") != nil, "Fuzzy subsequence query should match 'Compress Clean ZIP'")
require(CommandPaletteEngine.fuzzyScore(query: "pkg", against: "Package.swift")! > CommandPaletteEngine.fuzzyScore(query: "pkg", against: "some-other-package-file.txt")!, "Prefix/boundary match should outscore deep match")
let samplePaletteItems: [CommandPaletteItem] = [
    CommandPaletteItem(id: "cmd1", title: "Compress Clean ZIP", subtitle: "Strip .DS_Store", category: "Archive", symbolName: "sparkles", target: .command("clean")),
    CommandPaletteItem(id: "folder1", title: "SamplePkg", subtitle: swiftPkgDir.path, category: "Folder", symbolName: "folder.fill", target: .folder(swiftPkgDir))
]
let commandRanked = CommandPaletteEngine.rank(items: samplePaletteItems, query: ">zip", mode: .fuzzyNavigation)
require(commandRanked.count == 1 && commandRanked.first?.id == "cmd1", "Leading '>' should filter strictly to commands even in fuzzy navigation mode")
let nestedDiscovered = CommandPaletteEngine.discoverNestedItems(under: creationTestDirectory, maxDepth: 3)
require(nestedDiscovered.contains(where: { $0.relativePath.contains("Package.swift") }), "Nested fuzzy discovery should find files inside subdirectories")

// Test .gitignore Awareness, Dimming Matcher & Default Recursive Search Exclusion
let gitIgnoreTestRoot = creationTestDirectory.appendingPathComponent("gitignore-repo", isDirectory: true)
let nodeModulesDir = gitIgnoreTestRoot.appendingPathComponent("node_modules/pkg", isDirectory: true)
let dotBuildDir = gitIgnoreTestRoot.appendingPathComponent(".build/arm64", isDirectory: true)
let distDir = gitIgnoreTestRoot.appendingPathComponent("dist", isDirectory: true)
let targetDir = gitIgnoreTestRoot.appendingPathComponent("target", isDirectory: true)
let srcDir = gitIgnoreTestRoot.appendingPathComponent("src", isDirectory: true)
for dir in [nodeModulesDir, dotBuildDir, distDir, targetDir, srcDir] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
let gitignoreContent = """
# Build and log outputs
*.log
/secret-config.json
custom-ignored-dir/
!important.log
"""
try Data(gitignoreContent.utf8).write(to: gitIgnoreTestRoot.appendingPathComponent(".gitignore"))
let ignoredDepFile = nodeModulesDir.appendingPathComponent("searchable-token-xyz.js")
let ignoredBuildFile = dotBuildDir.appendingPathComponent("searchable-token-xyz.o")
let ignoredDistFile = distDir.appendingPathComponent("searchable-token-xyz.bundle.js")
let ignoredTargetFile = targetDir.appendingPathComponent("searchable-token-xyz.rlib")
let ignoredLogFile = gitIgnoreTestRoot.appendingPathComponent("debug-searchable-token-xyz.log")
let unignoredImportantLog = gitIgnoreTestRoot.appendingPathComponent("important.log")
let trackedSrcFile = srcDir.appendingPathComponent("searchable-token-xyz.swift")
for file in [ignoredDepFile, ignoredBuildFile, ignoredDistFile, ignoredTargetFile, ignoredLogFile, unignoredImportantLog, trackedSrcFile] {
    try Data("sample".utf8).write(to: file)
}

let ignoreMatcher = GitIgnoreMatcher(directory: gitIgnoreTestRoot)
require(ignoreMatcher.isIgnored(gitIgnoreTestRoot.appendingPathComponent("node_modules"), isDirectory: true), "node_modules should be recognized as git-ignored")
require(ignoreMatcher.isIgnored(gitIgnoreTestRoot.appendingPathComponent(".build"), isDirectory: true), ".build should be recognized as git-ignored")
require(ignoreMatcher.isIgnored(distDir, isDirectory: true), "dist should be recognized as git-ignored")
require(ignoreMatcher.isIgnored(targetDir, isDirectory: true), "target should be recognized as git-ignored")
require(ignoreMatcher.isIgnored(ignoredLogFile, isDirectory: false), "*.log pattern in .gitignore should mark debug log as ignored")
require(!ignoreMatcher.isIgnored(unignoredImportantLog, isDirectory: false), "!important.log negation rule should un-ignore important.log")
require(!ignoreMatcher.isIgnored(trackedSrcFile, isDirectory: false), "Regular source files should not be marked git-ignored")

let defaultFilteredSearch = try SpotlightSearch.find(named: "searchable-token-xyz", under: gitIgnoreTestRoot)
let defaultFilteredPaths = Set(defaultFilteredSearch.map { $0.standardizedFileURL.path })
require(defaultFilteredPaths.contains(trackedSrcFile.standardizedFileURL.path), "Recursive search should return non-ignored source files")
require(!defaultFilteredPaths.contains(ignoredDepFile.standardizedFileURL.path), "Recursive search should exclude node_modules by default")
require(!defaultFilteredPaths.contains(ignoredBuildFile.standardizedFileURL.path), "Recursive search should exclude .build by default")
require(!defaultFilteredPaths.contains(ignoredDistFile.standardizedFileURL.path), "Recursive search should exclude dist by default")
require(!defaultFilteredPaths.contains(ignoredTargetFile.standardizedFileURL.path), "Recursive search should exclude target by default")
require(!defaultFilteredPaths.contains(ignoredLogFile.standardizedFileURL.path), "Recursive search should exclude .gitignore matched files by default")

let unfilteredSearch = try SpotlightSearch.find(named: "searchable-token-xyz", under: gitIgnoreTestRoot, excludeGitIgnored: false)
let unfilteredPaths = Set(unfilteredSearch.map { $0.standardizedFileURL.path })
require(unfilteredPaths.contains(ignoredDepFile.standardizedFileURL.path) && unfilteredPaths.contains(ignoredLogFile.standardizedFileURL.path), "Disabling excludeGitIgnored should include ignored files in recursive search")

print("OpenExplorerCore checks passed")
