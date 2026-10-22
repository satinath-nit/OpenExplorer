import AppKit
import Foundation
import OpenExplorerCore
import QuickLookUI
import UniformTypeIdentifiers

private struct FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    var isPackage: Bool = false
    let size: Int64
    let modified: Date?
    let created: Date?
    let tags: [String]
    let cloudStatus: CloudItemStatus
    let projectBadge: ProjectBadgeKind?
    let gitState: GitFileState?
    var isGitIgnored: Bool = false

    var kind: String {
        if isDirectory, let projectBadge {
            return "Folder (\(projectBadge.rawValue))"
        }
        return FileTextFormatter.kind(for: url, isDirectory: isDirectory)
    }

    func sizeText(calculatedFolderSize: Int64? = nil) -> String {
        if isDirectory || isPackage {
            if let calculatedFolderSize {
                return ByteCountFormatter.string(fromByteCount: calculatedFolderSize, countStyle: .file)
            }
            return "—"
        }
        return FileTextFormatter.byteCount(size, isDirectory: false)
    }

    var sizeText: String { sizeText(calculatedFolderSize: nil) }
}

private struct ItemDetails: Sendable {
    let size: Int64
    let owner: String
    let group: String
    let permissions: Int
    let isLocked: Bool
    let hashes: FileHashes?
}

private struct TrashRecord: Codable, Sendable {
    let trashedPath: String
    let originalPath: String
}

private struct BrowserTab {
    var history: BrowserHistory
    var title: String {
        let name = history.current.lastPathComponent
        return name.isEmpty ? "Macintosh HD" : name
    }
}

private enum BrowserViewMode: Int, CaseIterable {
    case extraLargeIcons
    case largeIcons
    case mediumIcons
    case smallIcons
    case list
    case details
    case tiles
    case content

    var title: String {
        switch self {
        case .extraLargeIcons: "Extra large icons"
        case .largeIcons: "Large icons"
        case .mediumIcons: "Medium icons"
        case .smallIcons: "Small icons"
        case .list: "List"
        case .details: "Details"
        case .tiles: "Tiles"
        case .content: "Content"
        }
    }

    var usesIconGrid: Bool {
        switch self {
        case .extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons, .tiles: true
        case .list, .details, .content: false
        }
    }
}

