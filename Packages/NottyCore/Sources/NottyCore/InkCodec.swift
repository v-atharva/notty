import CoreGraphics
import Foundation
import PencilKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 27.0, macOS 27.0, *)
public actor InkCodec {
    public enum CodecError: Error, Sendable {
        case duplicateStrokeID
        case invalidSingleStrokeArchive
        case oversizedStrokeArchive
        case tooManyStrokes
        case oversizedDrawingArchive
        case invalidMaskGeometry
    }

    public static let maximumStrokeBytes = 10 * 1_024 * 1_024
    public static let maximumStrokeCount = 10_000
    public static let maximumDrawingBytes = 64 * 1_024 * 1_024
    public private(set) var serializedStrokeCount = 0

    private let strokeLimit: Int
    private let byteLimit: Int
    var cachedStrokeCount: Int { cache.count }

    private struct CachedStroke {
        let signature: StrokeSignature
        let data: Data
    }

    private struct StrokeSignature: Equatable {
        let path: PKStrokePath
        let transform: CGAffineTransform
        let inkType: PKInk.InkType
        let color: CGColor
        let randomSeed: UInt32
        let mask: CGPath?
        let evenOddFill: Bool
        let renderGroupID: UUID?
        let renderState: PKStroke.RenderState?

        init(_ stroke: PKStroke) throws {
            path = stroke.path
            transform = stroke.transform
            inkType = stroke.ink.inkType
            color = stroke.ink.color.cgColor
            randomSeed = stroke.randomSeed
            renderGroupID = stroke.renderGroupID
            renderState = stroke.renderState

            if let nativeMask = stroke.mask {
                guard let copy = nativeMask.cgPath.copy() else {
                    throw CodecError.invalidMaskGeometry
                }
                mask = copy
                #if canImport(UIKit)
                evenOddFill = nativeMask.usesEvenOddFillRule
                #else
                evenOddFill = nativeMask.windingRule == .evenOdd
                #endif
            } else {
                mask = nil
                evenOddFill = false
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.path.id == rhs.path.id,
                  lhs.path.creationDate == rhs.path.creationDate,
                  lhs.path.count == rhs.path.count,
                  lhs.transform == rhs.transform,
                  lhs.inkType == rhs.inkType,
                  lhs.color == rhs.color,
                  lhs.randomSeed == rhs.randomSeed,
                  lhs.mask == rhs.mask,
                  lhs.evenOddFill == rhs.evenOddFill,
                  lhs.renderGroupID == rhs.renderGroupID,
                  lhs.renderState == rhs.renderState else {
                return false
            }

            return lhs.path.elementsEqual(rhs.path) { first, second in
                first.location == second.location
                    && first.timeOffset == second.timeOffset
                    && first.size == second.size
                    && first.opacity == second.opacity
                    && first.force == second.force
                    && first.azimuth == second.azimuth
                    && first.altitude == second.altitude
                    && first.secondaryScale == second.secondaryScale
                    && first.threshold == second.threshold
                    && first.lateralJitter == second.lateralJitter
            }
        }
    }

    private var cache: [UUID: CachedStroke] = [:]

    public init() {
        strokeLimit = Self.maximumStrokeCount
        byteLimit = Self.maximumDrawingBytes
    }

    init(maximumStrokeCount: Int, maximumDrawingBytes: Int) {
        precondition(maximumStrokeCount >= 0 && maximumDrawingBytes >= 0)
        strokeLimit = maximumStrokeCount
        byteLimit = maximumDrawingBytes
    }

    public func encode(_ drawing: PKDrawing) throws -> [NotebookStroke] {
        guard drawing.strokes.count <= strokeLimit else {
            throw CodecError.tooManyStrokes
        }
        var identities = Set<UUID>()
        for stroke in drawing.strokes {
            guard identities.insert(stroke.id).inserted else {
                throw CodecError.duplicateStrokeID
            }
        }

        var nextCache: [UUID: CachedStroke] = [:]
        var result: [NotebookStroke] = []
        var totalBytes = 0
        result.reserveCapacity(drawing.strokes.count)

        for stroke in drawing.strokes {
            let signature = try StrokeSignature(stroke)
            let data: Data
            if let existing = cache[stroke.id], existing.signature == signature {
                data = existing.data
            } else {
                data = PKDrawing(strokes: [stroke]).dataRepresentation()
                guard data.count <= Self.maximumStrokeBytes else {
                    throw CodecError.oversizedStrokeArchive
                }
                serializedStrokeCount += 1
            }
            guard data.count <= byteLimit - totalBytes else {
                throw CodecError.oversizedDrawingArchive
            }
            totalBytes += data.count
            nextCache[stroke.id] = CachedStroke(signature: signature, data: data)
            result.append(NotebookStroke(id: stroke.id, data: data))
        }

        cache = nextCache
        return result
    }

    public func decode(_ assets: [NotebookStroke]) throws -> PKDrawing {
        guard assets.count <= strokeLimit else {
            throw CodecError.tooManyStrokes
        }
        var identities = Set<UUID>()
        for asset in assets {
            guard identities.insert(asset.id).inserted else {
                throw CodecError.duplicateStrokeID
            }
        }

        var strokes: [PKStroke] = []
        var totalBytes = 0
        var nextCache: [UUID: CachedStroke] = [:]
        strokes.reserveCapacity(assets.count)

        for asset in assets {
            guard asset.data.count <= Self.maximumStrokeBytes else {
                throw CodecError.oversizedStrokeArchive
            }
            guard asset.data.count <= byteLimit - totalBytes else {
                throw CodecError.oversizedDrawingArchive
            }
            totalBytes += asset.data.count
            let archive = try PKDrawing(data: asset.data)
            guard archive.strokes.count == 1, var stroke = archive.strokes.first else {
                throw CodecError.invalidSingleStrokeArchive
            }

            // The manifest identity remains authoritative across archive versions.
            stroke.id = asset.id
            let signature = try StrokeSignature(stroke)
            nextCache[asset.id] = CachedStroke(signature: signature, data: asset.data)
            strokes.append(stroke)
        }

        cache = nextCache
        return PKDrawing(strokes: strokes)
    }
}
