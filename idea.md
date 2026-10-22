# OpenExplorer — Roadmap to a True macOS Finder Replacement

This document outlines product, UX, system-integration, and architectural improvements to evolve **OpenExplorer** from a feature-rich prototype into a daily-driver, production-ready replacement for macOS Finder—combining the best of **Windows 11 File Explorer** ergonomics with deep **macOS system integration**.

---

## 1. Deep macOS System Integration ("True Finder Replacement")

Right now, OpenExplorer works well when launched directly, but macOS still routes many system-level file interactions to Finder. To replace Finder completely:

### 1.1 Default File Manager Registration (`NSFileViewer`)
- **Set as Default File Manager**: Add a toggle in Preferences/Settings that sets `NSFileViewer` in `com.apple.LaunchServices/com.apple.launchservices.secure.plist` (and `defaults write -g NSFileViewer -string local.openexplorer.app`) so clicking **"Show in Finder" / "Reveal in Finder"** in browsers (Chrome, Safari, Arc), VS Code, Slack, and Xcode opens OpenExplorer instead of Finder.
- **Folder & `file://` URL Handling**: Declare `public.folder`, `public.directory`, and `public.volume` document types and `file` / `openexplorer` URL schemes in `Resources/Info.plist`, and implement `application(_:open:)` in `AppDelegate` so external apps can open specific folders or highlight specific files directly in a new or active tab.

### 1.2 CLI Tool (`openexplorer` / `oe`)
- Provide an **"Install `oe` Command in PATH"** action in the app menu (symlinking a CLI helper to `/usr/local/bin/oe`).
- Support commands like:
  - `oe .` — open current Terminal directory in an OpenExplorer tab
  - `oe --reveal <path>` — open parent directory and select the target item

### 1.3 macOS Services & Share Sheet Integration
- **Native Share Sheet (`NSSharingServicePicker`)**: Add a **Share** button in the toolbar and right-click context menu for **AirDrop**, Mail, Messages, and third-party share extensions.
- **System Services Menu**: Support the standard macOS **Services** submenu on right-click so user Automator workflows, Shortcuts, and third-party app services work seamlessly.
- **Quick Actions / Shortcuts App Support**: Expose App Intents or AppleScript dictionary (`sdef`) so Raycast, Alfred, and macOS Shortcuts can query the active OpenExplorer tab path or current selection.

### 1.4 Launch at Login & Global Hotkey Customization
- **Launch at Login (`SMAppService`)**: Add a native macOS 13+ Login Item toggle so the background process and `⌘E` shortcut are always available after reboot.
- **Configurable Global Shortcut**: Allow users to customize `⌘E` (or `⌥Space`, `⌃⌘E`) in a Settings window to avoid conflicts with other apps that bind `⌘E` (e.g., "Use Selection for Find").

---

## 2. Windows Explorer Power-User UX & Navigation

Users coming from Windows File Explorer expect fast keyboard-driven workflows, visual clarity, and multi-location file management.

### 2.1 Dual-PaneView & Multi-Window Support
- **Multiple Windows (`⌘⇧N`)**: Currently `AppDelegate` holds a single `browserWindow: BrowserWindowController?`. Support an array of `BrowserWindowController` instances so users can place two windows side-by-side across monitors and drag files between them.
- **Split View (Dual Pane - `⌘P` or `F3`)**: Add an optional side-by-side or top-bottom split pane inside a single window (like Commander One / Total Commander / Q-Dir) with `Tab` switching focus between panes and `F5`/`F6` for instant Copy/Move across panes.
- **Tab Dragging & Reordering**: Allow dragging tabs to reorder them, dragging a tab out to create a new window, or dragging files *onto* a tab header to switch to (or drop into) that tab.
- **Middle-Click Navigation**: Middle-clicking a folder in the file list or sidebar should open it in a new background tab; middle-clicking a tab should close it.

