import Darwin
import Foundation

enum NotebookFileSystem {
    enum MaintenanceLocation: Sendable, Hashable {
        case library
        case notebook
        case assets
        case revisions
        case historyGeneration
        case events
        case checkpoints
        case privateTransaction
    }

    enum MaintenanceFailure: Sendable, Hashable {
        case unsafePath
        case sizeLimit
        case io
        case unexpected
    }

    enum MaintenanceEvent: Sendable, Hashable {
        case directoryEnumeration(MaintenanceLocation)
        case skippedNonRegularStage
        case removedStage
        case limitReached
        case failed(MaintenanceFailure)
    }

    typealias MaintenanceObserver = @Sendable (MaintenanceEvent) -> Void

    // Finite event cases bound the report; saturating counters avoid overflow.
    final class MaintenanceDiagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [MaintenanceEvent: Int] = [:]

        func record(_ event: MaintenanceEvent) {
            lock.lock()
            defer { lock.unlock() }
            let previous = counts[event, default: 0]
            if previous < Int.max { counts[event] = previous + 1 }
        }

        func snapshot() -> [MaintenanceEvent: Int] {
            lock.lock()
            defer { lock.unlock() }
            return counts
        }
    }

    enum ItemKind: Equatable {
        case directory
        case regularFile
        case other
    }

    static func prepareRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw NotebookRepositoryError.unsafePath("Notebook storage requires a file URL.")
        }
        let root = url.standardizedFileURL
        if try kind(root) == nil {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
        }
        guard try kind(root) == .directory else {
            throw NotebookRepositoryError.unsafePath("Notebook storage must use a directory without a symbolic link.")
        }
        return root.resolvingSymlinksInPath()
    }

    static func existingDirectory(_ url: URL) throws -> Bool {
        guard let kind = try kind(url) else { return false }
        guard kind == .directory else {
            throw NotebookRepositoryError.unsafePath("A notebook directory has an unsafe file type.")
        }
        return true
    }

    static func ensureDirectory(_ url: URL) throws {
        if try kind(url) == nil {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false
            )
        }
        guard try existingDirectory(url) else {
            throw NotebookRepositoryError.unsafePath("A notebook directory is missing.")
        }
    }

    static func kind(_ url: URL) throws -> ItemKind? {
        var metadata = stat()
        let result = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw NotebookRepositoryError.unsafePath("A notebook path cannot be represented.")
            }
            return lstat(path, &metadata)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw NotebookRepositoryError.ioFailure(code)
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        default: return .other
        }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard try kind(url) == .regularFile else {
            throw NotebookRepositoryError.unsafePath("Notebook files must be regular files without symbolic links.")
        }
        let descriptor = try openFile(url, flags: O_RDONLY | O_NOFOLLOW)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NotebookRepositoryError.ioFailure(errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw NotebookRepositoryError.unsafePath("A notebook file changed to an unsafe file type.")
        }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else {
            throw NotebookRepositoryError.sizeLimitExceeded("A notebook file exceeds its supported size.")
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1_024)),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw NotebookRepositoryError.sizeLimitExceeded("A notebook file exceeds its supported size.")
    }

    static func writeSynchronized(
        _ data: Data,
        to url: URL,
        writeBody: ((FileHandle, Data) throws -> Void)? = nil
    ) throws {
        let descriptor = try openFile(
            url, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var synchronized = false
        defer {
            try? handle.close()
            if !synchronized { try? FileManager.default.removeItem(at: url) }
        }
        if let writeBody {
            try writeBody(handle, data)
        } else {
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()
        synchronized = true
    }

    static func withSynchronizedStage<T>(
        _ data: Data,
        in directory: URL,
        head: Bool = false,
        publish: (URL) throws -> T
    ) throws -> T {
        let name = head ? ".head-\(UUID().uuidString).tmp" : ".\(UUID().uuidString).tmp"
        let stage = directory.appendingPathComponent(name)
        var created = false
        defer {
            if created { try? FileManager.default.removeItem(at: stage) }
        }
        try writeSynchronized(data, to: stage)
        created = true
        return try publish(stage)
    }

    static func sweepPrivateTransactions(
        in root: URL,
        prefix: String,
        additionalPrefixes: [String] = [],
        observer: MaintenanceObserver? = nil
    ) throws {
        let prefixes = [prefix] + additionalPrefixes
        guard prefixes.allSatisfy({ [".creation-", ".recovery-", ".migration-"].contains($0) }) else {
            throw NotebookRepositoryError.unsafePath("Unknown storage transaction namespace.")
        }
        var removed = 0
        try visitChildren(
            in: root, limit: 2_048, location: .library, observer: observer
        ) { entry in
            guard let owner = prefixes.first(where: {
                isTransactionName(entry.lastPathComponent, prefix: $0)
            }) else { return true }
            try removePrivateTransaction(entry, prefix: owner, observer: observer)
            removed += 1
            if removed == 16 { observer?(.limitReached) }
            return removed < 16
        }
    }

    static func removePrivateTransaction(
        _ url: URL,
        prefix: String,
        observer: MaintenanceObserver? = nil
    ) throws {
        guard isTransactionName(url.lastPathComponent, prefix: prefix) else {
            throw NotebookRepositoryError.unsafePath("The storage transaction has an invalid name.")
        }
        guard let type = try kind(url) else { return }
        guard type == .directory else {
            throw NotebookRepositoryError.unsafePath("The storage transaction has an unsafe file type.")
        }
        var directories = [url]
        var visited = 0
        var bytes: Int64 = 0
        while let directory = directories.popLast() {
            try visitChildren(
                in: directory, limit: 50_001, location: .privateTransaction, observer: observer
            ) { child in
                visited += 1
                guard visited <= 50_000 else {
                    throw NotebookRepositoryError.sizeLimitExceeded("The abandoned transaction exceeds cleanup bounds.")
                }
                guard let type = try kind(child) else { return true }
                switch type {
                case .directory:
                    directories.append(child)
                case .regularFile:
                    let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                    bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard bytes <= 600 * 1_024 * 1_024 else {
                        throw NotebookRepositoryError.sizeLimitExceeded("The abandoned transaction exceeds cleanup bounds.")
                    }
                case .other:
                    throw NotebookRepositoryError.unsafePath("The storage transaction contains an unsafe file type.")
                }
                return true
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    static func sweepNotebookStages(
        in directory: URL,
        observer: MaintenanceObserver? = nil,
        additionalLocations: [(URL, MaintenanceLocation)] = []
    ) throws {
        let locations: [(URL, MaintenanceLocation)] = [
            (directory, .notebook),
            (directory.appendingPathComponent("assets", isDirectory: true), .assets),
            (directory.appendingPathComponent("revisions", isDirectory: true), .revisions)
        ] + additionalLocations
        var removed = 0
        for (location, role) in locations {
            guard try existingDirectory(location) else { continue }
            try visitChildren(
                in: location, limit: 20_000, location: role, observer: observer
            ) { entry in
                guard isStageName(entry.lastPathComponent) else { return true }
                guard let type = try kind(entry) else { return true }
                guard type == .regularFile else {
                    observer?(.skippedNonRegularStage)
                    return true
                }
                // unlink cannot recursively remove a directory or follow a link target.
                try unlinkStage(entry)
                observer?(.removedStage)
                removed += 1
                return removed < 64
            }
            if removed == 64 {
                observer?(.limitReached)
                return
            }
        }
    }

    static func maintenanceFailure(for error: Error) -> MaintenanceFailure {
        guard let error = error as? NotebookRepositoryError else {
            let domain = (error as NSError).domain
            return domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain ? .io : .unexpected
        }
        switch error {
        case .unsafePath: return .unsafePath
        case .sizeLimitExceeded: return .sizeLimit
        case .ioFailure: return .io
        default: return .unexpected
        }
    }

    private static func unlinkStage(_ url: URL) throws {
        let result = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw NotebookRepositoryError.unsafePath("A notebook stage cannot be represented.")
            }
            return Darwin.unlink(path)
        }
        guard result == 0 else { throw NotebookRepositoryError.ioFailure(errno) }
    }

    private static func visitChildren(
        in directory: URL,
        limit: Int,
        location: MaintenanceLocation,
        observer: MaintenanceObserver? = nil,
        _ visit: (URL) throws -> Bool
    ) throws {
        observer?(.directoryEnumeration(location))
        let failure = EnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                failure.record(error)
                return false
            }
        ) else {
            throw NotebookRepositoryError.unsafePath("A storage directory cannot be enumerated.")
        }
        var visited = 0
        for case let entry as URL in enumerator {
            if visited == limit {
                observer?(.limitReached)
                break
            }
            visited += 1
            if try !visit(entry) { break }
        }
        if let error = failure.value() { throw error }
    }

    private final class EnumerationFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            self.error = error
        }

        func value() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    private static func isTransactionName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard let identifier = UUID(uuidString: suffix) else { return false }
        return suffix == identifier.uuidString || suffix == identifier.uuidString.lowercased()
    }

    private static func isStageName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        var identifier = String(name.dropFirst().dropLast(4))
        if identifier.hasPrefix("head-") { identifier = String(identifier.dropFirst(5)) }
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return identifier == uuid.uuidString || identifier == uuid.uuidString.lowercased()
    }

    static func publishImmutable(_ stage: URL, to destination: URL) throws {
        guard try kind(destination) == nil else {
            throw NotebookRepositoryError.corruptData("An immutable notebook file already exists.")
        }
        try renameFile(stage, destination: destination)
    }

    static func replaceAtomically(_ stage: URL, destination: URL) throws {
        if let existing = try kind(destination), existing != .regularFile {
            throw NotebookRepositoryError.unsafePath("The notebook HEAD has an unsafe file type.")
        }
        try renameFile(stage, destination: destination)
    }

    static func acquireWriterLock(_ root: URL) throws -> Int32 {
        guard try existingDirectory(root) else {
            throw NotebookRepositoryError.unsafePath("The notebook storage directory is missing.")
        }
        let descriptor = try openFile(
            root.appendingPathComponent(".writer.lock"),
            flags: O_RDWR | O_CREAT | O_NOFOLLOW
        )
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NotebookRepositoryError.ioFailure(code)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw NotebookRepositoryError.unsafePath("The notebook writer lock has an unsafe file type.")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            Darwin.close(descriptor)
            throw NotebookRepositoryError.ioFailure(code)
        }
        return descriptor
    }

    static func releaseWriterLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func openFile(_ url: URL, flags: Int32) throws -> Int32 {
        let descriptor = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw NotebookRepositoryError.unsafePath("A notebook path cannot be represented.")
            }
            return Darwin.open(path, flags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw NotebookRepositoryError.unsafePath("Notebook files cannot be symbolic links.")
            }
            throw NotebookRepositoryError.ioFailure(code)
        }
        return descriptor
    }

    private static func renameFile(_ source: URL, destination: URL) throws {
        let result = try source.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else {
                throw NotebookRepositoryError.unsafePath("A notebook path cannot be represented.")
            }
            return try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else {
                    throw NotebookRepositoryError.unsafePath("A notebook path cannot be represented.")
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NotebookRepositoryError.ioFailure(errno)
        }
    }
}
