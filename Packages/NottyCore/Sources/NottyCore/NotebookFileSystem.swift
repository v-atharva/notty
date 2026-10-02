import Darwin
import Foundation

enum NotebookFileSystem {
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

    static func writeSynchronized(_ data: Data, to url: URL) throws {
        let descriptor = try openFile(
            url, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
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
