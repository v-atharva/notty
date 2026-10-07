import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// The procedural paper-fibre tile. It is rendered once per process on a utility task, never on
/// the main thread, and shared by every view; strokes, scrolling, zooming and saves never
/// regenerate texture. Until the tile exists, views show the flat paper colour.
@MainActor
final class NotebookMaterials {
    static let shared = NotebookMaterials()

    /// Side of the square tile in points; the pattern repeats once per tile.
    nonisolated static let tileSide: CGFloat = 256
    /// Every supported iPad has a 2x display, so one tile at a fixed scale serves them all.
    nonisolated static let tileScale: CGFloat = 2

    /// Pattern colour of the fibre tile; Core Animation repeats it without a layer-sized bitmap.
    private(set) var paperFibrePattern: CGColor?

    private let render: @Sendable () -> CGImage?
    private var hasStartedPreparation = false
    private var readyHandlers: [@MainActor (NotebookMaterials) -> Void] = []

    /// - Parameter render: called once, off the main thread, to produce the fibre tile; nil
    ///   when Core Image cannot render it, in which case a flat tile stands in.
    init(render: @escaping @Sendable () -> CGImage? = NotebookMaterials.renderFibreTile) {
        self.render = render
    }

    /// Starts rendering the tile in the background the first time it is called; returns at once.
    func prepare() {
        guard !hasStartedPreparation else { return }
        hasStartedPreparation = true
        let render = render
        Task {
            let rendered = await Task.detached(priority: .utility) { render() }.value
            install(rendered)
        }
    }

    /// Calls `handler` once the tile exists: immediately when it already does. Callers capture
    /// their views weakly, so a pending handler never keeps one alive.
    func whenReady(_ handler: @escaping @MainActor (NotebookMaterials) -> Void) {
        if paperFibrePattern != nil {
            handler(self)
            return
        }
        readyHandlers.append(handler)
        prepare()
    }

    nonisolated static func renderFibreTile() -> CGImage? {
        renderTile(paperFibres())
    }

    private func install(_ tile: CGImage?) {
        let fibre = tile.map { UIImage(cgImage: $0, scale: Self.tileScale, orientation: .up) }
            ?? Self.flatTile(NotebookTheme.paperIvory.uiColor)
        paperFibrePattern = UIColor(patternImage: fibre).cgColor
        let handlers = readyHandlers
        readyHandlers.removeAll()
        for handler in handlers { handler(self) }
    }

    nonisolated private static var pixelSide: Int { Int(tileSide * tileScale) }

    /// Renders `image` as one tile; nil if Core Image cannot.
    nonisolated private static func renderTile(_ image: CIImage) -> CGImage? {
        let side = CGFloat(pixelSide)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Working in gamma-encoded sRGB keeps the shading perceptually centred on the paper tone.
        let context = CIContext(options: [
            .workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false
        ])
        return context.createCGImage(image.cropped(to: bounds), from: bounds, format: .RGBA8, colorSpace: space)
    }

    private static func flatTile(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = tileScale
        format.opaque = true
        let size = CGSize(width: tileSide, height: tileSide)
        return UIGraphicsImageRenderer(size: size, format: format).image { canvas in
            color.setFill()
            canvas.fill(canvas.format.bounds)
        }
    }

    /// Paper texture: soft fibres of several lengths and directions over a fine tooth and a faint
    /// cloudy formation. Dark fibres are drawn stronger than light ones.
    nonisolated private static func paperFibres() -> CIImage {
        let light = fibres(lightFibreLayers)
        let dark = fibres(darkFibreLayers)
        let strands = mix(contrast(light, gain: 0.6, pivot: 0), inverted(dark), amount: 0.5)
        let tooth = contrast(blurred(noise(.paperTooth), radius: 1), gain: 6, pivot: 0.5)
        let formation = contrast(blurred(noise(.paperFormation), radius: 8), gain: 24, pivot: 0.5)
        let texture = mix(mix(formation, tooth, amount: 0.6), strands, amount: 0.6)
        // Subtracting a wide blur centres the texture on mid-grey, so the tile mean lands on the
        // paper colour however lopsided the fibres are.
        let centred = mix(texture, inverted(blurred(texture, radius: 32)), amount: 0.5)
        let grain = contrast(centred, gain: 2, pivot: 0.5)
        // The grain strays up to 0.03 per sRGB component from the paper: about 0.057 in relative
        // luminance at the darkest fibre, where thin ink still keeps about 94% of its contrast.
        return shade(grain, around: NotebookTheme.paperIvory.uiColor, spread: 0.03)
    }

    /// One direction and length of fibre, drawn from its own noise field.
    private struct FibreLayer {
        let field: NoiseField
        /// Direction of the strands in radians.
        let angle: Float
        /// Half the length of a strand in pixels.
        let reach: Float
    }

