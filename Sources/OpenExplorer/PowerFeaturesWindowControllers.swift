import AppKit
import Carbon
import Foundation
import OpenExplorerCore
import ServiceManagement

enum FolderIconStyle: String, CaseIterable {
    case windowsGold = "Windows 11 Gold"
    case macOSBlue = "macOS Classic Blue"
}

enum ZipDoubleClickBehavior: String, CaseIterable {
    case extract = "Extract to Neighboring Folder"
    case browse = "Browse Inside Archive"
}

enum GlobalHotKeyPreset: String, CaseIterable {
    case commandE = "⌘E (Command + E)"
    case optionCommandE = "⌥⌘E (Option + Command + E)"
    case controlCommandE = "⌃⌘E (Control + Command + E)"
    case disabled = "Disabled"

    var keyCodeAndModifiers: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .commandE:
            return (UInt32(kVK_ANSI_E), UInt32(cmdKey))
        case .optionCommandE:
            return (UInt32(kVK_ANSI_E), UInt32(cmdKey | optionKey))
        case .controlCommandE:
            return (UInt32(kVK_ANSI_E), UInt32(cmdKey | controlKey))
        case .disabled:
            return nil
        }
    }
}

@MainActor
final class ExplorerPreferences {
    static let shared = ExplorerPreferences()
    static let didChangeNotification = Notification.Name("OpenExplorerPreferencesDidChange")

    private let defaults = UserDefaults.standard