@MainActor
final class BrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let fileManager = FileManager.default
    private var tabs: [BrowserTab]
    private var activeTabIndex = 0
    private var items: [FileItem] = []
    private var visibleItems: [FileItem] = []
    private var sidebarURLs: [ObjectIdentifier: URL] = [:]
    private var tabIndexes: [ObjectIdentifier: Int] = [:]
    private var sidebarButtons: [NSButton] = []
    private var favoriteURLs: [URL] = []
    private var recentLocations: [URL] = []
    private var cutURLs: Set<URL> = []
    private var checkedURLs: Set<URL> = []
    private var showHiddenFiles = false
    private var activeTagFilter: String?
    private var groupMode: FileGroupMode = .none
    private var calculatedFolderSizes: [String: Int64] = [:]
    private var gitSummary: GitDirectorySummary?
    private var gitIgnoreMatcher: GitIgnoreMatcher?
    private var textEditors: [TextEditorWindowController] = []
    private var archiveBrowsers: [ArchiveBrowserWindowController] = []
    private var batchRenameController: BatchRenameWindowController?
    private var commandPaletteController: CommandPaletteWindowController?
    private var directoryMonitor: DirectoryMonitor?
    private var pendingDirectoryReload: DispatchWorkItem?
    private let fileOperations = FileOperationEngine()
    private let undoStack = FileUndoStack()
    private var lastTransferRecords: [FileTransferRecord] = []
    private var operationCancellation: FileOperationCancellation?
    private var searchTask: Task<Void, Never>?
    private var folderSizeTask: Task<Void, Never>?
    private var searchResults: [FileItem]?
    private var isShowingTrashAccessAlert = false
    var onCloseWindow: (() -> Void)?

    // Dual-pane state
    private var isDualPaneVisible = false
    private var secondaryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    private var secondaryItems: [FileItem] = []
    private let secondaryPaneContainer = AppearanceSurfaceView()
    private let secondaryPathLabel = NSTextField(labelWithString: "")
    private let secondaryTableView = NSTableView()
    private let dualPaneSplitView = NSSplitView()

    private var trashURL: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }
    private var springLoadWorkItem: DispatchWorkItem?
    private var springLoadURL: URL?
    private var trashRecords: [TrashRecord] = {
        guard let data = UserDefaults.standard.data(forKey: "trashRecordsV1") else { return [] }
        return (try? JSONDecoder().decode([TrashRecord].self, from: data)) ?? []
    }()
    private let devicesStack = NSStackView()
    private let quickAccessStack = NSStackView()
    private let tagsStack = NSStackView()
    private var workspaceObservers: [NSObjectProtocol] = []

    private let tabStack = NSStackView()
    private let breadcrumbStack = NSStackView()
    private let breadcrumbContainer = BreadcrumbView()
    private let addressField = NSTextField()
    private let filterField = NSSearchField()
    private let searchField = NSSearchField()
    private let tableView = ExplorerTableView()
    private let tableScroll = NSScrollView()
    private let collectionView = ExplorerCollectionView()
    private let collectionScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let gitStatusBadgeLabel = NSTextField(labelWithString: "")
    private let diskUsageLabel = NSTextField(labelWithString: "")
    private let diskUsageBar = NSLevelIndicator()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let dualPaneButton = NSButton()
    private let shareButton = NSButton()
    private let compressButton = NSButton()
    private let previewToggle = NSButton()
    private let sortPopup = NSPopUpButton()
    private let groupPopup = NSPopUpButton()
    private let viewPopup = NSPopUpButton()
    private let contentSplit = NSSplitView()
    private let previewPanel = NSVisualEffectView()
    private let previewImage = NSImageView()
    private var qlPreviewView: QLPreviewView?
    private let previewName = NSTextField(labelWithString: "Select an item")
    private let previewKind = NSTextField(labelWithString: "")
    private let previewKindDetail = NSTextField(labelWithString: "—")
    private let previewSize = NSTextField(labelWithString: "—")
    private let previewDimensions = NSTextField(labelWithString: "—")
    private let previewTagsLabel = NSTextField(labelWithString: "—")
    private let previewModified = NSTextField(labelWithString: "—")
    private let previewCreated = NSTextField(labelWithString: "—")
    private let previewWhere = NSTextField(wrappingLabelWithString: "")
    private let favoritesStack = NSStackView()
    private let versionLabel = NSTextField(labelWithString: "")
    private var previewOnlyViews: [NSView] = []
    private var detailsOnlyViews: [NSView] = []
    private var viewMode = (UserDefaults.standard.object(forKey: "viewModeV2") as? Int).flatMap(BrowserViewMode.init(rawValue:)) ?? .details
    private var showsDetailsPane = UserDefaults.standard.object(forKey: "showsDetailsPane") as? Bool ?? true
    private var showsPreviewPane = UserDefaults.standard.object(forKey: "showsPreviewPane") as? Bool ?? true

    var currentDirectoryURL: URL { currentURL }
    private var currentURL: URL { tabs[activeTabIndex].history.current }

    init(initialFolderURL: URL? = nil) {
        if DemoScreenshotEnvironment.isActive {
            try? DemoScreenshotGenerator.prepareWorkspace()
        }
        let storedPath = DemoScreenshotEnvironment.isActive ? nil : UserDefaults.standard.string(forKey: "lastFolder")
        let storedURL = initialFolderURL ?? storedPath.map { URL(fileURLWithPath: $0) }
        let homeURL = DemoScreenshotEnvironment.isActive ? DemoScreenshotEnvironment.sandboxRootURL : FileManager.default.homeDirectoryForCurrentUser
        let protectedTrashURL = homeURL.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
        let initialURL = storedURL.flatMap { url -> URL? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if url.standardizedFileURL == protectedTrashURL,
               (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) == nil {
                return nil
            }
            return url
        }
            ?? (DemoScreenshotEnvironment.isActive ? DemoScreenshotEnvironment.workspaceURL : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            ?? homeURL

        if DemoScreenshotEnvironment.isActive {
            tabs = [
                BrowserTab(history: BrowserHistory(initialURL: DemoScreenshotEnvironment.workspaceURL)),
                BrowserTab(history: BrowserHistory(initialURL: DemoScreenshotEnvironment.productDesignURL)),
                BrowserTab(history: BrowserHistory(initialURL: DemoScreenshotEnvironment.releaseBuildsURL))
            ]
            secondaryURL = DemoScreenshotEnvironment.releaseBuildsURL
            favoriteURLs = DemoScreenshotEnvironment.favoriteURLs
            recentLocations = DemoScreenshotEnvironment.recentURLs
            viewMode = .details
            showsDetailsPane = true
            showsPreviewPane = true
        } else {
            tabs = [BrowserTab(history: BrowserHistory(initialURL: initialURL))]
            secondaryURL = homeURL
            if let storedFavorites = UserDefaults.standard.stringArray(forKey: "favoriteFolders") {
                favoriteURLs = storedFavorites.map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            if let storedRecent = UserDefaults.standard.stringArray(forKey: "recentFoldersV1") {
                recentLocations = storedRecent.map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenExplorer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        observeMountedVolumes()
        observePreferences()
        renderActiveTab()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func openExternalURL(_ url: URL, revealOnly: Bool = false) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue && !FileTextFormatter.isPackage(url) && !revealOnly {
            navigate(to: url)
        } else {
            let parent = url.deletingLastPathComponent()
            navigate(to: parent)
            selectItem(at: url)
        }
    }

    func appearanceSmokeTestFailures() -> [String] {
        guard let window else { return ["window is unavailable"] }
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }

        var failures: [String] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            window.appearance = appearance
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()

            let expected = NSColor.controlBackgroundColor.resolvedColor(with: appearance)
            guard let background = breadcrumbContainer.layer?.backgroundColor else {
                failures.append("breadcrumb has no background in \(appearanceName.rawValue)")
                continue
            }
            let actual = NSColor(cgColor: background) ?? .clear
            if !actual.isVisuallyEqual(to: expected) {
                failures.append("breadcrumb background is fixed in \(appearanceName.rawValue)")
            }

            if let activeTab = tabStack.arrangedSubviews[safe: activeTabIndex] as? AppearanceSurfaceView,
               let tabBackground = activeTab.layer?.backgroundColor {
                let actualTab = NSColor(cgColor: tabBackground) ?? .clear
                if !actualTab.isVisuallyEqual(to: expected) {
                    failures.append("active tab background is fixed in \(appearanceName.rawValue)")
                }
            }
        }
        return failures
    }

    func interactionSmokeTestFailures() -> [String] {
        var failures: [String] = []
        if tableView.sortDescriptors.first?.key != FileSortKey.modified.rawValue
            || tableView.sortDescriptors.first?.ascending != false
            || sortPopup.indexOfSelectedItem != 2 {
            failures.append("Date Modified is not the newest-first default sort")
        }
        if !addressField.isEditable || !addressField.isSelectable {
            failures.append("address field is not editable and selectable")
        }
        let expectedContextActions = [
            "Refresh", "Get Info", "Edit in OpenExplorer", "Copy Path Relative to Home",
            "Open in Terminal", "Compress to ZIP", "Compress Clean ZIP (No .DS_Store)",
            "Batch Rename…", "Restore from Trash"
        ]
        for title in expectedContextActions {
            if tableView.menu?.item(withTitle: title)?.target !== self {
                failures.append("list context menu is missing \(title)")
            }
            if collectionView.menu?.item(withTitle: title)?.target !== self {
                failures.append("icon context menu is missing \(title)")
            }
        }
        for menu in [tableView.menu, collectionView.menu] {
            let newMenu = menu?.item(withTitle: "New")?.submenu
            if newMenu?.item(withTitle: "New Folder")?.target !== self
                || newMenu?.item(withTitle: "New Blank File…")?.target !== self {
                failures.append("context menu is missing New Folder or New Blank File")
            }
            if menu?.item(withTitle: "Open With")?.submenu?.item(withTitle: "Choose Application…")?.target !== self {
                failures.append("Open With is missing Choose Application")
            }
        }
        if breadcrumbContainer.menu?.item(withTitle: "Copy Address")?.target !== self
            || breadcrumbContainer.menu?.item(withTitle: "Edit Address")?.target !== self {
            failures.append("address bar actions are incomplete")
        }
        if searchField.placeholderString != "Search this folder recursively" {
            failures.append("recursive search is not exposed")
        }
        if filterField.placeholderString != "Filter current folder" {
            failures.append("instant filter bar is not exposed")
        }
        if !tableView.registeredDraggedTypes.contains(.fileURL) || !collectionView.registeredDraggedTypes.contains(.fileURL) || collectionView.onFileDrop == nil {
            failures.append("internal file and folder drop targets are not registered")
        }
        if devicesStack.arrangedSubviews.isEmpty {
            failures.append("mounted volumes are not listed")
        }
        if sidebarButtons.compactMap({ $0 as? FileDropButton }).contains(where: { $0.onFileDrop == nil }) {
            failures.append("sidebar locations are not drop targets")
        }
        if tabStack.arrangedSubviews.compactMap({ $0 as? FileDropSurfaceView }).contains(where: { $0.onFileDrop == nil }) {
            failures.append("folder tabs are not drop targets")
        }
        let expectedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let expectedVersion, versionLabel.stringValue != "Version \(expectedVersion)" {
            failures.append("sidebar does not show the installed version")
        }
        let sample = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Example", isDirectory: true)
        if pathRelativeToHome(sample) != "Documents/Example" {
            failures.append("home-relative path formatting is incorrect")
        }
        focusAddress(nil)
        if addressField.isHidden || !breadcrumbStack.isHidden || addressField.stringValue != currentURL.path {
            failures.append("address editing mode does not open")
        }
        rebuildBreadcrumbs()
        return failures
    }

    func dragExportSmokeTestFailures() -> [String] {
        let originalItems = visibleItems
        defer {
            visibleItems = originalItems
            tableView.reloadData()
            collectionView.reloadData()
        }

        let folderURL = fileManager.homeDirectoryForCurrentUser
        let fileURL = Bundle.main.executableURL ?? folderURL.appendingPathComponent("OpenExplorer")
        visibleItems = [
            FileItem(url: fileURL, name: fileURL.lastPathComponent, isDirectory: false, size: 0, modified: nil, created: nil, tags: [], cloudStatus: .local, projectBadge: nil, gitState: nil),
            FileItem(url: folderURL, name: folderURL.lastPathComponent, isDirectory: true, size: 0, modified: nil, created: nil, tags: [], cloudStatus: .local, projectBadge: nil, gitState: nil)
        ]

        var failures: [String] = []
        for index in visibleItems.indices {
            let expectedURL = visibleItems[index].url.standardizedFileURL
            let tableURL = (tableView(tableView, pasteboardWriterForRow: index) as? NSURL).map { $0 as URL }?.standardizedFileURL
            if tableURL != expectedURL {
                failures.append("list view does not export \(visibleItems[index].name) as a file URL")
            }
            let collectionURL = (collectionView(collectionView, pasteboardWriterForItemAt: IndexPath(item: index, section: 0)) as? NSURL).map { $0 as URL }?.standardizedFileURL
            if collectionURL != expectedURL {
                failures.append("icon view does not export \(visibleItems[index].name) as a file URL")
            }
        }
        return failures
    }

    func listColumnTransitionSmokeTestFailures() -> [String] {
        guard let window else { return ["window is unavailable"] }
        let originalMode = viewMode
        let originalSize = window.contentView?.bounds.size ?? .zero
        defer {
            viewMode = originalMode
            window.setContentSize(originalSize)
            applyViewMode()
        }

        window.setContentSize(NSSize(width: 1800, height: 820))
        window.contentView?.layoutSubtreeIfNeeded()
        viewMode = .list
        applyViewMode()
        window.contentView?.layoutSubtreeIfNeeded()
        let before = visibleListColumnWidths()

        viewMode = .largeIcons
        applyViewMode()
        window.contentView?.layoutSubtreeIfNeeded()
        viewMode = .list
        applyViewMode()
        window.contentView?.layoutSubtreeIfNeeded()
        let after = visibleListColumnWidths()

        let changed = zip(before, after).contains { abs($0 - $1) > 2 }
        let excessiveNameWidth = after.first.map { $0 > 600 } ?? true
        guard !changed, !excessiveNameWidth else {
            return ["List widths changed from \(before.map(Int.init)) to \(after.map(Int.init))"]
        }
        return []
    }

    private func visibleListColumnWidths() -> [CGFloat] {
        ["name", "modified", "created"].compactMap { identifier in
            tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.width
        }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let shell = NSStackView()
        shell.orientation = .vertical
        shell.alignment = .leading
        shell.spacing = 0
        shell.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            shell.topAnchor.constraint(equalTo: content.topAnchor),
            shell.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let tabs = buildTabBar()
        let navigation = buildNavigationBar()
        let commands = buildCommandBar()
        configureContentSplit()

        shell.addArrangedSubview(tabs)
        shell.addArrangedSubview(makeSeparator())
        shell.addArrangedSubview(navigation)
        shell.addArrangedSubview(makeSeparator())
        shell.addArrangedSubview(commands)
        shell.addArrangedSubview(makeSeparator())
        shell.addArrangedSubview(contentSplit)

        [tabs, navigation, commands, contentSplit].forEach {
            $0.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        }
        tabs.heightAnchor.constraint(equalToConstant: 46).isActive = true
        navigation.heightAnchor.constraint(equalToConstant: 56).isActive = true
        commands.heightAnchor.constraint(equalToConstant: 50).isActive = true
        contentSplit.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
    }

    private func buildTabBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .behindWindow

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 6
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addButton.title = ""
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.toolTip = "New Tab (⌘N)"
        addButton.target = self
        addButton.action = #selector(newTab(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let quickJumpPill = NSButton(title: "⌘K  Command Palette", target: self, action: #selector(showCommandPalette(_:)))
        quickJumpPill.bezelStyle = .recessed
        quickJumpPill.font = .systemFont(ofSize: 11.5, weight: .medium)
        quickJumpPill.contentTintColor = .secondaryLabelColor
        quickJumpPill.toolTip = "Open Command Palette (⌘K) or Fuzzy Go-To (⌘P)"
        quickJumpPill.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(tabStack)
        bar.addSubview(addButton)
        bar.addSubview(quickJumpPill)
        NSLayoutConstraint.activate([
            // Leave room on the leading side for macOS window traffic-light buttons
            tabStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 80),
            tabStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            tabStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            addButton.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor, constant: 6),
            addButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28),
            quickJumpPill.leadingAnchor.constraint(greaterThanOrEqualTo: addButton.trailingAnchor, constant: 12),
            quickJumpPill.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            quickJumpPill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            quickJumpPill.heightAnchor.constraint(equalToConstant: 26)
        ])
        return bar
    }

    private func rebuildTabs() {
        tabStack.arrangedSubviews.forEach { view in
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tabIndexes.removeAll()

        for (index, tab) in tabs.enumerated() {
            let isActive = index == activeTabIndex
            let container = FileDropSurfaceView()
            container.layer?.cornerRadius = 9
            container.layer?.borderWidth = isActive ? 1 : 0
            container.fillColor = isActive ? .controlBackgroundColor : .clear
            container.strokeColor = isActive ? .separatorColor : nil
            container.destinationURL = tab.history.current
            container.onFileDrop = { [weak self] sources, destination, info in
                guard let self else { return false }
                self.runTransfer(sources, to: destination, kind: self.internalDragKind(info))
                return true
            }
            container.registerForDraggedTypes([.fileURL])

            let button = NSButton(title: tab.title, target: self, action: #selector(selectTab(_:)))
            button.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder tab")
            button.contentTintColor = .explorerFolderTint
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12.5, weight: isActive ? .semibold : .regular)
            button.contentTintColor = isActive ? .explorerFolderTint : .secondaryLabelColor
            button.lineBreakMode = .byTruncatingMiddle
            button.translatesAutoresizingMaskIntoConstraints = false
            tabIndexes[ObjectIdentifier(button)] = index

            let close = NSButton()
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
            close.title = ""
            close.isBordered = false
            close.contentTintColor = .secondaryLabelColor
            close.target = self
            close.action = #selector(closeTab(_:))
            close.tag = index
            close.isEnabled = tabs.count > 1
            close.isHidden = tabs.count <= 1
            close.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(button)
            container.addSubview(close)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 184),
                container.heightAnchor.constraint(equalToConstant: 32),
                button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 11),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                button.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
                close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
                close.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 18)
            ])
            tabStack.addArrangedSubview(container)
        }
    }

    private func buildNavigationBar() -> NSView {
        let bar = NSView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureNavButton(backButton, symbol: "chevron.left", help: "Back", action: #selector(goBack(_:)))
        configureNavButton(forwardButton, symbol: "chevron.right", help: "Forward", action: #selector(goForward(_:)))
        configureNavButton(upButton, symbol: "arrow.up", help: "Up", action: #selector(goUp(_:)))

        breadcrumbContainer.layer?.cornerRadius = 8
        breadcrumbContainer.layer?.borderWidth = 1
        breadcrumbContainer.fillColor = .controlBackgroundColor
        breadcrumbContainer.strokeColor = .separatorColor
        breadcrumbContainer.translatesAutoresizingMaskIntoConstraints = false

        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.spacing = 2
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbContainer.addSubview(breadcrumbStack)

        addressField.isHidden = true
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.font = .systemFont(ofSize: 13)
        addressField.placeholderString = "/path/to/folder"
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))
        addressField.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbContainer.addSubview(addressField)

        let recentButton = NSButton()
        recentButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Recent locations")
        recentButton.title = ""
        recentButton.isBordered = false
        recentButton.refusesFirstResponder = true
        recentButton.toolTip = "Recent folders & path completions"
        recentButton.target = self
        recentButton.action = #selector(showRecentLocationsMenu(_:))
        recentButton.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbContainer.addSubview(recentButton)

        let editAddress = NSButton()
        editAddress.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit address")
        editAddress.title = ""
        editAddress.isBordered = false
        editAddress.refusesFirstResponder = true
        editAddress.toolTip = "Edit or copy address (Command-L)"
        editAddress.target = self
        editAddress.action = #selector(focusAddress(_:))
        editAddress.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbContainer.addSubview(editAddress)

        let addressMenu = NSMenu()
        let copyAddress = addressMenu.addItem(withTitle: "Copy Address", action: #selector(copyCurrentAddress(_:)), keyEquivalent: "")
        copyAddress.target = self
        let copyRelativeAddress = addressMenu.addItem(withTitle: "Copy Address Relative to Home", action: #selector(copyCurrentAddressRelativeToHome(_:)), keyEquivalent: "")
        copyRelativeAddress.target = self
        addressMenu.addItem(.separator())
        let editAddressItem = addressMenu.addItem(withTitle: "Edit Address", action: #selector(focusAddress(_:)), keyEquivalent: "")
        editAddressItem.target = self
        breadcrumbContainer.menu = addressMenu

        NSLayoutConstraint.activate([
            breadcrumbStack.leadingAnchor.constraint(equalTo: breadcrumbContainer.leadingAnchor, constant: 10),
            breadcrumbStack.trailingAnchor.constraint(lessThanOrEqualTo: recentButton.leadingAnchor, constant: -6),
            breadcrumbStack.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: breadcrumbContainer.leadingAnchor, constant: 10),
            addressField.trailingAnchor.constraint(equalTo: recentButton.leadingAnchor, constant: -6),
            addressField.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            recentButton.trailingAnchor.constraint(equalTo: editAddress.leadingAnchor, constant: -4),
            recentButton.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            recentButton.widthAnchor.constraint(equalToConstant: 22),
            recentButton.heightAnchor.constraint(equalToConstant: 22),
            editAddress.trailingAnchor.constraint(equalTo: breadcrumbContainer.trailingAnchor, constant: -8),
            editAddress.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            editAddress.widthAnchor.constraint(equalToConstant: 22),
            editAddress.heightAnchor.constraint(equalToConstant: 22)
        ])

        breadcrumbContainer.onBackgroundClick = { [weak self] in
            self?.focusAddress(nil)
        }

        filterField.placeholderString = "Filter current folder"
        filterField.delegate = self
        filterField.controlSize = .regular
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        searchField.placeholderString = "Search this folder recursively"
        searchField.delegate = self
        searchField.controlSize = .regular
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 215).isActive = true

        let navCluster = AppearanceSurfaceView()
        navCluster.fillColor = .controlBackgroundColor
        navCluster.strokeColor = .separatorColor
        navCluster.layer?.cornerRadius = 8
        navCluster.layer?.borderWidth = 1
        let navButtonsStack = NSStackView(views: [backButton, forwardButton, upButton])
        navButtonsStack.orientation = .horizontal
        navButtonsStack.spacing = 2
        navButtonsStack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        navButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        navCluster.addSubview(navButtonsStack)
        NSLayoutConstraint.activate([
            navButtonsStack.leadingAnchor.constraint(equalTo: navCluster.leadingAnchor),
            navButtonsStack.trailingAnchor.constraint(equalTo: navCluster.trailingAnchor),
            navButtonsStack.topAnchor.constraint(equalTo: navCluster.topAnchor),
            navButtonsStack.bottomAnchor.constraint(equalTo: navCluster.bottomAnchor),
            navCluster.heightAnchor.constraint(equalToConstant: 34)
        ])

        [navCluster, breadcrumbContainer, filterField, searchField].forEach(stack.addArrangedSubview)
        breadcrumbContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        breadcrumbContainer.heightAnchor.constraint(equalToConstant: 34).isActive = true

        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        return bar
    }

    private func buildCommandBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .headerView
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let newButton = commandButton("New", symbol: "plus.circle.fill", help: "Create a folder or file from template", action: #selector(showNewMenu(_:)), labeled: true)
        newButton.contentTintColor = .controlAccentColor

        let cut = commandButton("", symbol: "scissors", help: "Cut (⌘X)", action: #selector(cutSelection(_:)))
        let copy = commandButton("", symbol: "doc.on.doc", help: "Copy (⌘C)", action: #selector(copySelection(_:)))
        let paste = commandButton("", symbol: "clipboard", help: "Paste (⌘V)", action: #selector(paste(_:)))
        let rename = commandButton("", symbol: "character.cursor.ibeam", help: "Rename (Return / F2) or Batch Rename", action: #selector(smartRenameOrBatchRename(_:)))
        let trash = commandButton("", symbol: "trash", help: "Move to Trash (⌘⌫)", action: #selector(trashSelection(_:)))
        let clipboardGroup = makeToolbarPillGroup([cut, copy, paste, rename, trash])

        compressButton.title = "ZIP"
        compressButton.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Compress to ZIP")
        compressButton.imagePosition = .imageLeading
        compressButton.bezelStyle = .recessed
        compressButton.isBordered = false
        compressButton.font = .systemFont(ofSize: 12, weight: .medium)
        compressButton.target = self
        compressButton.action = #selector(compressSelectionToZip(_:))
        compressButton.toolTip = "Compress selected items to a ZIP archive"

        shareButton.title = "Share"
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareButton.imagePosition = .imageLeading
        shareButton.bezelStyle = .recessed
        shareButton.isBordered = false
        shareButton.font = .systemFont(ofSize: 12, weight: .medium)
        shareButton.target = self
        shareButton.action = #selector(shareSelection(_:))
        shareButton.toolTip = "Share via AirDrop, Mail, Messages…"
        let archiveShareGroup = makeToolbarPillGroup([compressButton, shareButton])

        sortPopup.addItems(withTitles: ["Sort: Name", "Name: Z–A", "Date Modified", "Date Created", "Size"])
        sortPopup.bezelStyle = .texturedRounded
        sortPopup.controlSize = .regular
        sortPopup.font = .systemFont(ofSize: 12, weight: .medium)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))

        groupPopup.addItems(withTitles: FileGroupMode.allCases.map(\.title))
        groupPopup.bezelStyle = .texturedRounded
        groupPopup.controlSize = .regular
        groupPopup.font = .systemFont(ofSize: 12, weight: .medium)
        groupPopup.target = self
        groupPopup.action = #selector(groupModeChanged(_:))
        groupPopup.toolTip = "Group items by Date, Type, or Size"

        viewPopup.addItems(withTitles: BrowserViewMode.allCases.map { "View: \($0.title)" })
        let viewSymbols = [
            "square.fill", "square", "rectangle", "square.grid.2x2",
            "list.bullet", "list.bullet.rectangle", "rectangle.grid.1x2", "list.bullet.indent"
        ]
        for (index, symbol) in viewSymbols.enumerated() {
            viewPopup.item(at: index)?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: BrowserViewMode.allCases[index].title)
        }
        viewPopup.menu?.addItem(.separator())
        viewPopup.addItem(withTitle: "Details pane")
        viewPopup.item(at: BrowserViewMode.allCases.count + 1)?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Details pane")
        viewPopup.addItem(withTitle: "Preview pane")
        viewPopup.item(at: BrowserViewMode.allCases.count + 2)?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview pane")
        viewPopup.bezelStyle = .texturedRounded
        viewPopup.controlSize = .regular
        viewPopup.font = .systemFont(ofSize: 12, weight: .medium)
        viewPopup.target = self
        viewPopup.action = #selector(viewModeChanged(_:))
        viewPopup.toolTip = "Change file view"
        refreshViewMenu()

        let hidden = commandButton("Hidden", symbol: "eye.slash", help: "Show hidden files", action: #selector(toggleHidden(_:)), labeled: true)
        hidden.setButtonType(.toggle)
        let reload = commandButton("", symbol: "arrow.clockwise", help: "Refresh", action: #selector(reload(_:)))
        let quickLook = commandButton("", symbol: "eye", help: "Quick Look (Space / ⌘Y)", action: #selector(quickLook(_:)))

        dualPaneButton.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Dual-Pane Split View")
        dualPaneButton.title = "Split"
        dualPaneButton.imagePosition = .imageLeading
        dualPaneButton.bezelStyle = .recessed
        dualPaneButton.isBordered = false
        dualPaneButton.font = .systemFont(ofSize: 12, weight: .medium)
        dualPaneButton.setButtonType(.toggle)
        dualPaneButton.state = isDualPaneVisible ? .on : .off
        dualPaneButton.target = self
        dualPaneButton.action = #selector(toggleDualPane(_:))
        dualPaneButton.toolTip = "Toggle Dual-Pane Split View (⌥⌘P)"

        previewToggle.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Details pane")
        previewToggle.title = ""
        previewToggle.bezelStyle = .recessed
        previewToggle.isBordered = false
        previewToggle.setButtonType(.toggle)
        previewToggle.state = showsDetailsPane ? .on : .off
        previewToggle.target = self
        previewToggle.action = #selector(togglePreview(_:))
        previewToggle.toolTip = "Show details pane"
        let rightGroup = makeToolbarPillGroup([reload, hidden, dualPaneButton, quickLook, previewToggle])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [newButton, clipboardGroup, archiveShareGroup, sortPopup, groupPopup, viewPopup, spacer, rightGroup]
            .forEach(stack.addArrangedSubview)

        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        return bar
    }

    private func makeToolbarPillGroup(_ views: [NSView]) -> NSView {
        let surface = AppearanceSurfaceView()
        surface.fillColor = .controlBackgroundColor
        surface.strokeColor = .separatorColor
        surface.layer?.cornerRadius = 8
        surface.layer?.borderWidth = 1
        let inner = NSStackView(views: views)
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 4
        inner.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        inner.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            inner.topAnchor.constraint(equalTo: surface.topAnchor),
            inner.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            surface.heightAnchor.constraint(equalToConstant: 32)
        ])
        return surface
    }

    private func configureContentSplit() {
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let center = buildFileArea()
        buildPreviewPanel()
        contentSplit.addArrangedSubview(sidebar)
        contentSplit.addArrangedSubview(center)
        contentSplit.addArrangedSubview(previewPanel)

        sidebar.widthAnchor.constraint(equalToConstant: 220).isActive = true
        previewPanel.widthAnchor.constraint(equalToConstant: 290).isActive = true
        contentSplit.setPosition(220, ofDividerAt: 0)
        contentSplit.setPosition(1030, ofDividerAt: 1)
    }

    private func buildSidebar() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        favoritesStack.orientation = .vertical
        favoritesStack.alignment = .leading
        favoritesStack.spacing = 3
        addSidebarSection("FAVORITES", symbol: "star.fill", color: .systemYellow, collapsibleTarget: favoritesStack, to: stack)
        stack.addArrangedSubview(favoritesStack)
        favoritesStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildFavorites()

        stack.addArrangedSubview(sidebarSeparator())
        quickAccessStack.orientation = .vertical
        quickAccessStack.alignment = .leading
        quickAccessStack.spacing = 3
        addSidebarSection("QUICK ACCESS", collapsibleTarget: quickAccessStack, to: stack)
        stack.addArrangedSubview(quickAccessStack)
        quickAccessStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addKnownFolder("Applications", symbol: "macwindow", color: .systemBlue, directory: .applicationDirectory, domain: .localDomainMask, to: quickAccessStack)
        addKnownFolder("Desktop", symbol: "desktopcomputer", color: .systemTeal, directory: .desktopDirectory, to: quickAccessStack)
        addKnownFolder("Documents", symbol: "doc.text", color: .systemBlue, directory: .documentDirectory, to: quickAccessStack)
        addKnownFolder("Downloads", symbol: "arrow.down.circle", color: .systemGreen, directory: .downloadsDirectory, to: quickAccessStack)
        addKnownFolder("Movies", symbol: "film", color: .systemPink, directory: .moviesDirectory, to: quickAccessStack)
        addKnownFolder("Music", symbol: "music.note", color: .systemRed, directory: .musicDirectory, to: quickAccessStack)
        addKnownFolder("Pictures", symbol: "photo", color: .systemPurple, directory: .picturesDirectory, to: quickAccessStack)

        stack.addArrangedSubview(sidebarSeparator())
        addSidebarSection("CLOUD & DEVICES", collapsibleTarget: devicesStack, to: stack)
        if DemoScreenshotEnvironment.isActive {
            addSidebarLocation("iCloud Drive", symbol: "icloud.fill", color: .systemCyan, url: DemoScreenshotEnvironment.sandboxRootURL, to: stack)
        } else {
            for provider in CloudStorageInspector.discoveredCloudRoots(fileManager: fileManager) {
                let tint: NSColor = provider.name == "iCloud Drive" ? .systemCyan : .systemBlue
                addSidebarLocation(provider.name, symbol: provider.symbol, color: tint, url: provider.url, to: stack)
            }
        }
        let homeTitle = DemoScreenshotEnvironment.isActive ? DemoScreenshotEnvironment.demoUserName : NSUserName()
        let homeLocationURL = DemoScreenshotEnvironment.isActive ? DemoScreenshotEnvironment.sandboxRootURL : fileManager.homeDirectoryForCurrentUser
        addSidebarLocation(homeTitle, symbol: "house", color: .systemOrange, url: homeLocationURL, to: stack)
        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 3
        stack.addArrangedSubview(devicesStack)
        devicesStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildMountedVolumes()

        stack.addArrangedSubview(sidebarSeparator())
        tagsStack.orientation = .vertical
        tagsStack.alignment = .leading
        tagsStack.spacing = 2
        addSidebarSection("FINDER TAGS", symbol: "tag.fill", color: .systemGreen, collapsibleTarget: tagsStack, to: stack)
        stack.addArrangedSubview(tagsStack)
        tagsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildSidebarTags()

        let connect = NSButton(title: "Connect to Server…", target: self, action: #selector(connectToServer(_:)))
        connect.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Connect to Server")
        connect.imagePosition = .imageLeading
        connect.alignment = .left
        connect.isBordered = false
        connect.contentTintColor = .systemBlue
        stack.addArrangedSubview(connect)
        connect.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let trash = NSButton(title: "Trash", target: self, action: #selector(openTrash(_:)))
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")
        trash.imagePosition = .imageLeading
        trash.alignment = .left
        trash.isBordered = false
        let trashMenu = NSMenu()
        let emptyTrash = trashMenu.addItem(withTitle: "Empty Trash…", action: #selector(emptyTrash(_:)), keyEquivalent: "")
        emptyTrash.target = self
        trash.menu = trashMenu
        stack.addArrangedSubview(trash)
        trash.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let brand = NSButton(title: "OpenExplorer", target: self, action: #selector(openProjectWebsite(_:)))
        brand.attributedTitle = NSAttributedString(
            string: "OpenExplorer",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        brand.isBordered = false
        brand.alignment = .left
        brand.toolTip = "https://github.com/satinath-nit/OpenExplorer"
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (DemoScreenshotEnvironment.isActive ? "2.1.1" : nil)
        versionLabel.stringValue = version.map { "Version \($0)" } ?? "Development build"
        versionLabel.font = .systemFont(ofSize: 9, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        let credit = NSTextField(wrappingLabelWithString: "Designed and developed by\nSatinath Mondal")
        credit.font = .systemFont(ofSize: 9)
        credit.textColor = .tertiaryLabelColor
        credit.maximumNumberOfLines = 2
        let creditStack = NSStackView(views: [brand, versionLabel, credit])
        creditStack.orientation = .vertical
        creditStack.alignment = .leading
        creditStack.spacing = 3
        stack.addArrangedSubview(creditStack)
        creditStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        return effect
    }

    private func addSidebarSection(_ title: String, symbol: String? = nil, color: NSColor? = nil, collapsibleTarget: NSView? = nil, to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
            icon.contentTintColor = color
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            row.addArrangedSubview(icon)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        row.addArrangedSubview(label)
        if let collapsibleTarget {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let collapseBtn = CollapseToggleButton(targetView: collapsibleTarget)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(collapseBtn)
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(7, after: row)
    }

    private func rebuildSidebarTags() {
        tagsStack.arrangedSubviews.forEach {
            tagsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let colors: [(FinderColorTag, NSColor)] = [
            (.red, .systemRed), (.orange, .systemOrange), (.yellow, .systemYellow),
            (.green, .systemGreen), (.blue, .systemBlue), (.purple, .systemPurple), (.gray, .systemGray)
        ]
        for (tag, nsColor) in colors {
            let btn = NSButton(title: tag.rawValue, target: self, action: #selector(filterBySidebarTag(_:)))
            btn.image = NSImage(systemSymbolName: activeTagFilter == tag.rawValue ? "checkmark.circle.fill" : "circle.fill", accessibilityDescription: tag.rawValue)
            btn.contentTintColor = nsColor
            btn.imagePosition = .imageLeading
            btn.alignment = .left
            btn.isBordered = activeTagFilter == tag.rawValue
            btn.bezelStyle = .recessed
            btn.font = .systemFont(ofSize: 12)
            tagsStack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalTo: tagsStack.widthAnchor).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
    }

    @objc private func filterBySidebarTag(_ sender: NSButton) {
        let tag = sender.title
        activeTagFilter = (activeTagFilter == tag) ? nil : tag
        rebuildSidebarTags()
        applyFilterAndSort()
    }

    private func rebuildFavorites() {
        favoritesStack.arrangedSubviews.forEach { view in
            if let button = view as? NSButton {
                sidebarURLs.removeValue(forKey: ObjectIdentifier(button))
                sidebarButtons.removeAll { $0 === button }
            }
            favoritesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if favoriteURLs.isEmpty {
            let hint = NSTextField(wrappingLabelWithString: "Right-click a folder and choose Add to Favorites.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .tertiaryLabelColor
            hint.maximumNumberOfLines = 2
            favoritesStack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: favoritesStack.widthAnchor).isActive = true
        } else {
            for (idx, favURL) in favoriteURLs.enumerated() {
                addSidebarLocation(favURL.lastPathComponent, symbol: "folder.fill", color: .explorerFolderTint, url: favURL, to: favoritesStack)
                if let button = favoritesStack.arrangedSubviews.last as? NSButton {
                    let menu = NSMenu()
                    if idx > 0 {
                        let up = menu.addItem(withTitle: "Move Up", action: #selector(moveFavoriteUp(_:)), keyEquivalent: "")
                        up.tag = idx
                        up.target = self
                    }
                    if idx + 1 < favoriteURLs.count {
                        let down = menu.addItem(withTitle: "Move Down", action: #selector(moveFavoriteDown(_:)), keyEquivalent: "")
                        down.tag = idx
                        down.target = self
                    }
                    let remove = menu.addItem(withTitle: "Remove from Favorites", action: #selector(removeFavorite(_:)), keyEquivalent: "")
                    remove.tag = idx
                    remove.target = self
                    button.menu = menu
                }
            }
        }
    }

    @objc private func moveFavoriteUp(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx > 0, favoriteURLs.indices.contains(idx) else { return }
        favoriteURLs.swapAt(idx, idx - 1)
        UserDefaults.standard.set(favoriteURLs.map(\.path), forKey: "favoriteFolders")
        rebuildFavorites()
    }

    @objc private func moveFavoriteDown(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx + 1 < favoriteURLs.count, favoriteURLs.indices.contains(idx) else { return }
        favoriteURLs.swapAt(idx, idx + 1)
        UserDefaults.standard.set(favoriteURLs.map(\.path), forKey: "favoriteFolders")
        rebuildFavorites()
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard favoriteURLs.indices.contains(idx) else { return }
        favoriteURLs.remove(at: idx)
        UserDefaults.standard.set(favoriteURLs.map(\.path), forKey: "favoriteFolders")
        rebuildFavorites()
    }

    private func addKnownFolder(_ title: String, symbol: String, color: NSColor, directory: FileManager.SearchPathDirectory, domain: FileManager.SearchPathDomainMask = .userDomainMask, to stack: NSStackView) {
        guard let url = fileManager.urls(for: directory, in: domain).first else { return }
        addSidebarLocation(title, symbol: symbol, color: color, url: url, to: stack)
    }

    private func addSidebarLocation(_ title: String, symbol: String, color: NSColor, url: URL, to stack: NSStackView) {
        let button = FileDropButton(title: "  " + title, target: self, action: #selector(sidebarLocation(_:)))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.contentTintColor = color
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .recessed
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.font = .systemFont(ofSize: 13)
        button.toolTip = url.path
        button.destinationURL = url
        button.onFileDrop = { [weak self] sources, destination, info in
            guard let self else { return false }
            guard !sources.contains(where: { destination.standardizedFileURL == $0.standardizedFileURL || destination.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { return false }
            self.runTransfer(sources, to: destination, kind: self.internalDragKind(info))
            return true
        }
        button.registerForDraggedTypes([.fileURL])
        sidebarURLs[ObjectIdentifier(button)] = url
        sidebarButtons.append(button)
        stack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        button.heightAnchor.constraint(equalToConstant: 29).isActive = true
    }

    private func oneDriveURL() -> URL? {
        let cloudRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        return (try? fileManager.contentsOfDirectory(at: cloudRoot, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.lowercased().hasPrefix("onedrive") }
    }

    private func observeMountedVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildMountedVolumes() }
            })
        }
    }

    private func observePreferences() {
        NotificationCenter.default.addObserver(
            forName: ExplorerPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadContents(preservingSelection: true)
                self?.rebuildFavorites()
                self?.rebuildTabs()
            }
        }
    }

    private func rebuildMountedVolumes() {
        devicesStack.arrangedSubviews.forEach {
            if let button = $0 as? NSButton {
        if DemoScreenshotEnvironment.isActive {
            addSidebarLocation("Macintosh HD", symbol: "internaldrive.fill", color: .systemIndigo, url: DemoScreenshotEnvironment.sandboxRootURL, to: devicesStack)
            let miniBar = NSLevelIndicator()
            miniBar.levelIndicatorStyle = .continuousCapacity
            miniBar.minValue = 0
            miniBar.maxValue = 100
            miniBar.warningValue = 82
            miniBar.criticalValue = 92
            miniBar.doubleValue = 31.4
            miniBar.controlSize = .mini
            miniBar.widthAnchor.constraint(equalToConstant: 158).isActive = true
            miniBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let capLabel = NSTextField(labelWithString: "342.8 GB free of 500 GB")
            capLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            capLabel.textColor = .tertiaryLabelColor
            let meterStack = NSStackView(views: [miniBar, capLabel])
            meterStack.orientation = .vertical
            meterStack.alignment = .leading
            meterStack.spacing = 2
            meterStack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 4, right: 4)
            devicesStack.addArrangedSubview(meterStack)
            return
        }
                sidebarURLs.removeValue(forKey: ObjectIdentifier(button))
                sidebarButtons.removeAll { $0 === button }
            }
            devicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [URL(fileURLWithPath: "/")]
        for volume in volumes.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let title = values?.volumeName ?? (volume.path == "/" ? "Macintosh HD" : volume.lastPathComponent)
            let isReadOnly = values?.volumeIsReadOnly == true
            addSidebarLocation(title, symbol: volume.path == "/" ? "internaldrive.fill" : (isReadOnly ? "opticaldiscdrive" : "externaldrive.fill"), color: volume.path == "/" ? .systemIndigo : .secondaryLabelColor, url: volume, to: devicesStack)
            if !isReadOnly,
               let total = values?.volumeTotalCapacity, total > 100 * 1_024 * 1_024,
               let avail = values?.volumeAvailableCapacityForImportantUsage, avail > 0 {
                let freeStr = ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .file)
                let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                let usedPct = max(2.0, min(100.0, Double(Int64(total) - avail) / Double(total) * 100.0))

                let miniBar = NSLevelIndicator()
                miniBar.levelIndicatorStyle = .continuousCapacity
                miniBar.minValue = 0
                miniBar.maxValue = 100
                miniBar.warningValue = 82
                miniBar.criticalValue = 92
                miniBar.doubleValue = usedPct
                miniBar.controlSize = .mini
                miniBar.widthAnchor.constraint(equalToConstant: 158).isActive = true
                miniBar.heightAnchor.constraint(equalToConstant: 6).isActive = true

                let capLabel = NSTextField(labelWithString: "\(freeStr) free of \(totalStr)")
                capLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
                capLabel.textColor = .tertiaryLabelColor

                let meterStack = NSStackView(views: [miniBar, capLabel])
                meterStack.orientation = .vertical
                meterStack.alignment = .leading
                meterStack.spacing = 2
                meterStack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 4, right: 4)
                devicesStack.addArrangedSubview(meterStack)
            }
            guard volume.path != "/", let button = devicesStack.arrangedSubviews.compactMap({ $0 as? NSButton }).last else { continue }
            let menu = NSMenu()
            let eject = menu.addItem(withTitle: "Eject \(title)", action: #selector(ejectVolume(_:)), keyEquivalent: "")
            eject.representedObject = volume
            eject.target = self
            button.menu = menu
        }
    }

    @objc private func ejectVolume(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { [weak self] in
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            catch { self?.showError("Could not eject \(url.lastPathComponent)", detail: error.localizedDescription) }
        }
    }

    @objc private func connectToServer(_ sender: Any?) {
        guard let value = prompt(title: "Connect to Server", message: "Enter an address such as smb://server/share", defaultValue: "smb://", confirm: "Connect"),
              let url = URL(string: value), let scheme = url.scheme, ["smb", "afp", "nfs", "webdav", "webdavs"].contains(scheme.lowercased()) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTrash(_ sender: Any?) {
        do {
            _ = try fileManager.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
            navigate(to: trashURL)
        } catch where FolderAccessDiagnostics.isPermissionDenied(error) {
            showTrashAccessAlert()
        } catch {
            showError("Could not open Trash", detail: error.localizedDescription)
        }
    }

    @objc private func emptyTrash(_ sender: Any?) {
        let trash = trashURL
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Empty Trash?"
        alert.informativeText = "This permanently deletes every item in your Trash and cannot be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for url in try fileManager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
                try fileManager.removeItem(at: url)
            }
            reloadContents()
        } catch where FolderAccessDiagnostics.isPermissionDenied(error) {
            showTrashAccessAlert()
        } catch {
            showError("Could not empty Trash", detail: error.localizedDescription)
        }
    }

    @objc private func restoreFromTrash(_ sender: Any?) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        var failures: [String] = []
        var fallbackDirectory: URL?
        for item in selection {
            let requested: URL
            if let record = trashRecords.last(where: { $0.trashedPath == item.url.path }) {
                requested = URL(fileURLWithPath: record.originalPath)
            } else {
                if fallbackDirectory == nil {
                    let panel = NSOpenPanel()
                    panel.title = "Choose a Restore Location"
                    panel.message = "The original location is unavailable because this item was not moved to Trash by OpenExplorer."
                    panel.prompt = "Restore Here"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = fileManager.homeDirectoryForCurrentUser
                    guard panel.runModal() == .OK, let chosen = panel.url else { return }
                    fallbackDirectory = chosen
                }
                requested = fallbackDirectory!.appendingPathComponent(item.name)
            }
            let destination = fileOperations.availableDestination(for: requested)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: item.url, to: destination)
                trashRecords.removeAll { $0.trashedPath == item.url.path }
            } catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
        if let data = try? JSONEncoder().encode(trashRecords) { UserDefaults.standard.set(data, forKey: "trashRecordsV1") }
        reloadContents()
        if !failures.isEmpty { showError("Some items could not be restored", detail: failures.joined(separator: "\n")) }
    }

    private func buildFileArea() -> NSView {
        let area = AppearanceSurfaceView()
        area.fillColor = .controlBackgroundColor
        configureTable()
        configureCollectionView()
        configureSecondaryDualPane()

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        collectionScroll.documentView = collectionView
        collectionScroll.hasVerticalScroller = true
        collectionScroll.autohidesScrollers = true
        collectionScroll.drawsBackground = false
        collectionScroll.translatesAutoresizingMaskIntoConstraints = false

        let primaryPane = NSView()
        primaryPane.translatesAutoresizingMaskIntoConstraints = false
        primaryPane.addSubview(tableScroll)
        primaryPane.addSubview(collectionScroll)
        NSLayoutConstraint.activate([
            tableScroll.leadingAnchor.constraint(equalTo: primaryPane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: primaryPane.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: primaryPane.topAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: primaryPane.bottomAnchor),
            collectionScroll.leadingAnchor.constraint(equalTo: primaryPane.leadingAnchor),
            collectionScroll.trailingAnchor.constraint(equalTo: primaryPane.trailingAnchor),
            collectionScroll.topAnchor.constraint(equalTo: primaryPane.topAnchor),
            collectionScroll.bottomAnchor.constraint(equalTo: primaryPane.bottomAnchor)
        ])

        dualPaneSplitView.isVertical = true
        dualPaneSplitView.dividerStyle = .thin
        dualPaneSplitView.translatesAutoresizingMaskIntoConstraints = false
        dualPaneSplitView.addArrangedSubview(primaryPane)
        dualPaneSplitView.addArrangedSubview(secondaryPaneContainer)
        secondaryPaneContainer.isHidden = !isDualPaneVisible

        let footer = NSVisualEffectView()
        footer.material = .headerView
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        gitStatusBadgeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        gitStatusBadgeLabel.textColor = .systemBlue
        diskUsageLabel.font = .systemFont(ofSize: 10.5)
        diskUsageLabel.textColor = .tertiaryLabelColor
        diskUsageBar.levelIndicatorStyle = .continuousCapacity
        diskUsageBar.minValue = 0
        diskUsageBar.maxValue = 100
        diskUsageBar.warningValue = 80
        diskUsageBar.criticalValue = 92
        diskUsageBar.widthAnchor.constraint(equalToConstant: 80).isActive = true
        diskUsageBar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerStack = NSStackView(views: [statusLabel, gitStatusBadgeLabel, footerSpacer, diskUsageLabel, diskUsageBar])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 10
        footerStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerStack)

        area.addSubview(dualPaneSplitView)
        area.addSubview(footer)
        NSLayoutConstraint.activate([
            dualPaneSplitView.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            dualPaneSplitView.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            dualPaneSplitView.topAnchor.constraint(equalTo: area.topAnchor),
            dualPaneSplitView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerStack.topAnchor.constraint(equalTo: footer.topAnchor),
            footerStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor)
        ])
        applyViewMode()
        return area
    }

    private func configureSecondaryDualPane() {
        secondaryPaneContainer.fillColor = .controlBackgroundColor
        let header = NSVisualEffectView()
        header.material = .headerView
        let upBtn = NSButton()
        configureNavButton(upBtn, symbol: "arrow.up", help: "Up in Secondary Pane", action: #selector(secondaryGoUp(_:)))
        let copyToRightBtn = NSButton(title: "← Copy Here (F5)", target: self, action: #selector(copySelectionToSecondaryPane(_:)))
        copyToRightBtn.bezelStyle = .recessed
        copyToRightBtn.font = .systemFont(ofSize: 11)
        let moveToRightBtn = NSButton(title: "← Move Here (F6)", target: self, action: #selector(moveSelectionToSecondaryPane(_:)))
        moveToRightBtn.bezelStyle = .recessed
        moveToRightBtn.font = .systemFont(ofSize: 11)

        secondaryPathLabel.font = .systemFont(ofSize: 12, weight: .medium)
        secondaryPathLabel.lineBreakMode = .byTruncatingMiddle
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let barStack = NSStackView(views: [upBtn, secondaryPathLabel, spacer, copyToRightBtn, moveToRightBtn])
        barStack.orientation = .horizontal
        barStack.alignment = .centerY
        barStack.spacing = 6
        barStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        barStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(barStack)

        let nameCol = tableColumn("secName", title: "Secondary Pane — Name", width: 250, min: 150)
        let sizeCol = tableColumn("secSize", title: "Size", width: 85, min: 65)
        secondaryTableView.addTableColumn(nameCol)
        secondaryTableView.addTableColumn(sizeCol)
        secondaryTableView.rowHeight = 28
        secondaryTableView.dataSource = self
        secondaryTableView.delegate = self
        secondaryTableView.target = self
        secondaryTableView.doubleAction = #selector(openSecondarySelection(_:))

        let scroll = NSScrollView()
        scroll.documentView = secondaryTableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false

        secondaryPaneContainer.addSubview(header)
        secondaryPaneContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: secondaryPaneContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: secondaryPaneContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: secondaryPaneContainer.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            barStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            barStack.topAnchor.constraint(equalTo: header.topAnchor),
            barStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: secondaryPaneContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: secondaryPaneContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: secondaryPaneContainer.bottomAnchor)
        ])
    }

    @objc func toggleDualPane(_ sender: Any?) {
        isDualPaneVisible.toggle()
        dualPaneButton.state = isDualPaneVisible ? .on : .off
        secondaryPaneContainer.isHidden = !isDualPaneVisible
        if isDualPaneVisible {
            reloadSecondaryPane()
        }
        dualPaneSplitView.adjustSubviews()
    }

    @objc func toggleDimGitIgnoredFiles(_ sender: Any?) {
        ExplorerPreferences.shared.dimGitIgnoredFiles.toggle()
    }

    @objc func toggleExcludeGitIgnoredFromSearch(_ sender: Any?) {
        ExplorerPreferences.shared.excludeGitIgnoredFromSearch.toggle()
        if !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performRecursiveSearch()
        }
    }

    private func reloadSecondaryPane() {
        secondaryPathLabel.stringValue = DemoScreenshotEnvironment.displayPath(for: secondaryURL)
        let secondaryIgnoreMatcher = ExplorerPreferences.shared.dimGitIgnoredFiles
            ? GitIgnoreMatcher(directory: secondaryURL, fileManager: fileManager)
            : nil
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .nameKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: secondaryURL,
            includingPropertiesForKeys: Array(keys),
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )) ?? []
        secondaryItems = urls.compactMap { url in
            guard var item = makeFileItem(url) else { return nil }
            if let secondaryIgnoreMatcher {
                item.isGitIgnored = secondaryIgnoreMatcher.isIgnored(url, isDirectory: item.isDirectory)
            }
            return item
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        secondaryTableView.reloadData()
    }

    @objc private func secondaryGoUp(_ sender: Any?) {
        guard secondaryURL.path != "/" else { return }
        secondaryURL = secondaryURL.deletingLastPathComponent()
        reloadSecondaryPane()
    }

    @objc private func openSecondarySelection(_ sender: Any?) {
        let row = secondaryTableView.clickedRow >= 0 ? secondaryTableView.clickedRow : secondaryTableView.selectedRow
        guard secondaryItems.indices.contains(row) else { return }
        let item = secondaryItems[row]
        if item.isDirectory {
            secondaryURL = item.url
            reloadSecondaryPane()
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func copySelectionToSecondaryPane(_ sender: Any?) {
        let sources = selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        runTransfer(sources, to: secondaryURL, kind: .copy)
    }

    @objc private func moveSelectionToSecondaryPane(_ sender: Any?) {
        let sources = selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        runTransfer(sources, to: secondaryURL, kind: .move)
    }

    private func configureTable() {
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        // Hidden columns participate unpredictably in AppKit's automatic width
        // redistribution. Keep user-visible widths stable across view-mode changes;
        // the scroll view already provides horizontal scrolling when needed.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.onKeyCommand = { [weak self] event in
            self?.handleExplorerKeyEvent(event) ?? false
        }

        let name = tableColumn("name", title: "Name", width: 390, min: 200)
        name.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        tableView.addTableColumn(name)
        let modified = tableColumn("modified", title: "Date modified", width: 180, min: 130)
        modified.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        tableView.addTableColumn(modified)
        let created = tableColumn("created", title: "Date created", width: 180, min: 130)
        created.sortDescriptorPrototype = NSSortDescriptor(key: "created", ascending: false)
        tableView.addTableColumn(created)
        let kind = tableColumn("kind", title: "Type", width: 150, min: 100)
        kind.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        tableView.addTableColumn(kind)
        let size = tableColumn("size", title: "Size", width: 100, min: 75)
        size.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tableView.addTableColumn(size)
        tableView.sortDescriptors = [
            NSSortDescriptor(
                key: FileItemSorter.defaultKey.rawValue,
                ascending: FileItemSorter.defaultAscending
            )
        ]
        tableView.menu = makeItemContextMenu(includesRevealInFinder: true)
    }

    private func configureCollectionView() {
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.onKeyCommand = { [weak self] event in
            self?.handleExplorerKeyEvent(event) ?? false
        }
        collectionView.onFileDrop = { [weak self, weak collectionView] urls, indexPath, info in
            guard let self else { return false }
            let destination: URL
            if let indexPath, self.visibleItems.indices.contains(indexPath.item), self.visibleItems[indexPath.item].isDirectory {
                destination = self.visibleItems[indexPath.item].url
            } else {
                destination = self.currentURL
            }
            guard !urls.contains(where: { destination.standardizedFileURL == $0.standardizedFileURL || destination.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { return false }
            self.runTransfer(urls, to: destination, kind: self.internalDragKind(info))
            collectionView?.needsDisplay = true
            return true
        }
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(collectionDoubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        collectionView.menu = makeItemContextMenu(includesRevealInFinder: false)
    }

    private func handleExplorerKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let winMode = ExplorerPreferences.shared.windowsShortcutsEnabled

        // Spacebar -> Quick Look
        if flags.isEmpty && event.keyCode == 49 {
            quickLook(nil)
            return true
        }
        // F2 (keyCode 120) -> Smart Rename or Batch Rename
        if winMode && event.keyCode == 120 {
            smartRenameOrBatchRename(nil)
            return true
        }
        // F5 (keyCode 96) / F6 (keyCode 97) in Dual Pane
        if isDualPaneVisible && event.keyCode == 96 {
            copySelectionToSecondaryPane(nil)
            return true
        }
        if isDualPaneVisible && event.keyCode == 97 {
            moveSelectionToSecondaryPane(nil)
            return true
        }
        // Shift + Delete (Backspace 51 or Forward Delete 117) -> Permanent Delete
        if flags == [.shift] && (event.keyCode == 51 || event.keyCode == 117) {
            permanentlyDeleteSelection(nil)
            return true
        }
        // Forward Delete (keyCode 117) -> Move to Trash
        if winMode && flags.isEmpty && event.keyCode == 117 {
            trashSelection(nil)
            return true
        }
        // Alt + Up / Left / Right / Return
        if winMode && flags == [.option] {
            switch event.keyCode {
            case 126: goUp(nil); return true
            case 123: goBack(nil); return true
            case 124: goForward(nil); return true
            case 36: showGetInfo(nil); return true
            default: break
            }
        }
        // Type-ahead quick jump (single alphanumeric character without modifiers)
        if flags.isEmpty,
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) {
            if let matchIndex = visibleItems.firstIndex(where: { $0.name.lowercased().hasPrefix(chars) }) {
                selectItem(at: visibleItems[matchIndex].url)
                return true
            }
        }
        return false
    }

    private func buildPreviewPanel() {
        previewPanel.material = .sidebar
        previewPanel.blendingMode = .withinWindow

        let heading = NSTextField(labelWithString: "INSPECTOR")
        heading.font = .systemFont(ofSize: 10.5, weight: .bold)
        heading.textColor = .secondaryLabelColor

        let previewCard = AppearanceSurfaceView()
        previewCard.fillColor = .controlBackgroundColor
        previewCard.strokeColor = .separatorColor
        previewCard.layer?.cornerRadius = 12
        previewCard.layer?.borderWidth = 1
        previewCard.translatesAutoresizingMaskIntoConstraints = false

        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(previewImage)
        NSLayoutConstraint.activate([
            previewImage.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 14),
            previewImage.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -14),
            previewImage.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 14),
            previewImage.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -14),
            previewCard.heightAnchor.constraint(equalToConstant: 190)
        ])

        previewName.font = .systemFont(ofSize: 14.5, weight: .semibold)
        previewName.alignment = .center
        previewName.lineBreakMode = .byTruncatingMiddle
        previewKind.font = .systemFont(ofSize: 11.5, weight: .medium)
        previewKind.textColor = .secondaryLabelColor
        previewKind.alignment = .center

        let quickLookAction = commandButton("Preview", symbol: "eye", help: "Quick Look (Space)", action: #selector(quickLook(_:)), labeled: true)
        let zipAction = commandButton("ZIP", symbol: "doc.zipper", help: "Compress to ZIP", action: #selector(compressSelectionToZip(_:)), labeled: true)
        let infoAction = commandButton("Info", symbol: "info.circle", help: "Get Info & Checksums (⌘I)", action: #selector(showGetInfo(_:)), labeled: true)
        let actionRow = makeToolbarPillGroup([quickLookAction, zipAction, infoAction])

        let infoCard = AppearanceSurfaceView()
        infoCard.fillColor = .controlBackgroundColor
        infoCard.strokeColor = .separatorColor
        infoCard.layer?.cornerRadius = 10
        infoCard.layer?.borderWidth = 1
        infoCard.translatesAutoresizingMaskIntoConstraints = false

        let infoGrid = NSGridView(views: [
            [detailLabel("Kind"), previewKindDetail],
            [detailLabel("Size"), previewSize],
            [detailLabel("Dimensions"), previewDimensions],
            [detailLabel("Tags"), previewTagsLabel],
            [detailLabel("Modified"), previewModified],
            [detailLabel("Created"), previewCreated],
            [detailLabel("Location"), previewWhere]
        ])
        infoGrid.rowSpacing = 9
        infoGrid.columnSpacing = 12
        infoGrid.column(at: 0).xPlacement = .trailing
        infoGrid.column(at: 1).xPlacement = .leading
        infoGrid.translatesAutoresizingMaskIntoConstraints = false
        infoCard.addSubview(infoGrid)
        NSLayoutConstraint.activate([
            infoGrid.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 12),
            infoGrid.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -12),
            infoGrid.topAnchor.constraint(equalTo: infoCard.topAnchor, constant: 12),
            infoGrid.bottomAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: -12)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(previewCard)
        stack.addArrangedSubview(previewName)
        stack.addArrangedSubview(previewKind)
        stack.addArrangedSubview(actionRow)
        stack.addArrangedSubview(infoCard)
        previewOnlyViews = [previewCard, previewName]
        detailsOnlyViews = [previewKind, actionRow, infoCard]
        previewPanel.addSubview(stack)

        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewName.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewKind.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        infoCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: previewPanel.bottomAnchor, constant: -14)
        ])
        updatePaneVisibility()
    }

    private func detailLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func renderActiveTab() {
        let url = currentURL
        if !DemoScreenshotEnvironment.isActive {
            UserDefaults.standard.set(url.path, forKey: "lastFolder")
            recordRecentLocation(url)
            restorePerFolderViewPreference(for: url)
        }
        window?.representedURL = url
        window?.title = "OpenExplorer — \(tabs[activeTabIndex].title)"
        rebuildTabs()
        rebuildBreadcrumbs()
        reloadContents()
        startMonitoringCurrentDirectory()
        updateNavigationButtons()
        updateSidebarSelection()
    }

    private func recordRecentLocation(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentLocations.removeAll { $0.standardizedFileURL == standardized }
        recentLocations.insert(standardized, at: 0)
        if recentLocations.count > 15 {
            recentLocations = Array(recentLocations.prefix(15))
        }
        if !DemoScreenshotEnvironment.isActive {
            UserDefaults.standard.set(recentLocations.map(\.path), forKey: "recentFoldersV1")
        }
    }

    private func savePerFolderViewPreference(for url: URL) {
        guard !DemoScreenshotEnvironment.isActive else { return }
        var map = (UserDefaults.standard.dictionary(forKey: "perFolderViewModeV1") as? [String: Int]) ?? [:]
        map[url.standardizedFileURL.path] = viewMode.rawValue
        UserDefaults.standard.set(map, forKey: "perFolderViewModeV1")
    }

    private func restorePerFolderViewPreference(for url: URL) {
        guard let map = UserDefaults.standard.dictionary(forKey: "perFolderViewModeV1") as? [String: Int],
              let raw = map[url.standardizedFileURL.path],
              let savedMode = BrowserViewMode(rawValue: raw),
              savedMode != viewMode else { return }
        viewMode = savedMode
        applyViewMode()
    }

    private func rebuildBreadcrumbs() {
        breadcrumbStack.arrangedSubviews.forEach { view in
            breadcrumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let displayPath = DemoScreenshotEnvironment.displayPath(for: currentURL)
        let parts = (displayPath as NSString).pathComponents
        var path = URL(fileURLWithPath: "/")
        for (index, part) in parts.enumerated() {
            if index > 0 { path.appendPathComponent(part) }
            if index > 0 {
                let chevronBtn = PathButton(title: "", target: self, action: #selector(breadcrumbSiblingChevronClicked(_:)))
                chevronBtn.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Browse sibling folders")
                chevronBtn.contentTintColor = .tertiaryLabelColor
                chevronBtn.isBordered = false
                chevronBtn.destinationURL = path
                chevronBtn.toolTip = "Click to jump to a sibling folder"
                chevronBtn.widthAnchor.constraint(equalToConstant: 14).isActive = true
                breadcrumbStack.addArrangedSubview(chevronBtn)
            }
            let isLast = index == parts.count - 1
            let title = index == 0 ? "Macintosh HD" : part
            let button = PathButton(title: title, target: self, action: #selector(breadcrumbSelected(_:)))
            if index == 0 {
                button.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Drive")
                button.imagePosition = .imageLeading
                button.contentTintColor = .secondaryLabelColor
            } else if isLast {
                button.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Current folder")
                button.imagePosition = .imageLeading
                button.contentTintColor = .explorerFolderTint
            }
            button.destinationURL = path
            button.isBordered = false
            button.font = .systemFont(ofSize: 12.5, weight: isLast ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingMiddle
            breadcrumbStack.addArrangedSubview(button)
        }
        addressField.stringValue = displayPath
        breadcrumbStack.isHidden = false
        addressField.isHidden = true
    }

    @objc private func breadcrumbSiblingChevronClicked(_ sender: PathButton) {
        guard let targetURL = sender.destinationURL else { return }
        let siblings = PathAutocompleteEngine.siblingDirectories(of: targetURL, fileManager: fileManager)
        guard !siblings.isEmpty else { return }
        let menu = NSMenu(title: "Sibling Folders")
        for sibling in siblings.prefix(40) {
            let item = menu.addItem(withTitle: sibling.lastPathComponent, action: #selector(navigateFromMenuItem(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            item.representedObject = sibling
            item.state = sibling.standardizedFileURL == targetURL.standardizedFileURL ? .on : .off
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func showRecentLocationsMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Recent Locations")
        if !addressField.isHidden {
            let completions = PathAutocompleteEngine.completions(for: addressField.stringValue, fileManager: fileManager)
            if !completions.isEmpty {
                let header = menu.addItem(withTitle: "Path Autocomplete", action: nil, keyEquivalent: "")
                header.isEnabled = false
                for match in completions {
                    let item = menu.addItem(withTitle: match.path, action: #selector(navigateFromMenuItem(_:)), keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    item.representedObject = match
                    item.target = self
                }
                menu.addItem(.separator())
            }
        }
        let header = menu.addItem(withTitle: "Recent Locations", action: nil, keyEquivalent: "")
        header.isEnabled = false
        for loc in recentLocations {
            let item = menu.addItem(withTitle: loc.path, action: #selector(navigateFromMenuItem(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            item.representedObject = loc
            item.state = loc.standardizedFileURL == currentURL.standardizedFileURL ? .on : .off
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func navigateFromMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(to: url)
    }

    private func navigate(to url: URL, recordHistory: Bool = true) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showError("Folder not found", detail: url.path)
            return
        }
        searchTask?.cancel()
        searchResults = nil
        searchField.stringValue = ""
        filterField.stringValue = ""
        if recordHistory { tabs[activeTabIndex].history.visit(url) }
        renderActiveTab()
    }

    private func reloadContents(preservingSelection: Bool = false) {
        let selectedPaths = preservingSelection ? Set(selectedItems.map { $0.url.standardizedFileURL.path }) : []
        do {
            gitSummary = (ExplorerPreferences.shared.showGitBadges || ExplorerPreferences.shared.dimGitIgnoredFiles)
                ? GitRepositoryInspector.inspect(directory: currentURL, fileManager: fileManager)
                : nil
            gitIgnoreMatcher = ExplorerPreferences.shared.dimGitIgnoredFiles
                ? GitIgnoreMatcher(
                    directory: currentURL,
                    gitIgnoredPaths: gitSummary?.ignoredPaths ?? [],
                    fileManager: fileManager
                )
                : nil
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isPackageKey, .isApplicationKey,
                .fileSizeKey, .contentModificationDateKey,
                .creationDateKey, .nameKey, .tagNamesKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
            ]
            let urls = try fileManager.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(keys),
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            items = urls.compactMap(makeFileItem)
            applyFilterAndSort()
            scheduleFolderSizeCalculationsIfNeeded()
            if isDualPaneVisible { reloadSecondaryPane() }
            if preservingSelection, !selectedPaths.isEmpty {
                let indexes = IndexSet(visibleItems.indices.filter { selectedPaths.contains(visibleItems[$0].url.standardizedFileURL.path) })
                if viewMode.usesIconGrid {
                    collectionView.selectItems(at: Set(indexes.map { IndexPath(item: $0, section: 0) }), scrollPosition: [])
                } else {
                    tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                }
                updateStatus()
                updatePreview()
            }
        } catch {
            items = []
            visibleItems = []
            tableView.reloadData()
            collectionView.reloadData()
            if currentURL.standardizedFileURL == trashURL.standardizedFileURL,
               FolderAccessDiagnostics.isPermissionDenied(error) {
                showTrashAccessAlert()
            } else {
                showError("Could not open folder", detail: error.localizedDescription)
            }
        }
    }

    private func scheduleFolderSizeCalculationsIfNeeded() {
        folderSizeTask?.cancel()
        guard ExplorerPreferences.shared.calculateFolderSizes,
              !viewMode.usesIconGrid else { return }
        let directories = visibleItems.filter { $0.isDirectory || $0.isPackage }.prefix(35).map(\.url)
        guard !directories.isEmpty else { return }
        let targetFolder = currentURL.standardizedFileURL
        folderSizeTask = Task { [weak self] in
            for dir in directories {
                guard !Task.isCancelled else { return }
                let size = await Task.detached(priority: .utility) {
                    FolderSizeCache.shared.calculateSize(for: dir, maxFiles: 12_000)
                }.value
                guard !Task.isCancelled, let self, self.currentURL.standardizedFileURL == targetFolder else { return }
                self.calculatedFolderSizes[dir.standardizedFileURL.path] = size
            }
            guard !Task.isCancelled, let self, self.currentURL.standardizedFileURL == targetFolder else { return }
            self.tableView.reloadData()
        }
    }

    private func startMonitoringCurrentDirectory() {
        directoryMonitor?.stop()
        pendingDirectoryReload?.cancel()
        let monitoredURL = currentURL.standardizedFileURL
        directoryMonitor = try? DirectoryMonitor(url: monitoredURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDirectoryReload(for: monitoredURL)
            }
        }
        directoryMonitor?.start()
    }

    private func scheduleDirectoryReload(for monitoredURL: URL) {
        guard currentURL.standardizedFileURL == monitoredURL else { return }
        pendingDirectoryReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentURL.standardizedFileURL == monitoredURL else { return }
            self.reloadContents(preservingSelection: true)
        }
        pendingDirectoryReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localFilter = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered = query.isEmpty ? items : (searchResults ?? items.filter { $0.name.localizedCaseInsensitiveContains(query) })
        if !localFilter.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(localFilter) }
        }
        if let activeTagFilter {
            filtered = filtered.filter { $0.tags.contains { $0.caseInsensitiveCompare(activeTagFilter) == .orderedSame } }
        }
        let descriptor = tableView.sortDescriptors.first
        let key = FileSortKey(rawValue: descriptor?.key ?? "name") ?? .name
        let ascending = descriptor?.ascending ?? true
        let itemsByIdentifier = Dictionary(uniqueKeysWithValues: filtered.map { ($0.url.path, $0) })
        let sortableItems = filtered.map {
            FileSortEntry(
                identifier: $0.url.path,
                name: $0.name,
                isDirectory: $0.isDirectory,
                modified: $0.modified,
                created: $0.created,
                kind: $0.kind,
                size: $0.isDirectory ? (calculatedFolderSizes[$0.url.standardizedFileURL.path] ?? 0) : $0.size
            )
        }
        let sortedEntries = FileItemSorter.sorted(sortableItems, by: key, ascending: ascending)
        if groupMode == .none {
            visibleItems = sortedEntries.compactMap { itemsByIdentifier[$0.identifier] }
        } else {
            let grouped = Dictionary(grouping: sortedEntries) { FileItemGrouper.groupTitle(for: $0, mode: groupMode) }
            let orderedKeys = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            visibleItems = orderedKeys.flatMap { grouped[$0] ?? [] }.compactMap { itemsByIdentifier[$0.identifier] }
        }
        tableView.reloadData()
        tableView.deselectAll(nil)
        collectionView.reloadData()
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        updateStatus()
        updatePreview()
    }

    private func makeFileItem(_ url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isApplicationKey,
            .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .nameKey, .tagNamesKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let rawIsDir = values.isDirectory ?? false
        let isPkg = rawIsDir && ((values.isPackage == true) || (values.isApplication == true) || FileTextFormatter.isPackage(url))
        let isDir = rawIsDir && !isPkg
        let stdPath = url.standardizedFileURL.path
        let badge = isDir ? GitRepositoryInspector.projectBadge(for: url, fileManager: fileManager) : nil
        let gitState = ExplorerPreferences.shared.showGitBadges ? gitSummary?.fileStates[stdPath] : nil
        let isIgnored = gitIgnoreMatcher?.isIgnored(url, isDirectory: isDir) ?? false
        return FileItem(
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDir,
            isPackage: isPkg,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate,
            created: values.creationDate,
            tags: values.tagNames ?? [],
            cloudStatus: CloudStorageInspector.status(for: url),
            projectBadge: badge,
            gitState: gitState,
            isGitIgnored: isIgnored
        )
    }

    private func performRecursiveSearch() {
        searchTask?.cancel()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            applyFilterAndSort()
            return
        }
        let root = currentURL
        let excludeIgnored = ExplorerPreferences.shared.excludeGitIgnoredFromSearch
        statusLabel.stringValue = "Searching \(root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent)…"
        searchTask = Task { [weak self] in
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try SpotlightSearch.find(named: query, under: root, excludeGitIgnored: excludeIgnored)
                }.value
                guard !Task.isCancelled, let self,
                      self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                      self.currentURL.standardizedFileURL == root.standardizedFileURL else { return }
                self.searchResults = urls.compactMap(self.makeFileItem)
                self.applyFilterAndSort()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.searchResults = []
                self.applyFilterAndSort()
                self.statusLabel.stringValue = "Search unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func updateNavigationButtons() {
        let history = tabs[activeTabIndex].history
        backButton.isEnabled = history.canGoBack
        forwardButton.isEnabled = history.canGoForward
        upButton.isEnabled = currentURL.path != "/"
    }

    private func updateSidebarSelection() {
        for button in sidebarButtons {
            let selected = sidebarURLs[ObjectIdentifier(button)]?.standardizedFileURL == currentURL.standardizedFileURL
            button.state = selected ? .on : .off
            button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            (button as? FileDropButton)?.isSelectedLocation = selected
        }
    }

    private func updateStatus() {
        let selected = selectedItems
        if selected.isEmpty {
            statusLabel.stringValue = "\(visibleItems.count) item\(visibleItems.count == 1 ? "" : "s")"
        } else {
            let bytes = selected.reduce(Int64(0)) { acc, item in
                acc + (item.isDirectory ? (calculatedFolderSizes[item.url.standardizedFileURL.path] ?? 0) : item.size)
            }
            let size = bytes > 0 ? " · \(FileTextFormatter.byteCount(bytes, isDirectory: false))" : ""
            statusLabel.stringValue = "\(selected.count) selected\(size) · \(visibleItems.count) items"
        }

        if let gitSummary {
            let dirtyCount = gitSummary.fileStates.count
            gitStatusBadgeLabel.stringValue = dirtyCount > 0 ? "⎇ \(gitSummary.branchName) (\(dirtyCount) changed)" : "⎇ \(gitSummary.branchName)"
            gitStatusBadgeLabel.isHidden = false
        } else {
            gitStatusBadgeLabel.stringValue = ""
            gitStatusBadgeLabel.isHidden = true
        }

        if DemoScreenshotEnvironment.isActive {
            diskUsageLabel.stringValue = "342.8 GB free of 500 GB"
            diskUsageBar.doubleValue = 31.4
            diskUsageLabel.isHidden = false
            diskUsageBar.isHidden = false
        } else if let values = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let total = values.volumeTotalCapacity, total > 0,
           let avail = values.volumeAvailableCapacityForImportantUsage {
            let usedPercent = Double(Int64(total) - avail) / Double(total) * 100.0
            let freeStr = ByteCountFormatter.string(fromByteCount: avail, countStyle: .file)
            let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            diskUsageLabel.stringValue = "\(freeStr) free of \(totalStr)"
            diskUsageBar.doubleValue = max(0, min(100, usedPercent))
            diskUsageLabel.isHidden = false
            diskUsageBar.isHidden = false
        } else {
            diskUsageLabel.isHidden = true
            diskUsageBar.isHidden = true
        }
    }

    private func updatePreview() {
        guard let item = selectedItems.first else {
            let folderCount = visibleItems.filter(\.isDirectory).count
            let fileCount = visibleItems.count - folderCount
            let totalBytes = visibleItems.reduce(Int64(0)) { acc, entry in
                acc + (entry.isDirectory ? (calculatedFolderSizes[entry.url.standardizedFileURL.path] ?? 0) : entry.size)
            }
            previewImage.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Current Folder")
            previewImage.contentTintColor = .explorerFolderTint
            previewName.stringValue = currentURL.lastPathComponent.isEmpty ? "Macintosh HD" : currentURL.lastPathComponent
            previewKind.stringValue = "\(folderCount) folder\(folderCount == 1 ? "" : "s") · \(fileCount) file\(fileCount == 1 ? "" : "s")"
            previewKindDetail.stringValue = gitSummary.map { "Folder (⎇ \($0.branchName))" } ?? "Folder"
            previewSize.stringValue = totalBytes > 0 ? FileTextFormatter.byteCount(totalBytes, isDirectory: false) : "—"
            previewDimensions.stringValue = "\(visibleItems.count) total items"
            let folderTags = FinderTagManager.tags(for: currentURL)
            previewTagsLabel.stringValue = folderTags.isEmpty ? "None" : folderTags.joined(separator: ", ")
            let currentValues = try? currentURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            previewModified.stringValue = currentValues?.contentModificationDate.map { Self.formatFriendlyDate($0) } ?? "—"
            previewCreated.stringValue = currentValues?.creationDate.map { Self.formatFriendlyDate($0) } ?? "—"
            previewWhere.stringValue = DemoScreenshotEnvironment.displayPath(for: currentURL)
            return
        }
        if item.isDirectory {
            previewImage.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            previewImage.contentTintColor = .explorerFolderTint
            previewDimensions.stringValue = "—"
        } else {
            if let cached = ThumbnailCacheService.shared.cachedThumbnail(for: item.url, size: 200) {
                previewImage.image = cached
                previewImage.contentTintColor = nil
            } else if let image = NSImage(contentsOf: item.url) {
                previewImage.image = image
                previewImage.contentTintColor = nil
            } else {
                previewImage.image = NSWorkspace.shared.icon(forFile: item.url.path)
                previewImage.contentTintColor = nil
                if ThumbnailCacheService.shared.isEligibleForThumbnail(item.url, isDirectory: false) {
                    let targetURL = item.url
                    ThumbnailCacheService.shared.requestThumbnail(for: targetURL, size: 200) { [weak self] thumb in
                        guard let self, let thumb, self.selectedItems.first?.url == targetURL else { return }
                        self.previewImage.image = thumb
                    }
                }
            }
            previewDimensions.stringValue = ThumbnailCacheService.imageDimensions(for: item.url) ?? "—"
        }
        previewName.stringValue = item.name
        previewKind.stringValue = item.isGitIgnored ? "\(item.kind) · Git Ignored" : item.kind
        previewKindDetail.stringValue = item.isGitIgnored ? "\(item.kind) (Git Ignored)" : item.kind
        previewSize.stringValue = item.sizeText(calculatedFolderSize: calculatedFolderSizes[item.url.standardizedFileURL.path])
        previewTagsLabel.stringValue = item.tags.isEmpty ? "None" : item.tags.joined(separator: ", ")
        previewModified.stringValue = item.modified.map { Self.formatFriendlyDate($0) } ?? "—"
        previewCreated.stringValue = item.created.map { Self.formatFriendlyDate($0) } ?? "—"
        previewWhere.stringValue = DemoScreenshotEnvironment.displayPath(for: item.url)
    }

    private var selectedItems: [FileItem] {
        if viewMode.usesIconGrid {
            return collectionView.selectionIndexPaths.compactMap { visibleItems.indices.contains($0.item) ? visibleItems[$0.item] : nil }
        }
        return tableView.selectedRowIndexes.compactMap { visibleItems.indices.contains($0) ? visibleItems[$0] : nil }
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window { alert.beginSheetModal(for: window) }
    }

    private func showTrashAccessAlert() {
        guard !isShowingTrashAccessAlert else { return }
        isShowingTrashAccessAlert = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "OpenExplorer Needs Full Disk Access"
        alert.informativeText = "macOS protects the Trash from third-party apps. Add OpenExplorer in System Settings > Privacy & Security > Full Disk Access, then quit and reopen OpenExplorer."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isShowingTrashAccessAlert = false
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(FolderAccessDiagnostics.fullDiskAccessSettingsURL)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func prompt(title: String, message: String, defaultValue: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transferSourcesFromPasteboard() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func destinationURL(for source: URL) -> URL {
        var destination = currentURL.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: destination.path) else { return destination }
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 2
        repeat {
            destination = currentURL.appendingPathComponent("\(base) copy \(counter)" + (ext.isEmpty ? "" : ".\(ext)"))
            counter += 1
        } while fileManager.fileExists(atPath: destination.path)
        return destination
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === secondaryTableView { return secondaryItems.count }
        return visibleItems.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ExplorerTableRowView()
        rowView.isEvenRow = row.isMultiple(of: 2)
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === secondaryTableView {
            guard secondaryItems.indices.contains(row), let column = tableColumn else { return nil }
            let item = secondaryItems[row]
            let isDimmed = item.isGitIgnored && ExplorerPreferences.shared.dimGitIgnoredFiles
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: column.identifier.rawValue == "secName" ? (item.isDirectory ? "📁 " : "📄 ") + item.name : item.sizeText)
            label.font = .systemFont(ofSize: 12)
            label.textColor = isDimmed ? .tertiaryLabelColor : .labelColor
            label.alphaValue = isDimmed ? 0.65 : 1.0
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        guard visibleItems.indices.contains(row), let column = tableColumn else { return nil }
        let item = visibleItems[row]
        let isDimmed = cutURLs.contains(item.url) || (item.isGitIgnored && ExplorerPreferences.shared.dimGitIgnoredFiles)
        let identifier = column.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 2
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = field
            cell.addSubview(field)
            if identifier.rawValue == "name" {
                let image = NSImageView()
                image.imageScaling = .scaleProportionallyDown
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = image
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 22),
                    image.heightAnchor.constraint(equalToConstant: 22),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
        }
        cell.textField?.alphaValue = isDimmed ? 0.62 : 1.0
        switch identifier.rawValue {
        case "name":
            let baseColor: NSColor = isDimmed ? .tertiaryLabelColor : .labelColor
            let nameAttr = NSMutableAttributedString()
            if ExplorerPreferences.shared.showItemCheckboxes {
                let isSel = tableView.selectedRowIndexes.contains(row)
                nameAttr.append(NSAttributedString(
                    string: isSel ? "☑  " : "☐  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: isSel ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
                    ]
                ))
            }
            nameAttr.append(NSAttributedString(
                string: item.name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: item.isDirectory ? .medium : .regular),
                    .foregroundColor: baseColor
                ]
            ))
            for tag in item.tags.prefix(3) {
                nameAttr.append(NSAttributedString(
                    string: "  ●",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                        .foregroundColor: Self.tagColor(for: tag)
                    ]
                ))
            }
            if let gitState = item.gitState {
                let gitColor: NSColor = switch gitState {
                case .modified: .systemOrange
                case .staged: .systemGreen
                case .untracked: .systemTeal
                case .conflict: .systemRed
                }
                nameAttr.append(NSAttributedString(
                    string: "   \(gitState.rawValue)",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                        .foregroundColor: gitColor
                    ]
                ))
            } else if item.isGitIgnored && ExplorerPreferences.shared.dimGitIgnoredFiles {
                nameAttr.append(NSAttributedString(
                    string: "   ignored",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]
                ))
            }
            if item.cloudStatus == .cloudOnly {
                nameAttr.append(NSAttributedString(
                    string: "  ☁︎",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.systemCyan
                    ]
                ))
            }
            if viewMode == .content {
                let modified = item.modified.map { Self.formatFriendlyDate($0) } ?? "—"
                let created = item.created.map { Self.formatFriendlyDate($0) } ?? "—"
                nameAttr.append(NSAttributedString(
                    string: "\n\(item.kind) · Modified \(modified) · Created \(created)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
            cell.textField?.attributedStringValue = nameAttr
            cell.imageView?.alphaValue = isDimmed ? 0.5 : 1.0
            if item.isDirectory {
                let symbol = item.projectBadge != nil ? "folder.fill.badge.gearshape" : "folder.fill"
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Folder")
                    ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                cell.imageView?.contentTintColor = .explorerFolderTint
            } else if let cachedThumb = ThumbnailCacheService.shared.cachedThumbnail(for: item.url, size: 24) {
                cell.imageView?.image = cachedThumb
                cell.imageView?.contentTintColor = nil
            } else {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
                cell.imageView?.contentTintColor = nil
                if ThumbnailCacheService.shared.isEligibleForThumbnail(item.url, isDirectory: false) {
                    let itemURL = item.url
                    ThumbnailCacheService.shared.requestThumbnail(for: itemURL, size: 24) { [weak cell] thumb in
                        guard let thumb else { return }
                        cell?.imageView?.image = thumb
                    }
                }
            }
        case "modified":
            cell.textField?.stringValue = item.modified.map { Self.formatFriendlyDate($0) } ?? "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
        case "created":
            cell.textField?.stringValue = item.created.map { Self.formatFriendlyDate($0) } ?? "—"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
        case "kind":
            cell.textField?.stringValue = item.kind
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .secondaryLabelColor
        case "size":
            let calc = calculatedFolderSizes[item.url.standardizedFileURL.path]
            cell.textField?.stringValue = item.sizeText(calculatedFolderSize: calc)
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .right
        default: break
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let explorerItem = ExplorerCollectionItem()
        guard visibleItems.indices.contains(indexPath.item) else { return explorerItem }
        _ = explorerItem.view
        let item = visibleItems[indexPath.item]
        let calc = calculatedFolderSizes[item.url.standardizedFileURL.path]
        let isDimmed = cutURLs.contains(item.url) || (item.isGitIgnored && ExplorerPreferences.shared.dimGitIgnoredFiles)
        explorerItem.configure(with: item, mode: viewMode, isCut: isDimmed, calculatedSize: calc)
        return explorerItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
        updatePreview()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
        updatePreview()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        updatePreview()
        if ExplorerPreferences.shared.showItemCheckboxes {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<visibleItems.count), columnIndexes: IndexSet(integer: 0))
        }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        syncSortPopup()
        applyFilterAndSort()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard visibleItems.indices.contains(row) else { return nil }
        return visibleItems[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let sources = fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        let destination = dropDestination(row: row, operation: dropOperation)
        guard !sources.contains(where: { destination.standardizedFileURL == $0.standardizedFileURL || destination.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { return [] }
        scheduleSpringLoadIfNeeded(destination, isFolderTarget: dropOperation == .on)
        return internalDragKind(info) == .move ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        springLoadWorkItem?.cancel()
        let sources = fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return false }
        runTransfer(sources, to: dropDestination(row: row, operation: dropOperation), kind: internalDragKind(info))
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard visibleItems.indices.contains(indexPath.item) else { return nil }
        return visibleItems[indexPath.item].url as NSURL
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func internalDragKind(_ info: NSDraggingInfo) -> FileTransferKind {
        let isOpenExplorerSource = info.draggingSource is ExplorerTableView || info.draggingSource is ExplorerCollectionView
        return isOpenExplorerSource && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL {
        if operation == .on, visibleItems.indices.contains(row), visibleItems[row].isDirectory { return visibleItems[row].url }
        return currentURL
    }

    private func scheduleSpringLoadIfNeeded(_ destination: URL, isFolderTarget: Bool) {
        guard isFolderTarget, destination.standardizedFileURL != currentURL.standardizedFileURL else {
            springLoadWorkItem?.cancel()
            springLoadURL = nil
            return
        }
        guard springLoadURL?.standardizedFileURL != destination.standardizedFileURL else { return }
        springLoadWorkItem?.cancel()
        springLoadURL = destination
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.springLoadURL?.standardizedFileURL == destination.standardizedFileURL else { return }
            self.navigate(to: destination)
            self.springLoadURL = nil
        }
        springLoadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField {
            performRecursiveSearch()
        } else if obj.object as? NSSearchField === filterField {
            applyFilterAndSort()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === addressField {
            breadcrumbStack.isHidden = false
            addressField.isHidden = true
        }
    }

    @objc private func sidebarLocation(_ sender: NSButton) {
        guard let url = sidebarURLs[ObjectIdentifier(sender)] else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            openFolderInNewTab(url)
        } else {
            navigate(to: url)
        }
    }

    private func openFolderInNewTab(_ url: URL) {
        tabs.append(BrowserTab(history: BrowserHistory(initialURL: url)))
        activeTabIndex = tabs.count - 1
        renderActiveTab()
    }

    @objc private func openProjectWebsite(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/satinath-nit/OpenExplorer") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func breadcrumbSelected(_ sender: PathButton) {
        if let url = sender.destinationURL { navigate(to: url) }
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        let expanded = PathAutocompleteEngine.expandPath(addressField.stringValue)
        navigate(to: URL(fileURLWithPath: expanded))
    }

    @objc func focusAddress(_ sender: Any?) {
        breadcrumbStack.isHidden = true
        addressField.isHidden = false
        addressField.stringValue = DemoScreenshotEnvironment.displayPath(for: currentURL)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.addressField)
            self.addressField.selectText(nil)
        }
    }

    @objc func focusFilter(_ sender: Any?) {
        window?.makeFirstResponder(filterField)
    }

    @objc func focusRecursiveSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func showCommandPalette(_ sender: Any?) {
        presentCommandPalette(mode: .commands)
    }

    @objc func showFuzzyGoTo(_ sender: Any?) {
        presentCommandPalette(mode: .fuzzyNavigation)
    }

    private func presentCommandPalette(mode: CommandPaletteMode) {
        if let existing = commandPaletteController, let panel = existing.window, panel.isVisible {
            if existing.mode == mode {
                existing.closePressed(nil)
                return
            }
            existing.reconfigure(
                mode: mode,
                currentDirectory: currentURL,
                includeHidden: showHiddenFiles,
                items: buildCommandPaletteItems()
            )
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let paletteItems = buildCommandPaletteItems()
        let controller = CommandPaletteWindowController(
            mode: mode,
            currentDirectory: currentURL,
            includeHidden: showHiddenFiles,
            initialItems: paletteItems
        ) { [weak self] item, openInNewTab in
            self?.executeCommandPaletteItem(item, openInNewTab: openInNewTab)
        }
        commandPaletteController = controller
        if let parentWindow = window, let panel = controller.window {
            let parentFrame = parentWindow.frame
            let panelSize = panel.frame.size
            let originX = parentFrame.midX - panelSize.width / 2
            let originY = parentFrame.maxY - panelSize.height - 90
            panel.setFrameOrigin(NSPoint(x: originX, y: max(parentFrame.minY + 40, originY)))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusSearchField()
    }

    private func buildCommandPaletteItems() -> [CommandPaletteItem] {
        var result: [CommandPaletteItem] = [
            CommandPaletteItem(id: "cmd.compress.clean", title: "Compress Clean ZIP (No .DS_Store / __MACOSX)", subtitle: "Create cross-platform ZIP archive for Windows/Linux", category: "Archive", symbolName: "sparkles", shortcutHint: "ZIP", keywords: ["zip", "compress", "clean", "windows", "archive"], target: .command("compress.clean")),
            CommandPaletteItem(id: "cmd.compress.native", title: "Compress to macOS Native ZIP", subtitle: "Create ZIP preserving macOS resource forks", category: "Archive", symbolName: "doc.zipper", shortcutHint: "ZIP", keywords: ["zip", "compress", "ditto", "archive"], target: .command("compress.native")),
            CommandPaletteItem(id: "cmd.archive.browse", title: "Browse Inside Selected Archive…", subtitle: "Inspect and extract individual files from .zip or .tar", category: "Archive", symbolName: "archivebox", shortcutHint: "Inspect", keywords: ["zip", "tar", "browse", "inspect", "extract"], target: .command("archive.browse")),
            CommandPaletteItem(id: "cmd.rename.batch", title: "Batch Rename Selected Items…", subtitle: "Find & Replace, Regex, Prefix/Suffix, or Sequential Numbering", category: "File Operations", symbolName: "pencil.and.list.clipboard", shortcutHint: "⇧⌘R", keywords: ["rename", "batch", "regex", "number"], target: .command("rename.batch")),
            CommandPaletteItem(id: "cmd.new.folder", title: "New Folder…", subtitle: "Create a new subfolder in \(currentURL.lastPathComponent)", category: "File Operations", symbolName: "folder.badge.plus", shortcutHint: "⇧⌘N", keywords: ["mkdir", "folder", "create", "new"], target: .command("new.folder")),
            CommandPaletteItem(id: "cmd.new.blank", title: "New Blank File…", subtitle: "Create an empty file with any extension", category: "File Operations", symbolName: "doc.badge.plus", shortcutHint: "", keywords: ["touch", "file", "create", "new"], target: .command("new.blank")),
            CommandPaletteItem(id: "cmd.new.tab", title: "New Tab", subtitle: "Open a new folder tab in this window", category: "Navigation", symbolName: "plus.square.on.square", shortcutHint: "⌘N", keywords: ["tab", "open"], target: .command("new.tab")),
            CommandPaletteItem(id: "cmd.view.dualpane", title: "Toggle Dual-Pane Split View", subtitle: "Side-by-side Norton/Total Commander dual file panes", category: "View", symbolName: "rectangle.split.2x1", shortcutHint: "⌥⌘P", keywords: ["split", "dual", "pane", "commander", "f5", "f6"], target: .command("view.dualpane")),
            CommandPaletteItem(id: "cmd.view.hidden", title: "Toggle Hidden Dotfiles", subtitle: showHiddenFiles ? "Currently showing hidden files" : "Currently hiding dotfiles", category: "View", symbolName: "eye.slash", shortcutHint: "", keywords: ["hidden", "dotfiles", "show"], target: .command("view.hidden")),
            CommandPaletteItem(id: "cmd.view.dim.gitignore", title: "Toggle Dimming of Git-Ignored Files", subtitle: ExplorerPreferences.shared.dimGitIgnoredFiles ? "Currently dimming .gitignore & build artifact folders (node_modules, .build, dist, target)" : "Currently displaying git-ignored files at full opacity", category: "Developer", symbolName: "eye.trianglebadge.exclamationmark", shortcutHint: "", keywords: ["gitignore", "dim", "ignored", "node_modules", "build", "dist", "target"], target: .command("view.dim.gitignore")),
            CommandPaletteItem(id: "cmd.search.exclude.gitignore", title: "Toggle Excluding Git-Ignored Files from Recursive Search", subtitle: ExplorerPreferences.shared.excludeGitIgnoredFromSearch ? "Currently excluding git-ignored files from recursive search" : "Currently including git-ignored files in recursive search", category: "Developer", symbolName: "magnifyingglass.circle", shortcutHint: "", keywords: ["gitignore", "search", "exclude", "ignored", "node_modules"], target: .command("search.exclude.gitignore")),
            CommandPaletteItem(id: "cmd.view.details", title: "Switch to Details View", subtitle: "Columns for Name, Date Modified, Date Created, Type, Size", category: "View", symbolName: "list.bullet.rectangle", shortcutHint: "", keywords: ["view", "details", "table"], target: .command("view.details")),
            CommandPaletteItem(id: "cmd.view.icons", title: "Switch to Large Icons View", subtitle: "Grid view with async image & PDF thumbnails", category: "View", symbolName: "square.grid.2x2", shortcutHint: "", keywords: ["view", "icons", "grid", "thumbnails"], target: .command("view.icons")),
            CommandPaletteItem(id: "cmd.copy.path", title: "Copy Current Folder Address", subtitle: DemoScreenshotEnvironment.displayPath(for: currentURL), category: "Clipboard", symbolName: "doc.on.clipboard", shortcutHint: "", keywords: ["copy", "path", "pwd", "address"], target: .command("copy.path")),
            CommandPaletteItem(id: "cmd.copy.relpath", title: "Copy Path Relative to Home (~)", subtitle: pathRelativeToHome(contextualLocationURL), category: "Clipboard", symbolName: "link", shortcutHint: "", keywords: ["copy", "relative", "path", "home"], target: .command("copy.relpath")),
            CommandPaletteItem(id: "cmd.open.terminal", title: "Open in Terminal Here", subtitle: "Launch preferred terminal at \(DemoScreenshotEnvironment.displayPath(for: currentURL))", category: "Developer", symbolName: "terminal", shortcutHint: "", keywords: ["terminal", "shell", "zsh", "iterm", "warp"], target: .command("open.terminal")),
            CommandPaletteItem(id: "cmd.get.info", title: "Get Info & Compute Checksums (SHA-256 / MD5)", subtitle: "Inspect permissions, size, and cryptographic hashes", category: "Inspector", symbolName: "info.circle", shortcutHint: "⌘I", keywords: ["info", "sha256", "md5", "hash", "checksum", "chmod", "permissions"], target: .command("get.info")),
            CommandPaletteItem(id: "cmd.share", title: "Share Selected Items (AirDrop / Mail / Messages)…", subtitle: "Open native macOS Share Sheet", category: "System", symbolName: "square.and.arrow.up", shortcutHint: "", keywords: ["share", "airdrop", "send"], target: .command("share")),
            CommandPaletteItem(id: "cmd.fav.add", title: "Add Current or Selected Folder to Favorites", subtitle: "Pin to sidebar Favorites section", category: "Sidebar", symbolName: "star.fill", shortcutHint: "", keywords: ["favorite", "pin", "bookmark", "sidebar"], target: .command("fav.add")),
            CommandPaletteItem(id: "cmd.undo", title: "Undo Last File Operation", subtitle: "Revert last move, copy, rename, or ZIP creation", category: "Edit", symbolName: "arrow.uturn.backward", shortcutHint: "⌘Z", keywords: ["undo", "revert"], target: .command("undo")),
            CommandPaletteItem(id: "cmd.redo", title: "Redo Last File Operation", subtitle: "Reapply last undone file operation", category: "Edit", symbolName: "arrow.uturn.forward", shortcutHint: "⇧⌘Z", keywords: ["redo"], target: .command("redo")),
            CommandPaletteItem(id: "cmd.delete.perm", title: "Permanently Delete Selection…", subtitle: "Bypass Trash and remove selected items from disk", category: "File Operations", symbolName: "trash.slash", shortcutHint: "⇧Delete", keywords: ["delete", "permanent", "remove", "rm"], target: .command("delete.perm"))
        ]

        for (idx, template) in DeveloperToolsManager.builtInTemplates.enumerated() {
            result.append(
                CommandPaletteItem(
                    id: "cmd.template.\(idx)",
                    title: "New File from Template: \(template.title)",
                    subtitle: "Creates \(template.defaultFileName) in current folder",
                    category: "Templates",
                    symbolName: "doc.badge.plus",
                    shortcutHint: "Create",
                    keywords: ["template", "new", template.defaultFileName],
                    target: .command("template.\(idx)")
                )
            )
        }

        for editor in DeveloperToolsManager.installedEditors(fileManager: fileManager) {
            result.append(
                CommandPaletteItem(
                    id: "cmd.editor.\(editor.bundleIdentifier)",
                    title: "Open in \(editor.name)",
                    subtitle: editor.url.path,
                    category: "Developer",
                    symbolName: editor.symbolName,
                    shortcutHint: "IDE",
                    keywords: ["open", "editor", "ide", "code", editor.name],
                    target: .command("editor:\(editor.url.path)")
                )
            )
        }

        var seenPaths = Set<String>()
        for item in visibleItems {
            let stdPath = item.url.standardizedFileURL.path
            guard seenPaths.insert(stdPath).inserted else { continue }
            result.append(
                CommandPaletteItem(
                    id: "item:\(stdPath)",
                    title: item.name,
                    subtitle: DemoScreenshotEnvironment.displayPath(for: item.url),
                    category: item.isDirectory ? "Current Folder — Directory" : "Current Folder — \(item.kind)",
                    symbolName: item.isDirectory ? "folder.fill" : "doc.text",
                    shortcutHint: item.isDirectory ? "Jump" : "Open",
                    keywords: [item.name, item.kind],
                    target: item.isDirectory ? .folder(item.url) : .file(item.url)
                )
            )
        }

        for fav in favoriteURLs {
            let stdPath = fav.standardizedFileURL.path
            guard seenPaths.insert(stdPath).inserted else { continue }
            result.append(
                CommandPaletteItem(
                    id: "fav:\(stdPath)",
                    title: fav.lastPathComponent,
                    subtitle: DemoScreenshotEnvironment.displayPath(for: fav),
                    category: "Favorite Folder",
                    symbolName: "star.fill",
                    shortcutHint: "Favorite",
                    keywords: [fav.lastPathComponent, "favorite"],
                    target: .folder(fav)
                )
            )
        }

        for recent in recentLocations {
            let stdPath = recent.standardizedFileURL.path
            guard seenPaths.insert(stdPath).inserted else { continue }
            result.append(
                CommandPaletteItem(
                    id: "recent:\(stdPath)",
                    title: recent.lastPathComponent.isEmpty ? "Macintosh HD" : recent.lastPathComponent,
                    subtitle: DemoScreenshotEnvironment.displayPath(for: recent),
                    category: "Recent Location",
                    symbolName: "clock",
                    shortcutHint: "Recent",
                    keywords: [recent.lastPathComponent, stdPath, "recent"],
                    target: .folder(recent)
                )
            )
        }

        return result
    }

    private func executeCommandPaletteItem(_ item: CommandPaletteItem, openInNewTab: Bool) {
        switch item.target {
        case .folder(let url):
            if openInNewTab {
                openFolderInNewTab(url)
            } else {
                navigate(to: url)
            }
        case .file(let url):
            let parent = url.deletingLastPathComponent()
            if parent.standardizedFileURL != currentURL.standardizedFileURL {
                navigate(to: parent)
            }
            selectItem(at: url)
            if openInNewTab {
                NSWorkspace.shared.open(url)
            }
        case .command(let cmd):
            switch cmd {
            case "compress.clean": compressSelectionCleanZip(nil)
            case "compress.native": compressSelectionNativeZip(nil)
            case "archive.browse": browseInsideArchive(nil)
            case "rename.batch": batchRenameSelection(nil)
            case "new.folder": createFolder(nil)
            case "new.blank": createBlankFile(nil)
            case "new.tab": newTab(nil)
            case "view.dualpane": toggleDualPane(nil)
            case "view.hidden":
                showHiddenFiles.toggle()
                reloadContents()
            case "view.dim.gitignore":
                toggleDimGitIgnoredFiles(nil)
            case "search.exclude.gitignore":
                toggleExcludeGitIgnoredFromSearch(nil)
            case "view.details":
                viewMode = .details
                applyViewMode()
            case "view.icons":
                viewMode = .largeIcons
                applyViewMode()
            case "copy.path": copyCurrentAddress(nil)
            case "copy.relpath": copyPathRelativeToHome(nil)
            case "open.terminal": openInTerminal(nil)
            case "get.info": showGetInfo(nil)
            case "share": shareSelection(nil)
            case "fav.add": addFavorite(nil)
            case "undo": undoLastOperation(nil)
            case "redo": redoLastOperation(nil)
            case "delete.perm": permanentlyDeleteSelection(nil)
            default:
                if cmd.hasPrefix("template."),
                   let idx = Int(cmd.dropFirst("template.".count)),
                   DeveloperToolsManager.builtInTemplates.indices.contains(idx) {
                    let menuItem = NSMenuItem()
                    menuItem.tag = idx
                    createFileFromTemplateItem(menuItem)
                } else if cmd.hasPrefix("editor:") {
                    let path = String(cmd.dropFirst("editor:".count))
                    let targets = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
                    NSWorkspace.shared.open(targets, withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    @objc private func copyCurrentAddress(_ sender: Any?) {
        copyStringToPasteboard(currentURL.path)
    }

    @objc private func copyCurrentAddressRelativeToHome(_ sender: Any?) {
        copyStringToPasteboard(pathRelativeToHome(currentURL))
    }

    @objc func goBack(_ sender: Any?) {
        guard let url = tabs[activeTabIndex].history.back() else { return }
        navigate(to: url, recordHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let url = tabs[activeTabIndex].history.forward() else { return }
        navigate(to: url, recordHistory: false)
    }

    @objc func goUp(_ sender: Any?) {
        guard currentURL.path != "/" else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    @objc func newTab(_ sender: Any?) {
        tabs.append(BrowserTab(history: BrowserHistory(initialURL: fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)))
        activeTabIndex = tabs.count - 1
        renderActiveTab()
    }

    @objc func closeWindow(_ sender: Any?) {
        if let paletteWindow = commandPaletteController?.window, paletteWindow.isVisible {
            commandPaletteController?.closePressed(sender)
            return
        }
        if let attachedSheet = window?.attachedSheet {
            window?.endSheet(attachedSheet, returnCode: .cancel)
        }
        window?.performClose(sender)
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard let index = tabIndexes[ObjectIdentifier(sender)], tabs.indices.contains(index) else { return }
        activeTabIndex = index
        searchField.stringValue = ""
        filterField.stringValue = ""
        renderActiveTab()
    }

    @objc private func closeTab(_ sender: NSButton) {
        guard tabs.count > 1, tabs.indices.contains(sender.tag) else { return }
        tabs.remove(at: sender.tag)
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        renderActiveTab()
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1: tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        case 2: tableView.sortDescriptors = [NSSortDescriptor(key: "modified", ascending: false)]
        case 3: tableView.sortDescriptors = [NSSortDescriptor(key: "created", ascending: false)]
        case 4: tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        default: tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        }
    }

    @objc private func groupModeChanged(_ sender: NSPopUpButton) {
        if let mode = FileGroupMode(rawValue: sender.indexOfSelectedItem) {
            groupMode = mode
            applyFilterAndSort()
        }
    }

    private func syncSortPopup() {
        guard let descriptor = tableView.sortDescriptors.first else {
            sortPopup.selectItem(at: 0)
            return
        }
        switch descriptor.key {
        case "name": sortPopup.selectItem(at: descriptor.ascending ? 0 : 1)
        case "modified": sortPopup.selectItem(at: 2)
        case "created": sortPopup.selectItem(at: 3)
        case "size": sortPopup.selectItem(at: 4)
        default: break
        }
    }

    @objc private func viewModeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if let mode = BrowserViewMode(rawValue: index) {
            viewMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "viewModeV2")
            savePerFolderViewPreference(for: currentURL)
            applyViewMode()
        } else if index == BrowserViewMode.allCases.count + 1 {
            showsDetailsPane.toggle()
            UserDefaults.standard.set(showsDetailsPane, forKey: "showsDetailsPane")
            updatePaneVisibility()
        } else if index == BrowserViewMode.allCases.count + 2 {
            showsPreviewPane.toggle()
            UserDefaults.standard.set(showsPreviewPane, forKey: "showsPreviewPane")
            updatePaneVisibility()
        }
        refreshViewMenu()
    }

    private func applyViewMode() {
        tableScroll.isHidden = viewMode.usesIconGrid
        collectionScroll.isHidden = !viewMode.usesIconGrid
        for column in tableView.tableColumns {
            switch column.identifier.rawValue {
            case "name": column.isHidden = false
            case "modified", "created": column.isHidden = viewMode != .details && viewMode != .list
            default: column.isHidden = viewMode != .details
            }
        }
        tableView.rowHeight = viewMode == .content ? 62 : 34
        tableView.intercellSpacing = NSSize(width: 0, height: viewMode == .content ? 2 : 1)
        configureCollectionLayout()
        tableView.reloadData()
        collectionView.reloadData()
        scheduleFolderSizeCalculationsIfNeeded()
        updateStatus()
        updatePreview()
        refreshViewMenu()
    }

    private func configureCollectionLayout() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        switch viewMode {
        case .extraLargeIcons: layout.itemSize = NSSize(width: 190, height: 180)
        case .largeIcons: layout.itemSize = NSSize(width: 155, height: 145)
        case .mediumIcons: layout.itemSize = NSSize(width: 125, height: 118)
        case .smallIcons: layout.itemSize = NSSize(width: 100, height: 88)
        case .tiles: layout.itemSize = NSSize(width: 285, height: 76)
        case .list, .details, .content: layout.itemSize = NSSize(width: 125, height: 118)
        }
        collectionView.collectionViewLayout = layout
    }

    private func refreshViewMenu() {
        viewPopup.selectItem(at: viewMode.rawValue)
        viewPopup.item(at: BrowserViewMode.allCases.count + 1)?.state = showsDetailsPane ? .on : .off
        viewPopup.item(at: BrowserViewMode.allCases.count + 2)?.state = showsPreviewPane ? .on : .off
        previewToggle.state = showsDetailsPane ? .on : .off
    }

    private func updatePaneVisibility() {
        previewOnlyViews.forEach { $0.isHidden = !showsPreviewPane }
        detailsOnlyViews.forEach { $0.isHidden = !showsDetailsPane }
        previewPanel.isHidden = !showsPreviewPane && !showsDetailsPane
        contentSplit.adjustSubviews()
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        showHiddenFiles = sender.state == .on
        reloadContents()
    }

    @objc private func togglePreview(_ sender: NSButton) {
        showsDetailsPane = sender.state == .on
        UserDefaults.standard.set(showsDetailsPane, forKey: "showsDetailsPane")
        updatePaneVisibility()
        refreshViewMenu()
    }

    @objc private func collectionDoubleClicked(_ sender: NSClickGestureRecognizer) {
        openSelection(sender)
    }

    @objc func reload(_ sender: Any?) { reloadContents() }

    @objc func openSelection(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        if item.isDirectory {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                openFolderInNewTab(item.url)
            } else {
                navigate(to: item.url)
            }
        } else if ZipExtractor.isSupportedArchive(item.url) {
            if ExplorerPreferences.shared.zipDoubleClickBehavior == .browse {
                browseInsideArchive(nil)
            } else {
                extractZip(item.url)
            }
        } else if item.url.pathExtension.lowercased() == "dmg" {
            mountDiskImage(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let item = selectedItems.first, item.isPackage else { return }
        navigate(to: item.url)
    }

    private func mountDiskImage(_ imageURL: URL) {
        statusLabel.stringValue = "Mounting \(imageURL.lastPathComponent)…"
        Task { [weak self] in
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    let pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    process.arguments = ["attach", "-nobrowse", imageURL.path]
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw NSError(domain: "OpenExplorer.DiskImage", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "The disk image could not be mounted."])
                    }
                    return String(data: data, encoding: .utf8) ?? "Mounted"
                }.value
                guard let self else { return }
                self.rebuildMountedVolumes()
                self.statusLabel.stringValue = output.split(separator: "\n").last.map(String.init) ?? "Disk image mounted"
            } catch { self?.showError("Could not mount \(imageURL.lastPathComponent)", detail: error.localizedDescription) }
        }
    }

    private func extractZip(_ archiveURL: URL) {
        statusLabel.stringValue = "Extracting \(archiveURL.lastPathComponent)…"
        Task { [weak self] in
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    try ZipExtractor.extract(archiveURL)
                }.value
                guard let self else { return }
                self.undoStack.record(.createdItem(destination))
                self.reloadContents()
                self.selectItem(at: destination)
                self.statusLabel.stringValue = "Extracted to \(destination.lastPathComponent)"
            } catch {
                guard let self else { return }
                self.reloadContents(preservingSelection: true)
                self.showError("Could not extract \(archiveURL.lastPathComponent)", detail: error.localizedDescription)
            }
        }
    }

    @objc func compressSelectionToZip(_ sender: Any?) {
        compressSelection(mode: ExplorerPreferences.shared.defaultZipMode)
    }

    @objc func compressSelectionCleanZip(_ sender: Any?) {
        compressSelection(mode: .cleanCrossPlatform)
    }

    @objc func compressSelectionNativeZip(_ sender: Any?) {
        compressSelection(mode: .macOSNative)
    }

    private func compressSelection(mode: ZipCompressionMode) {
        let targets = selectedItems.isEmpty ? [FileItem(url: currentURL, name: currentURL.lastPathComponent, isDirectory: true, size: 0, modified: nil, created: nil, tags: [], cloudStatus: .local, projectBadge: nil, gitState: nil)] : selectedItems
        let urls = targets.map(\.url)
        let targetDir = currentURL
        let labelText = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        statusLabel.stringValue = "Compressing \(labelText) to ZIP…"
        Task { [weak self] in
            do {
                let archiveURL = try await Task.detached(priority: .userInitiated) {
                    try ZipExtractor.compress(urls, in: targetDir, mode: mode)
                }.value
                guard let self else { return }
                self.undoStack.record(.createdItem(archiveURL))
                self.reloadContents()
                self.selectItem(at: archiveURL)
                let cleanTag = mode == .cleanCrossPlatform ? " (Clean Cross-Platform ZIP)" : ""
                self.statusLabel.stringValue = "Created \(archiveURL.lastPathComponent)\(cleanTag) — ⌘Z to undo"
            } catch {
                self?.showError("Could not compress selection", detail: error.localizedDescription)
            }
        }
    }

    @objc func browseInsideArchive(_ sender: Any?) {
        guard let item = selectedItems.first, ZipExtractor.isSupportedArchive(item.url) else { return }
        do {
            let browser = try ArchiveBrowserWindowController(archiveURL: item.url)
            archiveBrowsers.append(browser)
            browser.onExtractedURL = { [weak self] extracted in
                self?.reloadContents()
                self?.selectItem(at: extracted)
            }
            browser.showWindow(nil)
            browser.window?.makeKeyAndOrderFront(nil)
        } catch {
            showError("Could not inspect archive", detail: error.localizedDescription)
        }
    }

    @objc func shareSelection(_ sender: Any?) {
        let urls = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
        let anchorView = (sender as? NSView) ?? shareButton
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    private func selectItem(at url: URL) {
        guard let index = visibleItems.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        if viewMode.usesIconGrid {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.selectItems(at: [indexPath], scrollPosition: [.centeredVertically])
            collectionView.scrollToItems(at: [indexPath], scrollPosition: [.centeredVertically])
        } else {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        updateStatus()
        updatePreview()
    }

    @objc func editInOpenExplorer(_ sender: Any?) {
        guard selectedItems.count == 1, let item = selectedItems.first, !item.isDirectory else { return }
        do {
            let editor = try TextEditorWindowController(fileURL: item.url)
            textEditors.append(editor)
            editor.onClose = { [weak self, weak editor] in
                guard let self, let editor else { return }
                self.textEditors.removeAll { $0 === editor }
                self.reloadContents()
            }
            editor.showWindow(nil)
            editor.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            showError("Could not edit “\(item.name)”", detail: error.localizedDescription)
        }
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let applicationURL = sender.representedObject as? URL else { return }
        openSelection(with: applicationURL)
    }

    @objc private func chooseApplication(_ sender: Any?) {
        let selection = selectedItems.map(\.url)
        guard !selection.isEmpty, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(selection.count == 1 ? "“\(selection[0].lastPathComponent)”" : "the selected items")."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let applicationURL = panel.url else { return }
            self?.openSelection(with: applicationURL)
        }
    }

    private func openSelection(with applicationURL: URL) {
        let urls = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.showError("Could not open the selection", detail: error.localizedDescription)
            }
        }
    }

    @objc func showGetInfo(_ sender: Any?) {
        let targetItem = selectedItems.first ?? makeFileItem(currentURL)
        guard let item = targetItem else { return }
        statusLabel.stringValue = "Calculating information for \(item.name)…"
        Task { [weak self] in
            do {
                let details = try await Task.detached(priority: .userInitiated) {
                    let manager = FileManager.default
                    let attributes = try manager.attributesOfItem(atPath: item.url.path)
                    var bytes = (attributes[.size] as? NSNumber)?.int64Value ?? item.size
                    if item.isDirectory, let enumerator = manager.enumerator(at: item.url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                        bytes = 0
                        while let child = enumerator.nextObject() as? URL {
                            bytes += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        }
                    }
                    let hashes: FileHashes? = (!item.isDirectory && bytes <= 150 * 1_024 * 1_024)
                        ? (try? FileHashCalculator.computeHashes(for: item.url))
                        : nil
                    return ItemDetails(
                        size: bytes,
                        owner: attributes[.ownerAccountName] as? String ?? "—",
                        group: attributes[.groupOwnerAccountName] as? String ?? "—",
                        permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
                        isLocked: (attributes[.immutable] as? NSNumber)?.boolValue ?? false,
                        hashes: hashes
                    )
                }.value
                self?.presentGetInfo(for: item, details: details)
            } catch { self?.showError("Could not read item information", detail: error.localizedDescription) }
        }
    }

    private func presentGetInfo(for item: FileItem, details: ItemDetails) {
        let alert = NSAlert()
        alert.messageText = item.name
        alert.informativeText = item.url.path
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        if details.hashes != nil {
            alert.addButton(withTitle: "Copy SHA-256")
        }

        let size = NSTextField(labelWithString: "Size: \(FileTextFormatter.byteCount(details.size, isDirectory: false)) (\(details.size) bytes)")
        let owner = NSTextField(labelWithString: "Owner: \(details.owner)    Group: \(details.group)")
        let permissions = NSTextField(string: String(format: "%03o", details.permissions))
        permissions.placeholderString = "Permissions, for example 644"
        let locked = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
        locked.state = details.isLocked ? .on : .off
        var views: [NSView] = [size, owner, NSTextField(labelWithString: "POSIX permissions:"), permissions, locked]
        if let hashes = details.hashes {
            let shaLabel = NSTextField(labelWithString: "SHA-256: \(hashes.sha256)")
            shaLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            shaLabel.isSelectable = true
            let md5Label = NSTextField(labelWithString: "MD5: \(hashes.md5) · SHA-1: \(hashes.sha1)")
            md5Label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            md5Label.textColor = .secondaryLabelColor
            md5Label.isSelectable = true
            views.append(shaLabel)
            views.append(md5Label)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.frame = NSRect(x: 0, y: 0, width: 470, height: details.hashes != nil ? 175 : 120)
        permissions.widthAnchor.constraint(equalToConstant: 100).isActive = true
        alert.accessoryView = stack
        statusLabel.stringValue = "\(visibleItems.count) items"
        let response = alert.runModal()
        if response == .alertThirdButtonReturn, let sha = details.hashes?.sha256 {
            copyStringToPasteboard(sha)
            statusLabel.stringValue = "Copied SHA-256 checksum to clipboard"
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        guard let mode = Int(permissions.stringValue, radix: 8), (0...0o7777).contains(mode) else {
            showError("Invalid permissions", detail: "Enter an octal value such as 644 or 755.")
            return
        }
        do {
            try fileManager.setAttributes([.posixPermissions: mode, .immutable: locked.state == .on], ofItemAtPath: item.url.path)
            reloadContents(preservingSelection: true)
        } catch { showError("Could not update item information", detail: error.localizedDescription) }
    }

    @objc func quickLook(_ sender: Any?) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p"] + selection.map { $0.url.path }
        do { try process.run() }
        catch { showError("Could not open Quick Look", detail: error.localizedDescription) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu.title == "Open With" {
            populateOpenWithMenu(menu)
            return
        }
        let canEdit = selectedItems.count == 1
            && selectedItems.first?.isDirectory == false
            && selectedItems.first?.isPackage == false
            && selectedItems.first.map { TextEditorWindowController.canOpen($0.url) } == true
        menu.item(withTitle: "Edit in OpenExplorer")?.isEnabled = canEdit
        menu.item(withTitle: "Open With")?.isEnabled = true
        menu.item(withTitle: "Quick Look")?.isEnabled = !selectedItems.isEmpty
        let isArchive = selectedItems.count == 1 && selectedItems.first.map { ZipExtractor.isSupportedArchive($0.url) } == true
        menu.item(withTitle: "Browse Inside Archive…")?.isHidden = !isArchive
        let isPackage = selectedItems.count == 1 && selectedItems.first?.isPackage == true
        menu.item(withTitle: "Show Package Contents")?.isHidden = !isPackage
        let isTrash = currentURL.standardizedFileURL == fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
        menu.item(withTitle: "Restore from Trash")?.isHidden = !isTrash
        menu.item(withTitle: "Move to Trash")?.isHidden = isTrash
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Open With" { populateOpenWithMenu(menu) }
    }

    @objc func addFavorite(_ sender: Any?) {
        let target = selectedItems.first(where: \.isDirectory)?.url ?? currentURL
        guard !favoriteURLs.contains(target) else { return }
        favoriteURLs.append(target)
        UserDefaults.standard.set(favoriteURLs.map(\.path), forKey: "favoriteFolders")
        rebuildFavorites()
    }

    @objc func createFolder(_ sender: Any?) {
        guard let name = prompt(title: "New Folder", message: "Create in \(currentURL.path)", defaultValue: "New Folder", confirm: "Create"), !name.isEmpty else { return }
        do {
            let folderURL = currentURL.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            undoStack.record(.createdItem(folderURL))
            reloadContents()
            selectItem(at: folderURL)
        } catch { showError("Could not create folder", detail: error.localizedDescription) }
    }

    @objc func createBlankFile(_ sender: Any?) {
        guard let name = prompt(
            title: "New Blank File",
            message: "Enter a name with any extension, such as notes.txt, page.html, or data.json.",
            defaultValue: "New File.txt",
            confirm: "Create"
        ) else { return }
        do {
            let fileURL = try BlankFileCreator.create(named: name, in: currentURL)
            undoStack.record(.createdItem(fileURL))
            reloadContents()
            selectItem(at: fileURL)
        } catch {
            showError("Could not create file", detail: error.localizedDescription)
        }
    }

    @objc private func createFileFromTemplateItem(_ sender: NSMenuItem) {
        let index = sender.tag
        guard DeveloperToolsManager.builtInTemplates.indices.contains(index) else { return }
        let template = DeveloperToolsManager.builtInTemplates[index]
        do {
            let created = try DeveloperToolsManager.createFromTemplate(template, in: currentURL, fileManager: fileManager)
            undoStack.record(.createdItem(created))
            reloadContents()
            selectItem(at: created)
            statusLabel.stringValue = "Created \(created.lastPathComponent)"
        } catch {
            showError("Could not create file from template", detail: error.localizedDescription)
        }
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = makeNewMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func smartRenameOrBatchRename(_ sender: Any?) {
        if selectedItems.count > 1 {
            batchRenameSelection(sender)
        } else {
            renameSelection(sender)
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        if selectedItems.count > 1 {
            batchRenameSelection(sender)
            return
        }
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        guard let name = prompt(title: "Rename", message: item.name, defaultValue: item.name, confirm: "Rename"), !name.isEmpty, name != item.name else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fileManager.moveItem(at: item.url, to: destination)
            let record = FileTransferRecord(source: item.url, destination: destination, kind: .move)
            lastTransferRecords = [record]
        if let existingSheet = window?.attachedSheet {
            window?.endSheet(existingSheet, returnCode: .cancel)
        }
            undoStack.record(.transfer([record]))
            reloadContents()
            selectItem(at: destination)
        } catch { showError("Could not rename item", detail: error.localizedDescription) }
    }

    @objc func batchRenameSelection(_ sender: Any?) {
        let urls = selectedItems.isEmpty ? visibleItems.map(\.url) : selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let controller = BatchRenameWindowController(urls: urls) { [weak self] plan in
            guard let self else { return }
            do {
                let records = try BatchRenameEngine.apply(plan, fileManager: self.fileManager)
                if !records.isEmpty {
                    self.lastTransferRecords = records
                    self.undoStack.record(.transfer(records))
                    self.reloadContents()
                    self.statusLabel.stringValue = "Renamed \(records.count) item(s) — ⌘Z to undo"
                }
            } catch {
                self.showError("Batch Rename failed", detail: error.localizedDescription)
            }
        }
        batchRenameController = controller
        if let window, let sheet = controller.window {
            window.beginSheet(sheet)
        } else {
            controller.showWindow(nil)
        }
    }

    @objc func trashSelection(_ sender: Any?) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selection.count == 1 ? "Move “\(selection[0].name)” to Trash?" : "Move \(selection.count) items to Trash?"
        alert.informativeText = "The items can be recovered from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failures: [String] = []
        var records: [FileTransferRecord] = []
        for item in selection {
            do {
                var trashedURL: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &trashedURL)
                if let destination = trashedURL as URL? {
                    records.append(FileTransferRecord(source: item.url, destination: destination, kind: .move))
                    trashRecords.append(TrashRecord(trashedPath: destination.path, originalPath: item.url.path))
                }
            }
            catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
        if let data = try? JSONEncoder().encode(trashRecords) { UserDefaults.standard.set(data, forKey: "trashRecordsV1") }
        fileOperations.discardUndo(lastTransferRecords)
        lastTransferRecords = records
        if !records.isEmpty { undoStack.record(.transfer(records)) }
        reloadContents()
        if !failures.isEmpty { showError("Some items could not be moved", detail: failures.joined(separator: "\n")) }
    }

    @objc func permanentlyDeleteSelection(_ sender: Any?) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = selection.count == 1
            ? "Permanently delete “\(selection[0].name)”?"
            : "Permanently delete \(selection.count) items?"
        alert.informativeText = "This bypasses the Trash and permanently removes the items from disk. This action cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failures: [String] = []
        for item in selection {
            do {
                try fileManager.removeItem(at: item.url)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        reloadContents()
        if !failures.isEmpty {
            showError("Could not delete some items", detail: failures.joined(separator: "\n"))
        } else {
            statusLabel.stringValue = "Permanently deleted \(selection.count) item(s)"
        }
    }

    @objc func copySelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        cutURLs.removeAll()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        tableView.reloadData()
        collectionView.reloadData()
    }

    @objc func copyPathRelativeToHome(_ sender: Any?) {
        copyStringToPasteboard(pathRelativeToHome(contextualLocationURL))
    }

    @objc func openInTerminal(_ sender: Any?) {
        let target = contextualLocationURL
        let directory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? target
            : target.deletingLastPathComponent()
        if let appURL = (sender as? NSMenuItem)?.representedObject as? URL {
            NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let terminals = DeveloperToolsManager.installedTerminals(fileManager: fileManager)
        guard let preferred = terminals.first else {
            showError("Terminal was not found", detail: "Open Terminal and navigate to \(directory.path).")
            return
        }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: preferred.url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func openInDeveloperApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let targets = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
        NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleFinderTagOnSelection(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let urls = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
        try? FinderTagManager.toggleTag(tag, for: urls)
        reloadContents(preservingSelection: true)
    }

    @objc private func downloadCloudSelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        for url in urls {
            try? CloudStorageInspector.downloadItem(at: url, fileManager: fileManager)
        }
        reloadContents(preservingSelection: true)
    }

    @objc private func evictCloudSelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        for url in urls {
            try? CloudStorageInspector.evictItem(at: url, fileManager: fileManager)
        }
        reloadContents(preservingSelection: true)
    }

    @objc func cutSelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        cutURLs = Set(urls)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        tableView.reloadData()
        collectionView.reloadData()
    }

    @objc func paste(_ sender: Any?) {
        let sources = transferSourcesFromPasteboard()
        guard !sources.isEmpty else { return }
        let kind: FileTransferKind = sources.allSatisfy { cutURLs.contains($0) } ? .move : .copy
        runTransfer(sources, to: currentURL, kind: kind)
    }

    private func runTransfer(_ sources: [URL], to directory: URL, kind: FileTransferKind) {
        guard !sources.isEmpty, operationCancellation == nil else { return }
        guard let resolution = conflictResolution(for: sources, in: directory, kind: kind) else { return }
        let cancellation = FileOperationCancellation()
        operationCancellation = cancellation

        let alert = NSAlert()
        alert.messageText = kind == .move ? "Moving \(sources.count) item\(sources.count == 1 ? "" : "s")…" : "Copying \(sources.count) item\(sources.count == 1 ? "" : "s")…"
        alert.informativeText = "You can cancel after the current item finishes."
        alert.addButton(withTitle: "Cancel")
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(sources.count)
        progress.doubleValue = 0
        progress.frame = NSRect(x: 0, y: 0, width: 360, height: 18)
        alert.accessoryView = progress
        let reporter = OperationProgressReporter(progress)
        if let window {
            alert.beginSheetModal(for: window) { _ in cancellation.cancel() }
        }

        let engine = fileOperations
        Task { [weak self, weak alert] in
            let result = await Task.detached(priority: .userInitiated) {
                engine.transfer(
                    sources,
                    to: directory,
                    kind: kind,
                    cancelled: { cancellation.isCancelled },
                    progress: { completed, total in
                        Task { @MainActor in reporter.update(completed: completed, total: total) }
                    }
                ) { _, _ in resolution }
            }.value
            guard let self else { return }
            if let alert, alert.window.sheetParent != nil { alert.window.sheetParent?.endSheet(alert.window) }
            self.operationCancellation = nil
            self.fileOperations.discardUndo(self.lastTransferRecords)
            self.lastTransferRecords = result.completed
            if !result.completed.isEmpty {
                self.undoStack.record(.transfer(result.completed))
            }
            if kind == .move { result.completed.forEach { self.cutURLs.remove($0.source) } }
            self.reloadContents()
            if !result.failures.isEmpty {
                self.showError("Some items could not be transferred", detail: result.failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
            } else if result.wasCancelled {
                self.statusLabel.stringValue = "Operation cancelled after \(result.completed.count) item(s)"
            } else {
                self.statusLabel.stringValue = "Completed \(result.completed.count) item(s) — use ⌘Z to undo"
            }
        }
    }

    private func conflictResolution(for sources: [URL], in directory: URL, kind: FileTransferKind) -> FileConflictResolution? {
        let conflicts = sources.compactMap { source -> (URL, URL)? in
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if kind == .copy, destination.standardizedFileURL == source.standardizedFileURL { return nil }
            return fileManager.fileExists(atPath: destination.path) ? (source, destination) : nil
        }
        guard let first = conflicts.first else { return .keepBoth }
        let srcValues = try? first.0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let dstValues = try? first.1.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let srcSize = ByteCountFormatter.string(fromByteCount: Int64(srcValues?.fileSize ?? 0), countStyle: .file)
        let dstSize = ByteCountFormatter.string(fromByteCount: Int64(dstValues?.fileSize ?? 0), countStyle: .file)
        let srcDate = srcValues?.contentModificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—"
        let dstDate = dstValues?.contentModificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(first.0.lastPathComponent)” already exists in \(directory.lastPathComponent)"
        alert.informativeText = """
        Source: \(srcSize) · Modified \(srcDate)
        Existing: \(dstSize) · Modified \(dstDate)
        \(conflicts.count > 1 ? "\nApplies to all \(conflicts.count) conflicting items in this transfer." : "")
        """
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    @objc func undoLastOperation(_ sender: Any?) {
        if let outcome = undoStack.undoLast() {
            if outcome.failures.isEmpty {
                lastTransferRecords = []
                reloadContents()
                statusLabel.stringValue = "Undid \(outcome.summary)"
            } else {
                showError("Could not completely undo the operation", detail: outcome.failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
            }
            return
        }
        guard !lastTransferRecords.isEmpty else { NSSound.beep(); return }
        let records = lastTransferRecords
        let failures = fileOperations.undo(records)
        if failures.isEmpty {
            lastTransferRecords = []
            reloadContents()
            statusLabel.stringValue = "Undid the last file operation"
        } else {
            showError("Could not completely undo the operation", detail: failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
        }
    }

    @objc func redoLastOperation(_ sender: Any?) {
        guard let outcome = undoStack.redoLast() else { NSSound.beep(); return }
        if outcome.failures.isEmpty {
            reloadContents()
            statusLabel.stringValue = "Redid \(outcome.summary)"
        } else {
            showError("Could not redo the operation", detail: outcome.failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
        }
    }

    @objc func selectAllItems(_ sender: Any?) {
        if viewMode.usesIconGrid {
            collectionView.selectItems(at: Set(visibleItems.indices.map { IndexPath(item: $0, section: 0) }), scrollPosition: [])
        } else {
            tableView.selectRowIndexes(IndexSet(integersIn: 0..<visibleItems.count), byExtendingSelection: false)
        }
        updateStatus()
        updatePreview()
    }

    @objc private func revealSelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        let targets = urls.isEmpty ? [currentURL] : urls
        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(targets, withApplicationAt: finderURL, configuration: config)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
    }

    @objc private func openSelectionInFinder(_ sender: Any?) {
        let target = selectedItems.first?.url ?? currentURL
        let folder = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !FileTextFormatter.isPackage(target)
            ? target
            : target.deletingLastPathComponent()
        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([folder], withApplicationAt: finderURL, configuration: config)
        } else {
            NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: folder.path)
        }
    }

    private var contextualLocationURL: URL {
        selectedItems.first?.url ?? currentURL
    }

    private func pathRelativeToHome(_ url: URL) -> String {
        let homeParts = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        let targetParts = url.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < min(homeParts.count, targetParts.count),
              homeParts[commonCount] == targetParts[commonCount] {
            commonCount += 1
        }
        let upward = Array(repeating: "..", count: homeParts.count - commonCount)
        let downward = Array(targetParts.dropFirst(commonCount))
        let relative = (upward + downward).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    private func copyStringToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func configureNavButton(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = help
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func commandButton(_ title: String, symbol: String, help: String, action: Selector, labeled: Bool = false) -> NSButton {
        let button = NSButton(title: labeled ? title : "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = labeled ? .imageLeading : .imageOnly
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.toolTip = help
        return button
    }

    private func makeItemContextMenu(includesRevealInFinder: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        addNewSubmenu(to: menu)
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(reload(_:)), keyEquivalent: "")
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refresh.target = self
        menu.addItem(.separator())

        let open = menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        open.target = self
        let openInFinder = menu.addItem(withTitle: "Open with Finder", action: #selector(openSelectionInFinder(_:)), keyEquivalent: "")
        openInFinder.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Open with Finder")
        openInFinder.target = self
        let showPkg = menu.addItem(withTitle: "Show Package Contents", action: #selector(showPackageContents(_:)), keyEquivalent: "")
        showPkg.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Show Package Contents")
        showPkg.target = self
        let openWithItem = menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
        openWithItem.submenu = makeOpenWithMenu()
        let quickLookItem = menu.addItem(withTitle: "Quick Look", action: #selector(quickLook(_:)), keyEquivalent: "")
        quickLookItem.target = self
        let getInfo = menu.addItem(withTitle: "Get Info", action: #selector(showGetInfo(_:)), keyEquivalent: "")
        getInfo.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Get Info")
        getInfo.target = self
        let edit = menu.addItem(withTitle: "Edit in OpenExplorer", action: #selector(editInOpenExplorer(_:)), keyEquivalent: "")
        edit.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Edit in OpenExplorer")
        edit.target = self

        menu.addItem(.separator())
        let compressZip = menu.addItem(withTitle: "Compress to ZIP", action: #selector(compressSelectionToZip(_:)), keyEquivalent: "")
        compressZip.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Compress to ZIP")
        compressZip.target = self
        let compressCleanZip = menu.addItem(withTitle: "Compress Clean ZIP (No .DS_Store)", action: #selector(compressSelectionCleanZip(_:)), keyEquivalent: "")
        compressCleanZip.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Clean Cross-Platform ZIP")
        compressCleanZip.target = self
        let browseArchive = menu.addItem(withTitle: "Browse Inside Archive…", action: #selector(browseInsideArchive(_:)), keyEquivalent: "")
        browseArchive.image = NSImage(systemSymbolName: "ArchiveBox", accessibilityDescription: "Browse Inside Archive")
        browseArchive.target = self

        menu.addItem(.separator())
        let favorite = menu.addItem(withTitle: "Add to Favorites", action: #selector(addFavorite(_:)), keyEquivalent: "")
        favorite.target = self
        let tagsMenuItem = menu.addItem(withTitle: "Finder Tags", action: nil, keyEquivalent: "")
        tagsMenuItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Finder Tags")
        tagsMenuItem.submenu = makeTagsSubmenu()
        let shareItem = menu.addItem(withTitle: "Share…", action: #selector(shareSelection(_:)), keyEquivalent: "")
        shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareItem.target = self
        let cut = menu.addItem(withTitle: "Cut", action: #selector(cutSelection(_:)), keyEquivalent: "")
        cut.target = self
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        copy.target = self
        let paste = menu.addItem(withTitle: "Paste Here", action: #selector(paste(_:)), keyEquivalent: "")
        paste.target = self
        let copyRelativePath = menu.addItem(withTitle: "Copy Path Relative to Home", action: #selector(copyPathRelativeToHome(_:)), keyEquivalent: "")
        copyRelativePath.target = self

        let openTerminal = menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        openTerminal.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Open in Terminal")
        openTerminal.target = self
        let editors = DeveloperToolsManager.installedEditors(fileManager: fileManager)
        if !editors.isEmpty {
            let ideItem = menu.addItem(withTitle: "Open in Code Editor", action: nil, keyEquivalent: "")
            let ideSubmenu = NSMenu(title: "Open in Code Editor")
            for editor in editors {
                let item = ideSubmenu.addItem(withTitle: "Open in \(editor.name)", action: #selector(openInDeveloperApp(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: editor.symbolName, accessibilityDescription: editor.name)
                item.representedObject = editor.url
                item.target = self
            }
            ideItem.submenu = ideSubmenu
        }

        let cloudSubmenuItem = menu.addItem(withTitle: "Cloud Storage", action: nil, keyEquivalent: "")
        let cloudSubmenu = NSMenu(title: "Cloud Storage")
        let dlItem = cloudSubmenu.addItem(withTitle: "Download Cloud Item Now", action: #selector(downloadCloudSelection(_:)), keyEquivalent: "")
        dlItem.target = self
        let evictItem = cloudSubmenu.addItem(withTitle: "Evict Local Copy (Free Up Space)", action: #selector(evictCloudSelection(_:)), keyEquivalent: "")
        evictItem.target = self
        cloudSubmenuItem.submenu = cloudSubmenu

        menu.addItem(.separator())
        let rename = menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "")
        rename.target = self
        let batchRename = menu.addItem(withTitle: "Batch Rename…", action: #selector(batchRenameSelection(_:)), keyEquivalent: "")
        batchRename.target = self
        let trash = menu.addItem(withTitle: "Move to Trash", action: #selector(trashSelection(_:)), keyEquivalent: "")
        trash.target = self
        let permDelete = menu.addItem(withTitle: "Delete Permanently…", action: #selector(permanentlyDeleteSelection(_:)), keyEquivalent: "")
        permDelete.target = self
        let restore = menu.addItem(withTitle: "Restore from Trash", action: #selector(restoreFromTrash(_:)), keyEquivalent: "")
        restore.target = self
        if includesRevealInFinder {
            let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelection(_:)), keyEquivalent: "")
            reveal.target = self
        }
        return menu
    }

    private func makeTagsSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Finder Tags")
        for tag in FinderColorTag.allCases {
            let item = menu.addItem(withTitle: tag.rawValue, action: #selector(toggleFinderTagOnSelection(_:)), keyEquivalent: "")
            item.representedObject = tag.rawValue
            item.target = self
        }
        return menu
    }

    private func makeOpenWithMenu() -> NSMenu {
        let menu = NSMenu(title: "Open With")
        menu.delegate = self
        addChooseApplicationItem(to: menu)
        return menu
    }

    private func populateOpenWithMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let fileURL = selectedItems.first?.url ?? currentURL

        let openWithOE = menu.addItem(withTitle: "OpenExplorer", action: #selector(openSelection(_:)), keyEquivalent: "")
        let oeIcon = NSApp.applicationIconImage ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "OpenExplorer")
        oeIcon?.size = NSSize(width: 16, height: 16)
        openWithOE.image = oeIcon
        openWithOE.target = self

        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            let finderItem = menu.addItem(withTitle: "Finder", action: #selector(openWithApplication(_:)), keyEquivalent: "")
            let finderIcon = NSWorkspace.shared.icon(forFile: finderURL.path)
            finderIcon.size = NSSize(width: 16, height: 16)
            finderItem.image = finderIcon
            finderItem.representedObject = finderURL
            finderItem.target = self
        }
        menu.addItem(.separator())

        var applications = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        if TextEditorWindowController.canOpen(fileURL),
           let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            applications.append(textEdit)
        }
        let ownBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let finderBundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")?.standardizedFileURL
        var seenPaths = Set<String>()
        applications = applications
            .filter {
                $0.standardizedFileURL != ownBundleURL
                    && $0.standardizedFileURL != finderBundleURL
                    && seenPaths.insert($0.standardizedFileURL.path).inserted
            }
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }

        if !applications.isEmpty {
            for applicationURL in applications {
                let name = applicationURL.deletingPathExtension().lastPathComponent
                let item = menu.addItem(withTitle: name, action: #selector(openWithApplication(_:)), keyEquivalent: "")
                let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                item.representedObject = applicationURL
                item.target = self
            }
            menu.addItem(.separator())
        }
        addChooseApplicationItem(to: menu)
    }

    private func addChooseApplicationItem(to menu: NSMenu) {
        let choose = menu.addItem(withTitle: "Choose Application…", action: #selector(chooseApplication(_:)), keyEquivalent: "")
        choose.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: "Choose Application")
        choose.target = self
    }

    private func makeNewMenu() -> NSMenu {
        let menu = NSMenu(title: "New")
        let folder = menu.addItem(withTitle: "New Folder", action: #selector(createFolder(_:)), keyEquivalent: "")
        folder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")
        folder.target = self
        let file = menu.addItem(withTitle: "New Blank File…", action: #selector(createBlankFile(_:)), keyEquivalent: "")
        file.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "New Blank File")
        file.target = self
        menu.addItem(.separator())
        for (idx, template) in DeveloperToolsManager.builtInTemplates.enumerated() {
            let item = menu.addItem(withTitle: template.title, action: #selector(createFileFromTemplateItem(_:)), keyEquivalent: "")
            item.tag = idx
            item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: template.title)
            item.target = self
        }
        return menu
    }

    private func addNewSubmenu(to menu: NSMenu) {
        let newItem = menu.addItem(withTitle: "New", action: nil, keyEquivalent: "")
        newItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
        newItem.submenu = makeNewMenu()
    }

    private func commandSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return separator
    }

    private func sidebarSeparator() -> NSBox {
        let separator = makeSeparator()
        separator.widthAnchor.constraint(equalToConstant: 190).isActive = true
        return separator
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func tableColumn(_ id: String, title: String, width: CGFloat, min: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        return column
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatFriendlyDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today, \(timeOnlyFormatter.string(from: date))"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday, \(timeOnlyFormatter.string(from: date))"
        }
        return dateFormatter.string(from: date)
    }

    private static func tagColor(for tag: String) -> NSColor {
        switch tag.lowercased() {
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "blue": .systemBlue
        case "purple": .systemPurple
        default: .systemGray
        }
    }

    // MARK: - Automated Feature Screenshot Capture

    func captureAllFeatureScreenshots(to outputDirectory: URL) throws {
        guard let window, let contentView = window.contentView else { return }
        if fileManager.fileExists(atPath: outputDirectory.path) {
            let existing = (try? fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in existing where ["png", "gif", "mp4", "mov"].contains(file.pathExtension.lowercased()) {
                try? fileManager.removeItem(at: file)
            }
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let savedCheckboxes = ExplorerPreferences.shared.showItemCheckboxes
        let savedFolderStyle = ExplorerPreferences.shared.folderIconStyle
        let savedFolderSizes = ExplorerPreferences.shared.calculateFolderSizes
        let savedGitBadges = ExplorerPreferences.shared.showGitBadges
        defer {
            ExplorerPreferences.shared.showItemCheckboxes = savedCheckboxes
            ExplorerPreferences.shared.folderIconStyle = savedFolderStyle
            ExplorerPreferences.shared.calculateFolderSizes = savedFolderSizes
            ExplorerPreferences.shared.showGitBadges = savedGitBadges
            try? fileManager.removeItem(at: DemoScreenshotEnvironment.sandboxRootURL)
        }

        ExplorerPreferences.shared.folderIconStyle = .windowsGold
        ExplorerPreferences.shared.calculateFolderSizes = true
        ExplorerPreferences.shared.showGitBadges = true
        ExplorerPreferences.shared.showItemCheckboxes = false

        window.setContentSize(NSSize(width: 1420, height: 860))
        window.appearance = NSAppearance(named: .aqua)

        // Pre-populate calculated folder sizes synchronously so every folder row shows realistic byte counts
        for dir in [
            DemoScreenshotEnvironment.productDesignURL,
            DemoScreenshotEnvironment.engineeringDocsURL,
            DemoScreenshotEnvironment.releaseBuildsURL,
            DemoScreenshotEnvironment.quarterlyReportsURL,
            DemoScreenshotEnvironment.marketingAssetsURL
        ] {
            calculatedFolderSizes[dir.standardizedFileURL.path] = FolderSizeCache.shared.calculateSize(for: dir, maxFiles: 1_000)
        }

        // Pre-populate image thumbnails in ThumbnailCacheService for crisp icon grids
        let imageURLs = [
            DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png"),
            DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Design-System-Cover.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-01.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-02.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-03.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-04.png")
        ]
        let trafficLightsPoint = NSPoint(x: 20, y: 23)
        var demoFrames: [(url: URL, title: String, subtitle: String)] = []

        func recordScreenshot(_ fileName: String, title: String, subtitle: String) -> URL {
            let url = outputDirectory.appendingPathComponent(fileName)
            demoFrames.append((url: url, title: title, subtitle: subtitle))
            return url
        }

        // 1. Home / Main Explorer (Details View)
        navigate(to: DemoScreenshotEnvironment.workspaceURL, recordHistory: false)
        viewMode = .details
        showsDetailsPane = true
        showsPreviewPane = true
        updatePaneVisibility()
        applyViewMode()
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png"))
        if let img = NSImage(contentsOf: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png")) {
            previewImage.image = img
        }
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("01-home-details-view.png", title: "Home & Details View", subtitle: "Multi-tab navigation, Git badges, folder sizes, and live Preview & Details pane")
        )

        // 2. Large Icons Grid View
        viewMode = .largeIcons
        applyViewMode()
        for url in imageURLs {
            if let img = NSImage(contentsOf: url) {
                for indexPath in collectionView.indexPathsForVisibleItems() where visibleItems.indices.contains(indexPath.item) {
                    if visibleItems[indexPath.item].url.standardizedFileURL == url.standardizedFileURL,
                       let cell = collectionView.item(at: indexPath) as? ExplorerCollectionItem {
                        cell.setPreviewThumbnail(img)
                    }
                }
            }
        }
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Design-System-Cover.png"))
        if let img = NSImage(contentsOf: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Design-System-Cover.png")) {
            previewImage.image = img
        }
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("02-large-icons-grid-view.png", title: "Icon Grid Views", subtitle: "Extra Large, Large, Medium, and Small icon grids with live image thumbnails")
        )

        // 3. Tiles View
        viewMode = .tiles
        applyViewMode()
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Release-Notes-v2.1.md"))
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("03-tiles-view.png", title: "Tiles Layout", subtitle: "Windows Explorer-style side-by-side cards with file type and size metadata")
        )

        // 4. Content View
        viewMode = .content
        applyViewMode()
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("System-Architecture.pdf"))
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("04-content-view.png", title: "Content Layout", subtitle: "Rich row summaries showing modification timestamps, file kind, and byte size")
        )

        // 5. Dual-Pane Split View
        viewMode = .details
        applyViewMode()
        secondaryURL = DemoScreenshotEnvironment.releaseBuildsURL
        if !isDualPaneVisible {
            toggleDualPane(nil)
        }
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Workspace-Bundle.zip"))
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("05-dual-pane-split-view.png", title: "Dual-Pane Split View (⌥⌘P)", subtitle: "Side-by-side folder comparison with F5 Copy and F6 Move commander shortcuts")
        )
        if isDualPaneVisible {
            toggleDualPane(nil)
        }

        // 6. Editable Address Bar, Checkboxes & Tag Filtering
        ExplorerPreferences.shared.showItemCheckboxes = true
        tableView.reloadData()
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png"))
        focusAddress(nil)
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("06-address-bar-and-checkboxes.png", title: "Editable Address Bar & Checkboxes", subtitle: "Direct path editing (⌘L), interactive breadcrumbs, and multi-select checkboxes")
        )
        ExplorerPreferences.shared.showItemCheckboxes = false
        rebuildBreadcrumbs()
        tableView.reloadData()

        // 7. Command Palette (⌘K)
        let paletteItems = buildCommandPaletteItems()
        let cmdPalette = CommandPaletteWindowController(
            mode: .commands,
            currentDirectory: currentURL,
            includeHidden: showHiddenFiles,
            initialItems: paletteItems
        ) { _, _ in }
        if let paletteView = cmdPalette.window?.contentView {
            cmdPalette.configureDemoQuery("", selectedIndex: 0)
            let origin = NSPoint(
                x: (contentView.bounds.width - paletteView.bounds.width) / 2,
                y: contentView.bounds.height - paletteView.bounds.height - 95
            )
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                overlayView: paletteView,
                overlayOriginInBase: origin,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("07-command-palette.png", title: "Command Palette (⌘K)", subtitle: "Instant keyboard-driven access to every file operation, view mode, and tool")
            )
        }

        // 8. Fuzzy Go-To Navigation (⌘P)
        let fuzzyPalette = CommandPaletteWindowController(
            mode: .fuzzyNavigation,
            currentDirectory: currentURL,
            includeHidden: showHiddenFiles,
            initialItems: paletteItems
        ) { _, _ in }
        if let fuzzyView = fuzzyPalette.window?.contentView {
            fuzzyPalette.configureDemoQuery("Design", selectedIndex: 0)
            let origin = NSPoint(
                x: (contentView.bounds.width - fuzzyView.bounds.width) / 2,
                y: contentView.bounds.height - fuzzyView.bounds.height - 95
            )
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                overlayView: fuzzyView,
                overlayOriginInBase: origin,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("08-fuzzy-go-to.png", title: "Fuzzy Go-To Navigation (⌘P)", subtitle: "Jump directly to nested files, folders, favorites, and recent locations")
            )
        }

        // 9. Batch Rename (⇧⌘R)
        navigate(to: DemoScreenshotEnvironment.productDesignURL, recordHistory: false)
        let renameTargets = (1...4).map {
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent(String(format: "icon-draft-0%d.png", $0))
        }
        let batchRename = BatchRenameWindowController(urls: renameTargets) { _ in }
        batchRename.configureDemoFindReplace(find: "icon-draft", replace: "brand-icon")
        if let batchView = batchRename.window?.contentView {
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                titleBarTitle: "Batch Rename (4 Items)",
                overlayView: batchView,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("09-batch-rename.png", title: "Batch Rename Engine (⇧⌘R)", subtitle: "Find & Replace, Regular Expressions, Prefix/Suffix, and Sequential Numbering")
            )
        }

        // 10. Virtual Archive Inspector (.zip Browser)
        navigate(to: DemoScreenshotEnvironment.workspaceURL, recordHistory: false)
        let archiveURL = DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Workspace-Bundle.zip")
        selectItem(at: archiveURL)
        if let archiveBrowser = try? ArchiveBrowserWindowController(archiveURL: archiveURL),
           let archiveView = archiveBrowser.window?.contentView {
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                titleBarTitle: "Workspace-Bundle.zip — Archive Inspector",
                overlayView: archiveView,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("10-archive-inspector.png", title: "Virtual Archive Inspector", subtitle: "Browse inside .zip archives and extract individual items without unpacking everything")
            )
        }

        // 11. Built-In Plain-Text & Code Editor
        let notesURL = DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Release-Notes-v2.1.md")
        if let editor = try? TextEditorWindowController(fileURL: notesURL),
           let editorView = editor.window?.contentView {
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                titleBarTitle: "Release-Notes-v2.1.md — OpenExplorer Editor",
                overlayView: editorView,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("11-built-in-text-editor.png", title: "Built-In Plain-Text & Code Editor", subtitle: "Edit dotfiles, Markdown, JSON, and scripts with line numbers and ⌘S save")
            )
        }

        // 12. Get Info & Checksums (⌘I)
        if let hashes = try? FileHashCalculator.computeHashes(for: notesURL) {
            let infoCard = buildDemoGetInfoOverlay(
                fileName: "Release-Notes-v2.1.md",
                displayPath: "/Users/\(DemoScreenshotEnvironment.demoUserName)/Workspace/Release-Notes-v2.1.md",
                byteCount: Int64((try? notesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 842),
                owner: DemoScreenshotEnvironment.demoUserName,
                group: "staff",
                permissions: "644",
                hashes: hashes
            )
            selectItem(at: notesURL)
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                overlayView: infoCard,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("12-get-info-and-checksums.png", title: "Get Info & Checksums (⌘I)", subtitle: "Inspect permissions, POSIX mode bits, and SHA-256 / SHA-1 / MD5 hashes")
            )
        }

        // 13. OpenExplorer Settings (⌘,)
        let settingsController = SettingsWindowController()
        settingsController.syncFromPreferences()
        if let settingsView = settingsController.window?.contentView {
            try DemoScreenshotGenerator.renderViewToPNG(
                contentView,
                appearance: NSAppearance(named: .aqua),
                drawTrafficLightsAt: trafficLightsPoint,
                titleBarTitle: "OpenExplorer Settings",
                overlayView: settingsView,
                dimBaseUnderOverlay: true,
                to: recordScreenshot("13-settings-preferences.png", title: "Settings & System Integration (⌘,)", subtitle: "Default file manager, global ⌘E hotkey, Clean ZIP mode, and ‘oe’ CLI installer")
            )
        }

        // 14. Dark Mode Home / Explorer View
        navigate(to: DemoScreenshotEnvironment.workspaceURL, recordHistory: false)
        viewMode = .details
        applyViewMode()
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png"))
        if let img = NSImage(contentsOf: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png")) {
            previewImage.image = img
        }
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .darkAqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("14-dark-mode-home.png", title: "Native Dark Appearance", subtitle: "Adaptive macOS materials, crisp contrast, and Windows 11 Gold folder icons")
        )

        // 15. Recursive Search & Local Folder Filter
        viewMode = .details
        applyViewMode()
        searchField.stringValue = "png"
        searchResults = [
            DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Dashboard-Preview.png"),
            DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Design-System-Cover.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-01.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-02.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-03.png"),
            DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-04.png")
        ].compactMap(makeFileItem)
        filterField.stringValue = ""
        applyFilterAndSort()
        statusLabel.stringValue = "6 matching items across Workspace & subfolders"
        selectItem(at: DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-01.png"))
        if let img = NSImage(contentsOf: DemoScreenshotEnvironment.productDesignURL.appendingPathComponent("icon-draft-01.png")) {
            previewImage.image = img
        }
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("15-recursive-search.png", title: "Spotlight-Backed Recursive Search", subtitle: "Instant current-folder filter plus recursive subfolder search with live fallback")
        )
        searchResults = nil
        searchField.stringValue = ""
        filterField.stringValue = ""
        applyFilterAndSort()

        // 16. Hidden Dotfiles View & macOS Classic Blue Folder Theme
        showHiddenFiles = true
        ExplorerPreferences.shared.folderIconStyle = .macOSBlue
        reloadContents()
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent(".env.example"))
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            to: recordScreenshot("16-hidden-dotfiles-and-blue-folders.png", title: "Hidden Dotfiles & Folder Themes", subtitle: "One-click hidden file toggle and customizable macOS Blue or Windows Gold folders")
        )
        showHiddenFiles = false
        ExplorerPreferences.shared.folderIconStyle = .windowsGold
        reloadContents()

        // 17. Rich Right-Click Context Menu & New File Templates
        selectItem(at: DemoScreenshotEnvironment.workspaceURL.appendingPathComponent("Release-Notes-v2.1.md"))
        let contextMenuCard = buildDemoContextMenuOverlay()
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            overlayView: contextMenuCard,
            overlayOriginInBase: NSPoint(x: 410, y: 175),
            dimBaseUnderOverlay: false,
            to: recordScreenshot("17-context-menu-and-templates.png", title: "Power Context Menu & File Templates", subtitle: "New file templates, Clean ZIP, Finder tags, Terminal launch, and iCloud actions")
        )

        // 18. File Transfer Progress & Conflict Resolution Dialog
        let conflictCard = buildDemoTransferAndConflictOverlay()
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            overlayView: conflictCard,
            dimBaseUnderOverlay: true,
            to: recordScreenshot("18-copy-progress-and-conflict-dialog.png", title: "Copy Progress & Conflict Resolution", subtitle: "Cancellable file transfers with Keep Both, Replace, Skip, and ⌘Z Undo")
        )

        // 19. Connect to Server (SMB / AFP / NFS / WebDAV)
        let serverCard = buildDemoConnectServerOverlay()
        try DemoScreenshotGenerator.renderViewToPNG(
            contentView,
            appearance: NSAppearance(named: .aqua),
            drawTrafficLightsAt: trafficLightsPoint,
            overlayView: serverCard,
            dimBaseUnderOverlay: true,
            to: recordScreenshot("19-connect-to-server.png", title: "Connect to Network Servers", subtitle: "Mount SMB, AFP, NFS, and WebDAV shares directly from the sidebar")
        )

        // Generate animated GIF and MP4 showcase demos from the unique screenshots
        try DemoScreenshotGenerator.generateAnimatedShowcase(
            frames: demoFrames,
            outputDirectory: outputDirectory
        )
    }

    private func buildDemoContextMenuOverlay() -> NSView {
        let card = AppearanceSurfaceView(frame: NSRect(x: 0, y: 0, width: 310, height: 470))
        card.fillColor = .windowBackgroundColor
        card.wantsLayer = true

        let entries: [(String, String, String, Bool)] = [
            ("plus", "New (Folder / Blank File / Templates)", "▸", false),
            ("arrow.clockwise", "Refresh", "⌘R", false),
            ("", "---", "", false),
            ("folder", "Open", "⌘O", true),
            ("eye", "Quick Look", "Space", false),
            ("info.circle", "Get Info & Checksums", "⌘I", false),
            ("pencil.and.outline", "Edit in OpenExplorer", "", false),
            ("", "---", "", false),
            ("doc.zipper", "Compress to ZIP", "", false),
            ("sparkles", "Compress Clean ZIP (No .DS_Store)", "", false),
            ("archivebox", "Browse Inside Archive…", "", false),
            ("", "---", "", false),
            ("star", "Add to Favorites", "", false),
            ("tag", "Finder Tags (Red, Orange, Blue…)", "▸", false),
            ("terminal", "Open in Terminal", "", false),
            ("chevron.left.forwardslash.chevron.right", "Open in Code Editor", "▸", false),
            ("icloud", "Cloud Storage (Download / Evict)", "▸", false),
            ("", "---", "", false),
            ("pencil", "Batch Rename…", "⇧⌘R", false),
            ("trash", "Move to Trash", "⌘⌫", false)
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (symbol, title, shortcut, highlighted) in entries {
            if title == "---" {
                let sep = NSBox()
                sep.boxType = .separator
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalToConstant: 290).isActive = true
                continue
            }
            let row = AppearanceSurfaceView(frame: NSRect(x: 0, y: 0, width: 294, height: 22))
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            if highlighted {
                row.fillColor = .controlAccentColor
            }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
            icon.contentTintColor = highlighted ? .white : .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let lbl = NSTextField(labelWithString: title)
            lbl.font = .systemFont(ofSize: 12, weight: highlighted ? .medium : .regular)
            lbl.textColor = highlighted ? .white : .labelColor

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let hint = NSTextField(labelWithString: shortcut)
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = highlighted ? .white : .tertiaryLabelColor

            let inner = NSStackView(views: [icon, lbl, spacer, hint])
            inner.orientation = .horizontal
            inner.alignment = .centerY
            inner.spacing = 8
            inner.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
            inner.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(inner)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: 294),
                row.heightAnchor.constraint(equalToConstant: 22),
                inner.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                inner.topAnchor.constraint(equalTo: row.topAnchor),
                inner.bottomAnchor.constraint(equalTo: row.bottomAnchor)
            ])
            stack.addArrangedSubview(row)
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor)
        ])
        return card
    }

    private func buildDemoTransferAndConflictOverlay() -> NSView {
        let card = AppearanceSurfaceView(frame: NSRect(x: 0, y: 0, width: 490, height: 250))
        card.fillColor = .windowBackgroundColor
        card.wantsLayer = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "File Conflict") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let title = NSTextField(labelWithString: "“Dashboard-Preview.png” already exists in Release Builds")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        let sub = NSTextField(wrappingLabelWithString: "Source: 284 KB · Modified Today, 2:15 PM\nExisting: 276 KB · Modified Yesterday, 6:40 PM\nApplies to all 3 conflicting items in this transfer.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        let progressLabel = NSTextField(labelWithString: "Copying 4 of 6 items to Release Builds…")
        progressLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 6
        progress.doubleValue = 4
        progress.widthAnchor.constraint(equalToConstant: 442).isActive = true

        let keepBoth = NSButton(title: "Keep Both", target: nil, action: nil)
        keepBoth.bezelStyle = .rounded
        keepBoth.keyEquivalent = "\r"
        let replace = NSButton(title: "Replace", target: nil, action: nil)
        replace.bezelStyle = .rounded
        let skip = NSButton(title: "Skip", target: nil, action: nil)
        skip.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let btnRow = NSStackView(views: [spacer, cancel, skip, replace, keepBoth])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let headerText = NSStackView(views: [title, sub])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        let headerRow = NSStackView(views: [icon, headerText])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 12

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [headerRow, divider, progressLabel, progress, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)
        ])
        return card
    }

    private func buildDemoConnectServerOverlay() -> NSView {
        let card = AppearanceSurfaceView(frame: NSRect(x: 0, y: 0, width: 460, height: 215))
        card.fillColor = .windowBackgroundColor
        card.wantsLayer = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "network", accessibilityDescription: "Connect to Server") ?? NSImage())
        icon.contentTintColor = .systemBlue
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let title = NSTextField(labelWithString: "Connect to Server")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        let sub = NSTextField(labelWithString: "Enter an SMB, AFP, NFS, or WebDAV network share address:")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        let addressInput = NSTextField(string: "smb://nas.example.internal/design-team-share")
        addressInput.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        addressInput.widthAnchor.constraint(equalToConstant: 414).isActive = true

        let protoHint = NSTextField(labelWithString: "Supported protocols: smb:// · afp:// · nfs:// · https:// (WebDAV)")
        protoHint.font = .systemFont(ofSize: 11)
        protoHint.textColor = .tertiaryLabelColor

        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
        cancelBtn.bezelStyle = .rounded
        let connectBtn = NSButton(title: "Connect", target: nil, action: nil)
        connectBtn.bezelStyle = .rounded
        connectBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let btnRow = NSStackView(views: [spacer, cancelBtn, connectBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let headerText = NSStackView(views: [title, sub])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 3
        let headerRow = NSStackView(views: [icon, headerText])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let stack = NSStackView(views: [headerRow, addressInput, protoHint, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)
        ])
        return card
    }

    private func buildDemoGetInfoOverlay(
        fileName: String,
        displayPath: String,
        byteCount: Int64,
        owner: String,
        group: String,
        permissions: String,
        hashes: FileHashes
    ) -> NSView {
        let card = AppearanceSurfaceView(frame: NSRect(x: 0, y: 0, width: 520, height: 310))
        card.fillColor = .windowBackgroundColor
        card.wantsLayer = true

        let iconView = NSImageView(image: NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Get Info") ?? NSImage())
        iconView.contentTintColor = .controlAccentColor
        iconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let titleLabel = NSTextField(labelWithString: fileName)
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        let pathLabel = NSTextField(labelWithString: displayPath)
        pathLabel.font = .systemFont(ofSize: 11.5)
        pathLabel.textColor = .secondaryLabelColor

        let sizeLabel = NSTextField(labelWithString: "Size: \(FileTextFormatter.byteCount(byteCount, isDirectory: false)) (\(byteCount) bytes)")
        sizeLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let ownerLabel = NSTextField(labelWithString: "Owner: \(owner)    Group: \(group)")
        ownerLabel.font = .systemFont(ofSize: 12)

        let permTitle = NSTextField(labelWithString: "POSIX permissions:")
        permTitle.font = .systemFont(ofSize: 12)
        let permField = NSTextField(string: permissions)
        permField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let lockedCheck = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
        let permRow = NSStackView(views: [permTitle, permField, lockedCheck])
        permRow.orientation = .horizontal
        permRow.alignment = .centerY
        permRow.spacing = 10

        let shaLabel = NSTextField(labelWithString: "SHA-256: \(hashes.sha256)")
        shaLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let md5Label = NSTextField(labelWithString: "MD5: \(hashes.md5) · SHA-1: \(hashes.sha1)")
        md5Label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        md5Label.textColor = .secondaryLabelColor

        let copyShaBtn = NSButton(title: "Copy SHA-256", target: nil, action: nil)
        copyShaBtn.bezelStyle = .rounded
        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
        cancelBtn.bezelStyle = .rounded
        let applyBtn = NSButton(title: "Apply", target: nil, action: nil)
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [copyShaBtn, spacer, cancelBtn, applyBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let headerTextStack = NSStackView(views: [titleLabel, pathLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 3
        let headerRow = NSStackView(views: [iconView, headerTextStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [headerRow, divider, sizeLabel, ownerLabel, permRow, shaLabel, md5Label, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)
        ])
        return card
    }
}

private final class ExplorerTableRowView: NSTableRowView {
    var isEvenRow = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let insetRect = bounds.insetBy(dx: 4, dy: 1.5)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 7, yRadius: 7)
        let fill = isEmphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.26)
            : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.32)
        fill.setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isEvenRow && !isSelected {
            let insetRect = bounds.insetBy(dx: 4, dy: 0.5)
            let path = NSBezierPath(roundedRect: insetRect, xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.025).setFill()
            path.fill()
        }
    }
}