    nonisolated private static let lightFibreLayers = [
        FibreLayer(field: .paperLightFibresLong, angle: 0.45, reach: 8),
        FibreLayer(field: .paperLightFibresMedium, angle: 1.6, reach: 5),
        FibreLayer(field: .paperLightFibresShort, angle: 2.6, reach: 3),
    ]

    nonisolated private static let darkFibreLayers = [
        FibreLayer(field: .paperDarkFibresLong, angle: 1.15, reach: 8),
        FibreLayer(field: .paperDarkFibresMedium, angle: 2.15, reach: 5),
        FibreLayer(field: .paperDarkFibresShort, angle: 0.05, reach: 3),
    ]

    /// Every layer's strands together, softened so that no fibre has a hard edge.
    nonisolated private static func fibres(_ layers: [FibreLayer]) -> CIImage {
        let strands = layers.map { layer in
            // The rare peaks of lightly blurred noise become scattered seeds of a few pixels; the
            // motion blur draws each into a strand, rescaled so a lone strand reaches 30%.
            let seeds = levels(blurred(noise(layer.field), radius: 1), black: 0.7, white: 0.78)
            let strand = streaked(seeds, angle: layer.angle, radius: layer.reach)
            return levels(strand, black: 0, white: 0.3 / (2 * CGFloat(layer.reach)))
        }
        let union = strands.dropFirst().reduce(strands[0]) { maximum($0, $1) }
        return blurred(union, radius: 0.8)
    }

    /// Mutually independent random fields, one per texture ingredient.
    enum NoiseField: CaseIterable {
        case paperLightFibresLong
        case paperLightFibresMedium
        case paperLightFibresShort
        case paperDarkFibresLong
        case paperDarkFibresMedium
        case paperDarkFibresShort
        case paperTooth
        case paperFormation

        /// Generator channel the field reads; never alpha, which Core Image premultiplies.
        fileprivate var channel: Int {
            switch self {
            case .paperDarkFibresLong, .paperLightFibresMedium, .paperTooth: 0
            case .paperLightFibresShort, .paperDarkFibresShort, .paperFormation: 1
            case .paperLightFibresLong, .paperDarkFibresMedium: 2
            }
        }

        /// How each 256 px quadrant of the tile reorients the generator's single period. Fields
        /// that share a channel take different cyclic shifts of the rotations or of the flips, so
        /// they never use the same orientation in the same quadrant.
        fileprivate var quadrantOrientations: [NoiseOrientation] {
            switch self {
            case .paperLightFibresLong: NoiseOrientation.rotations
            case .paperLightFibresShort: NoiseOrientation.rotations.cycled(by: 1)
            case .paperDarkFibresMedium: NoiseOrientation.rotations.cycled(by: 2)
            case .paperDarkFibresLong: NoiseOrientation.flips
            case .paperLightFibresMedium: NoiseOrientation.flips.cycled(by: 1)
            case .paperDarkFibresShort: NoiseOrientation.flips.cycled(by: 2)
            case .paperTooth, .paperFormation: NoiseOrientation.flips.cycled(by: 3)
            }
        }
    }

    /// Single-channel noise that repeats exactly once per tile. `CIRandomGenerator` repeats every
    /// 256 px, so each quadrant of the 512 px tile shows that period in a different orientation;
    /// the tiled result still wraps without seams, so blurs carry across tile edges.
    nonisolated static func noise(_ field: NoiseField) -> CIImage {
        let period = generatorPeriod
        let window = CGRect(x: 0, y: 0, width: period, height: period)
        let source = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
        let patch = channel(field.channel, of: source.settingAlphaOne(in: window).cropped(to: window))
            .samplingNearest()
        let quadrants = field.quadrantOrientations.enumerated().map { index, orientation in
            patch
                .transformed(by: orientation.transform(side: period))
                .cropped(to: window)
                .transformed(by: CGAffineTransform(
                    translationX: CGFloat(index % 2) * period, y: CGFloat(index / 2) * period
                ))
        }
        let side = CGFloat(pixelSide)
        let tileImage = quadrants.dropFirst()
            .reduce(quadrants[0]) { $1.composited(over: $0) }
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            // Filters such as motion blur sample between pixels; nearest sampling keeps them
            // from mixing in the transparent edges of the quadrants.
            .samplingNearest()
        let tile = CIFilter.affineTile()
        tile.inputImage = tileImage
        tile.transform = .identity
        return tile.outputImage ?? tileImage
    }

    /// Period of `CIRandomGenerator` in pixels; the tile holds two periods along each side.
    nonisolated private static let generatorPeriod: CGFloat = 256

    nonisolated private static func channel(_ index: Int, of image: CIImage) -> CIImage {
        let pick = CIVector(x: index == 0 ? 1 : 0, y: index == 1 ? 1 : 0, z: index == 2 ? 1 : 0, w: 0)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = pick
        filter.gVector = pick
        filter.bVector = pick
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }

