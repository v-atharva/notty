import UIKit

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
