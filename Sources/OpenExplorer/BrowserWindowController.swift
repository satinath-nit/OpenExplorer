import AppKit
import Foundation
import OpenExplorerCore

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
final class BrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
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
    private var previewOnlyViews: [NSView] = []
    private var detailsOnlyViews: [NSView] = []
    private var viewMode = (UserDefaults.standard.object(forKey: "viewModeV2") as? Int).flatMap(BrowserViewMode.init(rawValue:)) ?? .details
    private var showsDetailsPane = UserDefaults.standard.object(forKey: "showsDetailsPane") as? Bool ?? true
    private var showsPreviewPane = UserDefaults.standard.object(forKey: "showsPreviewPane") as? Bool ?? true

    private var currentURL: URL { tabs[activeTabIndex].history.current }

    init() {
        let storedPath = UserDefaults.standard.string(forKey: "lastFolder")
        let storedURL = storedPath.map { URL(fileURLWithPath: $0) }
        let initialURL = storedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
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
        if !addressField.isEditable || !addressField.isSelectable {
            failures.append("address field is not editable and selectable")
        }
        let expectedContextActions = ["Copy Path Relative to Home", "Open in Terminal"]
        for title in expectedContextActions {
            if tableView.menu?.item(withTitle: title)?.target !== self {
                failures.append("list context menu is missing \(title)")
            }
            if collectionView.menu?.item(withTitle: title)?.target !== self {
                failures.append("icon context menu is missing \(title)")
            }
        }
        if breadcrumbContainer.menu?.item(withTitle: "Copy Address")?.target !== self
            || breadcrumbContainer.menu?.item(withTitle: "Edit Address")?.target !== self {
            failures.append("address bar actions are incomplete")
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
            let container = AppearanceSurfaceView()
            container.layer?.cornerRadius = 8
            container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            container.fillColor = index == activeTabIndex ? .controlBackgroundColor : .clear

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

        searchField.placeholderString = "Search this folder"
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

        let newButton = commandButton("New", symbol: "folder.badge.plus", help: "New folder", action: #selector(createFolder(_:)), labeled: true)
        let cut = commandButton("", symbol: "scissors", help: "Cut", action: #selector(cutSelection(_:)))
        let copy = commandButton("", symbol: "doc.on.doc", help: "Copy", action: #selector(copySelection(_:)))
        let paste = commandButton("", symbol: "clipboard", help: "Paste", action: #selector(paste(_:)))
        let rename = commandButton("", symbol: "pencil", help: "Rename", action: #selector(renameSelection(_:)))
        let trash = commandButton("", symbol: "trash", help: "Move to Trash", action: #selector(trashSelection(_:)))

        let sort = NSPopUpButton()
        sort.addItems(withTitles: ["Sort: Name", "Name: Z–A", "Date Modified", "Date Created", "Size"])
        sort.bezelStyle = .texturedRounded
        sort.target = self
        sort.action = #selector(sortChanged(_:))

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
        [newButton, commandSeparator(), cut, copy, paste, rename, trash, commandSeparator(), sort, viewPopup, hidden, reload, spacer, quickLook, previewToggle]
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
        addSidebarLocation("Macintosh HD", symbol: "internaldrive", color: .secondaryLabelColor, url: URL(fileURLWithPath: "/"), to: stack)

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
        let credit = NSTextField(wrappingLabelWithString: "Designed and developed by\nSatinath Mondal")
        credit.font = .systemFont(ofSize: 9)
        credit.textColor = .tertiaryLabelColor
        credit.maximumNumberOfLines = 2
        let creditStack = NSStackView(views: [brand, credit])
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
        let button = NSButton(title: title, target: self, action: #selector(sidebarLocation(_:)))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.contentTintColor = color
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.toolTip = url.path
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
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Look", action: #selector(quickLook(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add to Favorites", action: #selector(addFavorite(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cut", action: #selector(cutSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste Here", action: #selector(paste(_:)), keyEquivalent: "")
        let copyRelativePath = menu.addItem(withTitle: "Copy Path Relative to Home", action: #selector(copyPathRelativeToHome(_:)), keyEquivalent: "")
        copyRelativePath.target = self
        let openTerminal = menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        openTerminal.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelection(_:)), keyEquivalent: "")
        tableView.menu = menu
    }

    private func configureCollectionView() {
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(collectionDoubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Look", action: #selector(quickLook(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add to Favorites", action: #selector(addFavorite(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cut", action: #selector(cutSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste Here", action: #selector(paste(_:)), keyEquivalent: "")
        let copyRelativePath = menu.addItem(withTitle: "Copy Path Relative to Home", action: #selector(copyPathRelativeToHome(_:)), keyEquivalent: "")
        copyRelativePath.target = self
        let openTerminal = menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        openTerminal.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashSelection(_:)), keyEquivalent: "")
        collectionView.menu = menu
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
        if recordHistory { tabs[activeTabIndex].history.visit(url) }
        renderActiveTab()
    }

    private func reloadContents() {
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .nameKey]
            let urls = try fileManager.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(keys),
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            items = urls.compactMap { url in
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
            applyFilterAndSort()
        } catch {
            items = []
            visibleItems = []
            tableView.reloadData()
            collectionView.reloadData()
            showError("Could not open folder", detail: error.localizedDescription)
        }
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let descriptor = tableView.sortDescriptors.first
        let key = descriptor?.key ?? "name"
        let ascending = descriptor?.ascending ?? true
        visibleItems.sort { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let order: ComparisonResult
            switch key {
            case "modified": order = (left.modified ?? .distantPast).compare(right.modified ?? .distantPast)
            case "created": order = (left.created ?? .distantPast).compare(right.created ?? .distantPast)
            case "kind": order = left.kind.localizedStandardCompare(right.kind)
            case "size": order = left.size == right.size ? .orderedSame : (left.size < right.size ? .orderedAscending : .orderedDescending)
            default: order = left.name.localizedStandardCompare(right.name)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        tableView.reloadData()
        tableView.deselectAll(nil)
        collectionView.reloadData()
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        updateStatus()
        updatePreview()
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
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilterAndSort() }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === searchField { applyFilterAndSort() } }
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
        else { NSWorkspace.shared.open(item.url) }
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
        for item in selection {
            do { try fileManager.trashItem(at: item.url, resultingItemURL: nil) }
            catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
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
        var failures: [String] = []
        for source in sources {
            let destination = destinationURL(for: source)
            do {
                if cutURLs.contains(source) {
                    try fileManager.moveItem(at: source, to: destination)
                    cutURLs.remove(source)
                } else {
                    try fileManager.copyItem(at: source, to: destination)
                }
            } catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        reloadContents()
        if !failures.isEmpty { showError("Some items could not be pasted", detail: failures.joined(separator: "\n")) }
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
}

private final class PathButton: NSButton {
    var destinationURL: URL?
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

private final class BreadcrumbView: AppearanceSurfaceView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onBackgroundClick?()
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
