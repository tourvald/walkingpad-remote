import Foundation

public enum DiagnosticZipArchive {
    public struct Result: Equatable, Sendable {
        public let url: URL
        public let outputBytes: UInt64
        public let maximumChunkBytes: Int
    }

    public enum ArchiveError: Error, Equatable {
        case destinationExists
        case emptyInput
        case invalidSource(String)
        case zip32LimitExceeded(String)
    }

    private struct Entry {
        let sourceURL: URL
        let name: String
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let modificationTime: UInt16
        let modificationDate: UInt16
        var localHeaderOffset: UInt32 = 0
    }

    public static func create(
        directoryURL: URL,
        fileURLs: [URL],
        archiveName: String
    ) throws -> URL {
        try createWithMetrics(
            directoryURL: directoryURL,
            fileURLs: fileURLs,
            archiveName: archiveName
        ).url
    }

    public static func createWithMetrics(
        directoryURL: URL,
        fileURLs: [URL],
        archiveName: String
    ) throws -> Result {
        try createWithMetrics(
            directoryURL: directoryURL,
            fileURLs: fileURLs,
            archiveName: archiveName,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    static func createWithMetrics(
        directoryURL: URL,
        fileURLs: [URL],
        archiveName: String,
        cancellationCheck: () throws -> Void
    ) throws -> Result {
        try cancellationCheck()
        guard !fileURLs.isEmpty else { throw ArchiveError.emptyInput }
        guard !archiveName.isEmpty,
              archiveName == URL(fileURLWithPath: archiveName).lastPathComponent,
              archiveName.lowercased().hasSuffix(".zip") else {
            throw ArchiveError.invalidSource(archiveName)
        }

        let root = directoryURL.standardizedFileURL
        let archiveURL = root.appendingPathComponent(archiveName, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ArchiveError.destinationExists
        }
        guard fileURLs.count <= Int(UInt16.max) else {
            throw ArchiveError.zip32LimitExceeded("file-count")
        }

        var entries: [Entry] = []
        var seenNames = Set<String>()
        var maximumChunkBytes = 0
        for fileURL in fileURLs {
            try cancellationCheck()
            let source = fileURL.standardizedFileURL
            let name = source.lastPathComponent
            guard source.deletingLastPathComponent() == root,
                  !name.isEmpty,
                  name != archiveName,
                  seenNames.insert(name).inserted else {
                throw ArchiveError.invalidSource(source.path)
            }
            let values = try source.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize else {
                throw ArchiveError.invalidSource(source.path)
            }
            guard fileSize >= 0, UInt64(fileSize) <= UInt64(UInt32.max) else {
                throw ArchiveError.zip32LimitExceeded(name)
            }
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw ArchiveError.zip32LimitExceeded(name)
            }
            let checksum = try checksum(
                of: source,
                cancellationCheck: cancellationCheck
            )
            maximumChunkBytes = max(maximumChunkBytes, checksum.maximumChunkBytes)
            let timestamp = dosTimestamp(values.contentModificationDate ?? Date())
            entries.append(Entry(
                sourceURL: source,
                name: name,
                nameData: nameData,
                crc32: checksum.value,
                size: UInt32(fileSize),
                modificationTime: timestamp.time,
                modificationDate: timestamp.date
            ))
        }

        guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: archiveURL)
        var offset: UInt64 = 0

        do {
            for index in entries.indices {
                try cancellationCheck()
                guard offset <= UInt64(UInt32.max) else {
                    throw ArchiveError.zip32LimitExceeded(entries[index].name)
                }
                entries[index].localHeaderOffset = UInt32(offset)
                let entry = entries[index]
                var header = Data()
                header.appendLittleEndian(UInt32(0x04034b50))
                header.appendLittleEndian(UInt16(20))
                header.appendLittleEndian(UInt16(0x0800))
                header.appendLittleEndian(UInt16(0))
                header.appendLittleEndian(entry.modificationTime)
                header.appendLittleEndian(entry.modificationDate)
                header.appendLittleEndian(entry.crc32)
                header.appendLittleEndian(entry.size)
                header.appendLittleEndian(entry.size)
                header.appendLittleEndian(UInt16(entry.nameData.count))
                header.appendLittleEndian(UInt16(0))
                header.append(entry.nameData)
                try write(header, to: output, offset: &offset)

                let input = try FileHandle(forReadingFrom: entry.sourceURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try cancellationCheck()
                    maximumChunkBytes = max(maximumChunkBytes, chunk.count)
                    try write(chunk, to: output, offset: &offset)
                }
            }

            guard offset <= UInt64(UInt32.max) else {
                throw ArchiveError.zip32LimitExceeded("central-directory-offset")
            }
            let centralDirectoryOffset = UInt32(offset)
            for entry in entries {
                try cancellationCheck()
                var header = Data()
                header.appendLittleEndian(UInt32(0x02014b50))
                header.appendLittleEndian(UInt16(20))
                header.appendLittleEndian(UInt16(20))
                header.appendLittleEndian(UInt16(0x0800))
                header.appendLittleEndian(UInt16(0))
                header.appendLittleEndian(entry.modificationTime)
                header.appendLittleEndian(entry.modificationDate)
                header.appendLittleEndian(entry.crc32)
                header.appendLittleEndian(entry.size)
                header.appendLittleEndian(entry.size)
                header.appendLittleEndian(UInt16(entry.nameData.count))
                header.appendLittleEndian(UInt16(0))
                header.appendLittleEndian(UInt16(0))
                header.appendLittleEndian(UInt16(0))
                header.appendLittleEndian(UInt16(0))
                header.appendLittleEndian(UInt32(0))
                header.appendLittleEndian(entry.localHeaderOffset)
                header.append(entry.nameData)
                try write(header, to: output, offset: &offset)
            }

            let centralDirectorySize = offset - UInt64(centralDirectoryOffset)
            guard centralDirectorySize <= UInt64(UInt32.max) else {
                throw ArchiveError.zip32LimitExceeded("central-directory-size")
            }
            var footer = Data()
            footer.appendLittleEndian(UInt32(0x06054b50))
            footer.appendLittleEndian(UInt16(0))
            footer.appendLittleEndian(UInt16(0))
            footer.appendLittleEndian(UInt16(entries.count))
            footer.appendLittleEndian(UInt16(entries.count))
            footer.appendLittleEndian(UInt32(centralDirectorySize))
            footer.appendLittleEndian(centralDirectoryOffset)
            footer.appendLittleEndian(UInt16(0))
            try write(footer, to: output, offset: &offset)
            try output.close()
            return Result(
                url: archiveURL,
                outputBytes: offset,
                maximumChunkBytes: maximumChunkBytes
            )
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }
    }

