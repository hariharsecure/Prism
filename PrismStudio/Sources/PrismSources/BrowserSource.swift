#if os(macOS)
import AppKit // macOS-only: WKWebView.takeSnapshot returns NSImage; browser source is inherently AppKit-adjacent.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore
import WebKit

/// A browser source (DESIGN.md §2.1 — "Browser source (WKWebView → layer
/// capture)") for the alerts/overlays ecosystem (StreamElements, etc.).
///
/// Hosts an offscreen `WKWebView`, renders it to IOSurface-backed BGRA frames
/// and emits at the configured fps.
///
/// ## Main-thread constraint (important)
/// `WKWebView` is **main-thread-only**. Everything that touches the web view —
/// creation, `load`, `takeSnapshot`, `layer.render` — is hopped to the main
/// queue here. The `VideoSource` timer runs on the source's own serial queue;
/// each tick requests a snapshot on main, and the finished frame is drawn and
/// delivered back on the source queue (so `onFrame` fires on the source queue,
/// like every other source). **The host process MUST have a running main
/// run loop** (a normal AppKit app does; a bare CLI must pump `RunLoop.main`).
///
/// ## fps ceiling
/// `WKWebView.takeSnapshot` is a full compositing snapshot; it is not a 60 fps
/// path. Treat ~15 fps as a practical ceiling for `.takeSnapshot`. A tick is
/// skipped if the previous snapshot has not completed, so the effective rate
/// self-limits to what WebKit can deliver rather than piling up requests.
/// `.layerRender` (CALayer → CGContext) is cheaper but captures only the
/// rendered layer tree.
public final class BrowserSource: TimedVideoSource {
    /// What to load.
    public enum Content: Sendable {
        case url(URL)
        case html(String, baseURL: URL?)
    }

    /// How a frame is grabbed from the web view.
    public enum SnapshotMethod: Sendable {
        /// `WKWebView.takeSnapshot` — correct & simplest; ~15 fps ceiling.
        case takeSnapshot
        /// `CALayer.render(in:)` into the pixel buffer — cheaper, layer-only.
        case layerRender
    }

    private let log = EngineLog.logger("sources.browser")
    private let canvas: SourceRenderCanvas
    private let content: Content
    private let method: SnapshotMethod
    private let canvasSize: CanvasSize

    // Main-thread-only state.
    private var webView: WKWebView?
    private let navDelegate = NavigationDelegate()

    // Source-queue-only guard against overlapping in-flight snapshots.
    private var inflight = false

    /// - Parameters:
    ///   - content: URL or HTML string to load.
    ///   - canvasSize: output dimensions (also the web view size).
    ///   - method: snapshot mechanism (default `.takeSnapshot`).
    ///   - fps: emit rate (default 15 — see the fps-ceiling note).
    public init(id: SourceID = SourceID("browser.\(UUID().uuidString)"),
                content: Content,
                canvasSize: CanvasSize = .hd,
                method: SnapshotMethod = .takeSnapshot,
                fps: Double = 15) throws {
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        self.content = content
        self.method = method
        self.canvasSize = canvasSize
        super.init(id: id, fps: fps, label: "studio.prism.source.browser")
    }

    override func willStart() throws {
        var setupError: Error?
        let make = { [self] in
            do { try setupWebViewOnMain() } catch { setupError = error }
        }
        if Thread.isMainThread { make() } else { DispatchQueue.main.sync(execute: make) }
        if let setupError { throw setupError }
    }

    override func willStop() {
        let teardown = { [self] in
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
        }
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.sync(execute: teardown) }
    }

    /// MAIN THREAD ONLY.
    private func setupWebViewOnMain() throws {
        let config = WKWebViewConfiguration()
        let frame = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        let view = WKWebView(frame: frame, configuration: config)
        view.navigationDelegate = navDelegate
        // Ensure a backing layer exists for the layer-render path.
        view.wantsLayer = true
        switch content {
        case .url(let url):
            view.load(URLRequest(url: url))
        case .html(let html, let baseURL):
            view.loadHTMLString(html, baseURL: baseURL)
        }
        self.webView = view
    }

    override func tick() {
        guard !inflight else { return } // skip; WebKit is slower than the timer
        inflight = true
        // Capture THIS run's generation at the moment the snapshot is requested.
        // The WebKit completion hops back onto `queue` after `tick()` returns, so
        // the delivery-generation context is gone by then; carrying the captured
        // token lets `emitDeferred` drop a snapshot that completes after a
        // stop/restart instead of leaking run-1 pixels into run 2.
        let token = currentRunToken
        switch method {
        case .takeSnapshot: requestSnapshot(token: token)
        case .layerRender:  requestLayerRender(token: token)
        }
    }

    // MARK: - takeSnapshot path

    private func requestSnapshot(token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.webView else { self?.finish(nil, token: token); return }
            let cfg = WKSnapshotConfiguration()
            cfg.afterScreenUpdates = true
            view.takeSnapshot(with: cfg) { [weak self] image, error in
                // Completion is on main.
                guard let self else { return }
                if let error {
                    self.log.error("takeSnapshot error: \(error.localizedDescription, privacy: .public)")
                    self.finish(nil, token: token)
                    return
                }
                let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                self.finish(cg, token: token)
            }
        }
    }

    /// Draw a captured CGImage into an IOSurface buffer on the source queue and
    /// emit — gated on the run token captured when the snapshot was requested.
    private func finish(_ cg: CGImage?, token: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.inflight = false }
            guard let cg else { return }
            do {
                let buffer = try self.canvas.render { ctx in
                    // Upright: CGImage top → high y → memory top.
                    ctx.draw(cg, in: self.canvas.canvasRect)
                }
                self.emitDeferred(buffer, capturedToken: token)
            } catch {
                self.log.error("browser frame draw failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - layerRender path

    private func requestLayerRender(token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.webView, let layer = view.layer else {
                self?.markDone(); return
            }
            var rendered: CVPixelBuffer?
            do {
                rendered = try self.canvas.render { ctx in
                    // CALayer is top-left origin; flip the CTM so it lands upright.
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: CGFloat(self.canvas.height))
                    ctx.scaleBy(x: 1, y: -1)
                    layer.render(in: ctx)
                    ctx.restoreGState()
                }
            } catch {
                self.log.error("layer render failed: \(String(describing: error), privacy: .public)")
            }
            let buffer = rendered
            self.queue.async {
                defer { self.inflight = false }
                if let buffer { self.emitDeferred(buffer, capturedToken: token) }
            }
        }
    }

    private func markDone() {
        queue.async { [weak self] in self?.inflight = false }
    }

    // MARK: - Navigation delegate

    /// Tracks first-load completion (useful for tests / readiness UI).
    final class NavigationDelegate: NSObject, WKNavigationDelegate {
        private let stateLock = OSAllocatedUnfairLock(initialState: false)
        var isLoaded: Bool { stateLock.withLock { $0 } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            stateLock.withLock { $0 = true }
        }
    }

    /// Whether the initial navigation has finished (thread-safe).
    public var isLoaded: Bool { navDelegate.isLoaded }
}
#endif