    var defaultZipMode: ZipCompressionMode {
        get {
            guard let raw = defaults.string(forKey: "pref.defaultZipMode"),
                  let mode = ZipCompressionMode(rawValue: raw) else {
                return .cleanCrossPlatform
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pref.defaultZipMode")
            notifyChange()
        }
    }

    var zipDoubleClickBehavior: ZipDoubleClickBehavior {
        get {
            guard let raw = defaults.string(forKey: "pref.zipDoubleClickBehavior"),
                  let value = ZipDoubleClickBehavior(rawValue: raw) else {
                return .extract
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pref.zipDoubleClickBehavior")
            notifyChange()
        }
    }

    var folderIconStyle: FolderIconStyle {
        get {
            guard let raw = defaults.string(forKey: "pref.folderIconStyle"),
                  let style = FolderIconStyle(rawValue: raw) else {
                return .windowsGold
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pref.folderIconStyle")
            notifyChange()
        }
    }

    var windowsShortcutsEnabled: Bool {
        get { defaults.object(forKey: "pref.windowsShortcutsEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.windowsShortcutsEnabled")
            notifyChange()
        }
    }

    var showItemCheckboxes: Bool {
        get { defaults.object(forKey: "pref.showItemCheckboxes") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "pref.showItemCheckboxes")
            notifyChange()
        }
    }

    var calculateFolderSizes: Bool {
        get { defaults.object(forKey: "pref.calculateFolderSizes") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.calculateFolderSizes")
            notifyChange()
        }
    }

    var showGitBadges: Bool {
        get { defaults.object(forKey: "pref.showGitBadges") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.showGitBadges")
            notifyChange()
        }
    }

    var dimGitIgnoredFiles: Bool {
        get { defaults.object(forKey: "pref.dimGitIgnoredFiles") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.dimGitIgnoredFiles")
            notifyChange()
        }
    }

    var excludeGitIgnoredFromSearch: Bool {
        get { defaults.object(forKey: "pref.excludeGitIgnoredFromSearch") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "pref.excludeGitIgnoredFromSearch")
            notifyChange()
        }
    }

    var globalHotKeyPreset: GlobalHotKeyPreset {
        get {
            guard let raw = defaults.string(forKey: "pref.globalHotKeyPreset"),
                  let preset = GlobalHotKeyPreset(rawValue: raw) else {
                return .commandE
            }
            return preset
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pref.globalHotKeyPreset")
            notifyChange()
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

// MARK: - Batch Rename Window Controller

@MainActor
final class BatchRenameWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let urls: [URL]
    private let onApply: ([BatchRenamePlanItem]) -> Void
    private var plan: [BatchRenamePlanItem] = []

    private let modeSegment = NSSegmentedControl(labels: ["Find & Replace", "Add Prefix / Suffix", "Numbering"], trackingMode: .selectOne, target: nil, action: nil)
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let regexCheck = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let caseCheck = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)

    private let prefixField = NSTextField()
    private let suffixField = NSTextField()

    private let baseNameField = NSTextField()
    private let startNumberField = NSTextField(string: "1")
    private let paddingPopup = NSPopUpButton()

    private let findStack = NSStackView()
    private let affixStack = NSStackView()
    private let numberStack = NSStackView()

    private let previewTable = NSTableView()
    private let applyButton = NSButton(title: "Rename", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")

    init(urls: [URL], onApply: @escaping ([BatchRenamePlanItem]) -> Void) {
        self.urls = urls
        self.onApply = onApply
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Batch Rename (\(urls.count) Items)"
        window.minSize = NSSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        recomputePreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        modeSegment.selectedSegment = 0
        modeSegment.target = self
        modeSegment.action = #selector(modeChanged(_:))

        findField.placeholderString = "Text or pattern to find"
        replaceField.placeholderString = "Replacement text"
        findField.delegate = self
        replaceField.delegate = self
        regexCheck.target = self
        regexCheck.action = #selector(optionsChanged(_:))
        caseCheck.state = .on
        caseCheck.target = self
        caseCheck.action = #selector(optionsChanged(_:))

        let findRow1 = NSStackView(views: [NSTextField(labelWithString: "Find:"), findField, NSTextField(labelWithString: "Replace:"), replaceField])
        findRow1.orientation = .horizontal
        findRow1.spacing = 8
        let findRow2 = NSStackView(views: [regexCheck, caseCheck])
        findRow2.orientation = .horizontal
        findRow2.spacing = 16
        findStack.orientation = .vertical
        findStack.alignment = .leading
        findStack.spacing = 8
        findStack.addArrangedSubview(findRow1)
        findStack.addArrangedSubview(findRow2)

        prefixField.placeholderString = "Prefix (before name)"
        suffixField.placeholderString = "Suffix (before extension)"
        prefixField.delegate = self
        suffixField.delegate = self
        let affixRow = NSStackView(views: [NSTextField(labelWithString: "Prefix:"), prefixField, NSTextField(labelWithString: "Suffix:"), suffixField])
        affixRow.orientation = .horizontal
        affixRow.spacing = 8
        affixStack.orientation = .vertical
        affixStack.alignment = .leading
        affixStack.addArrangedSubview(affixRow)
        affixStack.isHidden = true

        baseNameField.placeholderString = urls.first?.deletingPathExtension().lastPathComponent ?? "item"
        baseNameField.stringValue = urls.first?.deletingPathExtension().lastPathComponent ?? "item"
        baseNameField.delegate = self
        startNumberField.delegate = self
        startNumberField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        paddingPopup.addItems(withTitles: ["001 (3 digits)", "01 (2 digits)", "1 (No padding)", "0001 (4 digits)"])
        paddingPopup.target = self
        paddingPopup.action = #selector(optionsChanged(_:))
        let numRow = NSStackView(views: [
            NSTextField(labelWithString: "Base Name:"), baseNameField,
            NSTextField(labelWithString: "Start #:"), startNumberField,
            paddingPopup
        ])
        numRow.orientation = .horizontal
        numRow.spacing = 8
        numberStack.orientation = .vertical
        numberStack.alignment = .leading
        numberStack.addArrangedSubview(numRow)
        numberStack.isHidden = true

        let origCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("original"))
        origCol.title = "Current Name"
        origCol.width = 260
        let newCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("proposed"))
        newCol.title = "New Name (Preview)"
        newCol.width = 320
        previewTable.addTableColumn(origCol)
        previewTable.addTableColumn(newCol)
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.rowHeight = 24
        previewTable.dataSource = self
        previewTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = previewTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyPressed(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [summaryLabel, spacer, cancelButton, applyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let mainStack = NSStackView(views: [modeSegment, findStack, affixStack, numberStack, scroll, footer])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: content.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            footer.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -32)
        ])
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        findStack.isHidden = sender.selectedSegment != 0
        affixStack.isHidden = sender.selectedSegment != 1
        numberStack.isHidden = sender.selectedSegment != 2
        recomputePreview()
    }

