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
        case invalidRestoredStrokeIdentity
    }

    public struct WorkMetrics: Sendable, Equatable {
        public fileprivate(set) var serializedStrokes = 0
        public fileprivate(set) var comparedPoints = 0
        public fileprivate(set) var signatureChecks = 0
        public fileprivate(set) var hashedArchiveBytes = 0
        public fileprivate(set) var copiedArchiveBytes = 0
        public fileprivate(set) var maskSnapshots = 0
        public fileprivate(set) var comparedMaskPaths = 0
        public fileprivate(set) var encodedRenderStates = 0
        public fileprivate(set) var renderStateBytes = 0
        public fileprivate(set) var renderStateFallbacks = 0
        public fileprivate(set) var maskFallbacks = 0
        public fileprivate(set) var propertyListRenderStates = 0
        public fileprivate(set) var nativeDrawingFallbackSnapshots = 0
        public fileprivate(set) var nativeDrawingEqualityFallbacks = 0
        public fileprivate(set) var uncacheableStrokeSignatures = 0
    }

    public static let maximumStrokeBytes = 10 * 1_024 * 1_024
    public static let maximumStrokeCount = 10_000
    public static let maximumDrawingBytes = 64 * 1_024 * 1_024
    static let maximumRetiredStrokeCount = 64
    static let maximumRetiredBytes = 8 * 1_024 * 1_024
    public var serializedStrokeCount: Int { workMetrics.serializedStrokes }

    private let strokeLimit: Int
    private let byteLimit: Int
    private let retiredCountLimit: Int
    private let retiredByteLimit: Int
    private let forceRenderStateEncodingFallback: Bool
    private let forceNativeDrawingEqualityFallback: Bool
    private(set) var workMetrics = WorkMetrics()
    var cachedStrokeCount: Int { cache.count }
    var retiredStrokeCount: Int { retired.count }
    var retiredArchiveBytes: Int { retiredBytes }

    private struct CachedStroke {
        let signature: StrokeSignature
        let asset: NotebookStroke
    }

    fileprivate struct StrokeSignature {
        let path: PKStrokePath
        let transform: CGAffineTransform
        let inkType: PKInk.InkType
        let color: CGColor
        let randomSeed: UInt32
        let mask: CGPath?
        let evenOddFill: Bool
        let renderGroupID: UUID?
        let renderState: Data?
        let requiresNativeDrawingFallback: Bool

        init(
            _ stroke: PKStroke, work: inout WorkMetrics,
            forceRenderStateEncodingFallback: Bool = false,
            forceNativeDrawingEqualityFallback: Bool = false
        ) throws {
            work.signatureChecks += 1
            path = stroke.path
            transform = stroke.transform
            inkType = stroke.ink.inkType
            color = stroke.ink.color.cgColor
            randomSeed = stroke.randomSeed
            renderGroupID = stroke.renderGroupID
            var requiresFallback = false

            if let state = stroke.renderState {
                work.encodedRenderStates += 1
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.nonConformingFloatEncodingStrategy = .convertToString(
                    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
                )
                let json = forceRenderStateEncodingFallback || forceNativeDrawingEqualityFallback
                    ? nil : (try? encoder.encode(state))
                if let json {
                    renderState = json
                    work.renderStateBytes += json.count
                } else {
                    work.renderStateFallbacks += 1
                    work.encodedRenderStates += 1
                    work.propertyListRenderStates += 1
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    let binary = forceNativeDrawingEqualityFallback ? nil : try? encoder.encode(state)
                    if let binary {
                        renderState = binary
                        work.renderStateBytes += binary.count
                    } else {
                        renderState = nil
                        requiresFallback = true
                    }
                }
            } else {
                renderState = nil
            }

            if let nativeMask = stroke.mask {
                work.maskSnapshots += 1
                mask = nativeMask.cgPath.copy()
                if mask == nil {
                    work.maskFallbacks += 1
                    requiresFallback = true
                }
                #if canImport(UIKit)
                evenOddFill = nativeMask.usesEvenOddFillRule
                #else
                evenOddFill = nativeMask.windingRule == .evenOdd
                #endif
            } else {
                mask = nil
                evenOddFill = false
            }
            requiresNativeDrawingFallback = requiresFallback
            if requiresFallback { work.uncacheableStrokeSignatures += 1 }
        }

        func matches(_ other: Self, work: inout WorkMetrics) -> Bool {
            work.signatureChecks += 1
            guard !requiresNativeDrawingFallback, !other.requiresNativeDrawingFallback else {
                return false
            }
            guard path.id == other.path.id,
                  path.creationDate == other.path.creationDate,
                  path.count == other.path.count,
                  transform == other.transform,
                  inkType == other.inkType,
                  color == other.color,
                  randomSeed == other.randomSeed,
                  evenOddFill == other.evenOddFill,
                  renderGroupID == other.renderGroupID,
                  renderState == other.renderState else {
                return false
            }
            if mask != nil || other.mask != nil {
                work.comparedMaskPaths += 1
            }
            guard mask == other.mask else { return false }
            for (first, second) in zip(path, other.path) {
                work.comparedPoints += 1
                guard first.location == second.location,
                      first.timeOffset == second.timeOffset,
                      first.size == second.size,
                      first.opacity == second.opacity,
                      first.force == second.force,
                      first.azimuth == second.azimuth,
                      first.altitude == second.altitude,
                      first.secondaryScale == second.secondaryScale,
                      first.threshold == second.threshold,
                      first.lateralJitter == second.lateralJitter else {
                    return false
                }
            }
            return true
        }
    }

    private var cache: [UUID: CachedStroke] = [:]
    private var retired: [UUID: CachedStroke] = [:]
    private var retiredOrder: [UUID] = []
    private var retiredBytes = 0

    public init() {
        strokeLimit = Self.maximumStrokeCount
        byteLimit = Self.maximumDrawingBytes
        retiredCountLimit = Self.maximumRetiredStrokeCount
        retiredByteLimit = Self.maximumRetiredBytes
        forceRenderStateEncodingFallback = false
        forceNativeDrawingEqualityFallback = false
    }

    init(
        maximumStrokeCount: Int,
        maximumDrawingBytes: Int,
        maximumRetiredStrokeCount: Int = InkCodec.maximumRetiredStrokeCount,
        maximumRetiredBytes: Int = InkCodec.maximumRetiredBytes,
        forceRenderStateEncodingFallback: Bool = false,
        forceNativeDrawingEqualityFallback: Bool = false
    ) {
        precondition(maximumStrokeCount >= 0 && maximumDrawingBytes >= 0)
        precondition(maximumRetiredStrokeCount >= 0 && maximumRetiredBytes >= 0)
        strokeLimit = maximumStrokeCount
        byteLimit = maximumDrawingBytes
        retiredCountLimit = maximumRetiredStrokeCount
        retiredByteLimit = maximumRetiredBytes
        self.forceRenderStateEncodingFallback = forceRenderStateEncodingFallback
        self.forceNativeDrawingEqualityFallback = forceNativeDrawingEqualityFallback
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
            let signature = try StrokeSignature(
                stroke, work: &workMetrics,
                forceRenderStateEncodingFallback: forceRenderStateEncodingFallback,
                forceNativeDrawingEqualityFallback: forceNativeDrawingEqualityFallback
            )
            let asset: NotebookStroke
            if let existing = cache[stroke.id] ?? retired[stroke.id],
               existing.signature.matches(signature, work: &workMetrics) {
                asset = existing.asset
            } else {
                let archive = PKDrawing(strokes: [stroke]).dataRepresentation()
                workMetrics.serializedStrokes += 1
                guard archive.count <= Self.maximumStrokeBytes else {
                    throw CodecError.oversizedStrokeArchive
                }
                asset = ownedAsset(id: stroke.id, data: archive)
            }
            guard asset.data.count <= byteLimit - totalBytes else {
                throw CodecError.oversizedDrawingArchive
            }
            totalBytes += asset.data.count
            nextCache[stroke.id] = CachedStroke(signature: signature, asset: asset)
            result.append(asset)
        }

        commit(nextCache)
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
            let owned = ownedAsset(id: asset.id, data: asset.data)
            let archive = try PKDrawing(data: owned.data)
            guard archive.strokes.count == 1, var stroke = archive.strokes.first else {
                throw CodecError.invalidSingleStrokeArchive
            }
            // Manifest identities remain authoritative across archive versions.
            stroke.id = asset.id
            let signature = try StrokeSignature(
                stroke, work: &workMetrics,
                forceRenderStateEncodingFallback: forceRenderStateEncodingFallback,
                forceNativeDrawingEqualityFallback: forceNativeDrawingEqualityFallback
            )
            nextCache[asset.id] = CachedStroke(signature: signature, asset: owned)
            strokes.append(stroke)
        }

        let drawing = PKDrawing(strokes: strokes)
        guard drawing.strokes.map(\.id) == assets.map(\.id) else {
            throw CodecError.invalidRestoredStrokeIdentity
        }
        commit(nextCache)
        return drawing
    }

    private func ownedAsset(id: UUID, data: Data) -> NotebookStroke {
        let owned = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return Data() }
            return Data(bytes: base, count: bytes.count)
        }
        workMetrics.copiedArchiveBytes += owned.count
        workMetrics.hashedArchiveBytes += owned.count
        return NotebookStroke(id: id, data: owned, validatedDigest: NotebookDigest.sha256(owned))
    }

    private func commit(_ nextCache: [UUID: CachedStroke]) {
        for id in nextCache.keys {
            if let removed = retired.removeValue(forKey: id) {
                retiredBytes -= removed.asset.data.count
                retiredOrder.removeAll { $0 == id }
            }
        }
        for (id, entry) in cache where nextCache[id] == nil {
            if let replaced = retired.updateValue(entry, forKey: id) {
                retiredBytes -= replaced.asset.data.count
                retiredOrder.removeAll { $0 == id }
            }
            retiredBytes += entry.asset.data.count
            retiredOrder.append(id)
        }
        while retired.count > retiredCountLimit || retiredBytes > retiredByteLimit {
            guard let id = retiredOrder.first else { break }
            retiredOrder.removeFirst()
            if let removed = retired.removeValue(forKey: id) {
                retiredBytes -= removed.asset.data.count
            }
        }
        cache = nextCache
    }
}

