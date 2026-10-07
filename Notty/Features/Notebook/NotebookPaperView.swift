import QuartzCore
import UIKit

@MainActor
class NotebookPaperView: UIView {
    static var paperColor: UIColor { NotebookTheme.paperIvory.uiColor }
    static var backdropColor: UIColor { NotebookTheme.backdropStone.uiColor }

    let contentLayer = CALayer()
    /// Paper above page 1, so the space reserved for the chrome and for overscroll at the top
    /// shows paper rather than stone.
    let headMarginLayer = CALayer()
    /// Paper fibres under the dividers and the edges, continuing through the head margin. It
    /// repeats a cached tile and moves with `contentLayer`, so scrolling and zooming never redraw it.
    let grainLayer = CALayer()
    /// Line just below the last page.
    let edgeLayer = CALayer()
    /// Lines just outside the sides of the paper, from the top of the head margin to the bottom
    /// edge. At width fit the paper spans the view, so they fall beyond its bounds and never
    /// show as a line along the screen border.
    let leadingEdgeLayer = CALayer()
    let trailingEdgeLayer = CALayer()
    /// Divider at the top of page 1, where the head margin ends.
    let pageTopLayer = CALayer()
    /// Shading on the stone below the last page and beside the paper. Gradients in page
    /// coordinates zoom with the page, so nothing blurs while scrolling or zooming.
    let bottomShadowLayer = CAGradientLayer()
    let leadingShadowLayer = CAGradientLayer()
    let trailingShadowLayer = CAGradientLayer()
    /// Quarter ellipses outside the lower corners of the paper, where the bottom and side bands
    /// would otherwise end in hard cuts.
    let leadingCornerShadowLayer = CAGradientLayer()
    let trailingCornerShadowLayer = CAGradientLayer()
    private(set) var boundaryLayers: [CALayer] = []
    private(set) var geometryUpdates = 0
    private(set) var viewportUpdates = 0
    private(set) var thicknessUpdates = 0

    private var logicalWidth: CGFloat = 0
    private var logicalHeight: CGFloat = 0
    private var boundaries: [CGFloat] = []
    private var viewportScale: CGFloat = 1
    private var viewportOffset = CGPoint.zero
    /// Reduce Transparency and Increase Contrast as the paper reads them; the status veil
    /// shares the same source.
    let accessibility: NotebookMaterialAccessibility

    /// Layers that frame the paper; empty geometry hides them all.
    private var framingLayers: [CALayer] {
        [headMarginLayer, edgeLayer, leadingEdgeLayer, trailingEdgeLayer, pageTopLayer]
            + [bottomShadowLayer, leadingShadowLayer, trailingShadowLayer]
            + [leadingCornerShadowLayer, trailingCornerShadowLayer]
    }

    private var edgeLayers: [CALayer] { [edgeLayer, leadingEdgeLayer, trailingEdgeLayer] }

    init(
        frame: CGRect, materials: NotebookMaterials = .shared,
        accessibility: NotebookMaterialAccessibility = .system
    ) {
        self.accessibility = accessibility
        super.init(frame: frame)
        // Stone shows wherever there is no paper: past the last page, beside a page zoomed below
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
        // Each band is darkest where it touches the paper. A corner ellipse is centred on the page
        // corner with the bands' depths as radii, so it fades like the bottom band along the page
        // side and like the side band below the page; halfway between their strengths halves the
        // step left at either seam.
        let cornerOpacity = (NotebookTheme.pageShadowOpacity + NotebookTheme.pageSideShadowOpacity) / 2
        for (shadow, opacity, start, end) in [
            (bottomShadowLayer, NotebookTheme.pageShadowOpacity, CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
            (leadingShadowLayer, NotebookTheme.pageSideShadowOpacity, CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
            (trailingShadowLayer, NotebookTheme.pageSideShadowOpacity, CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            (leadingCornerShadowLayer, cornerOpacity, CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 1)),
            (trailingCornerShadowLayer, cornerOpacity, CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        ] {
            Self.shade(shadow, opacity: opacity, from: start, to: end)
            shadow.anchorPoint = .zero
            contentLayer.addSublayer(shadow)
        }
        for corner in [leadingCornerShadowLayer, trailingCornerShadowLayer] {
            corner.type = .radial
        }
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
            let depth = NotebookTheme.pageShadowDepth
            headMarginLayer.frame = CGRect(x: 0, y: -margin, width: width, height: margin)
            grainLayer.frame = CGRect(x: 0, y: -margin, width: width, height: height + margin)
            bottomShadowLayer.frame = CGRect(x: 0, y: height, width: width, height: depth)
            leadingShadowLayer.frame = CGRect(x: -side, y: -margin, width: side, height: height + margin)
            trailingShadowLayer.frame = CGRect(x: width, y: -margin, width: side, height: height + margin)
            leadingCornerShadowLayer.frame = CGRect(x: -side, y: height, width: side, height: depth)
            trailingCornerShadowLayer.frame = CGRect(x: width, y: height, width: side, height: depth)
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
