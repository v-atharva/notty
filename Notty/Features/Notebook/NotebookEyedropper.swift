import NottyCore
import UIKit

/// The notebook page as it showed when the colour screen opened, which the eyedropper samples.
/// Nothing on the page can change while the screen is open, so one picture serves the visit.
struct NotebookPageSnapshot {
    let image: UIImage
    /// Where the picture lay on screen, in window coordinates.
    let frame: CGRect

    /// Pictures `view` as it shows now, at the screen's scale in standard sRGB, the space inks
    /// are stored in.
    @MainActor
    static func capture(_ view: UIView) -> NotebookPageSnapshot? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: view.traitCollection)
        format.preferredRange = .standard
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return NotebookPageSnapshot(image: image, frame: view.convert(view.bounds, to: nil))
    }

    /// The colour at `point`, in window coordinates; nil off the picture.
    func color(at point: CGPoint) -> EditorInkColor? {
        guard frame.contains(point), let cgImage = image.cgImage else { return nil }
        let x = min(Int((point.x - frame.minX) / frame.width * CGFloat(cgImage.width)), cgImage.width - 1)
        let y = min(Int((point.y - frame.minY) / frame.height * CGFloat(cgImage.height)), cgImage.height - 1)
        guard let pixel = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn, bytes[3] > 0 else { return nil }
        let alpha = Double(bytes[3]) / 255
        return EditorInkColor(
            red: Double(bytes[0]) / 255 / alpha, green: Double(bytes[1]) / 255 / alpha, blue: Double(bytes[2]) / 255 / alpha
        ).quantized
    }

    /// The part of the picture around `point`, `size` points across, as a layer's contents rectangle.
    func contentsRect(around point: CGPoint, size: CGFloat) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGRect(
            x: (point.x - frame.minX - size / 2) / frame.width, y: (point.y - frame.minY - size / 2) / frame.height,
            width: size / frame.width, height: size / frame.height
        )
    }
}

/// The eyedropper: the page as it showed when the screen opened, with a loupe that follows a
/// finger or the Pencil. Lifting samples the colour under the loupe's centre.
@MainActor
final class NotebookEyedropperView: UIView {
    static let hint = "Drag over your page, then lift to pick a color"
    static let accessibilityLabel = "Your page"
    static let accessibilityHint = "Drag to a color and lift to pick it."

    let snapshot: NotebookPageSnapshot
    let page = UIImageView()
    let loupe = NotebookEyedropperLoupe()
    let hintLabel = NotebookEyedropperHint()
    /// Told of the colour picked when a touch lifts over the page.
    var onSample: (@MainActor (EditorInkColor) -> Void)?
    /// Told when the user leaves without picking.
    var onCancel: (@MainActor () -> Void)?
    /// The colour under the loupe's centre, while a touch is down over the page.
    private(set) var hoveredColor: EditorInkColor?

