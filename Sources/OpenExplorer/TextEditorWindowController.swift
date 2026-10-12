import AppKit
import Foundation

@MainActor
final class TextEditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    enum TextEditorError: LocalizedError {
        case directory
        case tooLarge(Int64)
        case binaryOrUnsupportedEncoding

        var errorDescription: String? {
            switch self {
            case .directory:
                return "Folders cannot be opened in the text editor."
            case .tooLarge(let bytes):
                return "This file is too large for the built-in editor (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
            case .binaryOrUnsupportedEncoding:
                return "This does not appear to be a supported text file. Try Open With instead."
            }
        }
    }

    private static let maximumFileSize: Int64 = 20 * 1_024 * 1_024

    private let fileURL: URL
    private let textView = EditorTextView()
    private let scrollView = NSScrollView()
    private let saveButton = NSButton()
    private let wrapButton = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var encoding: String.Encoding
    private var originalModificationDate: Date?
    private var originalPermissions: NSNumber?
    private var isDirty = false {
        didSet { updateWindowTitle() }
    }
    var onClose: (() -> Void)?

    static func canOpen(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              values.isDirectory != true,
              Int64(values.fileSize ?? 0) <= maximumFileSize,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return decode(data) != nil
    }

    init(fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isDirectory != true else { throw TextEditorError.directory }
        let size = Int64(values.fileSize ?? 0)
        guard size <= Self.maximumFileSize else { throw TextEditorError.tooLarge(size) }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard let decoded = Self.decode(data) else { throw TextEditorError.binaryOrUnsupportedEncoding }
        self.fileURL = fileURL
        self.encoding = decoded.encoding
        self.originalModificationDate = values.contentModificationDate
        self.originalPermissions = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]) as? NSNumber

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface(text: decoded.text)
        updateWindowTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface(text: String) {
        guard let content = window?.contentView else { return }

        let header = NSVisualEffectView()
        header.material = .headerView
        header.translatesAutoresizingMaskIntoConstraints = false

        let fileIcon = NSImageView(image: NSWorkspace.shared.icon(forFile: fileURL.path))
        fileIcon.imageScaling = .scaleProportionallyDown
        fileIcon.translatesAutoresizingMaskIntoConstraints = false
        let fileName = NSTextField(labelWithString: fileURL.lastPathComponent)
        fileName.font = .systemFont(ofSize: 13, weight: .semibold)
        fileName.lineBreakMode = .byTruncatingMiddle
        fileName.toolTip = fileURL.path

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = encodingName

        wrapButton.target = self
        wrapButton.action = #selector(toggleWrapping(_:))
        wrapButton.state = .on

        saveButton.title = "Save"
        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
        saveButton.imagePosition = .imageLeading
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerStack = NSStackView(views: [fileIcon, fileName, statusLabel, spacer, wrapButton, saveButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self
        textView.onSave = { [weak self] in self?.save(nil) }
        textView.onFind = { [weak self] in self?.showFindBar() }
        scrollView.documentView = textView
        applyWrapping(true)

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        content.addSubview(header)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: header.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: 24),
            fileIcon.heightAnchor.constraint(equalToConstant: 24),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
        saveButton.isEnabled = true
        scrollView.verticalRulerView?.needsDisplay = true
    }

    @objc func save(_ sender: Any?) {
        if fileChangedOutsideEditor() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The file changed outside OpenExplorer"
            alert.informativeText = "Saving now will replace those newer changes."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        guard let data = textView.string.data(using: encoding, allowLossyConversion: false) else {
            showError("Could not save the file", detail: "The edited text cannot be represented using \(encodingName).")
            return
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            if let originalPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: fileURL.path)
            }
            originalModificationDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            isDirty = false
            saveButton.isEnabled = false
            statusLabel.stringValue = "Saved · \(encodingName)"
        } catch {
            showError("Could not save the file", detail: error.localizedDescription)
        }
    }

    @objc private func toggleWrapping(_ sender: NSButton) {
        applyWrapping(sender.state == .on)
    }

    private func applyWrapping(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        if wraps {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: max(scrollView.contentSize.width, 1), height: .greatestFiniteMagnitude)
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func showFindBar() {
        window?.makeFirstResponder(textView)
        let findCommand = NSMenuItem()
        findCommand.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(findCommand)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(fileURL.lastPathComponent)” ?"
        alert.informativeText = "Your changes will be lost if you close without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(nil)
            return !isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func updateWindowTitle() {
        window?.title = "\(isDirty ? "• " : "")\(fileURL.lastPathComponent) — OpenExplorer Editor"
        window?.representedURL = fileURL
    }

    private func fileChangedOutsideEditor() -> Bool {
        guard isDirty, let originalModificationDate,
              let current = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return current != originalModificationDate
    }

    private var encodingName: String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16, .utf16LittleEndian, .utf16BigEndian: "UTF-16"
        case .isoLatin1: "ISO Latin 1"
        case .macOSRoman: "Mac OS Roman"
        default: "Text"
        }
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window { alert.beginSheetModal(for: window) }
    }

    private static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.isEmpty { return ("", .utf8) }
        guard !looksLikeKnownBinary(data) else { return nil }
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), isProbablyText(text, originalData: data, encoding: encoding) {
                return (text, encoding)
            }
        }
        return nil
    }

    private static func looksLikeKnownBinary(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(8_192))
        let signatures: [[UInt8]] = [
            [0x25, 0x50, 0x44, 0x46],       // PDF
            [0x50, 0x4B, 0x03, 0x04],       // ZIP and Office documents
            [0x89, 0x50, 0x4E, 0x47],       // PNG
            [0xFF, 0xD8, 0xFF],             // JPEG
            [0x47, 0x49, 0x46, 0x38],       // GIF
            [0xCA, 0xFE, 0xBA, 0xBE],       // Mach-O universal
            [0xCF, 0xFA, 0xED, 0xFE],       // Mach-O 64-bit
            [0xFE, 0xED, 0xFA, 0xCF]        // Mach-O 64-bit (swapped)
        ]
        if signatures.contains(where: { bytes.starts(with: $0) }) { return true }
        let hasUTF16ByteOrderMark = bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF])
        if !hasUTF16ByteOrderMark && bytes.contains(0) { return true }
        let controlCount = bytes.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }.count
        return !hasUTF16ByteOrderMark && Double(controlCount) / Double(max(bytes.count, 1)) >= 0.02
    }

    private static func isProbablyText(_ text: String, originalData: Data, encoding: String.Encoding) -> Bool {
        if encoding == .utf8 && originalData.prefix(8_192).contains(0) { return false }
        let sample = text.unicodeScalars.prefix(8_192)
        guard !sample.isEmpty || originalData.isEmpty else { return false }
        let disallowed = sample.filter { scalar in
            scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }.count
        return Double(disallowed) / Double(max(sample.count, 1)) < 0.02
    }
}

