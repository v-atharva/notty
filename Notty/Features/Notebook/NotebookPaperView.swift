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

/// Paper behind the status bar, above the canvas and below every control, so ink scrolling
/// under the time and battery fades out while blank paper shows no band. It replaces the
/// system's scroll edge effect, follows the scroll directly and never animates.
@MainActor
final class NotebookStatusVeil: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    private let accessibility: NotebookMaterialAccessibility
    private var width: CGFloat = 0
    private var safeTop: CGFloat = 0
    private var isOverPaper = false
    /// True under Reduce Transparency, when the veil is an opaque band with no fade.
    private(set) var isOpaqueBand = false

    /// The backing layer, a gradient as `layerClass` declares.
    var gradientLayer: CAGradientLayer {
        layer as! CAGradientLayer
    }

    init(accessibility: NotebookMaterialAccessibility) {
        self.accessibility = accessibility
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        accessibility.notificationCenter.addObserver(
            self, selector: #selector(reduceTransparencyChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(accessibility:).")
    }

    /// - Parameters:
    ///   - safeTop: the top safe area: the status bar, plus any system bar laid over the canvas.
    ///   - isOverPaper: false while the page is zoomed below width fit, where the veil would
    ///     lie over the stone beside it.
    func update(width: CGFloat, safeTop: CGFloat, isOverPaper: Bool) {
        guard width != self.width || safeTop != self.safeTop || isOverPaper != self.isOverPaper else { return }
        self.width = width
        self.safeTop = safeTop
        self.isOverPaper = isOverPaper
        applyStyle()
    }

    @objc private func reduceTransparencyChanged() {
        applyStyle()
    }

    private func applyStyle() {
        let opaque = accessibility.isReduceTransparencyEnabled()
        let fade = opaque ? 0 : NotebookTheme.statusVeilFade
        let height = safeTop + fade
        let paper = NotebookPaperView.paperColor
        let veil = paper.withAlphaComponent(opaque ? 1 : NotebookTheme.statusVeilOpacity).cgColor
        withoutAnimations {
            isOpaqueBand = opaque
            // Transparent paper rather than clear, so the fade never passes through gray.
            gradientLayer.colors = [veil, veil, paper.withAlphaComponent(opaque ? 1 : 0).cgColor]
            gradientLayer.locations = [0, NSNumber(value: height > 0 ? safeTop / height : 1), 1]
            frame = CGRect(x: 0, y: 0, width: width, height: height)
            isHidden = !isOverPaper || safeTop <= 0 || width <= 0
        }
    }
}

/// The "Add page" tab on the stone below the last page. The controller moves it with the
/// paper, and a move re-renders nothing: the shadow follows a fixed path and the edge is a
/// bitmap drawn once per size and tone.
@MainActor
final class NotebookEndOfPaperTab: UIControl {
    enum Mode: Equatable {
        /// Adds a page when tapped.
        case available
        /// Writing is paused, so the tab shows but adds nothing.
        case paused
        /// The notebook already has the most pages it can hold.
        case limitReached
    }

    /// How the shell's edge is drawn.
    private enum EdgeStyle: Equatable {
        /// Lit along the top and shaded along the bottom, as on the shell.
        case lit
        /// A solid outline all round, under Increase Contrast.
        case outline
        /// None, at the limit, where the tab lies flat.
        case none
    }

    /// What the edge bitmap was last drawn for.
    private struct EdgeRendering: Equatable {
        let size: CGSize
        let scale: CGFloat
        let style: EdgeStyle
    }

    static let symbolName = "rectangle.portrait.badge.plus"
    static let addTitle = "Add page"
    static let limitTitle = "Paper limit reached"

    private(set) var mode = Mode.available
    /// How many times the edge bitmap has been drawn.
    private(set) var edgeRenders = 0
    let titleLabel = UILabel()
    let iconView = UIImageView()
    /// Holds the icon and title, so a press can drop them together.
    private let content = UIView()
    private let faceLayer = CAGradientLayer()
    /// The lit top and shaded lower edge of the shell, or its outline under Increase Contrast.
    /// A gradient masked to the edge would render offscreen on every frame the tab moves.
    private let edgeLayer = CALayer()
    private var edgeRendering: EdgeRendering?
    /// The pressed well over the face and its edge, as on a secondary action key.
    private let pressLayer = CALayer()
    private var contentSize: UIContentSizeCategory?
    private var maximumWidth = CGFloat.greatestFiniteMagnitude