    init(snapshot: NotebookPageSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        backgroundColor = NotebookTheme.backdropStone.uiColor
        page.image = snapshot.image
        addSubview(page)
        loupe.contents.contents = snapshot.image.cgImage
        loupe.isHidden = true
        addSubview(loupe)
        addSubview(hintLabel)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = Self.accessibilityLabel
        accessibilityHint = Self.accessibilityHint
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(snapshot:).")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        page.frame = convert(snapshot.frame, from: nil)
        let size = hintLabel.sizeThatFits(CGSize(width: bounds.width - 2 * NotebookTheme.eyedropperHintInset, height: .greatestFiniteMagnitude))
        hintLabel.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: safeAreaInsets.top + NotebookTheme.eyedropperHintInset,
            width: size.width, height: size.height
        )
    }

    /// Moves the loupe over `point`, in this view's coordinates, and reads the colour there.
    func hover(at point: CGPoint) {
        let windowPoint = convert(point, to: nil)
        hoveredColor = snapshot.color(at: windowPoint)
        guard let hoveredColor else {
            loupe.isHidden = true
            return
        }
        let diameter = NotebookTheme.eyedropperLoupeDiameter
        // The loupe floats above the touch so the finger never hides it, and below it near the top.
        var center = CGPoint(x: point.x, y: point.y - NotebookTheme.eyedropperLoupeOffset)
        if center.y - diameter / 2 < safeAreaInsets.top { center.y = point.y + NotebookTheme.eyedropperLoupeOffset }
        withoutAnimations {
            loupe.center = center
            loupe.contents.contentsRect = snapshot.contentsRect(
                around: windowPoint, size: diameter / NotebookTheme.eyedropperLoupeZoom
            )
            loupe.ring.strokeColor = hoveredColor.platformColor.cgColor
        }
        loupe.isHidden = false
        hintLabel.isHidden = true
    }

    /// Picks the colour at `point`, in this view's coordinates; a lift off the page picks nothing.
    func lift(at point: CGPoint) {
        hover(at: point)
        loupe.isHidden = true
        hintLabel.isHidden = false
        guard let hoveredColor else { return }
        onSample?(hoveredColor)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        hover(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        hover(at: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        lift(at: touch.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        hoveredColor = nil
        loupe.isHidden = true
        hintLabel.isHidden = false
    }

    override func accessibilityPerformEscape() -> Bool {
        onCancel?()
        return true
    }
}

/// A round window onto the page, magnified, ringed in the colour under its centre with a small
/// square marking the exact point.
@MainActor
final class NotebookEyedropperLoupe: UIView {
    let contents = CALayer()
    let ring = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let reticle = CAShapeLayer()
    private let reticleRim = CAShapeLayer()

    override init(frame: CGRect) {
        let diameter = NotebookTheme.eyedropperLoupeDiameter
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isUserInteractionEnabled = false
        let circle = UIBezierPath(ovalIn: bounds).cgPath
        contents.frame = bounds
        // Each point of the page stays a crisp block, so the sampled point is plain to see.
        contents.magnificationFilter = .nearest
        contents.cornerRadius = diameter / 2
        contents.masksToBounds = true
        contents.backgroundColor = NotebookTheme.backdropStone.uiColor.cgColor
        layer.addSublayer(contents)

        let ringWidth = NotebookTheme.eyedropperLoupeRingWidth
        let ringPath = UIBezierPath(ovalIn: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)).cgPath
        ring.path = ringPath
        ring.fillColor = nil
        ring.lineWidth = ringWidth
        layer.addSublayer(ring)
        // A dark line and a light one around the ring, so it reads whatever the colour.
        rim.path = circle
        rim.fillColor = nil
        rim.lineWidth = NotebookTheme.colorHandleRimWidth * 2
        rim.strokeColor = NotebookTheme.colorHandleRim.uiColor.cgColor
        layer.addSublayer(rim)

        let size = NotebookTheme.eyedropperReticleSize
        let square = UIBezierPath(rect: CGRect(x: (diameter - size) / 2, y: (diameter - size) / 2, width: size, height: size)).cgPath
        for (mark, width, tone) in [
            (reticleRim, NotebookTheme.colorHandleRimWidth * 3, NotebookTheme.colorHandleRim),
            (reticle, NotebookTheme.colorHandleRimWidth, NotebookTheme.colorHandleRing)
        ] {
            mark.path = square
            mark.fillColor = nil
            mark.lineWidth = width
            mark.strokeColor = tone.uiColor.cgColor
            layer.addSublayer(mark)
        }
        layer.shadowColor = NotebookTheme.shadowTone.uiColor.cgColor
        layer.shadowOpacity = Float(NotebookTheme.shellShadow.opacity)
        layer.shadowRadius = NotebookTheme.shellShadow.radius
        layer.shadowOffset = NotebookTheme.shellShadow.offset
        layer.shadowPath = circle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }
}

/// The eyedropper's instruction, on a dark pill so it reads over any page.
@MainActor
final class NotebookEyedropperHint: UILabel {
    private static let padding = NotebookTheme.eyedropperHintPadding

    override init(frame: CGRect) {
        super.init(frame: frame)
        text = NotebookEyedropperView.hint
        font = UIFont.preferredFont(forTextStyle: .subheadline)
        adjustsFontForContentSizeCategory = true
        textColor = NotebookTheme.colorPanelText.uiColor
        textAlignment = .center
        numberOfLines = 0
        backgroundColor = NotebookTheme.colorPanelFill.uiColor
        layer.cornerRadius = NotebookTheme.colorKeyCornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.padding))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = Self.padding
        let inner = super.sizeThatFits(CGSize(width: size.width - padding.left - padding.right, height: size.height))
        return CGSize(width: inner.width + padding.left + padding.right, height: inner.height + padding.top + padding.bottom)
    }
}