private final class CollapseToggleButton: NSButton {
    private weak var targetView: NSView?

    init(targetView: NSView) {
        self.targetView = targetView
        super.init(frame: .zero)
        title = "▾"
        isBordered = false
        font = .systemFont(ofSize: 10, weight: .bold)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(toggleSection(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleSection(_ sender: Any?) {
        guard let targetView else { return }
        targetView.isHidden.toggle()
        title = targetView.isHidden ? "▸" : "▾"
    }
}

private final class ExplorerCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ExplorerCollectionItem")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let labels = NSStackView()
    private let layoutStack = NSStackView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    override func loadView() {
        view = AppearanceSurfaceView()
        view.layer?.cornerRadius = 9

        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 2
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.addArrangedSubview(name)
        labels.addArrangedSubview(detail)

        layoutStack.orientation = .vertical
        layoutStack.alignment = .centerX
        layoutStack.spacing = 7
        layoutStack.translatesAutoresizingMaskIntoConstraints = false
        layoutStack.addArrangedSubview(icon)
        layoutStack.addArrangedSubview(labels)
        view.addSubview(layoutStack)

        iconWidth = icon.widthAnchor.constraint(equalToConstant: 60)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            iconWidth,
            iconHeight,
            layoutStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            layoutStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            layoutStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            layoutStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            name.widthAnchor.constraint(lessThanOrEqualTo: layoutStack.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: layoutStack.widthAnchor)
        ])
    }