    private static let iconPointSize: CGFloat = 17
    private static let iconSpacing: CGFloat = 8
    private static let sidePadding: CGFloat = 16
    /// Room above and below the content once a large text size outgrows the standard height.
    private static let verticalPadding: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        // Each layer rounds its own corners, so none has to clip sublayers offscreen.
        for shape in [faceLayer, pressLayer] {
            shape.cornerRadius = NotebookTheme.endTabCornerRadius
            shape.cornerCurve = .continuous
        }
        pressLayer.opacity = Float(NotebookTheme.pressedWellOpacity)
        pressLayer.isHidden = true
        layer.addSublayer(faceLayer)
        layer.addSublayer(edgeLayer)
        layer.addSublayer(pressLayer)
        layer.shadowColor = NotebookTheme.shellShadow.tone.uiColor.cgColor
        layer.shadowRadius = NotebookTheme.shellShadow.radius
        layer.shadowOffset = NotebookTheme.shellShadow.offset
        titleLabel.textAlignment = .center
        // In a window too narrow for the title at a large text size, the title shrinks to fit.
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5
        iconView.contentMode = .center
        for view in [content, titleLabel, iconView] {
            view.isUserInteractionEnabled = false
        }
        content.addSubview(iconView)
        content.addSubview(titleLabel)
        addSubview(content)
        registerForTraitChanges(
            [UITraitAccessibilityContrast.self, UITraitDisplayScale.self]
        ) { (tab: NotebookEndOfPaperTab, _: UITraitCollection) in
            tab.applyTones()
        }
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            withoutAnimations {
                pressLayer.isHidden = !isHighlighted
                content.transform = isHighlighted
                    ? CGAffineTransform(translationX: 0, y: NotebookTheme.pressTravel) : .identity
            }
        }
    }

    /// Sets the mode, the text size and the widest the tab may be, resizing it when its title,
    /// text size or room changes.
    func configure(mode: Mode, contentSize: UIContentSizeCategory, maximumWidth: CGFloat) {
        guard mode != self.mode || contentSize != self.contentSize || maximumWidth != self.maximumWidth else {
            return
        }
        let resizes = mode == .limitReached || self.mode == .limitReached || contentSize != self.contentSize
            || maximumWidth != self.maximumWidth
        self.mode = mode
        self.maximumWidth = maximumWidth
        if contentSize != self.contentSize {
            self.contentSize = contentSize
            applyTextSize(contentSize)
        }
        applyMode()
        guard resizes else { return }
        let natural = sizeThatFits(.zero)
        let size = CGSize(width: max(min(natural.width, maximumWidth.rounded(.down)), 0), height: natural.height)
        withoutAnimations { bounds.size = size }
    }

    /// The tab's natural size, whatever size is offered; `configure` narrows it to the room the
    /// window leaves.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let (icon, spacing, title) = contentSizes
        let width = (2 * Self.sidePadding + icon.width + spacing + title.width).rounded(.up)
        let height = (max(title.height, icon.height) + 2 * Self.verticalPadding).rounded(.up)
        return CGSize(width: width, height: max(NotebookTheme.endTabHeight, height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (icon, spacing, natural) = contentSizes
        let title = CGSize(
            width: max(min(natural.width, bounds.width - 2 * Self.sidePadding - icon.width - spacing), 0),
            height: natural.height
        )
        let width = icon.width + spacing + title.width
        withoutAnimations {
            faceLayer.frame = bounds
            pressLayer.frame = bounds
            edgeLayer.frame = bounds
            layer.shadowPath = UIBezierPath(
                roundedRect: bounds, cornerRadius: NotebookTheme.endTabCornerRadius
            ).cgPath
            content.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: bounds.height))
            content.center = CGPoint(x: bounds.midX, y: bounds.midY)
            iconView.frame = CGRect(
                x: 0, y: (bounds.height - icon.height) / 2, width: icon.width, height: icon.height
            )
            titleLabel.frame = CGRect(
                x: icon.width + spacing, y: (bounds.height - title.height) / 2,
                width: title.width, height: title.height
            )
        }
        renderEdgeIfNeeded()
    }

    /// The icon, the gap after it and the title at its full size; the icon and gap are empty at
    /// the limit.
    private var contentSizes: (CGSize, CGFloat, CGSize) {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let title = titleLabel.sizeThatFits(unbounded)
        guard !iconView.isHidden else { return (.zero, 0, title) }
        return (iconView.intrinsicContentSize, Self.iconSpacing, title)
    }

    /// Sizes the title and icon for `contentSize` alone. The controller passes a new text size
    /// before this view's own traits catch up, so the icon takes a fixed point size: an image
    /// view rescales a font-sized symbol with its own, still stale, traits.
    private func applyTextSize(_ contentSize: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSize)
        let typeface = NotebookTheme.tabLabel
        let metrics = UIFontMetrics(forTextStyle: typeface.style.textStyle)
        titleLabel.font = metrics.scaledFont(
            for: .systemFont(ofSize: typeface.pointSize, weight: typeface.weight.fontWeight), compatibleWith: traits
        )
        let iconSize = metrics.scaledValue(for: Self.iconPointSize, compatibleWith: traits)
        iconView.image = UIImage(
            systemName: Self.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize)
        )
    }

    private func applyMode() {
        isEnabled = mode == .available
        titleLabel.text = mode == .limitReached ? Self.limitTitle : Self.addTitle
        // Adding is impossible at the limit, so the plus badge goes with it.
        iconView.isHidden = mode == .limitReached
        accessibilityLabel = titleLabel.text
        accessibilityTraits = mode == .available ? .button : [.button, .notEnabled]
        accessibilityHint = mode == .available ? "Adds a page at the end of the notebook." : nil
        applyTones()
        setNeedsLayout()
    }

    /// Layers hold resolved colours, so they are set again when Increase Contrast changes. At
    /// the limit the tab lies flat without a shadow; under Increase Contrast it is flat with an
    /// outline. While writing is paused it keeps its shell and dims its content as the paused
    /// rail does; the dimming is in the colours, so no layer needs group opacity.
    private func applyTones() {
        let traits = traitCollection
        let increased = traits.accessibilityContrast == .high
        let flat = increased || mode == .limitReached
        let content: UIColor
        switch mode {
        case .available:
            content = NotebookTheme.glyph.uiColor
        case .paused:
            let opacity = increased ? NotebookTheme.disabledOpacityIncreased : NotebookTheme.disabledOpacity
            content = NotebookTheme.glyph.uiColor.withAlphaComponent(opacity)
        case .limitReached:
            content = NotebookTheme.disabledGlyph.uiColor.resolvedColor(with: traits)
        }
        titleLabel.textColor = content
        iconView.tintColor = content
        withoutAnimations {
            if flat {
                let surface = NotebookTheme.panelSurface.cgColor(for: traits)
                faceLayer.colors = [surface, surface]
            } else {
                faceLayer.colors = [
                    NotebookTheme.panelTop.cgColor(for: traits), NotebookTheme.panelBottom.cgColor(for: traits)
                ]
            }
            pressLayer.backgroundColor = NotebookTheme.selectedWell.cgColor(for: traits)
            layer.shadowOpacity = mode == .limitReached ? 0 : Float(NotebookTheme.shellShadow.opacity)
        }
        renderEdgeIfNeeded()
    }

    private var edgeStyle: EdgeStyle {
        if traitCollection.accessibilityContrast == .high { return .outline }
        return mode == .limitReached ? .none : .lit
    }

    /// Draws the one-point edge inside the tab's outline into a bitmap, only when the tab's
    /// size, the screen scale or the edge style changes.
    private func renderEdgeIfNeeded() {
        let traits = traitCollection
        let rendering = EdgeRendering(
            size: bounds.size, scale: max(traits.displayScale, 1), style: edgeStyle
        )
        guard rendering != edgeRendering else { return }
        edgeRendering = rendering
        guard rendering.style != .none, rendering.size.width > 0, rendering.size.height > 0 else {
            withoutAnimations { edgeLayer.contents = nil }
            return
        }
        edgeRenders += 1
        let format = UIGraphicsImageRendererFormat()
        format.scale = rendering.scale
        format.opaque = false
        let lowerEdge = NotebookTheme.panelLowerEdge.uiColor.resolvedColor(with: traits)
        let highlight = NotebookTheme.panelHighlight.uiColor.resolvedColor(with: traits)
        let image = UIGraphicsImageRenderer(size: rendering.size, format: format).image { context in
            let inset = NotebookTheme.shellBorderWidth / 2
            let outline = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: rendering.size).insetBy(dx: inset, dy: inset),
                cornerRadius: NotebookTheme.endTabCornerRadius - inset
            )
            outline.lineWidth = NotebookTheme.shellBorderWidth
            switch rendering.style {
            case .outline:
                lowerEdge.setStroke()
                outline.stroke()
            case .lit:
                let cg = context.cgContext
                cg.addPath(outline.cgPath)
                cg.setLineWidth(NotebookTheme.shellBorderWidth)
                cg.replacePathWithStrokedPath()
                cg.clip()
                let colors = [
                    highlight, highlight.withAlphaComponent(0), lowerEdge.withAlphaComponent(0), lowerEdge
                ].map(\.cgColor)
                let locations: [CGFloat] = [0, 0.3, 0.7, 1]
                guard let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                    locations: locations
                ) else { return }
                cg.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: rendering.size.height), options: []
                )
            case .none:
                break
            }
        }
        withoutAnimations {
            edgeLayer.contentsScale = rendering.scale
            edgeLayer.contents = image.cgImage
        }
    }
}

private extension NotebookTheme.Typeface.Style {
    var textStyle: UIFont.TextStyle {
        switch self {
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }
}

private extension NotebookTheme.Typeface.Weight {
    var fontWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}

/// Applies `update` at once, even inside an animation block such as a rotation's, so paper
/// layers, the veil and the tab never animate.
@MainActor
private func withoutAnimations(_ update: () -> Void) {
    UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }
}
