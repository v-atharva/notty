import Foundation
import PencilKit

@available(iOS 27.0, macOS 27.0, *)
public actor InkCodec {
    public enum CodecError: Error, Sendable {
        case duplicateStrokeID
        case invalidSingleStrokeArchive
        case oversizedStrokeArchive
        case tooManyStrokes
        case oversizedDrawingArchive
    }

    public static let maximumStrokeBytes = 10 * 1_024 * 1_024
    public static let maximumStrokeCount = 10_000
    public static let maximumDrawingBytes = 64 * 1_024 * 1_024
    public private(set) var serializedStrokeCount = 0

    private let strokeLimit: Int
    private let byteLimit: Int
    var cachedStrokeCount: Int { cache.count }

    private struct CachedStroke {
        let drawing: PKDrawing
        let data: Data
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
            let single = PKDrawing(strokes: [stroke])
            let data: Data
            if let existing = cache[stroke.id], existing.drawing == single {
                data = existing.data
            } else {
                data = single.dataRepresentation()
                guard data.count <= Self.maximumStrokeBytes else {
                    throw CodecError.oversizedStrokeArchive
                }
                serializedStrokeCount += 1
            }
            guard data.count <= byteLimit - totalBytes else {
                throw CodecError.oversizedDrawingArchive
            }
            totalBytes += data.count
            nextCache[stroke.id] = CachedStroke(drawing: single, data: data)
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
            let single = PKDrawing(strokes: [stroke])
            nextCache[asset.id] = CachedStroke(drawing: single, data: asset.data)
            strokes.append(stroke)
        }

        cache = nextCache
        return PKDrawing(strokes: strokes)
    }
}