    func configure(with item: FileItem, mode: BrowserViewMode, isCut: Bool, calculatedSize: Int64? = nil) {
        let iconSize: CGFloat
        switch mode {
        case .extraLargeIcons: iconSize = 112
        case .largeIcons: iconSize = 82
        case .mediumIcons: iconSize = 56
        case .smallIcons: iconSize = 30
        case .tiles: iconSize = 48
        case .list, .details, .content: iconSize = 56
        }
        iconWidth.constant = iconSize
        iconHeight.constant = iconSize

        if item.isDirectory {
            let symbol = item.projectBadge != nil ? "folder.fill.badge.gearshape" : "folder.fill"
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Folder")
                ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            icon.contentTintColor = .explorerFolderTint
        } else if let cached = ThumbnailCacheService.shared.cachedThumbnail(for: item.url, size: iconSize) {
            icon.image = cached
            icon.contentTintColor = nil
        } else {
            icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.contentTintColor = nil
            if ThumbnailCacheService.shared.isEligibleForThumbnail(item.url, isDirectory: false) {
                let itemURL = item.url
                ThumbnailCacheService.shared.requestThumbnail(for: itemURL, size: iconSize) { [weak self] thumb in
                    guard let self, let thumb else { return }
                    self.icon.image = thumb
                }
            }
        }
        let gitPrefix = item.gitState.map { "[\($0.rawValue)] " } ?? ""
        icon.alphaValue = isCut ? 0.5 : 1.0
        name.stringValue = gitPrefix + item.name
        name.textColor = isCut ? .tertiaryLabelColor : .labelColor
        name.alphaValue = isCut ? 0.65 : 1.0
        detail.stringValue = "\(item.kind) · \(item.sizeText(calculatedFolderSize: calculatedSize))"
        detail.alphaValue = isCut ? 0.55 : 1.0

        if mode == .tiles {
            layoutStack.orientation = .horizontal
            layoutStack.alignment = .centerY
            name.alignment = .left
            detail.alignment = .left
            detail.isHidden = false
        } else {
            layoutStack.orientation = .vertical
            layoutStack.alignment = .centerX
            name.alignment = .center
            detail.isHidden = true
        }
    }

