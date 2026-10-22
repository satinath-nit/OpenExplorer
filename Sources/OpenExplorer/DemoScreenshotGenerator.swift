import AppKit
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import OpenExplorerCore
import UniformTypeIdentifiers

@MainActor
enum DemoScreenshotEnvironment {
    static var outputDirectoryPath: String? {
        ProcessInfo.processInfo.environment["OPENEXPLORER_CAPTURE_SCREENSHOTS"]
    }

    static var isActive: Bool {
        guard let path = outputDirectoryPath else { return false }
        return !path.isEmpty
    }

    static let demoUserName = "alex"
    static let sandboxRootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("OpenExplorerDemoSandbox", isDirectory: true)

    static var workspaceURL: URL {
        sandboxRootURL.appendingPathComponent("Workspace", isDirectory: true)
    }

    static var productDesignURL: URL {
        workspaceURL.appendingPathComponent("Product Design", isDirectory: true)
    }

    static var engineeringDocsURL: URL {
        workspaceURL.appendingPathComponent("Engineering Docs", isDirectory: true)
    }

    static var releaseBuildsURL: URL {
        workspaceURL.appendingPathComponent("Release Builds", isDirectory: true)
    }

    static var quarterlyReportsURL: URL {
        workspaceURL.appendingPathComponent("Quarterly Reports", isDirectory: true)
    }

    static var marketingAssetsURL: URL {
        workspaceURL.appendingPathComponent("Marketing Assets", isDirectory: true)
    }

    static var favoriteURLs: [URL] {
        [workspaceURL, productDesignURL, engineeringDocsURL, releaseBuildsURL]
    }

    static var recentURLs: [URL] {
        [workspaceURL, productDesignURL, releaseBuildsURL, engineeringDocsURL]
    }

    static func displayPath(for url: URL) -> String {
        guard isActive else { return url.path }
        let stdPath = url.standardizedFileURL.path
        let sandboxStd = sandboxRootURL.standardizedFileURL.path
        if stdPath == sandboxStd {
            return "/Users/\(demoUserName)"
        }
        if stdPath.hasPrefix(sandboxStd + "/") {
            let suffix = String(stdPath.dropFirst(sandboxStd.count))
            return "/Users/\(demoUserName)" + suffix
        }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if stdPath == realHome {
            return "/Users/\(demoUserName)"
        }
        if stdPath.hasPrefix(realHome + "/") {
            let suffix = String(stdPath.dropFirst(realHome.count))
            return "/Users/\(demoUserName)" + suffix
        }
        return stdPath
    }
}

@MainActor
final class DemoScreenshotGenerator {
    static func prepareWorkspace() throws {
        let fm = FileManager.default
        let root = DemoScreenshotEnvironment.sandboxRootURL
        if fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        let workspace = DemoScreenshotEnvironment.workspaceURL
        let design = DemoScreenshotEnvironment.productDesignURL
        let docs = DemoScreenshotEnvironment.engineeringDocsURL
        let releases = DemoScreenshotEnvironment.releaseBuildsURL
        let reports = DemoScreenshotEnvironment.quarterlyReportsURL
        let marketing = DemoScreenshotEnvironment.marketingAssetsURL

        for dir in [workspace, design, docs, releases, reports, marketing] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Sample Package.swift so Workspace gets a Swift project badge or realistic contents
        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "AcmeCloudKit",
            platforms: [.macOS(.v13)],
            products: [
                .library(name: "AcmeCloudKit", targets: ["AcmeCloudKit"])
            ],
            targets: [
                .target(name: "AcmeCloudKit")
            ]
        )
        """
        try Data(packageSwift.utf8).write(to: design.appendingPathComponent("Package.swift"))
        try Data("{\"name\": \"marketing-site\", \"version\": \"2.4.0\"}\n".utf8).write(to: marketing.appendingPathComponent("package.json"))
        try Data("[package]\nname = \"telemetry-engine\"\nversion = \"0.4.2\"\n".utf8).write(to: docs.appendingPathComponent("Cargo.toml"))

        let releaseNotes = """
        # OpenExplorer 2.1 — Release Highlights

