import NottyCore
import QuartzCore
import UIKit

@MainActor
class NotebookPaperView: UIView {
    static var paperColor: UIColor { NotebookTheme.paperIvory.uiColor }
    static var backdropColor: UIColor { NotebookTheme.backdropStone.uiColor }
    static var belowPaperColor: UIColor { NotebookTheme.backdropBelowPaper.uiColor }

    let contentLayer = CALayer()
    /// Paper above page 1, so the space reserved for the chrome and for overscroll at the top
    /// shows paper rather than stone.
    let headMarginLayer = CALayer()
    /// Paper fibres under the dividers and the edges, continuing through the head margin. It
    /// repeats a cached tile and moves with `contentLayer`, so scrolling and zooming never redraw it.
    let grainLayer = CALayer()
    /// Near-black below the last page, across the whole window at any zoom, while stone stays
    /// beside the paper down to its foot. It moves with `contentLayer`, so a pull or a fling past
    /// the end opens dark space beneath the page.
    let belowPaperLayer = CALayer()
    /// Line just below the last page.
    let edgeLayer = CALayer()
    /// Lines just outside the sides of the paper, from the top of the head margin to the bottom
    /// edge. At width fit the paper spans the view, so they fall beyond its bounds and never
    /// show as a line along the screen border.
    let leadingEdgeLayer = CALayer()
    let trailingEdgeLayer = CALayer()
    /// Divider at the top of page 1, where the head margin ends.
    let pageTopLayer = CALayer()
    /// Shading on the stone beside the paper, down to its foot. Gradients in page coordinates
    /// zoom with the page, so nothing blurs while scrolling or zooming.
    let leadingShadowLayer = CAGradientLayer()
    let trailingShadowLayer = CAGradientLayer()
    private(set) var boundaryLayers: [CALayer] = []
    private(set) var geometryUpdates = 0
    private(set) var viewportUpdates = 0
    private(set) var thicknessUpdates = 0

    private var logicalWidth: CGFloat = 0
    private var logicalHeight: CGFloat = 0
    private var boundaries: [CGFloat] = []
    private var viewportScale: CGFloat = 1
    private var viewportOffset = CGPoint.zero
    private var cachedTile: (pattern: CGColor, image: CGImage)?
    /// Reduce Transparency and Increase Contrast as the paper reads them; the status veil
    /// shares the same source.
    let accessibility: NotebookMaterialAccessibility

    /// Layers that frame the paper; empty geometry hides them all.
    private var framingLayers: [CALayer] {
        [headMarginLayer, belowPaperLayer, edgeLayer, leadingEdgeLayer, trailingEdgeLayer, pageTopLayer]
            + [leadingShadowLayer, trailingShadowLayer]
    }

    private var edgeLayers: [CALayer] { [edgeLayer, leadingEdgeLayer, trailingEdgeLayer] }

