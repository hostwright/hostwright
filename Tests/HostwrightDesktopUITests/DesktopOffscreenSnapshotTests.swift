import AppKit
import HostwrightDesktopModel
import HostwrightDesktopUI
import SwiftUI
import XCTest

@MainActor
final class DesktopOffscreenSnapshotTests: XCTestCase {
    func testRendersRealUnavailableSurfacesWithoutActivatingAnAppWindow() throws {
        let model = DesktopOperationsModel.live(
            homeDirectory: "/private/tmp/hostwright-phase14-headless-home",
            environment: [
                "HOSTWRIGHT_APPLICATION_SUPPORT_DIR": "relative"
            ]
        )
        XCTAssertEqual(model.connectionState, DesktopConnectionState.unavailable(
            DesktopControlFailure(
                code: "discovery.invalidEndpoint",
                message: "Hostwright's local control endpoint is unavailable."
            )
        ))
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(model.logChunks.isEmpty)

        let specifications: [(
            name: String,
            size: CGSize,
            mode: SnapshotRenderMode,
            view: AnyView
        )] = [
            (
                "overview-standard",
                CGSize(width: 1_180, height: 760),
                .hostingView,
                AnyView(OperationsConsoleView().environmentObject(model))
            ),
            (
                "overview-narrow",
                CGSize(width: 680, height: 520),
                .hostingView,
                AnyView(OperationsConsoleView().environmentObject(model))
            ),
            (
                "events-standard",
                CGSize(width: 1_180, height: 760),
                .hostingView,
                AnyView(
                    OperationsConsoleView(initialSelection: "events")
                        .environmentObject(model)
                )
            ),
            (
                "logs-narrow",
                CGSize(width: 680, height: 520),
                .hostingView,
                AnyView(
                    OperationsConsoleView(initialSelection: "logs")
                        .environmentObject(model)
                )
            ),
            (
                "menu-health",
                CGSize(width: 360, height: 220),
                .imageRenderer,
                AnyView(MenuBarHealthView().environmentObject(model))
            ),
        ]

        let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".codex/phase14-ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var manifest: [[String: Any]] = []
        for specification in specifications {
            let snapshot = try OffscreenSnapshotRenderer.render(
                rootView: specification.view,
                size: specification.size,
                mode: specification.mode
            )
            XCTAssertFalse(snapshot.windowWasVisible)
            XCTAssertFalse(snapshot.windowWasKey)
            if let bitmap = NSBitmapImageRep(data: snapshot.png) {
                XCTAssertEqual(bitmap.pixelsWide, Int(specification.size.width * 2))
                XCTAssertEqual(bitmap.pixelsHigh, Int(specification.size.height * 2))
            } else {
                XCTFail("Snapshot is not a readable bitmap: \(specification.name)")
            }
            let outputURL = outputDirectory.appendingPathComponent(
                "\(specification.name).png"
            )
            try snapshot.png.write(to: outputURL, options: .atomic)
            manifest.append([
                "name": specification.name,
                "path": outputURL.path,
                "width": Int(specification.size.width),
                "height": Int(specification.size.height),
                "renderer": snapshot.renderer,
                "windowRequired": specification.mode == .hostingView,
                "windowOrderedOut": specification.mode == .hostingView
                    && !snapshot.windowWasVisible,
                "windowKey": snapshot.windowWasKey,
            ])
        }

        let manifestObject: [String: Any] = [
            "connectionState": model.connectionState.label,
            "failureCode": model.lastFailure?.code as Any,
            "emptyProjects": model.projects.isEmpty,
            "emptyEvents": model.events.isEmpty,
            "emptyLogs": model.logChunks.isEmpty,
            "renderer": "NSHostingView.bitmapImageRepForCachingDisplay plus ImageRenderer for menu health",
            "windowPolicy": "Order-out and non-key whenever a window is required; ImageRenderer uses no window.",
            "allWindowsOrderedOut": true,
            "allWindowsNonKey": true,
            "foregroundActivation": false,
            "captureBoundary": "AppKit content snapshot; native SwiftUI window toolbar and some NavigationSplitView sidebar child views require foreground scene hosting. Menu health uses ImageRenderer so its actions remain visible in the headless artifact.",
            "snapshots": manifest,
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(
            to: outputDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        XCTAssertEqual(manifest.count, specifications.count)
        XCTAssertTrue(manifest.allSatisfy { ($0["width"] as? Int ?? 0) > 0 })
        XCTAssertTrue(manifest.allSatisfy { ($0["windowKey"] as? Bool) == false })
        XCTAssertTrue(
            manifest
                .filter { ($0["windowRequired"] as? Bool) == true }
                .allSatisfy { ($0["windowOrderedOut"] as? Bool) == true }
        )
    }
}

private enum SnapshotRenderMode: String {
    case hostingView = "NSHostingView.bitmapImageRepForCachingDisplay"
    case imageRenderer = "SwiftUI.ImageRenderer"
}

private enum OffscreenSnapshotRenderer {
    @MainActor
    static func render(
        rootView: AnyView,
        size: CGSize,
        mode: SnapshotRenderMode
    ) throws -> RenderedSnapshot {
        switch mode {
        case .hostingView:
            return try renderHostingView(rootView: rootView, size: size)
        case .imageRenderer:
            return try renderImageRenderer(rootView: rootView, size: size)
        }
    }

    @MainActor
    private static func renderHostingView(
        rootView: AnyView,
        size: CGSize
    ) throws -> RenderedSnapshot {
        let hostingView = NSHostingView(
            rootView: rootView
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.orderOut(nil)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.wantsLayer = true
        hostingView.layer?.contentsScale = 2
        hostingView.needsLayout = true
        hostingView.needsDisplay = true
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.displayIfNeeded()

        guard !window.isVisible else {
            throw SnapshotError.windowBecameVisible
        }
        guard !window.isKeyWindow else {
            throw SnapshotError.windowBecameKey
        }

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw SnapshotError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }
        return RenderedSnapshot(
            png: png,
            renderer: SnapshotRenderMode.hostingView.rawValue,
            windowWasVisible: window.isVisible,
            windowWasKey: window.isKeyWindow
        )
    }

    @MainActor
    private static func renderImageRenderer(
        rootView: AnyView,
        size: CGSize
    ) throws -> RenderedSnapshot {
        let renderer = ImageRenderer(
            content: rootView
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else {
            throw SnapshotError.renderingFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }
        return RenderedSnapshot(
            png: png,
            renderer: SnapshotRenderMode.imageRenderer.rawValue,
            windowWasVisible: false,
            windowWasKey: false
        )
    }

    private enum SnapshotError: Error {
        case windowBecameVisible
        case windowBecameKey
        case bitmapUnavailable
        case renderingFailed
        case pngEncodingFailed
    }
}

private struct RenderedSnapshot {
    let png: Data
    let renderer: String
    let windowWasVisible: Bool
    let windowWasKey: Bool
}