    func setPreviewThumbnail(_ image: NSImage) {
        icon.image = image
        icon.contentTintColor = nil
    }

    override var isSelected: Bool {
        didSet {
            (view as? AppearanceSurfaceView)?.fillColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.24)
                : .clear
        }
    }
}

private final class ExplorerTableView: NSTableView {
    var onKeyCommand: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyCommand?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 {
            if !selectedRowIndexes.contains(clicked) {
                selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
        } else {
            deselectAll(nil)
        }
        return super.menu(for: event)
    }
}

private final class ExplorerCollectionView: NSCollectionView {
    var onFileDrop: (([URL], IndexPath?, NSDraggingInfo) -> Bool)?
    var onKeyCommand: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyCommand?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let clicked = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(clicked) {
                selectItems(at: [clicked], scrollPosition: [])
            }
        } else {
            deselectItems(at: selectionIndexPaths)
        }
        return super.menu(for: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        let local = sender.draggingSource is ExplorerTableView || sender.draggingSource is ExplorerCollectionView
        return local && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let point = convert(sender.draggingLocation, from: nil)
        return onFileDrop?(urls, indexPathForItem(at: point), sender) ?? false
    }
}

private final class PathButton: NSButton {
    var destinationURL: URL?
}

private final class FileDropButton: NSButton {
    var destinationURL: URL?
    var onFileDrop: (([URL], URL, NSDraggingInfo) -> Bool)?
    var isSelectedLocation = false {
        didSet { updatePillAppearance() }
    }
    private var isHovered = false {
        didSet { updatePillAppearance() }
    }
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updatePillAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 7
        if isSelectedLocation {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard destinationURL != nil else { return [] }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        let local = sender.draggingSource is ExplorerTableView || sender.draggingSource is ExplorerCollectionView
        return local && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let destinationURL else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return onFileDrop?(urls, destinationURL, sender) ?? false
    }
}

