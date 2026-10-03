import CryptoKit
import Foundation
import XCTest
@testable import NottyCore

enum NotebookHistoryTestFixtures {
    struct LegacyFixture {
        let notebookID: UUID
        let states: [StoredNotebook]
        let headData: Data
        let originalFiles: [String: Data]
        let orphanRevisionID: UUID
    }

    struct Layout {
        let notebookDirectory: URL
        let generationDirectory: URL
        let generationID: UUID

        var eventsDirectory: URL {
            generationDirectory.appendingPathComponent("events", isDirectory: true)
        }

        var checkpointsDirectory: URL {
            generationDirectory.appendingPathComponent("checkpoints", isDirectory: true)
        }

        func eventURL(_ revisionID: UUID) -> URL {
            eventsDirectory.appendingPathComponent(revisionID.uuidString.lowercased() + ".json")
        }

        func checkpointURL(_ digest: String) -> URL {
            checkpointsDirectory.appendingPathComponent(digest + ".json")
        }
    }

    enum FixtureError: Error {
        case malformedMetadata
        case missingGeneration
    }

    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func noteDirectory(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    static func asset(index: Int, bytes: Int = 1_024, id: UUID = UUID()) -> NotebookStroke {
        var data = Data(repeating: UInt8(index % 251), count: bytes)
        let value = UInt64(index)
        for offset in 0..<min(8, bytes) {
            data[offset] = UInt8((value >> (offset * 8)) & 255)
        }
        return NotebookStroke(id: id, data: data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stamp(_ index: Int) -> NotebookEditStamp {
        NotebookEditStamp(
            capturedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 3.125),
            uptime: Double(index) * 0.125,
            sessionID: UUID(uuidString: "ABB4E8CA-CB63-4F64-A158-8A62324AB7AE")!
        )
    }

    static func contents() -> [NotebookContent] {
        let first = asset(index: 1)
        let second = asset(index: 2)
        let changed = asset(index: 3, id: first.id)
        let moved = asset(index: 4, id: first.id)
        let drawings: [[NotebookStroke]] = [
            [], [first], [first, second], [changed, second], [moved, second],
            [moved], [moved, second], [second, moved], [second, moved],
            [second, moved], [changed, second]
        ]
        return drawings.enumerated().map { index, strokes in
            NotebookContent(
                title: index >= 8 ? "Mechanics review" : "Mechanics",
                pageCount: index >= 9 ? 5 : 3,
                strokes: strokes,
                editStamp: index == 0 ? nil : stamp(index)
            )
        }
    }

    static func object(at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any] else {
            throw FixtureError.malformedMetadata
        }
        return object
    }

    static func layout(root: URL, id: UUID) throws -> Layout {
        let directory = noteDirectory(root: root, id: id)
        let head = try object(at: directory.appendingPathComponent("HEAD.json"))
        guard head["schemaVersion"] as? Int == 2,
              let raw = head["generationID"] as? String,
              let generation = UUID(uuidString: raw) else {
            throw FixtureError.missingGeneration
        }
        let selected = directory.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(generation.uuidString.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: selected.path) else {
            throw FixtureError.missingGeneration
        }
        return Layout(
            notebookDirectory: directory, generationDirectory: selected, generationID: generation
        )
    }

    static func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw FixtureError.malformedMetadata }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func byteCount(in directory: URL) throws -> Int {
        try regularFiles(in: directory).reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    static func snapshot(in directory: URL) throws -> [String: Data] {
        let prefix = directory.path + "/"
        return try Dictionary(uniqueKeysWithValues: regularFiles(in: directory).map { url in
            (String(url.path.dropFirst(prefix.count)), try Data(contentsOf: url))
        })
    }

    static func writeLegacy(
        root: URL, contents: [NotebookContent] = NotebookHistoryTestFixtures.contents()
    ) throws -> LegacyFixture {
        let id = UUID()
        let directory = noteDirectory(root: root, id: id)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        let revisions = directory.appendingPathComponent("revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var parent: UUID?
        var states: [StoredNotebook] = []
        var finalData = Data()

        for (index, content) in contents.enumerated() {
            let revisionID = UUID()
            let savedAt = Date(timeIntervalSince1970: 2_000_000 + Double(index) * 0.125)
            let references = try content.strokes.map { stroke in
                let digest = Self.digest(stroke.data)
                let url = assets.appendingPathComponent(digest + ".stroke")
                if !FileManager.default.fileExists(atPath: url.path) { try stroke.data.write(to: url) }
                return LegacyReference(id: stroke.id, digest: digest)
            }
            let revision = LegacyRevision(
                schemaVersion: 1, notebookID: id, revisionID: revisionID,
                parentRevisionID: parent, sequence: index + 1,
                title: content.title, pageCount: content.pageCount,
                strokes: references, editStamp: content.editStamp, savedAt: savedAt
            )
            finalData = try encoder.encode(revision)
            try finalData.write(to: revisions.appendingPathComponent(revisionID.uuidString.lowercased() + ".json"))
            states.append(StoredNotebook(
                id: id, revisionID: revisionID, sequence: index + 1, content: content, savedAt: savedAt
            ))
            parent = revisionID
        }

        guard let latest = states.last else { throw FixtureError.malformedMetadata }
        let head = LegacyHead(
            schemaVersion: 1, notebookID: id, revisionID: latest.revisionID,
            revisionDigest: digest(finalData)
        )
        let headData = try encoder.encode(head)
        try headData.write(to: directory.appendingPathComponent("HEAD.json"))
        let orphanID = UUID()
        let orphan = LegacyRevision(
            schemaVersion: 1, notebookID: id, revisionID: orphanID,
            parentRevisionID: states.first?.revisionID, sequence: 2,
            title: "Unselected branch", pageCount: 3, strokes: [],
            editStamp: stamp(500), savedAt: Date(timeIntervalSince1970: 3_000_000)
        )
        try encoder.encode(orphan).write(
            to: revisions.appendingPathComponent(orphanID.uuidString.lowercased() + ".json")
        )
        return LegacyFixture(
            notebookID: id, states: states, headData: headData,
            originalFiles: try snapshot(in: directory), orphanRevisionID: orphanID
        )
    }

    static func assertSame(
        _ actual: StoredNotebook,
        _ expected: StoredNotebook,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.revisionID, expected.revisionID, file: file, line: line)
        XCTAssertEqual(actual.sequence, expected.sequence, file: file, line: line)
        XCTAssertEqual(actual.content, expected.content, file: file, line: line)
        XCTAssertEqual(actual.savedAt, expected.savedAt, file: file, line: line)
    }

    static func assertOriginalFiles(
        _ fixture: LegacyFixture,
        root: URL,
        includeHead: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = noteDirectory(root: root, id: fixture.notebookID)
        for (path, data) in fixture.originalFiles where includeHead || path != "HEAD.json" {
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent(path)), data,
                "Legacy file changed: \(path)", file: file, line: line
            )
        }
    }

    private struct LegacyHead: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let revisionDigest: String
    }

    private struct LegacyReference: Codable {
        let id: UUID
        let digest: String
    }

    private struct LegacyRevision: Codable {
        let schemaVersion: Int
        let notebookID: UUID
        let revisionID: UUID
        let parentRevisionID: UUID?
        let sequence: Int
        let title: String
        let pageCount: Int
        let strokes: [LegacyReference]
        let editStamp: NotebookEditStamp?
        let savedAt: Date
    }
}