private final class EditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onFind: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command] {
            if event.charactersIgnoringModifiers == "s" { onSave?(); return }
            if event.charactersIgnoringModifiers == "f" { onFind?(); return }
        }
        super.keyDown(with: event)
    }
}

private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 48
        let center = NotificationCenter.default
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(redrawLineNumbers(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        }
        center.addObserver(self, selector: #selector(redrawLineNumbers(_:)), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redrawLineNumbers(_ notification: Notification) { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let string = textView.string as NSString
        var lineStart = 0
        var lineNumber = 1
        while lineStart < visibleCharacters.location && lineStart < string.length {
            lineStart = NSMaxRange(string.lineRange(for: NSRange(location: lineStart, length: 0)))
            lineNumber += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let upperBound = min(NSMaxRange(visibleCharacters) + 1, string.length + 1)
        repeat {
            let glyphIndex = lineStart < string.length ? layoutManager.glyphIndexForCharacter(at: lineStart) : layoutManager.numberOfGlyphs
            let fragment = glyphIndex < layoutManager.numberOfGlyphs
                ? layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                : NSRect(x: 0, y: layoutManager.usedRect(for: textContainer).maxY, width: 0, height: textView.font?.ascender ?? 14)
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + textView.textContainerInset.height - visibleRect.minY
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            if lineStart >= string.length { break }
            lineStart = NSMaxRange(string.lineRange(for: NSRange(location: lineStart, length: 0)))
            lineNumber += 1
        } while lineStart < upperBound
    }
}
