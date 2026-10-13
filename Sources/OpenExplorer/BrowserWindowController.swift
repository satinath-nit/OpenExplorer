import AppKit
import Foundation
import OpenExplorerCore
import UniformTypeIdentifiers

private struct FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let created: Date?

    var kind: String { FileTextFormatter.kind(for: url, isDirectory: isDirectory) }
    var sizeText: String { FileTextFormatter.byteCount(size, isDirectory: isDirectory) }
}

private struct ItemDetails: Sendable {
    let size: Int64
    let owner: String
    let group: String
    let permissions: Int
    let isLocked: Bool
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
    private var cutURLs: Set<URL> = []
    private var showHiddenFiles = false
    private var textEditors: [TextEditorWindowController] = []
    private var directoryMonitor: DirectoryMonitor?
    private var pendingDirectoryReload: DispatchWorkItem?
    private let fileOperations = FileOperationEngine()
    private var lastTransferRecords: [FileTransferRecord] = []
    private var operationCancellation: FileOperationCancellation?
    private var searchTask: Task<Void, Never>?
    private var searchResults: [FileItem]?
    private var isShowingTrashAccessAlert = false

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
    private var workspaceObservers: [NSObjectProtocol] = []

    private let tabStack = NSStackView()
    private let breadcrumbStack = NSStackView()
    private let breadcrumbContainer = BreadcrumbView()
    private let addressField = NSTextField()
    private let searchField = NSSearchField()
    private let tableView = ExplorerTableView()
    private let tableScroll = NSScrollView()
    private let collectionView = ExplorerCollectionView()
    private let collectionScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let previewToggle = NSButton()
    private let sortPopup = NSPopUpButton()
    private let viewPopup = NSPopUpButton()
    private let contentSplit = NSSplitView()
    private let previewPanel = NSVisualEffectView()
    private let previewImage = NSImageView()
    private let previewName = NSTextField(labelWithString: "Select an item")
    private let previewKind = NSTextField(labelWithString: "")
    private let previewKindDetail = NSTextField(labelWithString: "—")
    private let previewSize = NSTextField(labelWithString: "—")
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

    private var currentURL: URL { tabs[activeTabIndex].history.current }

