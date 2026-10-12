// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Persisted status of one queued game. Raw values are the on-disk strings, so
/// the file stays readable and a future value is never silently mapped onto a
/// completed one.
public enum HENBatchStatus: String, Codable, Sendable, CaseIterable {
    /// Waiting for Check batch.
    case queued = "Queued"
    /// Preflight approved this game; the user has not started the batch yet.
    case ready = "Ready"
    /// This game is being converted right now.
    case converting = "Converting"
    /// Published and verified locally. Only ever set by a successful export.
    case published = "Published"
    case failed = "Failed"
    case cancelled = "Cancelled"
    /// The app stopped while this game was mid-conversion.
    case interrupted = "Interrupted"

    /// A row only counts as finished work when it actually published.
    public var isTerminal: Bool {
        switch self {
        case .published, .failed, .cancelled, .interrupted: return true
        case .queued, .ready, .converting: return false
        }
    }
    public var isRetryable: Bool {
        self == .failed || self == .cancelled || self == .interrupted
    }
    /// Reopening the app must never present unfinished work as done.
    public var restoredAfterRelaunch: HENBatchStatus {
        self == .converting ? .interrupted : self
    }
}

/// One queued game, as persisted across app restarts. Only paths and
/// fingerprints are stored — never key bytes, CONFIG contents or image data.
public struct HENBatchItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: URL
    public var config: URL?
    public var configSHA256: String?
    public var status: HENBatchStatus
    public var detail: String
    /// Populated once preflight has read the ISO, and after publication.
    public var gameID: String?
    public var publishedFolder: URL?

    public init(id: UUID = UUID(), source: URL, config: URL? = nil, configSHA256: String? = nil,
                status: HENBatchStatus = .queued, detail: String = "Waiting to be checked.",
                gameID: String? = nil, publishedFolder: URL? = nil) {
        self.id = id; self.source = source; self.config = config; self.configSHA256 = configSHA256
        self.status = status; self.detail = detail; self.gameID = gameID
        self.publishedFolder = publishedFolder
    }

    public var input: HENBatchInput {
        HENBatchInput(id: id, source: source, config: config, configSHA256: configSHA256)
    }
}

/// The whole queue and its export settings.
public struct HENBatchState: Codable, Equatable, Sendable {
    public var items: [HENBatchItem]
    public var keyFile: URL?
    public var destination: URL?
    public var contentID: String
    public var folderLayout: Bool

    public init(items: [HENBatchItem] = [], keyFile: URL? = nil, destination: URL? = nil,
                contentID: String = "", folderLayout: Bool = false) {
        self.items = items; self.keyFile = keyFile; self.destination = destination
        self.contentID = contentID; self.folderLayout = folderLayout
    }

    public var isEmpty: Bool { items.isEmpty }
    public var finishedCount: Int { items.filter { $0.status == .published }.count }
}

/// Sidecar persistence for the HEN queue, kept separate from `StudioSession` so
/// the build queue's saved format is never touched. Loads are bounded and
/// tolerant of a damaged file; saves are atomic and never partial.
public enum HENBatchStore {
    /// A queue holds paths and short strings, never payloads.
    public static let maxBytes = 1 * 1024 * 1024
    public static let fileName = "hen-batch.json"

    public struct Outcome: Sendable {
        public var state: HENBatchState
        /// Recovery notes to surface, empty when the file read cleanly.
        public var notes: [String]
        /// A copy of a file that did not read cleanly, when one could be made.
        public var backup: URL?
        /// True when a damaged original must not be overwritten.
        public var locked: Bool
        public init(state: HENBatchState = HENBatchState(), notes: [String] = [],
                    backup: URL? = nil, locked: Bool = false) {
            self.state = state; self.notes = notes; self.backup = backup; self.locked = locked
        }
        public var didRecover: Bool { !notes.isEmpty }
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PS2 Classics for Mac")
            .appendingPathComponent(fileName)
    }

