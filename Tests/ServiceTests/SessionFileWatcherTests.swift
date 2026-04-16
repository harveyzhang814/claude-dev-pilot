import Testing
import Foundation
@testable import Core

@Suite("SessionFileWatcherTests")
struct SessionFileWatcherTests {

    @Test("incrementalRead returns only new lines after offset")
    func incrementalRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("test.jsonl")
        let line1 = "{\"type\":\"user\",\"sessionId\":\"s1\",\"cwd\":\"/p\"}\n"
        let line2 = "{\"type\":\"system\",\"sessionId\":\"s1\",\"cwd\":\"/p\"}\n"
        try line1.write(to: file, atomically: true, encoding: .utf8)

        var offset: Int = 0
        let first = SessionFileWatcher.readNewLines(from: file.path, offset: &offset)
        #expect(first.count == 1)
        #expect(first[0].contains("\"user\""))
        #expect(offset == line1.utf8.count)

        // Append second line
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(line2.data(using: .utf8)!)
        handle.closeFile()

        let second = SessionFileWatcher.readNewLines(from: file.path, offset: &offset)
        #expect(second.count == 1)
        #expect(second[0].contains("\"system\""))
        #expect(offset == line1.utf8.count + line2.utf8.count)
    }

    @Test("incrementalRead does not advance offset past a partial (unterminated) line")
    func partialLineNotConsumed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("partial.jsonl")
        let complete = "{\"type\":\"user\",\"sessionId\":\"s1\",\"cwd\":\"/p\"}\n"
        let partial  = "{\"type\":\"assistant\""  // no trailing newline
        try (complete + partial).write(to: file, atomically: true, encoding: .utf8)

        var offset: Int = 0
        let lines = SessionFileWatcher.readNewLines(from: file.path, offset: &offset)
        // Only the complete line should be returned
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"user\""))
        // Offset should stop at the end of the complete line, not include the partial bytes
        #expect(offset == complete.utf8.count)

        // Now complete the partial line
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(",\"sessionId\":\"s2\",\"cwd\":\"/p\"}\n".data(using: .utf8)!)
        handle.closeFile()

        let more = SessionFileWatcher.readNewLines(from: file.path, offset: &offset)
        #expect(more.count == 1)
        #expect(more[0].contains("\"assistant\""))
    }

    @Test("scanActiveFiles returns only files with mtime within window")
    func scanActiveFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recent = dir.appendingPathComponent("recent.jsonl")
        let old = dir.appendingPathComponent("old.jsonl")
        try "{}".write(to: recent, atomically: true, encoding: .utf8)
        try "{}".write(to: old, atomically: true, encoding: .utf8)

        // Back-date the old file to 2 hours ago
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: twoHoursAgo],
            ofItemAtPath: old.path
        )

        let found = SessionFileWatcher.scanActiveFiles(
            in: dir.path,
            activeWindowSeconds: 1800  // 30 min
        )
        #expect(found.contains(recent.path))
        #expect(!found.contains(old.path))
    }
}