        OpenExplorer brings familiar Windows File Explorer navigation and power-user ergonomics to macOS with native AppKit speed.

        ## What's New in 2.1

        - **Command Palette (⌘K) & Fuzzy Go-To (⌘P)**: Instant keyboard-driven access to every command and nested file.
        - **Dual-Pane Split View (⌥⌘P)**: Side-by-side folder comparison with F5 Copy and F6 Move shortcuts.
        - **Clean Cross-Platform ZIP**: Create archives free of `.DS_Store` and `__MACOSX` metadata.
        - **Virtual Archive Inspector**: Browse and extract individual files from `.zip` and `.tar` archives.
        - **Batch Rename (⇧⌘R)**: Regex, Find & Replace, Prefix/Suffix, and sequential numbering with live preview.
        - **Git Repository Awareness**: Live branch summary and file status badges (`M`, `A`, `U`) in the file table.
        """
        let releaseNotesURL = workspace.appendingPathComponent("Release-Notes-v2.1.md")
        try Data(releaseNotes.utf8).write(to: releaseNotesURL)

        let appConfig = """
        {
          "application": "OpenExplorer",
          "version": "2.1.0",
          "theme": {
            "folderStyle": "Windows 11 Gold",
            "showGitBadges": true,
            "calculateFolderSizes": true
          },
          "shortcuts": {
            "globalOpen": "Command+E",
            "commandPalette": "Command+K",
            "fuzzyGoTo": "Command+P",
            "dualPane": "Option+Command+P"
          }
        }
        """
        let appConfigURL = workspace.appendingPathComponent("AppConfig.json")
        try Data(appConfig.utf8).write(to: appConfigURL)

        let roadmapCSV = """
        Quarter,Initiative,Owner,Status,Progress
        Q1 2026,Multi-Tab Navigation & Breadcrumbs,Core UI,Completed,100%
        Q2 2026,Spotlight Recursive Search & Quick Look,Search Team,Completed,100%
        Q3 2026,Dual-Pane Commander & Batch Rename,Power Tools,Completed,100%
        Q4 2026,Virtual Archive Inspector & Checksums,Storage Engine,In Review,95%
        """
        let roadmapURL = workspace.appendingPathComponent("Roadmap-2026.csv")
        try Data(roadmapCSV.utf8).write(to: roadmapURL)

        let buildScript = """
        #!/bin/zsh
        set -euo pipefail
        echo "Building universal release bundle..."
        swift build -c release
        """
        let buildScriptURL = workspace.appendingPathComponent("build-release.sh")
        try Data(buildScript.utf8).write(to: buildScriptURL)

        let envExampleURL = workspace.appendingPathComponent(".env.example")
        try Data("APP_ENV=production\nLOG_LEVEL=info\nENABLE_METRICS=false\n".utf8).write(to: envExampleURL)

        // Generate crisp sample PDF and PNG artwork
        let pdfURL = workspace.appendingPathComponent("System-Architecture.pdf")
        try writeSamplePDF(to: pdfURL)

        let dashboardPNG = workspace.appendingPathComponent("Dashboard-Preview.png")
        try writeSampleIllustration(
            to: dashboardPNG,
            size: NSSize(width: 1200, height: 800),
            title: "Analytics Dashboard",
            subtitle: "Q4 Metrics · Active Sessions · Throughput",
            primaryColor: NSColor(calibratedRed: 0.14, green: 0.46, blue: 0.92, alpha: 1.0),
            accentColor: NSColor(calibratedRed: 0.18, green: 0.78, blue: 0.62, alpha: 1.0)
        )

        let designCoverPNG = workspace.appendingPathComponent("Design-System-Cover.png")
        try writeSampleIllustration(
            to: designCoverPNG,
            size: NSSize(width: 1200, height: 800),
            title: "Design System v3",
            subtitle: "Components · Color Tokens · Icon Grid",
            primaryColor: NSColor(calibratedRed: 0.48, green: 0.28, blue: 0.88, alpha: 1.0),
            accentColor: NSColor(calibratedRed: 0.96, green: 0.54, blue: 0.24, alpha: 1.0)
        )

        // Populate Product Design folder (also used for Batch Rename & Icon views)
        for index in 1...4 {
            let iconDraft = design.appendingPathComponent(String(format: "icon-draft-0%d.png", index))
            try writeSampleIllustration(
                to: iconDraft,
                size: NSSize(width: 600, height: 600),
                title: "Icon 0\(index)",
                subtitle: "Vector Asset",
                primaryColor: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.90, alpha: 1.0),
                accentColor: NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.18, alpha: 1.0)
            )
        }
        try Data("# Typography Scale\n\nHeading 1: 28pt Semibold\nBody: 13pt Regular\n".utf8)
            .write(to: design.appendingPathComponent("Typography-Scale.md"))
        try Data("{\n  \"accent\": \"#0A84FF\",\n  \"folderGold\": \"#F5B623\"\n}\n".utf8)
            .write(to: design.appendingPathComponent("Color-Tokens.json"))

        // Populate Engineering Docs & Quarterly Reports
        try Data("# Storage Engine Specification\n\nZero-dependency archive inspection and atomic file operations.\n".utf8)
            .write(to: docs.appendingPathComponent("Storage-Engine-RFC.md"))
        try Data("# Keyboard Shortcuts Reference\n\nStandard macOS and Windows Explorer shortcuts.\n".utf8)
            .write(to: docs.appendingPathComponent("Shortcuts-Guide.md"))
        try Data("Region,Revenue,Growth\nNorth America,4200000,18.4%\nEurope,2850000,15.2%\nAPAC,1940000,22.1%\n".utf8)
            .write(to: reports.appendingPathComponent("Q4-Financial-Summary.csv"))
        try writeSamplePDF(to: reports.appendingPathComponent("Executive-Briefing-2026.pdf"))

        // Create a real ZIP archive in Workspace and Release Builds
        let zipURL = try ZipExtractor.compress(
            [releaseNotesURL, appConfigURL, roadmapURL, design],
            in: workspace,
            mode: .cleanCrossPlatform
        )
        let renamedZipURL = workspace.appendingPathComponent("Workspace-Bundle.zip")
        if zipURL != renamedZipURL {
            if fm.fileExists(atPath: renamedZipURL.path) {
                try? fm.removeItem(at: renamedZipURL)
            }
            try fm.moveItem(at: zipURL, to: renamedZipURL)
        }

        // Populate Release Builds folder for Dual-Pane secondary view
        try fm.copyItem(at: renamedZipURL, to: releases.appendingPathComponent("Workspace-Bundle-2.1.0.zip"))
        try Data("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  Workspace-Bundle-2.1.0.zip\n".utf8)
            .write(to: releases.appendingPathComponent("Checksums-SHA256.txt"))
        try Data("{\n  \"version\": \"2.1.0\",\n  \"channel\": \"stable\",\n  \"arch\": \"arm64\"\n}\n".utf8)
            .write(to: releases.appendingPathComponent("Release-Manifest.json"))
        try writeSamplePDF(to: releases.appendingPathComponent("Install-Guide.pdf"))

        // Apply Finder tags so color dots and tag filtering show up
        try? FinderTagManager.setTags(["Blue"], for: pdfURL)
        try? FinderTagManager.setTags(["Green"], for: dashboardPNG)
        try? FinderTagManager.setTags(["Orange"], for: releaseNotesURL)
        try? FinderTagManager.setTags(["Purple"], for: designCoverPNG)
        try? FinderTagManager.setTags(["Blue"], for: design)
        try? FinderTagManager.setTags(["Green"], for: releases)

        // Initialize a sample Git repo inside Workspace so branch & status badges (M / A / U) render
        runGit(["init", "-b", "main"], in: workspace)
        runGit(["config", "user.name", "Alex Rivera"], in: workspace)
        runGit(["config", "user.email", "alex@example.com"], in: workspace)
        runGit(["add", "Release-Notes-v2.1.md", "System-Architecture.pdf", "build-release.sh"], in: workspace)
        runGit(["commit", "-m", "Initial workspace commit"], in: workspace)
        // Modify Release-Notes-v2.1.md so it shows 'M'
        let updatedNotes = releaseNotes + "\n- **SHA-256 & MD5 Checksums**: Instant cryptographic verification in Get Info.\n"
        try Data(updatedNotes.utf8).write(to: releaseNotesURL)
        // Stage AppConfig.json so it shows 'A'
        runGit(["add", "AppConfig.json"], in: workspace)
        // Leave Roadmap-2026.csv untracked so it shows 'U'
    }

    private static func runGit(_ args: [String], in directory: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = directory
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func writeSampleIllustration(
        to url: URL,
        size: NSSize,
        title: String,
        subtitle: String,
        primaryColor: NSColor,
        accentColor: NSColor
    ) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let bounds = NSRect(origin: .zero, size: size)
        let gradient = NSGradient(starting: primaryColor, ending: primaryColor.blended(withFraction: 0.45, of: .black) ?? primaryColor)
        gradient?.draw(in: bounds, angle: -35)

        // Decorative card and bar chart shapes
        let cardRect = bounds.insetBy(dx: size.width * 0.08, dy: size.height * 0.12)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 24, yRadius: 24)
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
        cardPath.fill()

        let barCount = 5
        let barAreaWidth = cardRect.width * 0.72
        let startX = cardRect.minX + (cardRect.width - barAreaWidth) / 2
        let barHeights: [CGFloat] = [0.35, 0.55, 0.48, 0.78, 0.90]
        for idx in 0..<barCount {
            let bw = barAreaWidth / CGFloat(barCount * 2 - 1)
            let bx = startX + CGFloat(idx * 2) * bw
            let bh = cardRect.height * 0.42 * barHeights[idx]
            let by = cardRect.minY + cardRect.height * 0.12
            let barPath = NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh), xRadius: 8, yRadius: 8)
            (idx == barCount - 1 ? accentColor : NSColor(calibratedWhite: 1.0, alpha: 0.75)).setFill()
            barPath.fill()
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(22, size.height * 0.055), weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(14, size.height * 0.028), weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 0.9)
        ]
        NSString(string: title).draw(at: NSPoint(x: cardRect.minX + 36, y: cardRect.maxY - 88), withAttributes: titleAttrs)
        NSString(string: subtitle).draw(at: NSPoint(x: cardRect.minX + 36, y: cardRect.maxY - 126), withAttributes: subAttrs)

        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: url, options: .atomic)
        }
    }

    private static func writeSamplePDF(to url: URL) throws {
        let pdfView = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        let data = pdfView.dataWithPDF(inside: pdfView.bounds)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Rendering Helpers

    static func renderViewToPNG(
        _ view: NSView,
        appearance: NSAppearance? = nil,
        drawTrafficLightsAt topLeftOffset: NSPoint? = nil,
        titleBarTitle: String? = nil,
        overlayView: NSView? = nil,
        overlayOriginInBase: NSPoint? = nil,
        dimBaseUnderOverlay: Bool = false,
        to outputURL: URL
    ) throws {
        let savedAppearance = view.window?.appearance
        if let appearance {
            view.window?.appearance = appearance
            view.appearance = appearance
        }
        defer {
            view.window?.appearance = savedAppearance
            view.appearance = nil
        }

        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let baseRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: baseRep)

        let titleBarHeight: CGFloat = (titleBarTitle != nil && overlayView == nil) ? 38 : 0
        let totalSize = NSSize(width: view.bounds.width, height: view.bounds.height + titleBarHeight)
        let scale: CGFloat = 2.0
        guard let finalRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(totalSize.width * scale),
            pixelsHigh: Int(totalSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        finalRep.size = totalSize

        let isDark = (appearance ?? view.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: finalRep)

        let fullRect = NSRect(origin: .zero, size: totalSize)
        let clipPath = NSBezierPath(roundedRect: fullRect, xRadius: 11, yRadius: 11)
        clipPath.addClip()

        let baseImage = NSImage(size: view.bounds.size)
        baseImage.addRepresentation(baseRep)
        baseImage.draw(in: NSRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height))

        if let titleBarTitle, overlayView == nil {
            let headerRect = NSRect(x: 0, y: view.bounds.height, width: totalSize.width, height: titleBarHeight)
            (isDark ? NSColor(calibratedWhite: 0.18, alpha: 1.0) : NSColor(calibratedWhite: 0.95, alpha: 1.0)).setFill()
            headerRect.fill()

            let sepRect = NSRect(x: 0, y: view.bounds.height, width: totalSize.width, height: 1)
            (isDark ? NSColor(calibratedWhite: 1.0, alpha: 0.12) : NSColor(calibratedWhite: 0.0, alpha: 0.12)).setFill()
            sepRect.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: isDark ? NSColor.white : NSColor(calibratedWhite: 0.15, alpha: 1.0)
            ]
            let titleStr = NSString(string: titleBarTitle)
            let strSize = titleStr.size(withAttributes: attrs)
            titleStr.draw(
                at: NSPoint(x: (totalSize.width - strSize.width) / 2, y: view.bounds.height + (titleBarHeight - strSize.height) / 2),
                withAttributes: attrs
            )
            drawTrafficLights(at: NSPoint(x: 18, y: totalSize.height - 19))
        } else if let topLeftOffset {
            drawTrafficLights(at: NSPoint(x: topLeftOffset.x, y: totalSize.height - topLeftOffset.y))
        }

        if let overlayView {
            if let appearance {
                overlayView.window?.appearance = appearance
                overlayView.appearance = appearance
            }
            overlayView.layoutSubtreeIfNeeded()
            overlayView.displayIfNeeded()
            if dimBaseUnderOverlay {
                NSColor(calibratedWhite: 0.0, alpha: 0.24).setFill()
                fullRect.fill()
            }
            if let overRep = overlayView.bitmapImageRepForCachingDisplay(in: overlayView.bounds) {
                overlayView.cacheDisplay(in: overlayView.bounds, to: overRep)
                let overHeaderH: CGFloat = titleBarTitle != nil ? 34 : 0
                let totalOverSize = NSSize(width: overlayView.bounds.width, height: overlayView.bounds.height + overHeaderH)
                let origin = overlayOriginInBase ?? NSPoint(
                    x: round((totalSize.width - totalOverSize.width) / 2),
                    y: round((totalSize.height - totalOverSize.height) / 2)
                )
                let overRect = NSRect(origin: origin, size: totalOverSize)

                // Subtle drop shadow behind floating panel/sheet
                let shadowRect = overRect.insetBy(dx: -5, dy: -7).offsetBy(dx: 0, dy: -4)
                let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: 14, yRadius: 14)
                NSColor(calibratedWhite: 0.0, alpha: 0.30).setFill()
                shadowPath.fill()

                NSGraphicsContext.saveGraphicsState()
                let overClip = NSBezierPath(roundedRect: overRect, xRadius: 11, yRadius: 11)
                overClip.addClip()
                (isDark ? NSColor(calibratedWhite: 0.14, alpha: 1.0) : NSColor.white).setFill()
                overRect.fill()

                let overImg = NSImage(size: overlayView.bounds.size)
                overImg.addRepresentation(overRep)
                overImg.draw(in: NSRect(x: overRect.minX, y: overRect.minY, width: overlayView.bounds.width, height: overlayView.bounds.height))

                if let titleBarTitle {
                    let hRect = NSRect(x: overRect.minX, y: overRect.minY + overlayView.bounds.height, width: overRect.width, height: overHeaderH)
                    (isDark ? NSColor(calibratedWhite: 0.19, alpha: 1.0) : NSColor(calibratedWhite: 0.95, alpha: 1.0)).setFill()
                    hRect.fill()
                    let sRect = NSRect(x: overRect.minX, y: overRect.minY + overlayView.bounds.height, width: overRect.width, height: 1)
                    (isDark ? NSColor(calibratedWhite: 1.0, alpha: 0.12) : NSColor(calibratedWhite: 0.0, alpha: 0.12)).setFill()
                    sRect.fill()
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                        .foregroundColor: isDark ? NSColor.white : NSColor(calibratedWhite: 0.15, alpha: 1.0)
                    ]
                    let titleStr = NSString(string: titleBarTitle)
                    let strSize = titleStr.size(withAttributes: attrs)
                    titleStr.draw(
                        at: NSPoint(x: overRect.minX + (overRect.width - strSize.width) / 2, y: hRect.minY + (overHeaderH - strSize.height) / 2),
                        withAttributes: attrs
                    )
                    drawTrafficLights(at: NSPoint(x: overRect.minX + 18, y: overRect.maxY - 17))
                }

                overClip.lineWidth = 1.5
                (isDark ? NSColor(calibratedWhite: 1.0, alpha: 0.22) : NSColor(calibratedWhite: 0.0, alpha: 0.18)).setStroke()
                overClip.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // Outer window border
        let borderPath = NSBezierPath(roundedRect: fullRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        borderPath.lineWidth = 1
        (isDark ? NSColor(calibratedWhite: 1.0, alpha: 0.18) : NSColor(calibratedWhite: 0.0, alpha: 0.15)).setStroke()
        borderPath.stroke()

        NSGraphicsContext.restoreGraphicsState()

        if let pngData = finalRep.representation(using: .png, properties: [:]) {
            try pngData.write(to: outputURL, options: .atomic)
        }
    }

    private static func drawTrafficLights(at centerFirst: NSPoint) {
        let colors: [NSColor] = [
            NSColor(calibratedRed: 1.0, green: 0.373, blue: 0.341, alpha: 1.0),
            NSColor(calibratedRed: 0.996, green: 0.737, blue: 0.180, alpha: 1.0),
            NSColor(calibratedRed: 0.157, green: 0.784, blue: 0.251, alpha: 1.0)
        ]
        let radius: CGFloat = 6.0
        let spacing: CGFloat = 20.0
        for (i, color) in colors.enumerated() {
            let cx = centerFirst.x + CGFloat(i) * spacing
            let cy = centerFirst.y
            let rect = NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            let circle = NSBezierPath(ovalIn: rect)
            color.setFill()
            circle.fill()
            NSColor(calibratedWhite: 0.0, alpha: 0.12).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
        }
    }

    // MARK: - Animated Demo Showcase (GIF & MP4)

    static func generateAnimatedShowcase(
        frames: [(url: URL, title: String, subtitle: String)],
        outputDirectory: URL
    ) throws {
        guard !frames.isEmpty else { return }

        let canvasSize = NSSize(width: 1280, height: 800)
        var renderedFrames: [(cgImage: CGImage, bitmap: NSBitmapImageRep)] = []

        for (index, item) in frames.enumerated() {
            guard let sourceImage = NSImage(contentsOf: item.url),
                  let rep = makeAnnotatedShowcaseFrame(
                    sourceImage: sourceImage,
                    stepIndex: index + 1,
                    totalSteps: frames.count,
                    title: item.title,
                    subtitle: item.subtitle,
                    canvasSize: canvasSize
                  ),
                  let cgImage = rep.cgImage else { continue }
            renderedFrames.append((cgImage: cgImage, bitmap: rep))
        }

        guard !renderedFrames.isEmpty else { return }

        // 1. Write Animated GIF
        let gifURL = outputDirectory.appendingPathComponent("OpenExplorer-Demo.gif")
        if let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            UTType.gif.identifier as CFString,
            renderedFrames.count,
            nil
        ) {
            let fileProps: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFLoopCount as String: 0
                ]
            ]
            CGImageDestinationSetProperties(destination, fileProps as CFDictionary)

            let frameProps: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: 1.8,
                    kCGImagePropertyGIFUnclampedDelayTime as String: 1.8
                ]
            ]
            for frame in renderedFrames {
                CGImageDestinationAddImage(destination, frame.cgImage, frameProps as CFDictionary)
            }
            CGImageDestinationFinalize(destination)
        }

        // 2. Write H.264 MP4 Video
        let mp4URL = outputDirectory.appendingPathComponent("OpenExplorer-Demo.mp4")
        try writeMP4Video(frames: renderedFrames.map(\.cgImage), size: canvasSize, to: mp4URL)
    }

    private static func makeAnnotatedShowcaseFrame(
        sourceImage: NSImage,
        stepIndex: Int,
        totalSteps: Int,
        title: String,
        subtitle: String,
        canvasSize: NSSize
    ) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let fullRect = NSRect(origin: .zero, size: canvasSize)
        let bgGradient = NSGradient(
            starting: NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.18, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.28, alpha: 1.0)
        )
        bgGradient?.draw(in: fullRect, angle: -45)

        let bannerHeight: CGFloat = 68
        let paddingX: CGFloat = 24
        let paddingTop: CGFloat = 18
        let paddingBottom: CGFloat = 12
        let availableWidth = canvasSize.width - paddingX * 2
        let availableHeight = canvasSize.height - bannerHeight - paddingTop - paddingBottom

        let srcSize = sourceImage.size
        let scale = min(availableWidth / max(srcSize.width, 1), availableHeight / max(srcSize.height, 1))
        let drawW = round(srcSize.width * scale)
        let drawH = round(srcSize.height * scale)
        let drawX = round((canvasSize.width - drawW) / 2)
        let drawY = round(bannerHeight + paddingBottom + (availableHeight - drawH) / 2)
        let targetRect = NSRect(x: drawX, y: drawY, width: drawW, height: drawH)

        let shadowRect = targetRect.insetBy(dx: -6, dy: -8).offsetBy(dx: 0, dy: -4)
        let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.0, alpha: 0.38).setFill()
        shadowPath.fill()

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: targetRect, xRadius: 10, yRadius: 10)
        clip.addClip()
        sourceImage.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // Bottom caption bar
        let bannerRect = NSRect(x: 24, y: 12, width: canvasSize.width - 48, height: 52)
        let bannerPath = NSBezierPath(roundedRect: bannerRect, xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 0.92).setFill()
        bannerPath.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
        bannerPath.lineWidth = 1
        bannerPath.stroke()

        // Step pill
        let pillRect = NSRect(x: bannerRect.minX + 14, y: bannerRect.minY + 13, width: 68, height: 26)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.setFill()
        pillPath.fill()

        let pillText = NSString(format: "%02d / %02d", stepIndex, totalSteps)
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let pillTextSize = pillText.size(withAttributes: pillAttrs)
        pillText.draw(
            at: NSPoint(
                x: pillRect.minX + (pillRect.width - pillTextSize.width) / 2,
                y: pillRect.minY + (pillRect.height - pillTextSize.height) / 2
            ),
            withAttributes: pillAttrs
        )

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1.0)
        ]
        let titleStr = NSString(string: title)
        let subStr = NSString(string: "  —  " + subtitle)
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        let textY = bannerRect.minY + (bannerRect.height - titleSize.height) / 2
        let textX = pillRect.maxX + 14
        titleStr.draw(at: NSPoint(x: textX, y: textY), withAttributes: titleAttrs)
        subStr.draw(at: NSPoint(x: textX + titleSize.width, y: textY - 1), withAttributes: subAttrs)

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func writeMP4Video(frames: [CGImage], size: NSSize, to outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = Int(size.width)
        let height = Int(size.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let sourceBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceBufferAttributes
        )
        guard writer.canAdd(input) else { return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let framesPerSlide: Int64 = 54 // 1.8 seconds per feature at 30fps

        for (index, cgImage) in frames.enumerated() {
            guard let pixelBufferPool = adaptor.pixelBufferPool else { continue }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { continue }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let startFrame = Int64(index) * framesPerSlide
            let endFrame = startFrame + framesPerSlide - 1
            for tick in [startFrame, endFrame] {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                let time = CMTime(value: tick, timescale: fps)
                adaptor.append(pixelBuffer, withPresentationTime: time)
            }
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting {
            sema.signal()
        }
        sema.wait()
    }
}
