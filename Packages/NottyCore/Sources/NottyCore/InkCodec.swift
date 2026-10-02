import Foundation
import PencilKit

@available(iOS 27.0, macOS 27.0, *)
public actor InkCodec {
    public enum CodecError: Error, Sendable {
        case duplicateStrokeID
        case invalidSingleStrokeArchive
        case oversizedStrokeArchive
    }

    public static let maximumStrokeBytes = 10 * 1_024 * 1_024
    public private(set) var serializedStrokeCount = 0

    private struct CachedStroke {
        let drawing: PKDrawing
        let data: Data
    }

    private var cache: [UUID: CachedStroke] = [:]

    public init() {}

    public func encode(_ drawing: PKDrawing) throws -> [NotebookStroke] {
        var identities = Set<UUID>()
        for stroke in drawing.strokes {
            guard identities.insert(stroke.id).inserted else {
                throw CodecError.duplicateStrokeID
            }
        }

        var nextCache: [UUID: CachedStroke] = [:]
        var result: [NotebookStroke] = []
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
            nextCache[stroke.id] = CachedStroke(drawing: single, data: data)
            result.append(NotebookStroke(id: stroke.id, data: data))
        }

        cache = nextCache
        return result
    }

    public func decode(_ assets: [NotebookStroke]) throws -> PKDrawing {
        var identities = Set<UUID>()
        for asset in assets {
            guard identities.insert(asset.id).inserted else {
                throw CodecError.duplicateStrokeID
            }
        }

        var strokes: [PKStroke] = []
        var nextCache: [UUID: CachedStroke] = [:]
        strokes.reserveCapacity(assets.count)

        for asset in assets {
            guard asset.data.count <= Self.maximumStrokeBytes else {
                throw CodecError.oversizedStrokeArchive
            }
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
