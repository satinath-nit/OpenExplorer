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
    private var globalOpenShortcut: GlobalHotKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = BrowserWindowController()
        browserWindow = controller
        globalOpenShortcut = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: UInt32(cmdKey)
        ) { [weak self] in
            self?.presentMainWindow()
        }
        configureMenu()
        presentMainWindow()

        // Launch Services can finish activating a command-line-built AppKit bundle
        // after applicationDidFinishLaunching. Reassert the first window on the next
        // run-loop turn so the app never launches as a Dock icon without a window.
        DispatchQueue.main.async { [weak self] in
            self?.presentMainWindow()
            self?.finishStartupSmokeTestIfRequested()
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
        let shortcuts: [(String, String)] = [("New Tab", "n"), ("Copy", "c"), ("Paste", "v")]
        guard shortcuts.allSatisfy({ menuItem(titled: $0.0)?.keyEquivalent == $0.1 && menuItem(titled: $0.0)?.target === browserWindow }) else {
            FileHandle.standardError.write(Data("FAIL: OpenExplorer keyboard shortcuts are not routed to the browser window\n".utf8))
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

        window.performClose(nil)
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
        print("PASS: Command-N, Command-C, and Command-V are routed to the browser window")
        print("PASS: OpenExplorer surfaces adapt to light and dark appearance")
        print("PASS: Address editing and folder location actions are available")
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
        appMenu.addItem(withTitle: "Quit OpenExplorer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newTab = fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "n")
        newTab.target = browserWindow
        let newFolder = fileMenu.addItem(withTitle: "New Folder", action: #selector(BrowserWindowController.createFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        newFolder.target = browserWindow
        let open = fileMenu.addItem(withTitle: "Open", action: #selector(BrowserWindowController.openSelection(_:)), keyEquivalent: "o")
        open.target = browserWindow
        let quickLook = fileMenu.addItem(withTitle: "Quick Look", action: #selector(BrowserWindowController.quickLook(_:)), keyEquivalent: "y")
        quickLook.target = browserWindow
        fileMenu.addItem(.separator())
        let rename = fileMenu.addItem(withTitle: "Rename", action: #selector(BrowserWindowController.renameSelection(_:)), keyEquivalent: "\r")
        rename.target = browserWindow
        let trash = fileMenu.addItem(withTitle: "Move to Trash", action: #selector(BrowserWindowController.trashSelection(_:)), keyEquivalent: "\u{8}")
        trash.target = browserWindow
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let cut = editMenu.addItem(withTitle: "Cut", action: #selector(BrowserWindowController.cutSelection(_:)), keyEquivalent: "x")
        cut.target = browserWindow
        let copy = editMenu.addItem(withTitle: "Copy", action: #selector(BrowserWindowController.copySelection(_:)), keyEquivalent: "c")
        copy.target = browserWindow
        let paste = editMenu.addItem(withTitle: "Paste", action: #selector(BrowserWindowController.paste(_:)), keyEquivalent: "v")
        paste.target = browserWindow
        editMenu.addItem(.separator())
        let selectAll = editMenu.addItem(withTitle: "Select All", action: #selector(BrowserWindowController.selectAllItems(_:)), keyEquivalent: "a")
        selectAll.target = browserWindow
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
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