    @objc private func optionsChanged(_ sender: Any?) {
        recomputePreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        recomputePreview()
    }

    private func recomputePreview() {
        let rule: BatchRenameRule
        switch modeSegment.selectedSegment {
        case 1:
            rule = .addAffix(prefix: prefixField.stringValue, suffix: suffixField.stringValue)
        case 2:
            let start = Int(startNumberField.stringValue) ?? 1
            let pad: Int
            switch paddingPopup.indexOfSelectedItem {
            case 1: pad = 2
            case 2: pad = 1
            case 3: pad = 4
            default: pad = 3
            }
            rule = .sequentialNumbering(baseName: baseNameField.stringValue, startNumber: start, paddingDigits: pad, separator: "_")
        default:
            rule = .findAndReplace(
                find: findField.stringValue,
                replace: replaceField.stringValue,
                useRegex: regexCheck.state == .on,
                caseInsensitive: caseCheck.state == .on
            )
        }
        plan = BatchRenameEngine.preview(for: urls, rule: rule)
        previewTable.reloadData()
        let changedCount = plan.filter { $0.isChanged && !$0.hasConflict }.count
        let conflictCount = plan.filter(\.hasConflict).count
        summaryLabel.stringValue = conflictCount > 0
            ? "\(changedCount) ready · \(conflictCount) conflict(s) skipped"
            : "\(changedCount) of \(plan.count) item(s) will be renamed"
        applyButton.isEnabled = changedCount > 0
        applyButton.title = "Rename \(changedCount) Item\(changedCount == 1 ? "" : "s")"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { plan.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard plan.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let item = plan[row]
        let label = NSTextField(labelWithString: id.rawValue == "original" ? item.originalName : item.proposedName)
        label.font = .systemFont(ofSize: 12, weight: id.rawValue == "proposed" && item.isChanged ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        if id.rawValue == "proposed" {
            if item.hasConflict {
                label.stringValue = "⚠️ \(item.proposedName) (Conflict)"
                label.textColor = .systemRed
            } else if item.isChanged {
                label.textColor = .systemGreen
            } else {
                label.textColor = .secondaryLabelColor
            }
        }
        return label
    }

    @objc private func cancelPressed(_ sender: Any?) {
        if let parent = window?.sheetParent {
            parent.endSheet(window!, returnCode: .cancel)
        } else {
            window?.close()
        }
    }

    @objc private func applyPressed(_ sender: Any?) {
        let currentPlan = plan
        if let parent = window?.sheetParent {
            parent.endSheet(window!, returnCode: .OK)
        } else {
            window?.close()
        }
        onApply(currentPlan)
    }

    func configureDemoFindReplace(find: String, replace: String) {
        modeSegment.selectedSegment = 0
        findField.stringValue = find
        replaceField.stringValue = replace
        recomputePreview()
    }
}

// MARK: - Virtual Archive Browser Window Controller

@MainActor
final class ArchiveBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let archiveURL: URL
    private let entries: [ArchiveEntry]
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    var onExtractedURL: ((URL) -> Void)?

    init(archiveURL: URL) throws {
        self.archiveURL = archiveURL
        self.entries = try ZipExtractor.listEntries(in: archiveURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(archiveURL.lastPathComponent) — Archive Inspector"
        window.minSize = NSSize(width: 520, height: 340)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let header = NSVisualEffectView()
        header.material = .headerView
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Archive") ?? NSImage())
        icon.contentTintColor = .systemOrange
        let titleLabel = NSTextField(labelWithString: "\(archiveURL.lastPathComponent) (\(entries.count) entries)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let extractSelectedBtn = NSButton(title: "Extract Selected", target: self, action: #selector(extractSelected(_:)))
        extractSelectedBtn.bezelStyle = .rounded
        let extractAllBtn = NSButton(title: "Extract All to Folder", target: self, action: #selector(extractAll(_:)))
        extractAllBtn.bezelStyle = .rounded
        extractAllBtn.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerBar = NSStackView(views: [icon, titleLabel, spacer, extractSelectedBtn, extractAllBtn])
        headerBar.orientation = .horizontal
        headerBar.alignment = .centerY
        headerBar.spacing = 10
        headerBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let pathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathCol.title = "Path Inside Archive"
        pathCol.width = 450
        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "Type"
        typeCol.width = 90
        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Uncompressed Size"
        sizeCol.width = 110
        tableView.addTableColumn(pathCol)
        tableView.addTableColumn(typeCol)
        tableView.addTableColumn(sizeCol)
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 25
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true

        let totalBytes = entries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        statusLabel.stringValue = "\(entries.count) items · Total uncompressed: \(FileTextFormatter.byteCount(totalBytes, isDirectory: false))"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [headerBar, scroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            headerBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let entry = entries[row]
        switch id.rawValue {
        case "path":
            let label = NSTextField(labelWithString: (entry.isDirectory ? "📁 " : "📄 ") + entry.path)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        case "type":
            let label = NSTextField(labelWithString: entry.isDirectory ? "Folder" : "File")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        case "size":
            let label = NSTextField(labelWithString: FileTextFormatter.byteCount(entry.uncompressedSize, isDirectory: entry.isDirectory))
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            return label
        default:
            return nil
        }
    }

    @objc private func extractSelected(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else {
            extractAll(sender)
            return
        }
        let targetDir = archiveURL.deletingLastPathComponent()
        var lastExtracted: URL?
        for index in rows where entries.indices.contains(index) {
            if let url = try? ZipExtractor.extractEntry(entries[index].path, from: archiveURL, to: targetDir) {
                lastExtracted = url
            }
        }
        if let lastExtracted {
            onExtractedURL?(lastExtracted)
            statusLabel.stringValue = "Extracted to \(lastExtracted.lastPathComponent)"
        }
    }

    @objc private func extractAll(_ sender: Any?) {
        do {
            let folder = try ZipExtractor.extract(archiveURL)
            onExtractedURL?(folder)
            window?.close()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not extract archive"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Settings Window Controller (⌘,)

@MainActor
final class SettingsWindowController: NSWindowController {
    private let defaultFileViewerCheck = NSButton(checkboxWithTitle: "Set OpenExplorer as Default File Manager (NSFileViewer)", target: nil, action: nil)
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: "Launch OpenExplorer at Login", target: nil, action: nil)
    private let hotKeyPopup = NSPopUpButton()
    private let zipModePopup = NSPopUpButton()
    private let zipDoubleClickPopup = NSPopUpButton()
    private let folderStylePopup = NSPopUpButton()
    private let winShortcutsCheck = NSButton(checkboxWithTitle: "Enable Windows Explorer Shortcuts (F2 Rename, ⇧Delete Permanent Delete, Alt+Up)", target: nil, action: nil)
    private let checkboxesCheck = NSButton(checkboxWithTitle: "Show Item Selection Checkboxes in List & Details Views", target: nil, action: nil)
    private let folderSizesCheck = NSButton(checkboxWithTitle: "Calculate Folder Sizes in Background for List & Details Views", target: nil, action: nil)
    private let gitBadgesCheck = NSButton(checkboxWithTitle: "Show Git Branch & File Status Badges (M / A / U)", target: nil, action: nil)
    private let dimGitIgnoredCheck = NSButton(checkboxWithTitle: "Dim Git-Ignored Files & Build Artifacts (node_modules, .build, dist, target)", target: nil, action: nil)
    private let excludeGitIgnoredSearchCheck = NSButton(checkboxWithTitle: "Exclude Git-Ignored Items from Recursive Search & Fuzzy Go-To by Default", target: nil, action: nil)
    private let cliStatusLabel = NSTextField(labelWithString: "")

    var onInstallCLI: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 545),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenExplorer Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        syncFromPreferences()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let prefs = ExplorerPreferences.shared

        defaultFileViewerCheck.target = self
        defaultFileViewerCheck.action = #selector(toggleDefaultFileViewer(_:))

        launchAtLoginCheck.target = self
        launchAtLoginCheck.action = #selector(toggleLaunchAtLogin(_:))

        hotKeyPopup.addItems(withTitles: GlobalHotKeyPreset.allCases.map(\.rawValue))
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(hotKeyChanged(_:))

        zipModePopup.addItems(withTitles: ZipCompressionMode.allCases.map(\.rawValue))
        zipModePopup.target = self
        zipModePopup.action = #selector(zipModeChanged(_:))

        zipDoubleClickPopup.addItems(withTitles: ZipDoubleClickBehavior.allCases.map(\.rawValue))
        zipDoubleClickPopup.target = self
        zipDoubleClickPopup.action = #selector(zipDoubleClickChanged(_:))

        folderStylePopup.addItems(withTitles: FolderIconStyle.allCases.map(\.rawValue))
        folderStylePopup.target = self
        folderStylePopup.action = #selector(folderStyleChanged(_:))

        winShortcutsCheck.target = self
        winShortcutsCheck.action = #selector(winShortcutsChanged(_:))
        checkboxesCheck.target = self
        checkboxesCheck.action = #selector(checkboxesChanged(_:))
        folderSizesCheck.target = self
        folderSizesCheck.action = #selector(folderSizesChanged(_:))
        gitBadgesCheck.target = self
        gitBadgesCheck.action = #selector(gitBadgesChanged(_:))
        dimGitIgnoredCheck.target = self
        dimGitIgnoredCheck.action = #selector(dimGitIgnoredChanged(_:))
        excludeGitIgnoredSearchCheck.target = self
        excludeGitIgnoredSearchCheck.action = #selector(excludeGitIgnoredSearchChanged(_:))

        let installCLIBtn = NSButton(title: "Install ‘oe’ Command in PATH…", target: self, action: #selector(installCLIPressed(_:)))
        installCLIBtn.bezelStyle = .rounded
        let fdaBtn = NSButton(title: "Open Full Disk Access Settings…", target: self, action: #selector(openFullDiskAccess(_:)))
        fdaBtn.bezelStyle = .rounded

        let cliRow = NSStackView(views: [installCLIBtn, fdaBtn, cliStatusLabel])
        cliRow.orientation = .horizontal
        cliRow.spacing = 10

        let stack = NSStackView(views: [
            sectionHeader("System Integration"),
            defaultFileViewerCheck,
            launchAtLoginCheck,
            labeledRow("Global Open Shortcut:", hotKeyPopup),
            cliRow,
            makeDivider(),
            sectionHeader("Archives & ZIP Compression"),
            labeledRow("Default Right-Click ZIP Format:", zipModePopup),
            labeledRow("When Double-Clicking a .zip:", zipDoubleClickPopup),
            makeDivider(),
            sectionHeader("Explorer Appearance & Ergonomics"),
            labeledRow("Folder Icon Theme:", folderStylePopup),
            winShortcutsCheck,
            checkboxesCheck,
            folderSizesCheck,
            gitBadgesCheck,
            dimGitIgnoredCheck,
            excludeGitIgnoredSearchCheck
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        _ = prefs
    }

    func syncFromPreferences() {
        let prefs = ExplorerPreferences.shared
        defaultFileViewerCheck.state = DefaultFileManagerRegistrar.isRegisteredAsDefaultFileViewer() ? .on : .off
        launchAtLoginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        if let idx = GlobalHotKeyPreset.allCases.firstIndex(of: prefs.globalHotKeyPreset) {
            hotKeyPopup.selectItem(at: idx)
        }
        if let idx = ZipCompressionMode.allCases.firstIndex(of: prefs.defaultZipMode) {
            zipModePopup.selectItem(at: idx)
        }
        if let idx = ZipDoubleClickBehavior.allCases.firstIndex(of: prefs.zipDoubleClickBehavior) {
            zipDoubleClickPopup.selectItem(at: idx)
        }
        if let idx = FolderIconStyle.allCases.firstIndex(of: prefs.folderIconStyle) {
            folderStylePopup.selectItem(at: idx)
        }
        winShortcutsCheck.state = prefs.windowsShortcutsEnabled ? .on : .off
        checkboxesCheck.state = prefs.showItemCheckboxes ? .on : .off
        folderSizesCheck.state = prefs.calculateFolderSizes ? .on : .off
        gitBadgesCheck.state = prefs.showGitBadges ? .on : .off
        dimGitIgnoredCheck.state = prefs.dimGitIgnoredFiles ? .on : .off
        excludeGitIgnoredSearchCheck.state = prefs.excludeGitIgnoredFromSearch ? .on : .off
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 195).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeDivider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return box
    }

    @objc private func toggleDefaultFileViewer(_ sender: NSButton) {
        try? DefaultFileManagerRegistrar.setAsDefaultFileViewer(sender.state == .on)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        if sender.state == .on {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    @objc private func hotKeyChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard GlobalHotKeyPreset.allCases.indices.contains(index) else { return }
        ExplorerPreferences.shared.globalHotKeyPreset = GlobalHotKeyPreset.allCases[index]
    }

    @objc private func zipModeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ZipCompressionMode.allCases.indices.contains(index) else { return }
        ExplorerPreferences.shared.defaultZipMode = ZipCompressionMode.allCases[index]
    }

    @objc private func zipDoubleClickChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ZipDoubleClickBehavior.allCases.indices.contains(index) else { return }
        ExplorerPreferences.shared.zipDoubleClickBehavior = ZipDoubleClickBehavior.allCases[index]
    }

    @objc private func folderStyleChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard FolderIconStyle.allCases.indices.contains(index) else { return }
        ExplorerPreferences.shared.folderIconStyle = FolderIconStyle.allCases[index]
    }

    @objc private func winShortcutsChanged(_ sender: NSButton) {
        ExplorerPreferences.shared.windowsShortcutsEnabled = sender.state == .on
    }

    @objc private func checkboxesChanged(_ sender: NSButton) {
        ExplorerPreferences.shared.showItemCheckboxes = sender.state == .on
    }

    @objc private func folderSizesChanged(_ sender: NSButton) {
        ExplorerPreferences.shared.calculateFolderSizes = sender.state == .on
    }

    @objc private func gitBadgesChanged(_ sender: NSButton) {
        ExplorerPreferences.shared.showGitBadges = sender.state == .on
    }

    @objc private func dimGitIgnoredChanged(_ sender: NSButton) {
        ExplorerPreferences.shared.dimGitIgnoredFiles = sender.state == .on
    }

    @objc private func excludeGitIgnoredSearchChanged(_ sender: NSButton) {
        ExplorerPreferences.shared.excludeGitIgnoredFromSearch = sender.state == .on
    }

    @objc private func installCLIPressed(_ sender: Any?) {
        onInstallCLI?()
    }

    @objc private func openFullDiskAccess(_ sender: Any?) {
        NSWorkspace.shared.open(FolderAccessDiagnostics.fullDiskAccessSettingsURL)
    }
}

// MARK: - Command Palette & Fuzzy Navigation Window Controller (`⌘K` / `⌘P`)

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var allItems: [CommandPaletteItem]
    private var filteredItems: [CommandPaletteItem] = []
    private(set) var mode: CommandPaletteMode
    private var currentDirectory: URL
    private var includeHidden: Bool
    private let onSelect: (CommandPaletteItem, _ openInNewTab: Bool) -> Void
    private var discoveryTask: Task<Void, Never>?

    private let searchField = NSSearchField()
    private let modeSegment = NSSegmentedControl(labels: ["Commands (⌘K)", "Fuzzy Go-To (⌘P)"], trackingMode: .selectOne, target: nil, action: nil)
    private let tableView = NSTableView()
    private let footerLabel = NSTextField(labelWithString: "↑↓ to navigate · Return to run/open · ⌘Return for new tab · Esc or click outside to close")

    init(
        mode: CommandPaletteMode,
        currentDirectory: URL,
        includeHidden: Bool,
        initialItems: [CommandPaletteItem],
        onSelect: @escaping (CommandPaletteItem, _ openInNewTab: Bool) -> Void
    ) {
        self.mode = mode
        self.currentDirectory = currentDirectory
        self.includeHidden = includeHidden
        self.allItems = initialItems
        self.onSelect = onSelect

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 450),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = mode == .commands ? "Command Palette (⌘K)" : "Go to File or Folder (⌘P)"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 540, height: 340)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        applyModeConfiguration()
        refreshResults()
        startNestedFuzzyDiscovery()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reconfigure(
        mode newMode: CommandPaletteMode,
        currentDirectory: URL,
        includeHidden: Bool,
        items: [CommandPaletteItem]
    ) {
        self.mode = newMode
        self.currentDirectory = currentDirectory
        self.includeHidden = includeHidden
        self.allItems = items
        window?.title = newMode == .commands ? "Command Palette (⌘K)" : "Go to File or Folder (⌘P)"
        applyModeConfiguration()
        searchField.stringValue = ""
        refreshResults()
        startNestedFuzzyDiscovery()
        focusSearchField()
    }

    func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.searchField)
        }
    }

    private func buildUI() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        window?.contentView = effect

        searchField.font = .systemFont(ofSize: 14.5, weight: .medium)
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        modeSegment.target = self
        modeSegment.action = #selector(modeSegmentChanged(_:))

        let topRow = NSStackView(views: [searchField, modeSegment])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let mainCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        mainCol.title = "Command or Location"
        mainCol.width = 510
        mainCol.minWidth = 320
        let shortcutCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutCol.title = "Shortcut"
        shortcutCol.width = 110
        shortcutCol.minWidth = 80
        tableView.addTableColumn(mainCol)
        tableView.addTableColumn(shortcutCol)
        tableView.style = .inset
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor

        let cancelBtn = NSButton(title: "Close", target: self, action: #selector(closePressed(_:)))
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.bezelStyle = .recessed
        let runBtn = NSButton(title: "Run / Open ↵", target: self, action: #selector(executeSelected(_:)))
        runBtn.bezelStyle = .rounded
        runBtn.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerRow = NSStackView(views: [footerLabel, spacer, cancelBtn, runBtn])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [topRow, divider, scroll, footerRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
    }

    private func applyModeConfiguration() {
        modeSegment.selectedSegment = (mode == .commands) ? 0 : 1
        searchField.placeholderString = mode == .commands
            ? "Type a command (e.g. Compress Clean ZIP, Dual Pane, New Swift File) or folder name…"
            : "Fuzzy jump to any file or subfolder in \(currentDirectory.lastPathComponent), or type '>' for commands…"
    }

    private func startNestedFuzzyDiscovery() {
        discoveryTask?.cancel()
        let root = currentDirectory
        let hidden = includeHidden
        let excludeGitIgnored = ExplorerPreferences.shared.excludeGitIgnoredFromSearch
        discoveryTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                CommandPaletteEngine.discoverNestedItems(
                    under: root,
                    maxDepth: 3,
                    limit: 300,
                    includeHidden: hidden,
                    excludeGitIgnored: excludeGitIgnored
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            var existingPaths = Set(self.allItems.compactMap { item -> String? in
                switch item.target {
                case .folder(let url), .file(let url): return url.standardizedFileURL.path
                case .command: return nil
                }
            })
            var extraItems: [CommandPaletteItem] = []
            for entry in discovered {
                guard existingPaths.insert(entry.url.standardizedFileURL.path).inserted else { continue }
                extraItems.append(
                    CommandPaletteItem(
                        id: "nested:\(entry.url.path)",
                        title: entry.relativePath,
                        subtitle: DemoScreenshotEnvironment.displayPath(for: entry.url),
                        category: entry.isDirectory ? "Subfolder" : "Nested File",
                        symbolName: entry.isDirectory ? "folder.fill" : "doc.text",
                        shortcutHint: entry.isDirectory ? "Jump" : "Open",
                        keywords: [entry.url.lastPathComponent, entry.relativePath],
                        target: entry.isDirectory ? .folder(entry.url) : .file(entry.url)
                    )
                )
            }
            if !extraItems.isEmpty {
                self.allItems.append(contentsOf: extraItems)
                self.refreshResults()
            }
        }
    }

    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 0 ? .commands : .fuzzyNavigation
        applyModeConfiguration()
        refreshResults()
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let next = min(filteredItems.count - 1, max(0, tableView.selectedRow + 1))
            if filteredItems.indices.contains(next) {
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let prev = max(0, tableView.selectedRow - 1)
            if filteredItems.indices.contains(prev) {
                tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                tableView.scrollRowToVisible(prev)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            executeSelected(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closePressed(nil)
            return true
        }
        return false
    }

    private func refreshResults() {
        filteredItems = CommandPaletteEngine.rank(
            items: allItems,
            query: searchField.stringValue,
            mode: mode,
            limit: 80
        )
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredItems.indices.contains(row), let column = tableColumn else { return nil }
        let item = filteredItems[row]
        let identifier = column.identifier

        if identifier.rawValue == "shortcut" {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: item.shortcutHint)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyDown
            image.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 2
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = image
            cell.textField = field
            cell.addSubview(image)
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.imageView?.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)
        switch item.target {
        case .command: cell.imageView?.contentTintColor = .systemBlue
        case .folder: cell.imageView?.contentTintColor = .systemOrange
        case .file: cell.imageView?.contentTintColor = .secondaryLabelColor
        }

        let combined = NSMutableAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        combined.append(
            NSAttributedString(
                string: "\n\(item.category) · \(item.subtitle)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        )
        cell.textField?.attributedStringValue = combined
        return cell
    }

    func windowDidResignKey(_ notification: Notification) {
        discoveryTask?.cancel()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        discoveryTask?.cancel()
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        executeSelected(sender)
    }

    @objc private func executeSelected(_ sender: Any?) {
        let index = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        guard filteredItems.indices.contains(index) else { return }
        let selected = filteredItems[index]
        let openInNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        discoveryTask?.cancel()
        if let parent = window?.sheetParent, let window {
            parent.endSheet(window, returnCode: .OK)
        } else {
            window?.orderOut(nil)
        }
        onSelect(selected, openInNewTab)
    }

    @objc func closePressed(_ sender: Any?) {
        discoveryTask?.cancel()
        if let parent = window?.sheetParent, let window {
            parent.endSheet(window, returnCode: .cancel)
        } else {
            window?.orderOut(nil)
        }
    }

    func configureDemoQuery(_ query: String, selectedIndex: Int = 0) {
        searchField.stringValue = query
        refreshResults()
        if filteredItems.indices.contains(selectedIndex) {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }
}