### 2.2 Keyboard Ergonomics (Windows + Mac Hybrid)
- **Windows Shortcut Compatibility Mode (Optional Toggle)**:
  - `F2` in addition to `Return` to Rename (selecting filename stem only, excluding extension)
  - `Delete` (Forward Delete) to Move to Trash, `⇧Delete` to **Permanently Delete** (bypassing Trash with confirmation)
  - `Alt + Up` / `⌘Up` for Parent Folder, `Alt + Left/Right` / `⌘[` and `⌘]` for History
  - `Alt + Enter` (`⌥Return`) in addition to `⌘I` for Properties / Get Info
  - `Ctrl + Shift + N` / `⌘⇧N` for New Folder
- **Type-Ahead Quick Jump & Filter Bar**:
  - Typing letters while focused on the file list should immediately jump to the matching file (`a-z` prefix matching).
  - `⌘F` focuses recursive search; `⌘⇧F` (or `/` key) opens an instant **in-folder filter bar** that filters the current directory live without querying Spotlight.
- **Rubber-Band (Marquee) Selection & Checkboxes**:
  - Smooth click-and-drag selection rectangle in both Icon and List/Details views.
  - Optional Windows-style **Item Checkboxes** on hover for effortless multi-selection on trackpads.

### 2.3 Breadcrumb & Address Bar Enhancements
- **Breadcrumb Sibling Dropdowns**: Clicking the `>` chevron next to any folder in the breadcrumb bar should pop up a menu of sibling subfolders for rapid tree jumping without loading intermediate folders.
- **Path Autocomplete**: When editing the address bar (`⌘L`), provide dropdown path completion (supporting `~`, environment variables like `$HOME`, and fuzzy subfolder matching).
- **Recent Locations Dropdown**: A history chevron at the right end of the address bar listing recently visited paths.

### 2.4 Grouping, Columns & Folder-Size Calculation
- **Group By Mode**: Like Windows Explorer, allow grouping items by **Date (Today, Yesterday, Earlier this week, Last month)**, **File Type**, or **Size**.
- **Calculate Folder Sizes on Demand**: In List/Details view, folders usually show `--` for size. Add a background, cached folder-size scanner (with an optional visual relative-size bar behind the size column, like TreeSize/WizTree).
- **Per-Folder View Memory**: Remember sort order, view mode (Details vs. Large Icons for `Pictures`), and column widths per folder path (with a "Apply to all folders" button).

---

## 3. UI Polish & Visual Refinements (Based on Current v2.0.3 UI)

Looking at the current screenshot, the dark theme layout is clean and functional, with room for high-impact visual polish:

### 3.1 Real File Thumbnails & Rich Icons
- **Async Thumbnail Generation (`QLThumbnailGenerator`)**: Replace generic document icons with real high-DPI thumbnails for images (`.png`, `.jpg`, `.webp`, `.heic`, `.svg`), videos, PDFs, and PSDs, backed by an in-memory `NSCache` and disk cache.
- **Custom Dev & Archive Badges**: Tint or badge folders that contain `.git`, `package.json`, `Package.swift`, or `.xcodeproj` (similar to VS Code icon themes) so developers can identify project roots at a glance.

### 3.2 Enhanced Details & Preview Pane
- **Interactive Preview Pane**:
  - Embed a persistent `QLPreviewView` when the Preview pane is toggled on, allowing inline PDF scrolling, audio/video playback, and syntax-highlighted code preview without pressing Spacebar.
  - Display image dimensions (e.g., `2560 × 1664`), EXIF camera metadata, audio duration, and Git branch/status in the Details pane.
- **Disk Space Capacity Bar**:
  - In the status bar (bottom) and under **CLOUD & DEVICES** in the sidebar, render a sleek Windows "This PC"-style usage bar (`412 GB free of 1 TB`) for mounted volumes.

### 3.3 Sidebar Improvements
- **Collapsible Sections & Drag-and-Drop Reordering**: Allow collapsing *Favorites*, *Quick Access*, and *Cloud & Devices*, and reordering Favorites via drag-and-drop instead of only removing/adding.
- **Collapsible Tree View Mode**: Option to toggle the left sidebar (or a secondary pane) into a classic **Windows Explorer Folder Tree** (`NSOutlineView`) with expandable chevrons.
- **macOS Finder Tags & Color Labels**: Support reading, filtering by, and assigning native macOS Finder color tags (`NSURLTagNamesKey`) in the sidebar and file rows.