    init() {
        let storedPath = UserDefaults.standard.string(forKey: "lastFolder")
        let storedURL = storedPath.map { URL(fileURLWithPath: $0) }
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let protectedTrashURL = homeURL.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
        let initialURL = storedURL.flatMap { url -> URL? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if url.standardizedFileURL == protectedTrashURL,
               (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) == nil {
                return nil
            }
            return url
        }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? homeURL
        tabs = [BrowserTab(history: BrowserHistory(initialURL: initialURL))]

        if let storedFavorites = UserDefaults.standard.stringArray(forKey: "favoriteFolders") {
            favoriteURLs = storedFavorites.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenExplorer"
        window.minSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        observeMountedVolumes()
        renderActiveTab()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        let expectedContextActions = ["Get Info", "Edit in OpenExplorer", "Copy Path Relative to Home", "Open in Terminal", "Restore from Trash"]
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
            FileItem(url: fileURL, name: fileURL.lastPathComponent, isDirectory: false, size: 0, modified: nil, created: nil),
            FileItem(url: folderURL, name: folderURL.lastPathComponent, isDirectory: true, size: 0, modified: nil, created: nil)
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
        bar.material = .headerView
        bar.blendingMode = .withinWindow

        tabStack.orientation = .horizontal
        tabStack.alignment = .bottom
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addButton.title = ""
        addButton.isBordered = false
        addButton.toolTip = "New tab"
        addButton.target = self
        addButton.action = #selector(newTab(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(tabStack)
        bar.addSubview(addButton)
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            tabStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            tabStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            addButton.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor, constant: 6),
            addButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 30),
            addButton.heightAnchor.constraint(equalToConstant: 30),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -12)
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
            let container = FileDropSurfaceView()
            container.layer?.cornerRadius = 8
            container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            container.fillColor = index == activeTabIndex ? .controlBackgroundColor : .clear
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
            button.font = .systemFont(ofSize: 13, weight: index == activeTabIndex ? .medium : .regular)
            button.lineBreakMode = .byTruncatingMiddle
            button.translatesAutoresizingMaskIntoConstraints = false
            tabIndexes[ObjectIdentifier(button)] = index

            let close = NSButton()
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
            close.title = ""
            close.isBordered = false
            close.target = self
            close.action = #selector(closeTab(_:))
            close.tag = index
            close.isEnabled = tabs.count > 1
            close.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(button)
            container.addSubview(close)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 190),
                container.heightAnchor.constraint(equalToConstant: 38),
                button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                button.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
                close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                close.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 20)
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
            breadcrumbStack.trailingAnchor.constraint(lessThanOrEqualTo: editAddress.leadingAnchor, constant: -6),
            breadcrumbStack.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: breadcrumbContainer.leadingAnchor, constant: 10),
            addressField.trailingAnchor.constraint(equalTo: editAddress.leadingAnchor, constant: -6),
            addressField.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            editAddress.trailingAnchor.constraint(equalTo: breadcrumbContainer.trailingAnchor, constant: -8),
            editAddress.centerYAnchor.constraint(equalTo: breadcrumbContainer.centerYAnchor),
            editAddress.widthAnchor.constraint(equalToConstant: 22),
            editAddress.heightAnchor.constraint(equalToConstant: 22)
        ])

        breadcrumbContainer.onBackgroundClick = { [weak self] in
            self?.focusAddress(nil)
        }

        searchField.placeholderString = "Search this folder recursively"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 250).isActive = true

        [backButton, forwardButton, upButton, breadcrumbContainer, searchField].forEach(stack.addArrangedSubview)
        breadcrumbContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        breadcrumbContainer.heightAnchor.constraint(equalToConstant: 36).isActive = true

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
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let newButton = commandButton("New", symbol: "folder.badge.plus", help: "Create a folder or blank file", action: #selector(showNewMenu(_:)), labeled: true)
        let cut = commandButton("", symbol: "scissors", help: "Cut", action: #selector(cutSelection(_:)))
        let copy = commandButton("", symbol: "doc.on.doc", help: "Copy", action: #selector(copySelection(_:)))
        let paste = commandButton("", symbol: "clipboard", help: "Paste", action: #selector(paste(_:)))
        let rename = commandButton("", symbol: "pencil", help: "Rename", action: #selector(renameSelection(_:)))
        let trash = commandButton("", symbol: "trash", help: "Move to Trash", action: #selector(trashSelection(_:)))

        sortPopup.addItems(withTitles: ["Sort: Name", "Name: Z–A", "Date Modified", "Date Created", "Size"])
        sortPopup.bezelStyle = .texturedRounded
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))

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
        viewPopup.target = self
        viewPopup.action = #selector(viewModeChanged(_:))
        viewPopup.toolTip = "Change file view"
        refreshViewMenu()

        let hidden = commandButton("Hidden", symbol: "eye.slash", help: "Show hidden files", action: #selector(toggleHidden(_:)), labeled: true)
        hidden.setButtonType(.toggle)
        let reload = commandButton("", symbol: "arrow.clockwise", help: "Refresh", action: #selector(reload(_:)))
        let quickLook = commandButton("", symbol: "eye", help: "Quick Look", action: #selector(quickLook(_:)))

        previewToggle.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Details pane")
        previewToggle.title = ""
        previewToggle.bezelStyle = .texturedRounded
        previewToggle.setButtonType(.toggle)
        previewToggle.state = showsDetailsPane ? .on : .off
        previewToggle.target = self
        previewToggle.action = #selector(togglePreview(_:))
        previewToggle.toolTip = "Show details pane"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [newButton, commandSeparator(), cut, copy, paste, rename, trash, commandSeparator(), sortPopup, viewPopup, hidden, reload, spacer, quickLook, previewToggle]
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
        addSidebarSection("FAVORITES", symbol: "star.fill", color: .systemYellow, to: stack)
        stack.addArrangedSubview(favoritesStack)
        favoritesStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildFavorites()

        stack.addArrangedSubview(sidebarSeparator())
        addSidebarSection("QUICK ACCESS", to: stack)
        addKnownFolder("Applications", symbol: "macwindow", color: .systemBlue, directory: .applicationDirectory, domain: .localDomainMask, to: stack)
        addKnownFolder("Desktop", symbol: "desktopcomputer", color: .systemTeal, directory: .desktopDirectory, to: stack)
        addKnownFolder("Documents", symbol: "doc.text", color: .systemBlue, directory: .documentDirectory, to: stack)
        addKnownFolder("Downloads", symbol: "arrow.down.circle", color: .systemGreen, directory: .downloadsDirectory, to: stack)
        addKnownFolder("Movies", symbol: "film", color: .systemPink, directory: .moviesDirectory, to: stack)
        addKnownFolder("Music", symbol: "music.note", color: .systemRed, directory: .musicDirectory, to: stack)
        addKnownFolder("Pictures", symbol: "photo", color: .systemPurple, directory: .picturesDirectory, to: stack)

        stack.addArrangedSubview(sidebarSeparator())
        addSidebarSection("CLOUD & DEVICES", to: stack)
        let cloud = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: cloud.path) {
            addSidebarLocation("iCloud Drive", symbol: "icloud", color: .systemCyan, url: cloud, to: stack)
        }
        if let oneDrive = oneDriveURL() {
            addSidebarLocation("OneDrive", symbol: "cloud", color: .systemBlue, url: oneDrive, to: stack)
        }
        addSidebarLocation(NSUserName(), symbol: "house", color: .systemOrange, url: fileManager.homeDirectoryForCurrentUser, to: stack)
        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 3
        stack.addArrangedSubview(devicesStack)
        devicesStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildMountedVolumes()

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
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

    private func addSidebarSection(_ title: String, symbol: String? = nil, color: NSColor? = nil, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        if let symbol {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
            icon.contentTintColor = color
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        } else {
            stack.addArrangedSubview(label)
        }
        stack.setCustomSpacing(7, after: stack.arrangedSubviews.last!)
    }

    private func rebuildFavorites() {
        favoritesStack.arrangedSubviews.forEach { view in
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
            favoriteURLs.forEach {
                addSidebarLocation($0.lastPathComponent, symbol: "folder.fill", color: .explorerFolderTint, url: $0, to: favoritesStack)
            }
        }
    }

    private func addKnownFolder(_ title: String, symbol: String, color: NSColor, directory: FileManager.SearchPathDirectory, domain: FileManager.SearchPathDomainMask = .userDomainMask, to stack: NSStackView) {
        guard let url = fileManager.urls(for: directory, in: domain).first else { return }
        addSidebarLocation(title, symbol: symbol, color: color, url: url, to: stack)
    }

    private func addSidebarLocation(_ title: String, symbol: String, color: NSColor, url: URL, to stack: NSStackView) {
        let button = FileDropButton(title: title, target: self, action: #selector(sidebarLocation(_:)))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.contentTintColor = color
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .recessed
        button.isBordered = false
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

    private func rebuildMountedVolumes() {
        devicesStack.arrangedSubviews.forEach {
            if let button = $0 as? NSButton {
                sidebarURLs.removeValue(forKey: ObjectIdentifier(button))
                sidebarButtons.removeAll { $0 === button }
            }
            devicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [URL(fileURLWithPath: "/")]
        for volume in volumes.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let title = values?.volumeName ?? (volume.path == "/" ? "Macintosh HD" : volume.lastPathComponent)
            addSidebarLocation(title, symbol: volume.path == "/" ? "internaldrive" : "externaldrive", color: .secondaryLabelColor, url: volume, to: devicesStack)
            guard volume.path != "/", let button = devicesStack.arrangedSubviews.last as? NSButton else { continue }
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

        let footer = NSVisualEffectView()
        footer.material = .headerView
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)

        area.addSubview(tableScroll)
        area.addSubview(collectionScroll)
        area.addSubview(footer)
        NSLayoutConstraint.activate([
            tableScroll.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: area.topAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            collectionScroll.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            collectionScroll.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            collectionScroll.topAnchor.constraint(equalTo: area.topAnchor),
            collectionScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        applyViewMode()
        return area
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
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

    private func buildPreviewPanel() {
        previewPanel.material = .sidebar
        previewPanel.blendingMode = .withinWindow

        let heading = NSTextField(labelWithString: "Details")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewName.font = .systemFont(ofSize: 15, weight: .semibold)
        previewName.alignment = .center
        previewName.lineBreakMode = .byTruncatingMiddle
        previewKind.font = .systemFont(ofSize: 12)
        previewKind.textColor = .secondaryLabelColor
        previewKind.alignment = .center

        let infoGrid = NSGridView(views: [
            [detailLabel("Kind"), previewKindDetail],
            [detailLabel("Size"), previewSize],
            [detailLabel("Modified"), previewModified],
            [detailLabel("Created"), previewCreated],
            [detailLabel("Where"), previewWhere]
        ])
        infoGrid.rowSpacing = 12
        infoGrid.columnSpacing = 12
        infoGrid.column(at: 0).xPlacement = .trailing
        infoGrid.column(at: 1).xPlacement = .leading

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(previewImage)
        stack.addArrangedSubview(previewName)
        stack.addArrangedSubview(previewKind)
        stack.addArrangedSubview(infoGrid)
        previewOnlyViews = [previewImage, previewName]
        detailsOnlyViews = [previewKind, infoGrid]
        previewPanel.addSubview(stack)

        previewImage.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        previewImage.heightAnchor.constraint(equalToConstant: 210).isActive = true
        previewName.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewKind.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.arrangedSubviews.compactMap { $0 as? NSBox }.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: previewPanel.bottomAnchor, constant: -16)
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
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        window?.representedURL = url
        window?.title = "OpenExplorer — \(tabs[activeTabIndex].title)"
        rebuildTabs()
        rebuildBreadcrumbs()
        reloadContents()
        startMonitoringCurrentDirectory()
        updateNavigationButtons()
        updateSidebarSelection()
    }

    private func rebuildBreadcrumbs() {
        breadcrumbStack.arrangedSubviews.forEach { view in
            breadcrumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let parts = currentURL.standardizedFileURL.pathComponents
        var path = URL(fileURLWithPath: "/")
        for (index, part) in parts.enumerated() {
            if index > 0 { path.appendPathComponent(part) }
            if index > 0 {
                let separator = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                separator.contentTintColor = .tertiaryLabelColor
                separator.widthAnchor.constraint(equalToConstant: 10).isActive = true
                breadcrumbStack.addArrangedSubview(separator)
            }
            let title = index == 0 ? "Macintosh HD" : part
            let button = PathButton(title: title, target: self, action: #selector(breadcrumbSelected(_:)))
            button.destinationURL = path
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: index == parts.count - 1 ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingMiddle
            breadcrumbStack.addArrangedSubview(button)
        }
        addressField.stringValue = currentURL.path
        breadcrumbStack.isHidden = false
        addressField.isHidden = true
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
        if recordHistory { tabs[activeTabIndex].history.visit(url) }
        renderActiveTab()
    }

    private func reloadContents(preservingSelection: Bool = false) {
        let selectedPaths = preservingSelection ? Set(selectedItems.map { $0.url.standardizedFileURL.path }) : []
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .nameKey]
            let urls = try fileManager.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(keys),
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            items = urls.compactMap(makeFileItem)
            applyFilterAndSort()
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
        visibleItems = query.isEmpty ? items : (searchResults ?? items.filter { $0.name.localizedCaseInsensitiveContains(query) })
        let descriptor = tableView.sortDescriptors.first
        let key = FileSortKey(rawValue: descriptor?.key ?? "name") ?? .name
        let ascending = descriptor?.ascending ?? true
        let itemsByIdentifier = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.url.path, $0) })
        let sortableItems = visibleItems.map {
            FileSortEntry(
                identifier: $0.url.path,
                name: $0.name,
                isDirectory: $0.isDirectory,
                modified: $0.modified,
                created: $0.created,
                kind: $0.kind,
                size: $0.size
            )
        }
        visibleItems = FileItemSorter.sorted(sortableItems, by: key, ascending: ascending).compactMap {
            itemsByIdentifier[$0.identifier]
        }
        tableView.reloadData()
        tableView.deselectAll(nil)
        collectionView.reloadData()
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        updateStatus()
        updatePreview()
    }

    private func makeFileItem(_ url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .nameKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return FileItem(
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate,
            created: values.creationDate
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
        statusLabel.stringValue = "Searching \(root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent)…"
        searchTask = Task { [weak self] in
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try SpotlightSearch.find(named: query, under: root)
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
            button.isBordered = selected
            button.state = selected ? .on : .off
        }
    }

    private func updateStatus() {
        let selected = selectedItems
        if selected.isEmpty {
            statusLabel.stringValue = "\(visibleItems.count) item\(visibleItems.count == 1 ? "" : "s")"
        } else {
            let bytes = selected.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            let size = bytes > 0 ? " · \(FileTextFormatter.byteCount(bytes, isDirectory: false))" : ""
            statusLabel.stringValue = "\(selected.count) selected\(size) · \(visibleItems.count) items"
        }
    }

    private func updatePreview() {
        guard let item = selectedItems.first else {
            previewImage.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
            previewImage.contentTintColor = .tertiaryLabelColor
            previewName.stringValue = "Select an item"
            previewKind.stringValue = "Details appear here"
            previewKindDetail.stringValue = "—"
            previewSize.stringValue = "—"
            previewModified.stringValue = "—"
            previewCreated.stringValue = "—"
            previewWhere.stringValue = currentURL.path
            return
        }
        if item.isDirectory {
            previewImage.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            previewImage.contentTintColor = .explorerFolderTint
        } else if let image = NSImage(contentsOf: item.url) {
            previewImage.image = image
            previewImage.contentTintColor = nil
        } else {
            previewImage.image = NSWorkspace.shared.icon(forFile: item.url.path)
            previewImage.contentTintColor = nil
        }
        previewName.stringValue = item.name
        previewKind.stringValue = item.kind
        previewKindDetail.stringValue = item.kind
        previewSize.stringValue = item.sizeText
        previewModified.stringValue = item.modified.map { Self.dateFormatter.string(from: $0) } ?? "—"
        previewCreated.stringValue = item.created.map { Self.dateFormatter.string(from: $0) } ?? "—"
        previewWhere.stringValue = item.url.path
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

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleItems.indices.contains(row), let column = tableColumn else { return nil }
        let item = visibleItems[row]
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
                    image.widthAnchor.constraint(equalToConstant: 21),
                    image.heightAnchor.constraint(equalToConstant: 21),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
        }
        switch identifier.rawValue {
        case "name":
            if viewMode == .content {
                let modified = item.modified.map { Self.dateFormatter.string(from: $0) } ?? "—"
                let created = item.created.map { Self.dateFormatter.string(from: $0) } ?? "—"
                cell.textField?.stringValue = "\(item.name)\n\(item.kind) · Modified \(modified) · Created \(created)"
                cell.textField?.font = .systemFont(ofSize: 12)
            } else {
                cell.textField?.stringValue = item.name
                cell.textField?.font = .systemFont(ofSize: 13)
            }
            if item.isDirectory {
                cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                cell.imageView?.contentTintColor = .explorerFolderTint
            } else {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
                cell.imageView?.contentTintColor = nil
            }
            cell.textField?.textColor = cutURLs.contains(item.url) ? .tertiaryLabelColor : .labelColor
        case "modified": cell.textField?.stringValue = item.modified.map { Self.dateFormatter.string(from: $0) } ?? "—"
        case "created": cell.textField?.stringValue = item.created.map { Self.dateFormatter.string(from: $0) } ?? "—"
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.sizeText
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
        explorerItem.configure(with: visibleItems[indexPath.item], mode: viewMode, isCut: cutURLs.contains(visibleItems[indexPath.item].url))
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
        if obj.object as? NSSearchField === searchField { performRecursiveSearch() }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === addressField {
            breadcrumbStack.isHidden = false
            addressField.isHidden = true
        }
    }

    @objc private func sidebarLocation(_ sender: NSButton) {
        guard let url = sidebarURLs[ObjectIdentifier(sender)] else { return }
        navigate(to: url)
    }

    @objc private func openProjectWebsite(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/satinath-nit/OpenExplorer") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func breadcrumbSelected(_ sender: PathButton) {
        if let url = sender.destinationURL { navigate(to: url) }
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        let expanded = NSString(string: addressField.stringValue).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: expanded))
    }

    @objc func focusAddress(_ sender: Any?) {
        breadcrumbStack.isHidden = true
        addressField.isHidden = false
        addressField.stringValue = currentURL.path
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.addressField)
            self.addressField.selectText(nil)
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
        window?.performClose(sender)
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard let index = tabIndexes[ObjectIdentifier(sender)], tabs.indices.contains(index) else { return }
        activeTabIndex = index
        searchField.stringValue = ""
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
        if item.isDirectory { navigate(to: item.url) }
        else if item.url.pathExtension.lowercased() == "zip" { extractZip(item.url) }
        else if item.url.pathExtension.lowercased() == "dmg" { mountDiskImage(item.url) }
        else { NSWorkspace.shared.open(item.url) }
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
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
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
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
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
                    return ItemDetails(
                        size: bytes,
                        owner: attributes[.ownerAccountName] as? String ?? "—",
                        group: attributes[.groupOwnerAccountName] as? String ?? "—",
                        permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
                        isLocked: (attributes[.immutable] as? NSNumber)?.boolValue ?? false
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

        let size = NSTextField(labelWithString: "Size: \(FileTextFormatter.byteCount(details.size, isDirectory: false))")
        let owner = NSTextField(labelWithString: "Owner: \(details.owner)    Group: \(details.group)")
        let permissions = NSTextField(string: String(format: "%03o", details.permissions))
        permissions.placeholderString = "Permissions, for example 644"
        let locked = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
        locked.state = details.isLocked ? .on : .off
        let stack = NSStackView(views: [size, owner, NSTextField(labelWithString: "POSIX permissions:"), permissions, locked])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 390, height: 120)
        permissions.widthAnchor.constraint(equalToConstant: 100).isActive = true
        alert.accessoryView = stack
        statusLabel.stringValue = "\(visibleItems.count) items"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
            && selectedItems.first.map { TextEditorWindowController.canOpen($0.url) } == true
        menu.item(withTitle: "Edit in OpenExplorer")?.isEnabled = canEdit
        menu.item(withTitle: "Open With")?.isEnabled = !selectedItems.isEmpty
        menu.item(withTitle: "Quick Look")?.isEnabled = !selectedItems.isEmpty
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
            try fileManager.createDirectory(at: currentURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            reloadContents()
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
            _ = try BlankFileCreator.create(named: name, in: currentURL)
            reloadContents()
        } catch {
            showError("Could not create file", detail: error.localizedDescription)
        }
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = makeNewMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func renameSelection(_ sender: Any?) {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        guard let name = prompt(title: "Rename", message: item.name, defaultValue: item.name, confirm: "Rename"), !name.isEmpty, name != item.name else { return }
        do {
            try fileManager.moveItem(at: item.url, to: item.url.deletingLastPathComponent().appendingPathComponent(name))
            reloadContents()
        } catch { showError("Could not rename item", detail: error.localizedDescription) }
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
        reloadContents()
        if !failures.isEmpty { showError("Some items could not be moved", detail: failures.joined(separator: "\n")) }
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
        let candidates = [
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities/Terminal.app", isDirectory: true)
        ]
        guard let terminal = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            showError("Terminal was not found", detail: "Open Terminal and navigate to \(directory.path).")
            return
        }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
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
        let hasConflict = sources.contains { source in
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if kind == .copy, destination.standardizedFileURL == source.standardizedFileURL { return false }
            return fileManager.fileExists(atPath: destination.path)
        }
        guard hasConflict else { return .keepBoth }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item with the same name already exists"
        alert.informativeText = "Choose how OpenExplorer should handle name conflicts in this operation."
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
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [currentURL] : urls)
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
        button.bezelStyle = .texturedRounded
        button.toolTip = help
        return button
    }

    private func makeItemContextMenu(includesRevealInFinder: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        addNewSubmenu(to: menu)
        menu.addItem(.separator())

        let open = menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        open.target = self
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
        let favorite = menu.addItem(withTitle: "Add to Favorites", action: #selector(addFavorite(_:)), keyEquivalent: "")
        favorite.target = self
        let cut = menu.addItem(withTitle: "Cut", action: #selector(cutSelection(_:)), keyEquivalent: "")
        cut.target = self
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        copy.target = self
        let paste = menu.addItem(withTitle: "Paste Here", action: #selector(paste(_:)), keyEquivalent: "")
        paste.target = self
        let copyRelativePath = menu.addItem(withTitle: "Copy Path Relative to Home", action: #selector(copyPathRelativeToHome(_:)), keyEquivalent: "")
        copyRelativePath.target = self
        let openTerminal = menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        openTerminal.target = self

        menu.addItem(.separator())
        let rename = menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "")
        rename.target = self
        let trash = menu.addItem(withTitle: "Move to Trash", action: #selector(trashSelection(_:)), keyEquivalent: "")
        trash.target = self
        let restore = menu.addItem(withTitle: "Restore from Trash", action: #selector(restoreFromTrash(_:)), keyEquivalent: "")
        restore.target = self
        if includesRevealInFinder {
            let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelection(_:)), keyEquivalent: "")
            reveal.target = self
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
        guard let fileURL = selectedItems.first?.url else {
            let unavailable = menu.addItem(withTitle: "No file selected", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(.separator())
            addChooseApplicationItem(to: menu)
            return
        }

        var applications = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        if TextEditorWindowController.canOpen(fileURL),
           let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            applications.append(textEdit)
        }
        let ownBundleURL = Bundle.main.bundleURL.standardizedFileURL
        var seenPaths = Set<String>()
        applications = applications
            .filter { $0.standardizedFileURL != ownBundleURL && seenPaths.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }

        if applications.isEmpty {
            let unavailable = menu.addItem(withTitle: "No compatible applications found", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
        } else {
            for applicationURL in applications {
                let name = applicationURL.deletingPathExtension().lastPathComponent
                let item = menu.addItem(withTitle: name, action: #selector(openWithApplication(_:)), keyEquivalent: "")
                let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                item.representedObject = applicationURL
                item.target = self
            }
        }
        menu.addItem(.separator())
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
        view.layer?.cornerRadius = 7

        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 12)
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

    func configure(with item: FileItem, mode: BrowserViewMode, isCut: Bool) {
        if item.isDirectory {
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            icon.contentTintColor = .explorerFolderTint
        } else {
            icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.contentTintColor = nil
        }
        name.stringValue = item.name
        name.textColor = isCut ? .tertiaryLabelColor : .labelColor
        detail.stringValue = "\(item.kind) · \(item.sizeText)"

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

    override var isSelected: Bool {
        didSet {
            (view as? AppearanceSurfaceView)?.fillColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28)
                : .clear
        }
    }
}

private final class ExplorerTableView: NSTableView {
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
    static let explorerFolderTint = NSColor(name: "OpenExplorerFolderTint") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(deviceRed: 0.89, green: 0.64, blue: 0.03, alpha: 1)
            : NSColor(deviceRed: 0.82, green: 0.55, blue: 0.00, alpha: 1)
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
    func windowWillClose(_ notification: Notification) {}
}