@available(iOS 27.0, macOS 27.0, *)
// Native paths and colors are immutable; mask geometry and render state are owned snapshots.
public struct InkDrawingSignature: @unchecked Sendable, Equatable {
    public struct Comparison: Sendable {
        public let isEqual: Bool
        public let work: InkCodec.WorkMetrics
    }

    private struct Entry {
        let id: UUID
        let stroke: InkCodec.StrokeSignature
    }

    private let entries: [Entry]
    private let nativeDrawingFallback: PKDrawing?
    private let captureID = UUID()
    public let constructionWork: InkCodec.WorkMetrics

    public init(_ drawing: PKDrawing) throws {
        try self.init(
            drawing, forceRenderStateEncodingFallback: false,
            forceNativeDrawingEqualityFallback: false
        )
    }

    init(
        _ drawing: PKDrawing, forceRenderStateEncodingFallback: Bool,
        forceNativeDrawingEqualityFallback: Bool = false
    ) throws {
        var work = InkCodec.WorkMetrics()
        var entries: [Entry] = []
        entries.reserveCapacity(drawing.strokes.count)
        for stroke in drawing.strokes {
            let signature = try InkCodec.StrokeSignature(
                stroke, work: &work,
                forceRenderStateEncodingFallback: forceRenderStateEncodingFallback,
                forceNativeDrawingEqualityFallback: forceNativeDrawingEqualityFallback
            )
            entries.append(Entry(id: stroke.id, stroke: signature))
        }
        self.entries = entries
        if entries.contains(where: { $0.stroke.requiresNativeDrawingFallback }) {
            nativeDrawingFallback = drawing
            work.nativeDrawingFallbackSnapshots += 1
        } else {
            nativeDrawingFallback = nil
        }
        constructionWork = work
    }

    public func compared(to other: Self) -> Comparison {
        var work = InkCodec.WorkMetrics()
        if captureID == other.captureID {
            return Comparison(isEqual: true, work: work)
        }
        if nativeDrawingFallback != nil || other.nativeDrawingFallback != nil {
            guard let first = nativeDrawingFallback, let second = other.nativeDrawingFallback else {
                return Comparison(isEqual: false, work: work)
            }
            work.nativeDrawingEqualityFallbacks += 1
            return Comparison(isEqual: first == second, work: work)
        }
        guard entries.count == other.entries.count else {
            return Comparison(isEqual: false, work: work)
        }
        for (first, second) in zip(entries, other.entries) {
            guard first.id == second.id,
                  first.stroke.matches(second.stroke, work: &work) else {
                return Comparison(isEqual: false, work: work)
            }
        }
        return Comparison(isEqual: true, work: work)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.compared(to: rhs).isEqual
    }
}