    public static func load(from url: URL) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Outcome()
        }
        let data: Data
        do { data = try BoundedFile.read(url, maximum: maxBytes) }
        catch {
            return Outcome(notes: ["The saved Super Slim / HEN queue could not be read (\(error.localizedDescription)). It was left untouched at \(url.path). Move it aside and reopen the app before editing this queue."],
                           locked: true)
        }
        do {
            var state = try JSONDecoder().decode(HENBatchState.self, from: data)
            let notes = normalize(&state)
            return Outcome(state: state, notes: notes)
        } catch {
            let copied = try? copyAside(url)
            let note = copied.map { "The saved Super Slim / HEN queue could not be decoded. A recoverable copy was kept at \($0.path), and the queue starts empty." }
                ?? "The saved Super Slim / HEN queue could not be decoded and could not be copied aside. It was left untouched at \(url.path). Move it aside and reopen the app before editing this queue."
            return Outcome(notes: [note], backup: copied, locked: copied == nil)
        }
    }

    public static func save(_ state: HENBatchState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        guard data.count <= maxBytes else {
            throw ConversionFailure(message: "The Super Slim / HEN queue is too large to save. Remove some games and try again.")
        }
        try data.write(to: url, options: .atomic)
    }

    /// A saved status alone is not evidence that an exported game still exists.
    /// This is a structural check at relaunch; the original export performs
    /// full cryptographic verification before it records `Published`.
    private static func hasPublishedPayload(_ row: HENBatchItem) -> Bool {
        guard let folder = row.publishedFolder else { return false }
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        let image = folder.appendingPathComponent(folder.lastPathComponent + ".BIN.ENC")
        guard lstat(image.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else { return false }
        if row.config != nil {
            let sidecar = folder.appendingPathComponent(image.lastPathComponent + ".CONFIG")
            guard lstat(sidecar.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else { return false }
        }
        return true
    }

    /// Applies the interrupted-on-relaunch rule and drops unusable rows.
    /// A `Converting` row becomes `Interrupted` with an explicit reason, so an
    /// interrupted conversion can restart but is never shown as complete.
    private static func normalize(_ state: inout HENBatchState) -> [String] {
        var notes = [String]()
        var kept = [HENBatchItem]()
        var seen = Set<String>()
        for item in state.items {
            let path = item.source.standardizedFileURL.path
            guard seen.insert(path).inserted else {
                notes.append("A duplicate entry for \(item.source.lastPathComponent) was removed from the restored queue.")
                continue
            }
            var row = item
            if row.status == .converting {
                row.status = .interrupted
                row.detail = "The app stopped while this game was converting. It is not complete. Use Check batch, then Retry — nothing was published."
            }
            if row.status == .ready {
                // The reviewed plan is deliberately not persisted, so a
                // preflight approval cannot outlive the session that made it.
                row.status = .queued
                row.detail = "Waiting to be checked again."
            }
            if row.status == .published {
                // An empty, replaced or linked folder is not finished work.
                if hasPublishedPayload(row) {
                    kept.append(row)
                } else {
                    row.status = .interrupted
                    row.detail = "The published game folder or its image is missing or incomplete, so this game is not treated as complete. If the incomplete folder still exists, move it aside before Retry; existing files are never replaced."
                    kept.append(row)
                }
                continue
            }
            kept.append(row)
        }
        state.items = kept
        return notes
    }

    private static func copyAside(_ url: URL) throws -> URL {
        let manager = FileManager.default
        let stamp = ISO8601DateFormatter()
        let base = "\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: ""))"
        var index = 0
        var target = url.deletingLastPathComponent().appendingPathComponent("\(base).json")
        while manager.fileExists(atPath: target.path) {
            index += 1
            target = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(index).json")
        }
        try Data(contentsOf: url).write(to: target, options: .withoutOverwriting)
        return target
    }
}