    init(
        frame: CGRect, materials: NotebookMaterials = .shared,
        accessibility: NotebookMaterialAccessibility = .system
    ) {
        self.accessibility = accessibility
        super.init(frame: frame)
        // Stone shows wherever there is no paper above the page's foot: beside a page zoomed below
        // width fit, and above the head margin when zoomed far out.
        backgroundColor = Self.backdropColor
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        contentLayer.backgroundColor = Self.paperColor.cgColor
        headMarginLayer.anchorPoint = .zero
        headMarginLayer.backgroundColor = Self.paperColor.cgColor
        // The fibre tile is opaque, so the head margin lies beneath the grain that continues over it.
        contentLayer.addSublayer(headMarginLayer)
        grainLayer.anchorPoint = .zero
        grainLayer.isHidden = accessibility.prefersPlainMaterials
        contentLayer.addSublayer(grainLayer)
        // Each band is darkest where it touches the paper.
        for (shadow, start, end) in [
            (leadingShadowLayer, CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
            (trailingShadowLayer, CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        ] {
            Self.shade(shadow, opacity: NotebookTheme.pageSideShadowOpacity, from: start, to: end)
            shadow.anchorPoint = .zero
            contentLayer.addSublayer(shadow)
        }
        // Under the edges, which frame the page on the near-black as on the stone.
        belowPaperLayer.anchorPoint = .zero
        belowPaperLayer.backgroundColor = Self.belowPaperColor.cgColor
        contentLayer.addSublayer(belowPaperLayer)
        for edge in edgeLayers {
            edge.anchorPoint = .zero
            contentLayer.addSublayer(edge)
        }
        pageTopLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        pageTopLayer.position = .zero
        contentLayer.addSublayer(pageTopLayer)
        layer.addSublayer(contentLayer)
        applyLineTones()
        // Increase Contrast turns the edges into solid one-point charcoal lines and darkens the
        // dividers; layers hold resolved colours, so both are set again when it changes.
        registerForTraitChanges(
            [UITraitDisplayScale.self, UITraitAccessibilityContrast.self]
        ) { (view: NotebookPaperView, _: UITraitCollection) in
            view.applyLineTones()
            view.finishZoom()
        }
        // The fibre tile renders off the main thread, so opening a notebook never waits for it;
        // the texture appears once, when it is ready.
        materials.whenReady { [weak self] materials in
            self?.applyMaterials(materials)
        }
        for name in NotebookMaterialAccessibility.statusChangeNotifications {
            accessibility.notificationCenter.addObserver(
                self, selector: #selector(accessibilityMaterialsChanged), name: name, object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyLineTones()
        finishZoom()
    }

    func setGeometry(width: CGFloat, height: CGFloat, boundaries: [CGFloat]) {
        guard width != logicalWidth || height != logicalHeight || boundaries != self.boundaries else { return }
        logicalWidth = width
        logicalHeight = height
        self.boundaries = boundaries
        geometryUpdates += 1
        withoutAnimations {
            while boundaryLayers.count > boundaries.count {
                boundaryLayers.removeLast().removeFromSuperlayer()
            }
            while boundaryLayers.count < boundaries.count {
                let divider = CALayer()
                divider.anchorPoint = CGPoint(x: 0, y: 0.5)
                divider.backgroundColor = NotebookTheme.paperDivider.cgColor(for: traitCollection)
                contentLayer.addSublayer(divider)
                boundaryLayers.append(divider)
            }
            contentLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let margin = NotebookTheme.headMarginLength
            let side = NotebookTheme.pageSideShadowDepth
            let reach = NotebookTheme.belowPaperReach
            headMarginLayer.frame = CGRect(x: 0, y: -margin, width: width, height: margin)
            grainLayer.frame = CGRect(x: 0, y: -margin, width: width, height: height + margin)
            belowPaperLayer.frame = CGRect(x: -reach, y: height, width: width + 2 * reach, height: reach)
            leadingShadowLayer.frame = CGRect(x: -side, y: -margin, width: side, height: height + margin)
            trailingShadowLayer.frame = CGRect(x: width, y: -margin, width: side, height: height + margin)
            for (divider, y) in zip(boundaryLayers, boundaries) {
                divider.position = CGPoint(x: 0, y: y)
            }
            edgeLayer.position = CGPoint(x: 0, y: height)
            for framing in framingLayers {
                framing.isHidden = width <= 0 || height <= 0
            }
        }
        finishZoom()
    }

    func setViewport(scale: CGFloat, offset: CGPoint) {
        guard scale.isFinite, scale > 0, offset.x.isFinite, offset.y.isFinite,
              scale != viewportScale || offset != viewportOffset else { return }
        viewportScale = scale
        viewportOffset = offset
        viewportUpdates += 1
        withoutAnimations {
            contentLayer.transform = CATransform3DMakeAffineTransform(
                CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: -offset.x, ty: -offset.y)
            )
        }
    }

    /// Sets every line to one device pixel at the current zoom; under Increase Contrast the
    /// page edges are one point instead.
    func finishZoom() {
        let screenScale = max(traitCollection.displayScale, 1)
        let thickness = 1 / (screenScale * viewportScale)
        let edge = traitCollection.accessibilityContrast == .high ? 1 / viewportScale : thickness
        thicknessUpdates += 1
        withoutAnimations {
            for divider in boundaryLayers + [pageTopLayer] {
                divider.bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: thickness)
            }
            edgeLayer.bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: edge)
            // The sides reach down past the bottom edge, so the lower corners close.
            let top = -NotebookTheme.headMarginLength
            let sideHeight = logicalHeight + edge - top
            leadingEdgeLayer.frame = CGRect(x: -edge, y: top, width: edge, height: sideHeight)
            trailingEdgeLayer.frame = CGRect(x: logicalWidth, y: top, width: edge, height: sideHeight)
        }
    }

    /// Resolves the edge and divider tones for this view's traits.
    private func applyLineTones() {
        let edge = NotebookTheme.paperEdge.cgColor(for: traitCollection)
        let divider = NotebookTheme.paperDivider.cgColor(for: traitCollection)
        withoutAnimations {
            for line in edgeLayers {
                line.backgroundColor = edge
            }
            for line in boundaryLayers + [pageTopLayer] {
                line.backgroundColor = divider
            }
        }
    }

    @objc private func accessibilityMaterialsChanged() {
        withoutAnimations {
            grainLayer.isHidden = accessibility.prefersPlainMaterials
        }
    }

    private func applyMaterials(_ materials: NotebookMaterials) {
        withoutAnimations {
            grainLayer.backgroundColor = materials.paperFibrePattern
        }
    }

    /// The blank paper within `rect`, in page points, as the page frost clears onto: the paper
    /// colour and, unless plain materials replace it, the fibres in the phase the grain layer
    /// shows them. The lines are left out, as the frost lies beneath them. It is tiled from one
    /// repeat of the fibre pattern rather than rendered from the layer tree, which costs several
    /// times as much on the main thread.
    ///
    /// - Parameter screenPixelsPerPoint: the display scale times the canvas's zoom scale; the
    ///   image has `PageUnfoldTimeline.pixelsPerPoint`'s pixels per point.
    func blankPageImage(_ rect: CGRect, screenPixelsPerPoint: CGFloat) -> CGImage? {
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
        guard !grainLayer.isHidden, let tile = fibreTile() else {
            context.setFillColor(Self.paperColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        // Core Graphics counts up from the bottom; the grain repeats down from its layer's top.
        let scaleX = CGFloat(width) / rect.width
        let scaleY = CGFloat(height) / rect.height
        let side = NotebookMaterials.tileSide
        let grain = grainLayer.frame
        let anchor = CGRect(
            x: ((grain.minX - rect.minX) * scaleX).rounded(),
            y: (CGFloat(height) - (grain.minY + side - rect.minY) * scaleY).rounded(),
            width: (side * scaleX).rounded(), height: (side * scaleY).rounded()
        )
        // The opaque fibres cover every pixel. At the tile's own scale each pixel is copied as it
        // is; zoomed out, the tile is resampled.
        let isNative = anchor.width == CGFloat(tile.width) && anchor.height == CGFloat(tile.height)
        context.interpolationQuality = isNative ? .none : .medium
        context.draw(tile, in: anchor, byTiling: true)
        return context.makeImage()
    }

    /// One repeat of the fibre pattern at the tile's own pixels per point, drawn once per pattern.
    private func fibreTile() -> CGImage? {
        guard let pattern = grainLayer.backgroundColor else { return nil }
        if let cachedTile, cachedTile.pattern === pattern { return cachedTile.image }
        let side = NotebookMaterials.tileSide
        let pixels = Int(side * NotebookMaterials.tileScale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let repeatLayer = CALayer()
        repeatLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        repeatLayer.backgroundColor = pattern
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: NotebookMaterials.tileScale, y: -NotebookMaterials.tileScale)
        repeatLayer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        cachedTile = (pattern, image)
        return image
    }

    /// Fades `layer` from the shadow tone at `opacity` to transparent of the same tone, which
    /// keeps the fade from passing through gray.
    private static func shade(_ layer: CAGradientLayer, opacity: CGFloat, from start: CGPoint, to end: CGPoint) {
        let tone = NotebookTheme.shadowTone.uiColor
        layer.colors = [tone.withAlphaComponent(opacity).cgColor, tone.withAlphaComponent(0).cgColor]
        layer.startPoint = start
        layer.endPoint = end
    }
}

/// Applies `update` at once, even inside an animation block such as a rotation's, so paper
/// layers, the veil and the tab never animate.
@MainActor
func withoutAnimations(_ update: () -> Void) {
    UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }
}
