import Metal
import NottyCore
import QuartzCore
import Synchronization
import UIKit

/// The frost that clears down a page as it is added, from its top edge to its bottom, drawn with
/// Metal as `PageUnfoldTimeline` and NotebookPageUnfold.metal describe.
///
/// The frost draws in a layer of its own, which `play` places over the new page inside the
/// paper's content layer, beneath the transparent canvas: ink written meanwhile shows above the
/// frost, and the frost scrolls and zooms with the page without being moved. It never takes
/// touches and never changes scrolling or insets, so writing and scrolling carry on while it
/// clears, and the main thread only encodes one draw per display frame.
///
/// To add a page with the frost:
/// 1. Grow the paper to include the new page.
/// 2. Unless `isVisible(page:in:)`, stop there: a page the user cannot see is simply there.
/// 3. When `needsSource`, take a picture of the new page as it will look, such as
///    `snapshot(of:rect:screenPixelsPerPoint:)` of the paper's content layer.
/// 4. In the same run-loop turn, call `play(page:source:in:above:completion:)`, so the frost
///    appears in the frame that shows the page.
///
/// `finish()` cuts to the end, for instance when the canvas is torn down.
@MainActor
final class NotebookPageUnfold {
    /// Under Reduce Motion the page's arrival is a fade to the page from the near-black it is
    /// added over, instead of the frost's sweep down it, as the header and tools only fade there.
    /// The new page still reads as new, without movement.
    static let reducedMotionFadeDuration: CFTimeInterval = 0.15
    /// Frames the GPU may hold at once. Past this a display frame is skipped rather than wait for a
    /// drawable on the main thread, so a busy GPU shows up as a slow frame.
    private static let framesInFlightLimit = 2
    /// The drawable's format: like WebGL's, the blur mixes gamma-encoded sRGB values.
    private nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// The fragment shader's uniforms, laid out as `PageUnfoldUniforms` in NotebookPageUnfold.metal.
    struct Uniforms {
        var glass: SIMD4<Float>
        var size: SIMD2<Float>
        var pixelsPerPoint: SIMD2<Float>
        var tilt: Float
        var eyeDistance: Float
        var blurSpread: Float
        var darkening: Float
        var maximumTaps: Float
        var distanceScale: Float
    }

    private struct Playback {
        enum Mode {
            /// The frost clears over a picture of the page.
            case frost(PageUnfoldTimeline, source: MTLTexture)
            /// The layer fades out over `duration` from `opacity`, starting at `start`.
            case fade(opacity: Float, duration: CFTimeInterval, start: CFTimeInterval)
        }

        var mode: Mode
        let pageSize: CGSize
        let start: CFTimeInterval
        var lastFrame: CFTimeInterval
        let completion: @MainActor () -> Void
    }

    let device: MTLDevice?
    /// The frost's layer while one plays.
    private(set) var layer: NotebookPageUnfoldLayer?
    /// Frost frames drawn since the latest `play`.
    private(set) var framesDrawn = 0
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var preparation: Task<Void, Never>?
    private let readsReducedMotion: @MainActor () -> Bool
    private let accounting = FrameAccounting()
    private var playback: Playback?
    private var displayLink: CADisplayLink?

    var isPlaying: Bool { playback != nil }
    /// When the frost now playing will have cleared, unless it is cut short; nil without one.
    var clearingEnd: CFTimeInterval? {
        guard let playback, case .frost = playback.mode else { return nil }
        return playback.start + PageUnfoldTimeline.clearingDuration / 1_000
    }
    /// Whether Reduce Motion is on, read afresh: a page then fades in where it lies, and nothing
    /// scrolls to show it.
    var prefersReducedMotion: Bool { readsReducedMotion() }
    /// Whether the shaders are ready to draw the frost; until they are, a page simply appears.
    var isReady: Bool { pipeline != nil }
    /// Whether a `play` now would draw the frost over its source. Reduce Motion's fade, and a
    /// play that shows nothing, need none, so the caller can skip drawing one.
    var needsSource: Bool { device != nil && isReady && !prefersReducedMotion }