    nonisolated private static func blurred(_ image: CIImage, radius: Float) -> CIImage {
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image
        filter.radius = radius
        return filter.outputImage ?? image
    }

    nonisolated private static func streaked(_ image: CIImage, angle: Float, radius: Float) -> CIImage {
        let filter = CIFilter.motionBlur()
        filter.inputImage = image
        filter.radius = radius
        filter.angle = angle
        return filter.outputImage ?? image
    }

    /// Scales values around `pivot` and clamps them to the unit range.
    nonisolated private static func contrast(_ image: CIImage, gain: CGFloat, pivot: CGFloat) -> CIImage {
        clamped(image, gain: gain, bias: pivot - pivot * gain)
    }

    nonisolated private static func inverted(_ image: CIImage) -> CIImage {
        contrast(image, gain: -1, pivot: 0.5)
    }

    /// Stretches values from `black` to `white` over the unit range and clamps them.
    nonisolated private static func levels(_ image: CIImage, black: CGFloat, white: CGFloat) -> CIImage {
        let gain = 1 / (white - black)
        return clamped(image, gain: gain, bias: -black * gain)
    }

    /// value × gain + bias per colour channel, clamped to the unit range.
    nonisolated private static func clamped(_ image: CIImage, gain: CGFloat, bias: CGFloat) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = filter.outputImage
        return clamp.outputImage ?? image
    }

    nonisolated private static func maximum(_ image: CIImage, _ other: CIImage) -> CIImage {
        let filter = CIFilter.maximumCompositing()
        filter.inputImage = image
        filter.backgroundImage = other
        return filter.outputImage ?? image
    }

    nonisolated private static func mix(_ image: CIImage, _ other: CIImage, amount: Float) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = image
        filter.targetImage = other
        filter.time = amount
        return filter.outputImage ?? image
    }

    /// Maps mid-grey to `color` and the ends of the unit range to `color` minus and plus `spread`
    /// in every component. A false-colour ramp would clamp its light end colour to white, which for
    /// paper whose red lies within `spread` of white would pull mid-grey, and so the page, off its hue.
    nonisolated private static func shade(_ image: CIImage, around color: UIColor, spread: CGFloat) -> CIImage {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        let scale = CIVector(x: 2 * spread, y: 0, z: 0, w: 0)
        filter.rVector = scale
        filter.gVector = scale
        filter.bVector = scale
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: red - spread, y: green - spread, z: blue - spread, w: 0)
        return filter.outputImage ?? image
    }
}

/// Accessibility settings that ask for plain materials. Injectable so tests can toggle them.
@MainActor
struct NotebookMaterialAccessibility {
    static let statusChangeNotifications = [
        UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        UIAccessibility.darkerSystemColorsStatusDidChangeNotification
    ]

    let notificationCenter: NotificationCenter
    let isReduceTransparencyEnabled: @MainActor () -> Bool
    /// Increase Contrast, reported by UIKit as darker system colours.
    let isIncreaseContrastEnabled: @MainActor () -> Bool

    static var system: NotebookMaterialAccessibility {
        NotebookMaterialAccessibility(
            notificationCenter: .default,
            isReduceTransparencyEnabled: { UIAccessibility.isReduceTransparencyEnabled },
            isIncreaseContrastEnabled: { UIAccessibility.isDarkerSystemColorsEnabled }
        )
    }

    var prefersPlainMaterials: Bool {
        isReduceTransparencyEnabled() || isIncreaseContrastEnabled()
    }
}

/// One of the eight symmetries of a square, applied to a square of side `side` in place.
private enum NoiseOrientation {
    case identity
    case quarterTurn
    case halfTurn
    case threeQuarterTurn
    case horizontalFlip
    case verticalFlip
    case diagonalFlip
    case antidiagonalFlip

    static let rotations: [NoiseOrientation] = [.identity, .quarterTurn, .halfTurn, .threeQuarterTurn]
    static let flips: [NoiseOrientation] = [.verticalFlip, .antidiagonalFlip, .horizontalFlip, .diagonalFlip]

    func transform(side: CGFloat) -> CGAffineTransform {
        switch self {
        case .identity: .identity
        case .quarterTurn: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: side, ty: 0)
        case .halfTurn: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: side, ty: side)
        case .threeQuarterTurn: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: side)
        case .horizontalFlip: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: side, ty: 0)
        case .verticalFlip: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: side)
        case .diagonalFlip: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .antidiagonalFlip: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: side, ty: side)
        }
    }
}

private extension [NoiseOrientation] {
    /// The orientations moved `steps` quadrants earlier, wrapping around.
    func cycled(by steps: Int) -> [NoiseOrientation] {
        indices.map { self[($0 + steps) % count] }
    }
}
