import Foundation

public final class SessionFileWatcher: @unchecked Sendable {

    public typealias PayloadHandler = @Sendable (HookPayload) -> Void

    private let projectsRoot: String
    private let pollInterval: TimeInterval
    private let activeWindowSeconds: TimeInterval
    private let onPayload: PayloadHandler
    private var offsets: [String: Int] = [:]   // filePath → byte offset
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.agentpilot.filewatcher", qos: .background)

    public init(
        projectsRoot: String = (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path),
        pollInterval: TimeInterval = 3.0,
        activeWindowSeconds: TimeInterval = 1800,  // 30 min
        onPayload: @escaping PayloadHandler
    ) {
        self.projectsRoot = projectsRoot
        self.pollInterval = pollInterval
        self.activeWindowSeconds = activeWindowSeconds
        self.onPayload = onPayload
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let files = Self.scanActiveFiles(in: projectsRoot, activeWindowSeconds: activeWindowSeconds)
        for path in files {
            var offset = offsets[path] ?? 0
            let lines = Self.readNewLines(from: path, offset: &offset)
            offsets[path] = offset
            for line in lines {
                guard
                    let data = line.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let payload = JournalEventNormalizer.normalize(obj)
                else { continue }
                onPayload(payload)
            }
        }
    }

    // MARK: - Testable helpers (public static so tests can call directly)

    /// Returns paths of .jsonl files under `root` whose mtime is within `activeWindowSeconds`.
    public static func scanActiveFiles(in root: String, activeWindowSeconds: TimeInterval) -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)
        var result: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { continue }
            if mtime >= cutoff {
                // Normalize: replace resolved prefix with original root path so symlinks are preserved
                let resolvedPath = url.resolvingSymlinksInPath().path
                let finalPath: String
                if resolvedPath.hasPrefix(resolvedRoot) {
                    finalPath = root + resolvedPath.dropFirst(resolvedRoot.count)
                } else {
                    finalPath = url.path
                }
                result.append(finalPath)
            }
        }
        return result
    }

    /// Reads new UTF-8 lines from `path` starting at `offset`, updates `offset` in place.
    public static func readNewLines(from path: String, offset: inout Int) -> [String] {
        guard
            let handle = FileHandle(forReadingAtPath: path)
        else { return [] }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: UInt64(offset))
        let data = handle.readDataToEndOfFile()
        offset += data.count
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: "\n")
            // Incomplete final lines (no trailing \n) are silently dropped and will be re-read next poll once the write completes.
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
