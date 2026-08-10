import Darwin
import Foundation

enum SecureLocalFile {
    static func read(from url: URL) throws -> Data {
        try validateDirectory(url.deletingLastPathComponent())
        try validateRegularFile(url)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func replace(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw SecureLocalFileError.openFailed }
        var descriptorIsOpen = true
        var removeTemporary = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if removeTemporary { _ = Darwin.unlink(temporary.path) }
        }
        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw SecureLocalFileError.synchronizationFailed
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw SecureLocalFileError.closeFailed
        }
        descriptorIsOpen = false
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw SecureLocalFileError.renameFailed
        }
        removeTemporary = false
        try validateRegularFile(url)
    }

    static func append(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw SecureLocalFileError.openFailed }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
        }
        try validateRegularFile(descriptor: descriptor)
        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw SecureLocalFileError.synchronizationFailed
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw SecureLocalFileError.closeFailed
        }
        descriptorIsOpen = false
    }

    static func ensureDirectory(_ url: URL) throws {
        let target = url.standardizedFileURL
        var missing: [URL] = []
        var cursor = target

        while true {
            var metadata = stat()
            if Darwin.lstat(cursor.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw SecureLocalFileError.invalidDirectory
                }
                break
            }
            guard errno == ENOENT else {
                throw SecureLocalFileError.invalidDirectory
            }
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw SecureLocalFileError.invalidDirectory
            }
            cursor = parent
        }

        for directory in missing.reversed() {
            if Darwin.mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
                throw SecureLocalFileError.invalidDirectory
            }
            try validateDirectory(directory)
        }
        try validateDirectory(target)
    }

    private static func validateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == geteuid() else {
            throw SecureLocalFileError.invalidDirectory
        }
    }

    private static func validateRegularFile(_ url: URL) throws {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == geteuid() else {
            throw SecureLocalFileError.invalidFile
        }
    }

    private static func validateRegularFile(descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == geteuid() else {
            throw SecureLocalFileError.invalidFile
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw SecureLocalFileError.writeFailed
                }
            }
        }
    }
}

enum SecureLocalFileError: Error, Sendable {
    case invalidDirectory
    case invalidFile
    case openFailed
    case writeFailed
    case synchronizationFailed
    case closeFailed
    case renameFailed
}
