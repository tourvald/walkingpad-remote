import Foundation

struct DebugLogRetentionPolicy: Equatable, Sendable {
    static let production = DebugLogRetentionPolicy(
        maxLines: 4_000,
        maxUTF8Bytes: 250_000
    )

    let maxLines: Int
    let maxUTF8Bytes: Int

    init(maxLines: Int, maxUTF8Bytes: Int) {
        precondition(maxLines > 0)
        precondition(maxUTF8Bytes > 1)
        self.maxLines = maxLines
        self.maxUTF8Bytes = maxUTF8Bytes
    }
}

struct BoundedDebugLogBuffer: Sendable {
    struct Snapshot: Equatable, Sendable {
        let revision: UInt64
        let text: String
        let lineCount: Int
        let retainedUTF8Bytes: Int
    }

    struct Diagnostics: Equatable, Sendable {
        let appendCount: UInt64
        let evictedLineCount: UInt64
        let snapshotAssemblyCount: UInt64
    }

    private struct Entry: Sendable {
        let utf8: [UInt8]

        var retainedUTF8Bytes: Int {
            utf8.count + 1
        }
    }

    let policy: DebugLogRetentionPolicy

    private var storage: [Entry?]
    private var headIndex = 0
    private(set) var lineCount = 0
    private(set) var retainedUTF8Bytes = 0
    private(set) var revision: UInt64 = 0
    private var appendCount: UInt64 = 0
    private var evictedLineCount: UInt64 = 0
    private var snapshotAssemblyCount: UInt64 = 0

    init(policy: DebugLogRetentionPolicy = .production) {
        self.policy = policy
        storage = Array(repeating: nil, count: policy.maxLines)
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            appendCount: appendCount,
            evictedLineCount: evictedLineCount,
            snapshotAssemblyCount: snapshotAssemblyCount
        )
    }

    mutating func append(_ line: String) {
        let logicalLines = line.split(separator: "\n", omittingEmptySubsequences: false)
        if logicalLines.isEmpty {
            appendEntry(Entry(utf8: []))
        } else {
            for logicalLine in logicalLines {
                appendEntry(Entry(utf8: boundedUTF8(logicalLine)))
            }
        }

        appendCount &+= 1
        revision &+= 1
    }

    mutating func clear() {
        guard lineCount > 0 else { return }

        storage = Array(repeating: nil, count: policy.maxLines)
        headIndex = 0
        lineCount = 0
        retainedUTF8Bytes = 0
        revision &+= 1
    }

    mutating func snapshot() -> Snapshot {
        snapshotAssemblyCount &+= 1

        var text = ""
        text.reserveCapacity(retainedUTF8Bytes)
        for offset in 0..<lineCount {
            if offset > 0 {
                text.append("\n")
            }
            let index = (headIndex + offset) % storage.count
            if let entry = storage[index] {
                text.append(String(decoding: entry.utf8, as: UTF8.self))
            }
        }

        return Snapshot(
            revision: revision,
            text: text,
            lineCount: lineCount,
            retainedUTF8Bytes: retainedUTF8Bytes
        )
    }

    private mutating func appendEntry(_ entry: Entry) {
        while lineCount > 0 && (
            lineCount >= policy.maxLines
                || retainedUTF8Bytes + entry.retainedUTF8Bytes > policy.maxUTF8Bytes
        ) {
            removeOldest()
        }

        let insertionIndex = (headIndex + lineCount) % storage.count
        storage[insertionIndex] = entry
        lineCount += 1
        retainedUTF8Bytes += entry.retainedUTF8Bytes
    }

    private mutating func removeOldest() {
        guard lineCount > 0, let entry = storage[headIndex] else { return }

        retainedUTF8Bytes -= entry.retainedUTF8Bytes
        storage[headIndex] = nil
        headIndex = (headIndex + 1) % storage.count
        lineCount -= 1
        evictedLineCount &+= 1
    }

    private func boundedUTF8(_ line: Substring) -> [UInt8] {
        let maxLineBytes = policy.maxUTF8Bytes - 1
        if line.utf8.count <= maxLineBytes {
            return Array(line.utf8)
        }
        var bytes = Array(line.utf8.prefix(maxLineBytes))

        // A byte prefix can end inside a multi-byte scalar. Removing at most
        // three continuation bytes restores a valid UTF-8 prefix.
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return bytes
    }
}

enum DebugLogPublicationPolicy {
    static let refreshInterval: TimeInterval = 0.5
}

struct DebugLogPublicationState: Sendable {
    private(set) var publishedRevision: UInt64 = 0

    mutating func consume(_ snapshot: BoundedDebugLogBuffer.Snapshot) -> String? {
        guard snapshot.revision != publishedRevision else { return nil }
        publishedRevision = snapshot.revision
        return snapshot.text
    }

    mutating func markPublished(revision: UInt64) {
        publishedRevision = revision
    }
}

final class DebugLogStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BluetoothManager.debugLog")
    private var buffer: BoundedDebugLogBuffer

    init(policy: DebugLogRetentionPolicy = .production) {
        buffer = BoundedDebugLogBuffer(policy: policy)
    }

    func append(_ line: String) {
        queue.async { [self] in
            buffer.append(line)
        }
    }

    func snapshot(
        after revision: UInt64?,
        completion: @escaping (BoundedDebugLogBuffer.Snapshot?) -> Void
    ) {
        queue.async { [self] in
            if let revision, revision == buffer.revision {
                completion(nil)
                return
            }
            completion(buffer.snapshot())
        }
    }

    func clear(completion: @escaping (UInt64) -> Void) {
        queue.async { [self] in
            buffer.clear()
            completion(buffer.revision)
        }
    }
}