private class AppearanceSurfaceView: NSView {
    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor? {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.resolvedColor(with: effectiveAppearance).cgColor
        layer?.borderColor = strokeColor?.resolvedColor(with: effectiveAppearance).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }
}

private final class FileDropSurfaceView: AppearanceSurfaceView {
    var destinationURL: URL?
    var onFileDrop: (([URL], URL, NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard destinationURL != nil else { return [] }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        let local = sender.draggingSource is ExplorerTableView || sender.draggingSource is ExplorerCollectionView
        return local && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let destinationURL else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return onFileDrop?(urls, destinationURL, sender) ?? false
    }
}

private final class BreadcrumbView: AppearanceSurfaceView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onBackgroundClick?()
    }
}

@MainActor
private final class OperationProgressReporter {
    private weak var indicator: NSProgressIndicator?

    init(_ indicator: NSProgressIndicator) { self.indicator = indicator }

    func update(completed: Int, total: Int) {
        indicator?.maxValue = Double(max(1, total))
        indicator?.doubleValue = Double(completed)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension NSColor {
    static var explorerFolderTint: NSColor {
        if UserDefaults.standard.string(forKey: "pref.folderIconStyle") == FolderIconStyle.macOSBlue.rawValue {
            return .systemBlue
        }
        return NSColor(name: "OpenExplorerFolderTint") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(deviceRed: 0.89, green: 0.64, blue: 0.03, alpha: 1)
                : NSColor(deviceRed: 0.82, green: 0.55, blue: 0.00, alpha: 1)
        }
    }

    func resolvedColor(with appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = usingColorSpace(.deviceRGB) ?? self
        }
        return resolved
    }

    func isVisuallyEqual(to other: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        guard let lhs = usingColorSpace(.deviceRGB), let rhs = other.usingColorSpace(.deviceRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onCloseWindow?()
    }
}