    /// - Parameters:
    ///   - device: the GPU to draw with; nil where there is no Metal, and then nothing ever plays.
    ///   - prefersReducedMotion: read at each `play`.
    init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        prefersReducedMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) {
        self.device = device
        readsReducedMotion = prefersReducedMotion
        queue = device?.makeCommandQueue()
        guard let device else { return }
        // The shaders compile off the main thread, so creating the frost never holds up a notebook.
        preparation = Task { [weak self] in
            let pipeline = await Self.makePipeline(device: device)
            self?.pipeline = pipeline
        }
    }

    isolated deinit {
        displayLink?.invalidate()
        layer?.removeFromSuperlayer()
    }

    /// Waits for the shaders and reports whether the frost can play.
    func ready() async -> Bool {
        await preparation?.value
        return isReady
    }

    // MARK: - Playing

    /// Plays the frost over `page`, the new page's rectangle in `host`'s coordinates, showing
    /// `source`, the page as it will look, until the live page takes over. The frost's layer goes
    /// into `host` above `sibling`, or on top without one, and leaves at the end.
    ///
    /// A play while another runs finishes that one first. `completion` runs once, whenever the
    /// frost ends, `finish()` included.
    ///
    /// - Returns: false when nothing plays: without Metal, before the shaders are ready, without a
    ///   source for the frost or for an empty page. `completion` has then already run.
    @discardableResult
    func play(
        page: CGRect, source: CGImage?, in host: CALayer, above sibling: CALayer? = nil,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        finish()
        framesDrawn = 0
        guard let device, let queue, !page.isEmpty, !page.isInfinite else {
            completion()
            return false
        }
        let start = CACurrentMediaTime()
        if prefersReducedMotion {
            let layer = install(page: page, in: host, above: sibling)
            withoutActions { layer.backgroundColor = NotebookTheme.backdropBelowPaper.cgColor }
            let fade = Playback.Mode.fade(opacity: 1, duration: Self.reducedMotionFadeDuration, start: start)
            playback = Playback(mode: fade, pageSize: page.size, start: start, lastFrame: start, completion: completion)
            startDisplayLink()
            return true
        }
        guard pipeline != nil, let source, let commands = queue.makeCommandBuffer(),
              let texture = makeTexture(source, commands: commands) else {
            completion()
            return false
        }
        let layer = install(page: page, in: host, above: sibling)
        layer.device = device
        layer.pixelFormat = Self.pixelFormat
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.drawableSize = CGSize(width: source.width, height: source.height)
        // The first frame shows with the transaction that adds the page, so the page never shows
        // unfrosted for a frame; later frames present as soon as they are drawn.
        layer.presentsWithTransaction = true
        _ = accounting.takeGPUTime()
        var timeline = PageUnfoldTimeline(pageHeight: Double(page.height))
        let frame = timeline.advance(elapsed: 0, interval: 0)
        playback = Playback(
            mode: .frost(timeline, source: texture), pageSize: page.size, start: start, lastFrame: start,
            completion: completion
        )
        if accounting.reserve(limit: Self.framesInFlightLimit) {
            draw(frame, source: texture, pageSize: page.size, commands: commands)
        } else {
            commands.commit()
        }
        layer.presentsWithTransaction = false
        startDisplayLink()
        return true
    }

    /// Ends the frost at once: the live page shows and the completion runs. Does nothing when no
    /// frost plays.
    func finish() {
        displayLink?.invalidate()
        displayLink = nil
        if let layer {
            withoutActions { layer.removeFromSuperlayer() }
        }
        layer = nil
        guard let playback else { return }
        self.playback = nil
        playback.completion()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard var playback else {
            link.invalidate()
            return
        }
        let now = link.targetTimestamp
        switch playback.mode {
        case let .fade(opacity, duration, start):
            let progress = min(max((now - start) / duration, 0), 1)
            setOpacity(opacity * Float(1 - progress))
            if progress >= 1 { finish() }
        case .frost(var timeline, let source):
            // With the GPU behind, this display frame passes undrawn and its time counts toward the next.
            guard accounting.reserve(limit: Self.framesInFlightLimit) else { return }
            let frame = timeline.advance(
                elapsed: (now - playback.start) * 1_000, interval: (now - playback.lastFrame) * 1_000,
                gpuTime: accounting.takeGPUTime()
            )
            playback.lastFrame = now
            switch frame.phase {
            case .clearing:
                playback.mode = .frost(timeline, source: source)
                self.playback = playback
                guard let commands = queue?.makeCommandBuffer() else {
                    accounting.release()
                    return
                }
                draw(frame, source: source, pageSize: playback.pageSize, commands: commands)
            case .finished:
                accounting.release()
                finish()
            case .abandoned:
                accounting.release()
                let opacity = layer?.opacity ?? 0
                let duration = PageUnfoldTimeline.skipDuration / 1_000
                playback.mode = .fade(opacity: opacity, duration: duration, start: now)
                self.playback = playback
            }
        }
    }

    /// Draws `frame` into the layer's next drawable, in a frame slot already reserved, and commits.
    private func draw(
        _ frame: PageUnfoldTimeline.Frame, source: MTLTexture, pageSize: CGSize, commands: MTLCommandBuffer
    ) {
        guard let layer, case let .frost(timeline, _) = playback?.mode, let drawable = layer.nextDrawable() else {
            accounting.release()
            commands.commit()
            return
        }
        encode(
            tilt: frame.tilt, taps: frame.taps, timeline: timeline, pageSize: pageSize, source: source,
            into: drawable.texture, commands: commands
        )
        commands.addCompletedHandler { [accounting] buffer in
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            accounting.complete(gpuTime: gpuTime > 0 ? gpuTime * 1_000 : nil)
        }
        if layer.presentsWithTransaction {
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
        } else {
            commands.present(drawable)
            commands.commit()
        }
        framesDrawn += 1
        setOpacity(Float(frame.fade))
    }

    // MARK: - Metal

    /// Encodes one frame of the frost over `source` into `target`, which covers a page of
    /// `pageSize` at its own pixels per point.
    func encode(
        tilt: Double, taps: Int, timeline: PageUnfoldTimeline, pageSize: CGSize, source: MTLTexture,
        into target: MTLTexture, commands: MTLCommandBuffer
    ) {
        guard let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = SIMD2(Float(pageSize.width), Float(pageSize.height))
        var uniforms = Uniforms(
            glass: Self.glass, size: size,
            pixelsPerPoint: SIMD2(Float(target.width), Float(target.height)) / size,
            tilt: Float(tilt), eyeDistance: Float(timeline.eyeDistance),
            blurSpread: Float(PageUnfoldTimeline.blurSpread), darkening: Float(timeline.darkeningPerPoint),
            maximumTaps: Float(taps), distanceScale: Float(timeline.distanceScale)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Uploads `image` through a shared buffer into a GPU-only texture, encoding the copy into
    /// `commands`.
    func makeTexture(_ image: CGImage, commands: MTLCommandBuffer) -> MTLTexture? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard let device, width > 0, height > 0,
              let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: buffer.contents(), width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: buffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
            destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        return texture
    }

    private nonisolated static func makePipeline(device: MTLDevice) async -> MTLRenderPipelineState? {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: NotebookPageUnfold.self)) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "pageUnfoldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "pageUnfoldFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? await device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The near-black the page is added over, shown wherever the glass misses the page.
    private static var glass: SIMD4<Float> {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        NotebookTheme.backdropBelowPaper.uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4(Float(red), Float(green), Float(blue), 1)
    }

    // MARK: - Layer

    private func install(page: CGRect, in host: CALayer, above sibling: CALayer?) -> NotebookPageUnfoldLayer {
        let layer = NotebookPageUnfoldLayer()
        layer.isOpaque = true
        withoutActions {
            layer.frame = page
            if let sibling, sibling.superlayer === host {
                host.insertSublayer(layer, above: sibling)
            } else {
                host.addSublayer(layer)
            }
        }
        self.layer = layer
        return layer
    }

    private func setOpacity(_ opacity: Float) {
        guard let layer, layer.opacity != opacity else { return }
        withoutActions { layer.opacity = opacity }
    }

    private func startDisplayLink() {
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        // The common modes keep it running while the paper is dragged or decelerating.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: - Placement

    /// The part of the paper `canvas` shows, in page points.
    static func visibleContent(of canvas: UIScrollView) -> CGRect {
        let scale = max(canvas.zoomScale, 0.001)
        return CGRect(
            x: canvas.contentOffset.x / scale, y: canvas.contentOffset.y / scale,
            width: canvas.bounds.width / scale, height: canvas.bounds.height / scale
        )
    }

    /// Whether any of `page` shows within `visibleContent`, both in page points.
    static func isVisible(page: CGRect, within visibleContent: CGRect) -> Bool {
        let shown = page.intersection(visibleContent)
        return !shown.isNull && shown.width > 0 && shown.height > 0
    }

    /// Whether any of `page`, in page points, shows in `canvas`.
    static func isVisible(page: CGRect, in canvas: UIScrollView) -> Bool {
        isVisible(page: page, within: visibleContent(of: canvas))
    }

    /// The new page as it will look once the frost has cleared: `rect` of the paper's content
    /// layer, drawn with `CALayer.render(in:)` at the pixels per point the frost draws at. Take it
    /// once the paper includes the page and before `play` adds the frost over it.
    ///
    /// - Parameter screenPixelsPerPoint: the screen's pixels per page point: the display scale
    ///   times the canvas's zoom scale.
    static func snapshot(of contentLayer: CALayer, rect: CGRect, screenPixelsPerPoint: CGFloat) -> CGImage? {
        guard !rect.isEmpty, !rect.isInfinite else { return nil }
        let scale = CGFloat(PageUnfoldTimeline.pixelsPerPoint(
            width: Double(rect.width), height: Double(rect.height), screenPixelsPerPoint: Double(screenPixelsPerPoint)
        ))
        let width = max(Int((rect.width * scale).rounded()), 1)
        let height = max(Int((rect.height * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Core Graphics counts up from the bottom, layers down from the top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / rect.width, y: -CGFloat(height) / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        contentLayer.render(in: context)
        return context.makeImage()
    }
}

/// The frost's layer. It lies over the new page and never takes touches.
final class NotebookPageUnfoldLayer: CAMetalLayer {
    override func hitTest(_ point: CGPoint) -> CALayer? { nil }

    override func contains(_ point: CGPoint) -> Bool { false }
}

/// Holds the frost weakly: a display link retains its target, and the frost must not outlive its owner.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var unfold: NotebookPageUnfold?

    init(_ unfold: NotebookPageUnfold) {
        self.unfold = unfold
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let unfold else {
            link.invalidate()
            return
        }
        unfold.tick(link)
    }
}

/// Frames the GPU has yet to finish, and its time for the latest one, shared with Metal's
/// completion handlers.
private final class FrameAccounting: Sendable {
    private struct State {
        var inFlight = 0
        var gpuTime: Double?
    }

    private let state = Mutex(State())

    /// Takes a slot for a frame, or returns false when `limit` frames are already in flight.
    func reserve(limit: Int) -> Bool {
        state.withLock { state in
            guard state.inFlight < limit else { return false }
            state.inFlight += 1
            return true
        }
    }

    /// Gives back a slot taken for a frame that was never drawn.
    func release() {
        state.withLock { $0.inFlight -= 1 }
    }

    /// Frees a drawn frame's slot once the GPU has finished it.
    func complete(gpuTime: Double?) {
        state.withLock { state in
            state.inFlight -= 1
            if let gpuTime { state.gpuTime = gpuTime }
        }
    }

    /// The GPU's time in milliseconds for the latest finished frame not yet taken.
    func takeGPUTime() -> Double? {
        state.withLock { state in
            defer { state.gpuTime = nil }
            return state.gpuTime
        }
    }
}

/// Applies `update` at once, even inside an animation block, so the frost's layer never animates
/// a change of its own.
@MainActor
private func withoutActions(_ update: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    update()
    CATransaction.commit()
}