---

## 4. Advanced File Operations & Built-in Utilities

To prevent users from ever needing Finder or third-party utilities:

### 4.1 Non-Blocking Queued Operations & Conflict Resolution
- **Unified Operations Queue Popover**: Instead of modal progress sheets, show a compact transfers button/panel (like browser downloads or Windows 11 copy graphs) with real-time **MB/s transfer speed**, time remaining, Pause/Resume, and queued jobs.
- **Rich Conflict Dialog**: When a file collision occurs, show side-by-side thumbnails, file sizes, and modification timestamps ("Source is newer and larger") with **"Apply to all conflicts"** checkbox.
- **Multi-Step Undo/Redo Stack**: Expand `lastTransferRecords` into a full history stack (`UndoManager`) supporting undo/redo of renames, creations, moves, copies, and Trash operations across multiple steps.

### 4.2 Batch Rename Utility
- Select multiple files and press `⌘R` or `F2` to open a power **Batch Rename** sheet supporting:
  - Find & Replace (with Regex support)
  - Add Prefix / Suffix
  - Sequential Numbering (`photo_001.jpg`, `photo_002.jpg`) with live preview table before applying.

### 4.3 Right-Click to ZIP a Folder / Compress Items & Full Archive Management
Currently, [Sources/OpenExplorerCore/ZipExtractor.swift](Sources/OpenExplorerCore/ZipExtractor.swift) only supports *extracting* `.zip` archives via `/usr/bin/ditto -x -k`. Adding native **Right-Click → Compress / Send to ZIP** is a must-have for daily Finder & Windows Explorer parity:

- **Context Menu Actions**:
  - **Single Folder or File**: Right-clicking a folder (e.g., `Project`) shows **`Compress "Project" to ZIP`** (or Windows-style **`Send to > Compressed (zipped) folder`**), creating `Project.zip` in the same folder and automatically selecting/highlighting the new `.zip` file.
  - **Multiple Selected Items**: Right-clicking $N$ selected files/folders shows **`Compress N Items to ZIP`**, creating `Archive.zip` (or naming it after the parent folder / first item) and immediately entering inline rename mode so the user can type a custom archive name.
  - **Collision-Safe Naming**: Reuse the numbered-suffix pattern from `ZipExtractor.uniqueDestination` (`Project.zip`, `Project 2.zip`, `Project 3.zip`) so existing archives are never overwritten.
- **"Clean ZIP for Windows" Option (Killer Feature)**:
  - Standard macOS Finder compression pollutes ZIP files with `.DS_Store` and `__MACOSX` resource-fork folders that annoy Windows/Linux recipients.
  - Offer two modes (or a Settings preference):
    1. **macOS Native ZIP**: `/usr/bin/ditto -c -k --sequesterRsrc --keepParent <source> <dest.zip>` (preserves macOS extended attributes & permissions).
    2. **Clean Cross-Platform ZIP**: `/usr/bin/zip -r -X <dest.zip> <source> -x "*.DS_Store" -x "__MACOSX/*"` (strips `.DS_Store` and AppleDouble metadata).
- **Non-Blocking Progress & Undo Support**:
  - Run compression asynchronously on a background thread with a progress indicator and Cancel button for large folders, and register the created `.zip` with `⌘Z` Undo.
- **Broader Format & Virtual Browsing Support**:
  - Support extracting `.tar.gz`, `.tgz`, `.tar.bz2`, `.7z`, and `.rar`.
  - **Browse Inside Archives**: Double-click a `.zip` to inspect or drag out individual files virtually (Windows Explorer style) without extracting the entire archive first.

### 4.4 Developer & Power-User Context Menu ("Open With" & Terminal)
- **Customizable "New File" Templates**: Allow users to add custom templates (`~/Library/Application Support/OpenExplorer/Templates`), plus one-click creation of `.md`, `.txt`, `.json`, `.sh`, `.py`, `.swift`.
- **One-Click Open in IDE / Terminal**:
  - Detect installed editors (VS Code, Cursor, Zed, Xcode, Sublime Text) and terminals (Terminal, iTerm2, Warp, Ghostty, Kitty) and offer **"Open in VS Code"** / **"Open Terminal Here"** directly in the toolbar and context menu.
