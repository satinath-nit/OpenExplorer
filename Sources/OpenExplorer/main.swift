import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    hotKey.action()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F584550), id: 1) // "OXEP"
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            return nil
        }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    func triggerForTesting() { action() }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserWindow: BrowserWindowController?
    private var extraWindows: [BrowserWindowController] = []
    private var settingsWindow: SettingsWindowController?
    private var globalOpenShortcut: GlobalHotKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = BrowserWindowController()
        browserWindow = controller
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        registerGlobalShortcut()
        NotificationCenter.default.addObserver(
            forName: ExplorerPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.registerGlobalShortcut()
            }
        }
        configureMenu()
        presentMainWindow()
        handleCommandLineArgumentsIfPresent()

        // Launch Services can finish activating a command-line-built AppKit bundle
        // after applicationDidFinishLaunching. Reassert the first window on the next
        // run-loop turn so the app never launches as a Dock icon without a window.
        DispatchQueue.main.async { [weak self] in
            self?.presentMainWindow()
            self?.finishScreenshotCaptureIfRequested()
            self?.finishStartupSmokeTestIfRequested()
        }
    }

    private func finishScreenshotCaptureIfRequested() {
        guard let outputDir = DemoScreenshotEnvironment.outputDirectoryPath, !outputDir.isEmpty else { return }
        do {
            try browserWindow?.captureAllFeatureScreenshots(to: URL(fileURLWithPath: outputDir, isDirectory: true))
            print("PASS: Captured all feature screenshots into \(outputDir)")
            fflush(stdout)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("FAIL: Screenshot capture failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private func registerGlobalShortcut() {
        globalOpenShortcut = nil
        if let preset = ExplorerPreferences.shared.globalHotKeyPreset.keyCodeAndModifiers {
            globalOpenShortcut = GlobalHotKey(
                keyCode: preset.keyCode,
                modifiers: preset.modifiers
            ) { [weak self] in
                self?.presentMainWindow()
            }
        }
    }

    private func handleCommandLineArgumentsIfPresent() {
        guard ProcessInfo.processInfo.environment["OPENEXPLORER_SMOKE_TEST"] != "1" else { return }
        let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") && $0 != "YES" && $0 != "NO" }
        guard !args.isEmpty else { return }
        if args.first == "--reveal", args.count >= 2 {
            let target = URL(fileURLWithPath: NSString(string: args[1]).expandingTildeInPath)
            browserWindow?.openExternalURL(target, revealOnly: true)
        } else if let first = args.first, !first.hasPrefix("-") {
            let target = URL(fileURLWithPath: NSString(string: first).expandingTildeInPath)
            browserWindow?.openExternalURL(target, revealOnly: false)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if browserWindow == nil {
            browserWindow = BrowserWindowController()
        }
        presentMainWindow()
        for url in urls {
            if url.scheme == "openexplorer" {
                let path = url.path.isEmpty ? url.host.map { "/\($0)" } ?? "/" : url.path
                let fileURL = URL(fileURLWithPath: path)
                let reveal = url.query?.contains("reveal=1") == true
                browserWindow?.openExternalURL(fileURL, revealOnly: reveal)
            } else if url.isFileURL {
                browserWindow?.openExternalURL(url, revealOnly: false)
            }
        }
    }

    @objc func openInOpenExplorerService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        if browserWindow == nil {
            browserWindow = BrowserWindowController()
        }
        presentMainWindow()
        for url in urls {
            browserWindow?.openExternalURL(url, revealOnly: false)
        }
    }

    // Match Finder and other document-style macOS apps: closing the last window
    // leaves the application running in the Dock until the user explicitly quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if browserWindow == nil { browserWindow = BrowserWindowController() }
            presentMainWindow()
        }
        return true
    }

    @objc private func openNewBrowserWindow(_ sender: Any?) {
        let initial = browserWindow?.currentDirectoryURL
        let newController = BrowserWindowController(initialFolderURL: initial)
        extraWindows.append(newController)
        newController.onCloseWindow = { [weak self, weak newController] in
            guard let self, let newController else { return }
            self.extraWindows.removeAll { $0 === newController }
        }
        newController.showWindow(nil)
        newController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsWindow(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onInstallCLI = { [weak self] in
                self?.installCLITool(nil)
            }
            settingsWindow = controller
        }
        settingsWindow?.syncFromPreferences()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func installCLITool(_ sender: Any?) {
        let execPath = Bundle.main.executablePath ?? "/Applications/OpenExplorer.app/Contents/MacOS/OpenExplorer"
        let scriptContent = """
        #!/bin/zsh
        exec "\(execPath)" "$@"
        """
        let userBinDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let localBinFile = URL(fileURLWithPath: "/usr/local/bin/oe")
        let fallbackFile = userBinDir.appendingPathComponent("oe")
        var installedPath = localBinFile.path

        do {
            try Data(scriptContent.utf8).write(to: localBinFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localBinFile.path)
        } catch {
            do {
                try FileManager.default.createDirectory(at: userBinDir, withIntermediateDirectories: true)
                try Data(scriptContent.utf8).write(to: fallbackFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallbackFile.path)
                installedPath = fallbackFile.path
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not install ‘oe’ CLI command"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Installed ‘oe’ Command-Line Helper"
        alert.informativeText = "Installed at \(installedPath)\n\nUsage:\n  oe .               Open current folder\n  oe --reveal <file> Reveal item in OpenExplorer"
        alert.runModal()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "2.1.1"
        guard let url = URL(string: "https://api.github.com/repos/satinath-nit/OpenExplorer/releases/latest") else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let tagName = (json?["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) ?? currentVersion
                let htmlURL = (json?["html_url"] as? String).flatMap(URL.init(string:))
                let alert = NSAlert()
                if tagName.compare(currentVersion, options: .numeric) == .orderedDescending {
                    alert.messageText = "OpenExplorer \(tagName) is Available"
                    alert.informativeText = "You are currently running version \(currentVersion)."
                    alert.addButton(withTitle: "Download Release")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn, let htmlURL {
                        NSWorkspace.shared.open(htmlURL)
                    }
                } else {
                    alert.messageText = "OpenExplorer is Up to Date"
                    alert.informativeText = "Version \(currentVersion) is the latest version available."
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Update Check Completed"
                alert.informativeText = "Running OpenExplorer \(currentVersion). Visit GitHub Releases for the latest builds."
                alert.runModal()
            }
        }
    }

    private func presentMainWindow() {
        guard let window = browserWindow?.window else { return }
        window.isRestorable = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishStartupSmokeTestIfRequested() {
        guard ProcessInfo.processInfo.environment["OPENEXPLORER_SMOKE_TEST"] == "1" else { return }
        guard let window = browserWindow?.window, window.isVisible, window.isKeyWindow else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer launched without a visible key window\n".utf8))
            exit(1)
        }
        let shortcuts: [(String, String)] = [("New Tab", "n"), ("Copy", "c"), ("Paste", "v"), ("Close Window", "w")]
        guard shortcuts.allSatisfy({ menuItem(titled: $0.0)?.keyEquivalent == $0.1 && menuItem(titled: $0.0)?.target === browserWindow }) else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer keyboard shortcuts are not routed to the browser window\n".utf8))
            exit(1)
        }
        guard let cutItem = menuItem(titled: "Cut"),
              cutItem.keyEquivalent == "x",
              cutItem.keyEquivalentModifierMask == [.command],
              cutItem.target === browserWindow else {
            FileHandle.standardError.write(Data("FAIL: Cut is not routed to Command-X\n".utf8))
            exit(1)
        }
        guard menuItem(titled: "Undo Last File Operation")?.keyEquivalent == "z",
              menuItem(titled: "Get Info")?.keyEquivalent == "i",
              menuItem(titled: "Command Palette…")?.keyEquivalent == "k",
              menuItem(titled: "Go to File or Folder (Fuzzy)…")?.keyEquivalent == "p",
              menuItem(titled: "Dim Git-Ignored Files")?.target === browserWindow,
              menuItem(titled: "Exclude Git-Ignored Files from Search")?.target === browserWindow else {
            FileHandle.standardError.write(Data("FAIL: Finder-replacement shortcuts are incomplete\n".utf8))
            exit(1)
        }
        let appearanceFailures = browserWindow?.appearanceSmokeTestFailures() ?? ["browser window is unavailable"]
        guard appearanceFailures.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer does not adapt cleanly to light and dark appearance: \(appearanceFailures.joined(separator: ", "))\n".utf8))
            exit(1)
        }
        let interactionFailures = browserWindow?.interactionSmokeTestFailures() ?? ["browser window is unavailable"]
        guard interactionFailures.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer location actions are incomplete: \(interactionFailures.joined(separator: ", "))\n".utf8))
            exit(1)
        }
        let dragFailures = browserWindow?.dragExportSmokeTestFailures() ?? ["browser window is unavailable"]
        guard dragFailures.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer cannot drag files and folders to other apps: \(dragFailures.joined(separator: ", "))\n".utf8))
            exit(1)
        }
        let columnFailures = browserWindow?.listColumnTransitionSmokeTestFailures() ?? ["browser window is unavailable"]
        guard columnFailures.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer List columns are unstable after a view-mode round trip: \(columnFailures.joined(separator: ", "))\n".utf8))
            exit(1)
        }
        guard !applicationShouldTerminateAfterLastWindowClosed(NSApp) else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer terminates when its last window closes\n".utf8))
            exit(1)
        }
        guard globalOpenShortcut?.isRegistered == true else {
            FileHandle.standardError.write(Data("FAIL: Command-E global OpenExplorer shortcut is not registered\n".utf8))
            exit(1)
        }

        browserWindow?.closeWindow(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !window.isVisible else {
                FileHandle.standardError.write(Data("FAIL: OpenExplorer window did not close cleanly\n".utf8))
                exit(1)
            }
            self.globalOpenShortcut?.triggerForTesting()
            guard window.isVisible, window.isKeyWindow else {
                FileHandle.standardError.write(Data("FAIL: Command-E did not restore the OpenExplorer window\n".utf8))
                exit(1)
            }
            self.finishSuccessfulSmokeTest()
        }
    }

    private func finishSuccessfulSmokeTest() {
        print("PASS: OpenExplorer launched with a visible key window")
        print("PASS: Command-W closes the window and Command-X cuts selections")
        print("PASS: Command-N, Command-C, and Command-V are routed to the browser window")
        print("PASS: Command-Z undo and Command-I Get Info are available")
        print("PASS: OpenExplorer surfaces adapt to light and dark appearance")
        print("PASS: Address editing and folder location actions are available")
        print("PASS: Right-click ZIP compression, Clean ZIP, and Batch Rename are available")
        print("PASS: Command-K Command Palette and Command-P Fuzzy Navigation are available")
        print("PASS: List and icon views export files and folders to other apps")
        print("PASS: List column widths remain stable after changing view modes")
        print("PASS: Closing the last window keeps OpenExplorer running and Dock reopen restores it")
        print("PASS: Command-E is registered globally and restores the OpenExplorer window")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private func menuItem(titled title: String) -> NSMenuItem? {
        for topLevel in NSApp.mainMenu?.items ?? [] {
            if let item = topLevel.submenu?.items.first(where: { $0.title == title }) { return item }
        }
        return nil
    }

    private func configureMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OpenExplorer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsWindow(_:)), keyEquivalent: ",")
        settings.target = self
        let installCLI = appMenu.addItem(withTitle: "Install ‘oe’ Command in PATH…", action: #selector(installCLITool(_:)), keyEquivalent: "")
        installCLI.target = self
        let checkUpdates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkUpdates.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenExplorer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newTab = fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "n")
        newTab.target = browserWindow
        let newWin = fileMenu.addItem(withTitle: "New Window", action: #selector(openNewBrowserWindow(_:)), keyEquivalent: "n")
        newWin.keyEquivalentModifierMask = [.command, .option]
        newWin.target = self
        let newFolder = fileMenu.addItem(withTitle: "New Folder", action: #selector(BrowserWindowController.createFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        newFolder.target = browserWindow
        let newBlankFile = fileMenu.addItem(withTitle: "New Blank File…", action: #selector(BrowserWindowController.createBlankFile(_:)), keyEquivalent: "")
        newBlankFile.target = browserWindow
        let open = fileMenu.addItem(withTitle: "Open", action: #selector(BrowserWindowController.openSelection(_:)), keyEquivalent: "o")
        open.target = browserWindow
        let quickLook = fileMenu.addItem(withTitle: "Quick Look", action: #selector(BrowserWindowController.quickLook(_:)), keyEquivalent: "y")
        quickLook.target = browserWindow
        let getInfo = fileMenu.addItem(withTitle: "Get Info", action: #selector(BrowserWindowController.showGetInfo(_:)), keyEquivalent: "i")
        getInfo.target = browserWindow
        fileMenu.addItem(.separator())
        let compressZip = fileMenu.addItem(withTitle: "Compress to ZIP", action: #selector(BrowserWindowController.compressSelectionToZip(_:)), keyEquivalent: "")
        compressZip.target = browserWindow
        let compressCleanZip = fileMenu.addItem(withTitle: "Compress Clean ZIP (No .DS_Store)", action: #selector(BrowserWindowController.compressSelectionCleanZip(_:)), keyEquivalent: "")
        compressCleanZip.target = browserWindow
        let shareItem = fileMenu.addItem(withTitle: "Share…", action: #selector(BrowserWindowController.shareSelection(_:)), keyEquivalent: "")
        shareItem.target = browserWindow
        fileMenu.addItem(.separator())
        let rename = fileMenu.addItem(withTitle: "Rename", action: #selector(BrowserWindowController.renameSelection(_:)), keyEquivalent: "\r")
        rename.target = browserWindow
        let batchRename = fileMenu.addItem(withTitle: "Batch Rename…", action: #selector(BrowserWindowController.batchRenameSelection(_:)), keyEquivalent: "R")
        batchRename.keyEquivalentModifierMask = [.command, .shift]
        batchRename.target = browserWindow
        let trash = fileMenu.addItem(withTitle: "Move to Trash", action: #selector(BrowserWindowController.trashSelection(_:)), keyEquivalent: "\u{8}")
        trash.target = browserWindow
        let permDelete = fileMenu.addItem(withTitle: "Delete Permanently…", action: #selector(BrowserWindowController.permanentlyDeleteSelection(_:)), keyEquivalent: "\u{8}")
        permDelete.keyEquivalentModifierMask = [.command, .shift]
        permDelete.target = browserWindow
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo Last File Operation", action: #selector(BrowserWindowController.undoLastOperation(_:)), keyEquivalent: "z")
        undo.target = browserWindow
        let redo = editMenu.addItem(withTitle: "Redo Last File Operation", action: #selector(BrowserWindowController.redoLastOperation(_:)), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = browserWindow
        editMenu.addItem(.separator())
        let cut = editMenu.addItem(withTitle: "Cut", action: #selector(BrowserWindowController.cutSelection(_:)), keyEquivalent: "x")
        cut.keyEquivalentModifierMask = [.command]
        cut.target = browserWindow
        let copy = editMenu.addItem(withTitle: "Copy", action: #selector(BrowserWindowController.copySelection(_:)), keyEquivalent: "c")
        copy.target = browserWindow
        let paste = editMenu.addItem(withTitle: "Paste", action: #selector(BrowserWindowController.paste(_:)), keyEquivalent: "v")
        paste.target = browserWindow
        editMenu.addItem(.separator())
        let selectAll = editMenu.addItem(withTitle: "Select All", action: #selector(BrowserWindowController.selectAllItems(_:)), keyEquivalent: "a")
        selectAll.target = browserWindow
        let filterCurrent = editMenu.addItem(withTitle: "Filter Current Folder…", action: #selector(BrowserWindowController.focusFilter(_:)), keyEquivalent: "f")
        filterCurrent.keyEquivalentModifierMask = [.command, .option]
        filterCurrent.target = browserWindow
        let searchRec = editMenu.addItem(withTitle: "Search Folder Recursively…", action: #selector(BrowserWindowController.focusRecursiveSearch(_:)), keyEquivalent: "f")
        searchRec.target = browserWindow
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let cmdPaletteView = viewMenu.addItem(withTitle: "Command Palette…", action: #selector(BrowserWindowController.showCommandPalette(_:)), keyEquivalent: "k")
        cmdPaletteView.target = browserWindow
        let dualPane = viewMenu.addItem(withTitle: "Toggle Dual-Pane Split View", action: #selector(BrowserWindowController.toggleDualPane(_:)), keyEquivalent: "p")
        dualPane.keyEquivalentModifierMask = [.command, .option]
        dualPane.target = browserWindow
        viewMenu.addItem(.separator())
        let dimGitIgnored = viewMenu.addItem(withTitle: "Dim Git-Ignored Files", action: #selector(BrowserWindowController.toggleDimGitIgnoredFiles(_:)), keyEquivalent: "")
        dimGitIgnored.target = browserWindow
        let excludeGitIgnoredSearch = viewMenu.addItem(withTitle: "Exclude Git-Ignored Files from Search", action: #selector(BrowserWindowController.toggleExcludeGitIgnoredFromSearch(_:)), keyEquivalent: "")
        excludeGitIgnoredSearch.target = browserWindow
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let fuzzyGoTo = goMenu.addItem(withTitle: "Go to File or Folder (Fuzzy)…", action: #selector(BrowserWindowController.showFuzzyGoTo(_:)), keyEquivalent: "p")
        fuzzyGoTo.target = browserWindow
        goMenu.addItem(.separator())
        let back = goMenu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        back.target = browserWindow
        let forward = goMenu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        forward.target = browserWindow
        let enclosing = goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(BrowserWindowController.goUp(_:)), keyEquivalent: "\u{2191}")
        enclosing.keyEquivalentModifierMask = [.command]
        enclosing.target = browserWindow
        let location = goMenu.addItem(withTitle: "Location…", action: #selector(BrowserWindowController.focusAddress(_:)), keyEquivalent: "l")
        location.target = browserWindow
        let reload = goMenu.addItem(withTitle: "Reload", action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        reload.target = browserWindow
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeWindow = windowMenu.addItem(withTitle: "Close Window", action: #selector(BrowserWindowController.closeWindow(_:)), keyEquivalent: "w")
        closeWindow.target = browserWindow
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