    private static func write(
        _ data: Data,
        to output: FileHandle,
        offset: inout UInt64
    ) throws {
        try output.write(contentsOf: data)
        offset += UInt64(data.count)
        guard offset <= UInt64(UInt32.max) else {
            throw ArchiveError.zip32LimitExceeded("archive-size")
        }
    }

    private static func checksum(
        of fileURL: URL,
        cancellationCheck: () throws -> Void
    ) throws -> (value: UInt32, maximumChunkBytes: Int) {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        var value = UInt32.max
        var maximumChunkBytes = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try cancellationCheck()
            maximumChunkBytes = max(maximumChunkBytes, chunk.count)
            for byte in chunk {
                let index = Int((value ^ UInt32(byte)) & 0xff)
                value = crcTable[index] ^ (value >> 8)
            }
        }
        return (value ^ UInt32.max, maximumChunkBytes)
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = min(2107, max(1980, components.year ?? 1980))
        let month = min(12, max(1, components.month ?? 1))
        let day = min(31, max(1, components.day ?? 1))
        let hour = min(23, max(0, components.hour ?? 0))
        let minute = min(59, max(0, components.minute ?? 0))
        let second = min(59, max(0, components.second ?? 0))
        return (
            UInt16((hour << 11) | (minute << 5) | (second / 2)),
            UInt16(((year - 1980) << 9) | (month << 5) | day)
        )
    }

    private static let crcTable: [UInt32] = (0..<256).map { seed in
        var value = UInt32(seed)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? 0xedb88320 ^ (value >> 1)
                : value >> 1
        }
        return value
    }
}

extension DiagnosticZipArchive.ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationExists:
            return "Диагностический архив уже существует."
        case .emptyInput:
            return "В диагностическом пакете нет файлов."
        case .invalidSource(let source):
            return "Диагностический пакет содержит недопустимый файл: \(source)"
        case .zip32LimitExceeded(let item):
            return "Диагностический пакет слишком велик для ZIP-архива: \(item)"
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