- **Git Status Integration**:
  - Optional column or badge icons showing modified (`M`), untracked (`U`), or staged (`A`) status for files inside Git repositories, plus current branch name in the bottom status bar.
- **Checksums & File Hashing**:
  - In the **Get Info** / Details panel, compute `SHA-256`, `SHA-1`, and `MD5` on demand with a one-click copy button.

---

## 5. Production Readiness, Performance & Architecture

To distribute OpenExplorer as a rock-solid macOS app used by thousands of users:

### 5.1 Modularizing the Codebase
- **Refactor `BrowserWindowController.swift`**: Split the monolithic window controller into focused modules:
  - `SidebarViewController` (Favorites, Quick Access, Volumes, Tags)
  - `FileBrowserViewController` (TableView, CollectionView, Selection, Drag & Drop)
  - `InspectorViewController` (Details & QuickLook Preview panes)
  - `AddressToolbarView` (Tabs, Breadcrumbs, Address Field, Command Bar)
  - `ThumbnailCacheService` & `FolderSizeService`

### 5.2 Extreme Directory Performance (10,000+ Files)
- **Async Incremental Directory Enumeration**: Use background `Task` streams with `FileManager.DirectoryEnumerator` so opening `node_modules`, `/usr/bin`, or large network shares (`SMB`/`NFS`) renders the first 200 items in `<16ms` without blocking the main thread.
- **Lazy Metadata & Icon Loading**: Fetch `NSWorkspace.shared.icon(forFile:)` and UTType strings lazily only for visible rows (`tableView(_:viewFor:row:)` / `collectionView(_:itemForRepresentedObjectAt:)`), cancelling tasks when rows scroll off-screen.
- **Debounced `FSEvents` Stream**: Upgrade `DirectoryMonitor` to use path-level `FSEventStream` with coalesced diff updates (`NSTableView.beginUpdates()` / diffable data source) instead of full reloads on every file event—preserving scroll position and active inline rename state when background files change.

### 5.3 Cloud Storage & FileProvider Awareness
- **iCloud Drive, OneDrive, Dropbox & Google Drive States**:
  - Read `URLResourceKey.ubiquitousItemDownloadingStatusKey` to display cloud status icons (Cloud-only, Downloading spinner, Downloaded locally checkmark).
  - Add right-click actions: **"Download Now"** (`startDownloadingUbiquitousItem`) and **"Evict Local Copy / Free Up Space"** (`evictUbiquitousItem`) so OpenExplorer doesn't accidentally trigger mass downloads when previewing cloud folders.

### 5.4 Permissions UX & Onboarding
- **First-Run Onboarding Wizard**: A clean 1-minute welcome sheet on first launch to:
  1. Grant **Full Disk Access** (with visual guide & deep link to System Settings so Trash, Desktop, Downloads, and External Drives never prompt repeatedly).
  2. Choose default theme, icon style (Windows Yellow vs. macOS Blue folders), and shortcut profile (macOS vs. Windows style).
  3. Optionally set OpenExplorer as the default file viewer.

### 5.5 Signing, Notarization & Auto-Updates
- **Developer ID Signing & Apple Notarization**: Add `xcrun notarytool` and `xcrun stapler` steps to `scripts/package-macos.sh` with hardened runtime entitlements so users never see Gatekeeper's *"OpenExplorer cannot be opened because the developer cannot be verified"* warning.
- **Universal Binary (`arm64` + `x86_64`)**: Build fat binaries with `lipo` in `package-macos.sh` so a single `.dmg` works on both Apple Silicon and Intel Macs.
- **Sparkle 2 Auto-Updater (or GitHub Releases Checker)**: Add a lightweight "Check for Updates…" menu item that queries GitHub Releases API and downloads the latest `.dmg` or applies delta updates automatically.

