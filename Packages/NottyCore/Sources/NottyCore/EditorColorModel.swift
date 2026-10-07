import Foundation

/// A colour as the colour picker edits it: hue in degrees, saturation, brightness and alpha.
/// The picker keeps this form rather than RGB so a hue survives a trip through gray or black:
/// dragging to the square's dark edge and back returns to the colour it left.
public struct EditorHSBColor: Hashable, Sendable {
    /// Degrees around the colour wheel, 0...360; 360 is the same red as 0.
    public let hue: Double
    public let saturation: Double
    public let brightness: Double
    public let alpha: Double

    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        func clamped(_ value: Double, to limit: Double) -> Double { value.isFinite ? max(0, min(value, limit)) : 0 }
        self.hue = clamped(hue, to: 360)
        self.saturation = clamped(saturation, to: 1)
        self.brightness = clamped(brightness, to: 1)
        self.alpha = clamped(alpha, to: 1)
    }

    /// The colour of `rgb`. A gray has no hue of its own and black no saturation either, so those
    /// take the ones given, usually the colour's before the change.
    public init(_ rgb: EditorInkColor, keepingHue keptHue: Double = 0, saturation keptSaturation: Double = 0) {
        let high = max(rgb.red, rgb.green, rgb.blue)
        let low = min(rgb.red, rgb.green, rgb.blue)
        let range = high - low
        var hue = keptHue
        if range > 0 {
            let sector: Double = switch high {
            case rgb.red: (rgb.green - rgb.blue) / range
            case rgb.green: (rgb.blue - rgb.red) / range + 2
            default: (rgb.red - rgb.green) / range + 4
            }
            hue = (sector * 60).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
        }
        self.init(
            hue: hue, saturation: high > 0 ? range / high : keptSaturation, brightness: high, alpha: rgb.alpha
        )
    }

    public var rgb: EditorInkColor {
        let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
        let index = sector.rounded(.down)
        let fraction = sector - index
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        let (red, green, blue): (Double, Double, Double) = switch Int(index) {
        case 0: (brightness, rising, low)
        case 1: (falling, brightness, low)
        case 2: (low, brightness, rising)
        case 3: (low, falling, brightness)
        case 4: (rising, low, brightness)
        default: (brightness, low, falling)
        }
        return EditorInkColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public func with(hue: Double? = nil, saturation: Double? = nil, brightness: Double? = nil, alpha: Double? = nil)
        -> EditorHSBColor {
        EditorHSBColor(
            hue: hue ?? self.hue, saturation: saturation ?? self.saturation,
            brightness: brightness ?? self.brightness, alpha: alpha ?? self.alpha
        )
    }

    /// The same visible colour at 8-bit precision, as the ink stores it.
    public func isSameColor(as other: EditorHSBColor) -> Bool {
        rgb.quantized == other.rgb.quantized
    }
}

// MARK: - Fields

public extension EditorInkColor {
    static let hexDigitCount = 6

    /// The opaque channels as six uppercase hexadecimal digits, as the picker's HEX field shows them.
    var hexString: String {
        let digits = Array("0123456789ABCDEF")
        return [red, green, blue].map { channel in
            let byte = Int((channel * 255).rounded())
            return String([digits[byte / 16], digits[byte % 16]])
        }.joined()
    }

    /// Reads six hexadecimal digits, with or without a leading "#", or the three-digit shorthand.
    /// Anything else is nil, so a field can return to the colour it showed.
    init?(hex: String, alpha: Double = 1) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = String(text.flatMap { [$0, $0] }) }
        guard text.count == Self.hexDigitCount, Self.areHexDigits(text), let value = Int(text, radix: 16) else {
            return nil
        }
        self.init(
            red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255, alpha: alpha
        )
    }

    /// Whether `text` may stand in the HEX field while it is typed: an optional leading "#", as
    /// the field reads it, then at most six ASCII hexadecimal digits.
    static func isHexTyping(_ text: String) -> Bool {
        let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        return digits.count <= hexDigitCount && areHexDigits(digits)
    }

    private static func areHexDigits(_ text: some StringProtocol) -> Bool {
        text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

/// The numeric fields under the picker's square, each a whole number in a fixed range.
public enum EditorColorField: CaseIterable, Sendable {
    case hue
    case saturation
    case brightness
    case alpha

    public static let maximumDigits = 3

    public var range: ClosedRange<Int> {
        self == .hue ? 0...360 : 0...100
    }

    /// Whether `text` may stand in a field while it is typed: digits only, at most three.
    public static func allowsTyping(_ text: String) -> Bool {
        text.count <= maximumDigits && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The value typed, brought into the field's range. An empty or non-numeric entry is nil, and
    /// the field returns to the value it showed.
    public func value(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(trimmed) else {
            return nil
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// What the field shows for `color`.
    public func value(of color: EditorHSBColor) -> Int {
        let value = switch self {
        case .hue: color.hue
        case .saturation: color.saturation * 100
        case .brightness: color.brightness * 100
        case .alpha: color.alpha * 100
        }
        return Int(value.rounded())
    }

    /// `color` with this field set to `value`, which the field has already brought into range.
    public func applying(_ value: Int, to color: EditorHSBColor) -> EditorHSBColor {
        let amount = Double(value)
        return switch self {
        case .hue: color.with(hue: amount)
        case .saturation: color.with(saturation: amount / 100)
        case .brightness: color.with(brightness: amount / 100)
        case .alpha: color.with(alpha: amount / 100)
        }
    }
}

// MARK: - Shades

/// The steps of the shade bar for one hue and saturation: tints that mix the middle colour with
/// white, the middle colour itself, and shades that darken it toward black. A vivid colour sits
/// in the middle at full brightness; a gray sits at a middle gray, so its tints and shades stay
/// apart rather than all turning white.
public enum EditorShadeRamp {
    /// The middle step's brightness for a gray; it rises with the saturation to full for a vivid colour.
    public static let grayMiddleBrightness = 0.6
    /// The palest tint keeps this share of the middle colour, the rest white.
    public static let palestShare = 0.1
    /// The darkest shade keeps this share of the middle colour's brightness.
    public static let darkestShare = 0.2

    /// The middle step for `base`'s hue, saturation and alpha.
    public static func middle(of base: EditorHSBColor) -> EditorHSBColor {
        base.with(brightness: grayMiddleBrightness + (1 - grayMiddleBrightness) * base.saturation)
    }

    /// `count` steps, lightest first, carrying `base`'s hue and alpha; its brightness plays no
    /// part. The count is odd, so the middle colour sits in the middle; an even count is taken as
    /// the odd number below it, and never under three.
    public static func steps(of base: EditorHSBColor, count: Int) -> [EditorHSBColor] {
        let count = max(3, count - (1 - count % 2))
        let center = count / 2
        let middle = middle(of: base)
        return (0..<count).map { index in
            if index <= center {
                // A share of the middle colour over white keeps its hue; in HSB that raises the
                // brightness and thins the saturation, whatever the hue.
                let share = palestShare + (1 - palestShare) * Double(index) / Double(center)
                let brightness = share * middle.brightness + 1 - share
                return middle.with(saturation: share * middle.brightness * middle.saturation / brightness, brightness: brightness)
            }
            let depth = Double(index - center) / Double(center)
            return middle.with(brightness: middle.brightness * (1 - (1 - darkestShare) * depth))
        }
    }
}
