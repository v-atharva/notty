import NottyCore
import SwiftUI
import UIKit

/// The single source of colours, metrics and typography for the retro notebook editor:
/// ivory writing paper on a warm stone backdrop and a pale ivory-gray toolbar with shallow depth.
/// Values are proposals for review on the device. The editor forces the light appearance,
/// so each token has one value.
enum NotebookTheme {
    /// A colour defined once and read from UIKit or SwiftUI.
    struct Tone: Sendable {
        let uiColor: UIColor

        var color: Color { Color(uiColor: uiColor) }
        var cgColor: CGColor { uiColor.cgColor }

        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
            uiColor = UIColor(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// A drop shadow drawn under a SwiftUI view.
    struct Shadow: Sendable {
        let tone: Tone
        let radius: CGFloat
        let offset: CGSize
        let opacity: Double

        var color: Color { tone.color.opacity(opacity) }
    }

    /// A text role scaled with Dynamic Type.
    struct Typeface: Sendable {
        enum Weight: Sendable {
            case medium
            case semibold

            var swiftUI: Font.Weight {
                switch self {
                case .medium: .medium
                case .semibold: .semibold
                }
            }
        }

        enum Style: Sendable {
            case title3
            case headline
            case footnote

            var swiftUI: Font.TextStyle {
                switch self {
                case .title3: .title3
                case .headline: .headline
                case .footnote: .footnote
                }
            }
        }

        /// A bundled typewriter face such as Berkeley Mono; `nil` selects the system face.
        let postScriptName: String?
        /// Size at the default content size; Dynamic Type scales from here along `style`.
        let pointSize: CGFloat
        let style: Style
        /// Weight of the system face, and of the monospaced fallback when the named face is missing.
        let weight: Weight

        var font: Font {
            guard let postScriptName else {
                return .system(style.swiftUI, weight: weight.swiftUI)
            }
            // Font.custom silently falls back to the proportional system face, so check first
            // and keep the typewriter character with the system monospaced design instead.
            guard UIFont(name: postScriptName, size: pointSize) != nil else {
                return .system(style.swiftUI, design: .monospaced, weight: weight.swiftUI)
            }
            return .custom(postScriptName, size: pointSize, relativeTo: style.swiftUI)
        }
    }

    // MARK: - Paper and backdrop

    /// Writing paper, the head margin above page 1, and the colour the fibre texture averages to.
    static let paperIvory = Tone(red: 0.98, green: 0.96, blue: 0.91)
    /// Hairline where the paper meets the backdrop, along its sides and below the last page.
    static let paperEdge = Tone(red: 0.47, green: 0.40, blue: 0.31, alpha: 0.65)
    /// Page divisions, including the top of page 1 below the head margin.
    static let paperDivider = Tone(red: 0.47, green: 0.40, blue: 0.31, alpha: 0.30)
    /// Flat stone wherever there is no paper, without fibres, so nothing outside a page reads
    /// as writable.
    static let backdropStone = Tone(red: 0.812, green: 0.792, blue: 0.749)
    /// Paper continues this far above page 1, so the space reserved for the chrome, the status
    /// bar and overscroll at the top all show paper rather than stone.
    static let headMarginLength: CGFloat = 600
    /// Gradient band below the last page; it zooms with the page, so nothing blurs per frame.
    static let pageShadowDepth: CGFloat = 6
    static let pageShadowOpacity: CGFloat = 0.18
    /// Narrower, lighter bands along the page sides, seen only when the page is narrower than
    /// the screen or pulled away from a side.
    static let pageSideShadowDepth: CGFloat = 3
    static let pageSideShadowOpacity: CGFloat = 0.12
    /// Tint of buttons and links on paper-toned surfaces, such as the screen behind the
    /// notebook and its sheets.
    static let paperControlTint = Tone(red: 0.36, green: 0.29, blue: 0.22)

    // MARK: - Toolbar

    /// Toolbar shell fill, a pale ivory-gray a step cooler than the paper so the two read apart.
    static let toolbarSurface = Tone(red: 0.93, green: 0.915, blue: 0.875)
    /// One-point top edge highlight that lifts the shell off the paper.
    static let toolbarHighlight = Tone(red: 0.99, green: 0.98, blue: 0.96)
    /// Lower edge of the shell and of raised controls, giving the shallow bevel.
    static let toolbarLowerEdge = Tone(red: 0.80, green: 0.77, blue: 0.71)
    /// Colour of the toolbar drop shadow and the page shading; warm so neither grays the paper
    /// or the stone.
    static let toolbarShadowTone = Tone(red: 0.24, green: 0.17, blue: 0.11)
    /// Inset well behind the selected tool, swatch or width control.
    static let selectedWell = Tone(red: 0.79, green: 0.77, blue: 0.72)
    /// Tool glyphs, the selection mark and toolbar labels.
    static let glyph = Tone(red: 0.17, green: 0.16, blue: 0.15)
    /// Glyphs of controls that are unavailable, and of the whole toolbar while writing is paused.
    static let disabledGlyph = Tone(red: 0.52, green: 0.50, blue: 0.47)
    /// Hairlines between tool groups and between the tool and swatch rows.
    static let toolbarDivider = Tone(red: 0.70, green: 0.67, blue: 0.61)

    // MARK: - Toolbar metrics

    /// Corner radius of the toolbar shell and the collapsed handle.
    static let toolbarCornerRadius: CGFloat = 18
    /// Corner radius of the inset well behind the selected control.
    static let selectedWellCornerRadius: CGFloat = 11
    /// Stroke width of the shell outline and its edge highlight.
    static let shellBorderWidth: CGFloat = 1
    /// Thickness of toolbar dividers.
    static let dividerThickness: CGFloat = 1
    /// Side of every tappable toolbar control; meets the 44 pt minimum touch target.
    static let controlSize: CGFloat = 44
    /// Point size of tool symbols; fixed so the strip height is stable, with the Large Content Viewer for accessibility sizes.
    static let glyphSize: CGFloat = 22
    /// Diameter of a colour swatch inside its 44 pt control.
    static let swatchDiameter: CGFloat = 28
    /// Height of each toolbar row: one control plus the vertical strip insets.
    static let rowHeight: CGFloat = controlSize + stripInsets.top + stripInsets.bottom
    /// Vertical gap between the tool row and the swatch row; the row divider sits in it.
    static let rowSpacing: CGFloat = 4
    /// Horizontal gap between neighbouring controls in a row.
    static let itemSpacing: CGFloat = 6
    /// Padding inside each scrolling strip, between the shell edge and the first control.
    static let stripInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    /// SwiftUI form of `stripInsets`.
    static var stripEdgeInsets: EdgeInsets {
        EdgeInsets(top: stripInsets.top, leading: stripInsets.left, bottom: stripInsets.bottom, trailing: stripInsets.right)
    }
    /// Visible grip pill on the toolbar's drag handle.
    static let dragHandleSize = CGSize(width: 36, height: 5)
    /// Touch region of the drag handle, kept separate from the tool strips.
    static let dragHandleHitSize = CGSize(width: controlSize, height: controlSize)
    /// Collapsed floating toolbar; it is the reveal control, so both sides are at least 44 pt.
    static let collapsedHandleSize = CGSize(width: 56, height: 44)
    /// Shallow drop shadow under the toolbar shell and collapsed handle.
    static let toolbarShadow = Shadow(tone: toolbarShadowTone, radius: 6, offset: CGSize(width: 0, height: 2), opacity: 0.18)
    /// Opacity of the whole toolbar while writing is paused, on top of the disabled glyph tone.
    static let disabledOpacity = 0.55
    /// A pressed control sinks into a lighter well than a selected one.
    static let pressedWellOpacity = 0.5
    /// Inner shadow that recesses the selected well below the shell.
    static let wellShadowOpacity = 0.35
    static let wellShadowRadius: CGFloat = 2
    static let wellShadowDepth: CGFloat = 1
    /// The bar under a selected glyph or width dot, so selection never relies on colour alone.
    static let selectionMarkSize = CGSize(width: 14, height: 3)
    static let selectionMarkInset: CGFloat = 4
    /// Length of the hairline between tool groups.
    static let dividerLength: CGFloat = 28
    /// The visible preset capsule; the chip still keeps a full control height for touch.
    static let presetChipHeight: CGFloat = 32
    static let presetChipPadding: CGFloat = 12
    static let presetDotDiameter: CGFloat = 10
    static let presetCheckmarkSize: CGFloat = 11
    static let swatchCheckmarkSize: CGFloat = 12
    /// Point size of the chevrons that page a scrolling strip.
    static let chevronSize: CGFloat = 15
    /// Seconds a chevron tap takes to page a strip.
    static let stripPageDuration = 0.25
    /// Compact-width chip that shows the current ink and opens the ink panel.
    static let currentInkChipWidth: CGFloat = 56
    static let currentInkSwatchDiameter: CGFloat = 20
    static let inkPanelWidth: CGFloat = 320
    static let inkPanelPadding: CGFloat = 16
    static let inkPanelSectionSpacing: CGFloat = 12
    /// Wide enough for the longest preset name at the default text size.
    static let presetColumnMinimum: CGFloat = 150

    // MARK: - Dock targets

    /// Fill of a dock target while a toolbar is dragged, and of the target it would land in.
    static let dockSlotFillOpacity = 0.3
    static let dockSlotTargetedFillOpacity = 0.7
    /// Dashed outline of every dock target, drawn in the glyph tone.
    static let dockSlotOutlineOpacity = 0.55
    static let dockSlotOutline = StrokeStyle(lineWidth: 1.5, dash: [6, 4])

    // MARK: - Typography

    // Berkeley Mono, bundled through UIAppFonts, is the typewriter face of the wordmark and
    // the note title. It never reaches controls or handwriting.

    /// The "notty" wordmark at the leading end of the navigation bar.
    static let wordmark = Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 20, style: .title3, weight: .medium)
    /// Note title on the navigation bar.
    static let noteTitle = Typeface(postScriptName: "BerkeleyMono-SemiBold", pointSize: 17, style: .headline, weight: .semibold)
    /// Toolbar and menu labels; the system face keeps dense controls legible.
    static let controlLabel = Typeface(postScriptName: nil, pointSize: 13, style: .footnote, weight: .medium)
    /// Font that sizes tool glyphs.
    static var glyphFont: Font { .system(size: glyphSize, weight: .regular) }
}