---

## 6. Suggested Implementation Priorities (Phased Roadmap)

| Phase | Focus | Key Deliverables |
| :--- | :--- | :--- |
| **Phase 1: Core Finder Parity** | System integration & daily usability | Multi-window support (`⌘⇧N`), Folder/File URL opening (`Info.plist`), "Set as Default File Manager", real async image/PDF thumbnails, Share Sheet & AirDrop, Archive Creation (`.zip`). |
| **Phase 2: Windows Explorer Power** | Speed & power-user workflows | Dual-pane split view, Breadcrumb sibling dropdown menus, `F2` smart rename & Batch Rename tool, `⇧Delete` permanent delete, Type-ahead jump & instant filter bar, "Open in VS Code / iTerm / Warp". |
| **Phase 3: Scale & Polish** | Performance & cloud/dev features | Diffable `FSEvents` updates (preserve selection/scroll), Cloud status badges & evict/download, Git status badges, Volume free-space bars, modularized ViewControllers. |
| **Phase 4: Distribution Ready** | Packaging & onboarding | First-run Full Disk Access onboarding, Settings window (`⌘,`), Universal DMG + Apple Notarization pipeline, GitHub Releases update checker. |

Date: 2026-22-10

Ideas from today

### 1. Terminal & Shell Integration
- **Embedded Terminal Drawer (`⌃` ` ` ` `)**: A toggleable bottom terminal pane automatically synced (`cd`) to the active folder tab—and updating the browser tab when you `cd` inside the terminal.
- **Quick Run / Script Execution**: Right-click any `.sh`, `.py`, `.js`, `Makefile`, or `package.json` to run scripts or npm/cargo/swift targets in an output sheet without leaving the window.

### 2. Deep Git & Version Control Workflow
- **Inline Side-by-Side Diff Viewer**: Select two files (or a modified Git file) and press `⌘D` to view a syntax-highlighted unified or split diff natively.
- **Git Quick Actions**: Stage/unstage files, discard changes, switch branches from the status bar badge, or view file commit history (`git log -p <file>`) directly from the context menu.
- **`.gitignore` Awareness & Dimming**: Optionally dim git-ignored files (`node_modules`, `.build`, `dist`, `target`) and exclude them from recursive search by default.

### 3. Developer Artifact & Disk Cleanup Tools
- **"Clean Build Artifacts" Action**: Detect heavy dev folders (`node_modules`, `.build`, `DerivedData`, `target`, `.venv`, `__pycache__`) and offer a one-click **Clean Project Artifacts** command showing reclaimable disk space.
- **Visual Treemap / Folder Size Breakdown**: An interactive disk-usage breakdown for the current folder to immediately spot what is eating disk space.

### 4. File Inspection & Data Viewers
- **Structured Preview & Formatting**: Pretty-print and tree-inspect `.json`, `.yaml`, `.plist` (including binary plists), `.sqlite`/`.db` tables, `.csv`/`.parquet`, and `.env` files in the Preview pane.
- **Hex & Binary Inspector**: Inspect binary headers, Mach-O architectures (`arm64` / `x86_64` universal slices), code-signing entitlements, and dynamic libraries (`otool -L` equivalent) inside Get Info.
- **Symlink & Hardlink Manager**: Visually show symlink targets inline (`link -> ../target`), highlight broken symlinks in red, and add a "Create Symbolic Link…" context action.

### 5. Power Navigation & Automation
- **Clipboard Paste-as-File (`⌘V` Raw Content)**: When the clipboard contains text, JSON, or a screenshot image (instead of a file), `⌘V` automatically creates `snippet.json`, `notes.txt`, or `clipboard-image.png` in the current folder.
- **Folder-Scoped Environment / Tasks (`.openexplorer.json`)**: Allow per-repo custom toolbar buttons or context actions (e.g., "Deploy", "Run Tests", "Open Simulator").
- **Port & Open-Process Inspector ("What's Locking This?")**: In Get Info or on `.lock` files/folders, show which running PIDs have open file descriptors (`lsof`) so you can kill stuck processes before deleting or unmounting.

