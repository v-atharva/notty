import Foundation

enum NotebookRecoveryIdentityFormat {
    static let bytesPerIdentity = 16
    static let maximumBytes = NotebookRecoveryStore.maximumStrokeIDs * bytesPerIdentity

    static func encode(_ identities: [UUID]) throws -> Data {
        guard identities.count <= NotebookRecoveryStore.maximumStrokeIDs else {
            throw NotebookRepositoryError.sizeLimitExceeded("A recovery edit exceeds 20,000 strokes.")
        }
        guard Set(identities).count == identities.count else {
            throw NotebookRepositoryError.invalidContent("Recovery stroke identifiers must be unique.")
        }
        var data = Data()
        data.reserveCapacity(identities.count * bytesPerIdentity)
        for identity in identities {
            var bytes = identity.uuid
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, count: Int) throws -> [UUID] {
        guard (0...NotebookRecoveryStore.maximumStrokeIDs).contains(count),
              data.count == count * bytesPerIdentity else {
            throw NotebookRepositoryError.corruptData("A recovery identity file has an invalid byte count.")
        }
        var identities: [UUID] = []
        identities.reserveCapacity(count)
        for offset in stride(from: 0, to: data.count, by: bytesPerIdentity) {
            identities.append(UUID(uuid: (
                data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
                data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
                data[offset + 8], data[offset + 9], data[offset + 10], data[offset + 11],
                data[offset + 12], data[offset + 13], data[offset + 14], data[offset + 15]
            )))
        }
        guard Set(identities).count == identities.count else {
            throw NotebookRepositoryError.corruptData("A recovery identity file contains duplicate identifiers.")
        }
        return identities
    }
}
