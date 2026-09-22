// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One queued job as persisted with the session. Moved into Core so session
/// loading, migration and recovery can be tested without the UI.
public struct BuildJob: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var project: GameProject
    public var status: String
    public var detail: String
    public var report: URL?
    /// Queue-owned build identity persisted at enqueue time. Recovery binds a
    /// published package to these fields — never to a neighboring report alone.
    /// Nil for jobs queued by older versions; those stay explicitly unconfirmed.
    public var queuedIdentity: QueuedJobIdentity?
    /// Immutable attempt snapshotted from the exact bytes used and persisted on
    /// the queue-owned side before encryption. Recovery compares this against
    /// the completion record; a job without one never confirms.
    public var attempt: BuildAttemptIdentity?
    public init(id: UUID = UUID(), project: GameProject, status: String = "Waiting",
                detail: String = "", report: URL? = nil,
                queuedIdentity: QueuedJobIdentity? = nil, attempt: BuildAttemptIdentity? = nil) {
        self.id = id; self.project = project; self.status = status; self.detail = detail
        self.report = report; self.queuedIdentity = queuedIdentity; self.attempt = attempt
    }
}

/// The persisted studio session: current project, queue, config library and an
/// optional local artwork folder.
public struct StudioSession: Codable, Sendable {
    public var project: GameProject
    public var jobs: [BuildJob]
    public var configLibrary: URL?
    public var artworkLibrary: URL?
    public init(project: GameProject = GameProject(), jobs: [BuildJob] = [],
                configLibrary: URL? = nil, artworkLibrary: URL? = nil) {
        self.project = project; self.jobs = jobs
        self.configLibrary = configLibrary; self.artworkLibrary = artworkLibrary
    }
}

/// Loads the saved session with backward-compatible migration, per-entry
/// resilience and a recoverable backup.
///
/// Two boundaries are treated structurally rather than by swallowing errors:
///  * a scalar setting (the CONFIG library URL) is read as a typed value, never
///    round-tripped through `JSONSerialization` where a bare string would raise
///    an uncatchable Objective-C exception; and
///  * the jobs array is read as heterogeneous members, so one malformed element
///    cannot make the whole cast fail and discard the rest of the queue.
///
/// Every unclean load either writes a byte-identical backup or locks the
/// session so it cannot be overwritten. Values are recovered only from data the
/// app itself saved; where historical identity is unknown the job is preserved
/// but remains unconfirmed for recovery.
public enum SessionStore {
    /// Hard cap for a session file. A session holds settings and paths, never
    /// payloads, so this is generous.
    public static let maxBytes = 8 * 1024 * 1024

    public struct Outcome: Sendable {
        /// The migrated session (a blank one when nothing could be read).
        public var session: StudioSession
        /// Human-readable migration/recovery notes. Empty when the file was
        /// read cleanly.
        public var notes: [String]
        /// A byte-for-byte copy of the original file, written whenever the file
        /// was not read cleanly.
        public var backup: URL?
        /// True when recovery was needed but the original could not be copied
        /// away. The caller must not overwrite the file in that case.
        public var locked: Bool
        public init(session: StudioSession = StudioSession(), notes: [String] = [],
                    backup: URL? = nil, locked: Bool = false) {
            self.session = session; self.notes = notes; self.backup = backup; self.locked = locked
        }
        public var didRecover: Bool { !notes.isEmpty }
    }

    public static func load(from url: URL) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return Outcome() }

        let data: Data
        do {
            data = try BoundedFile.read(url, maximum: maxBytes)
        } catch {
            return unclean(url, note: "The saved session could not be read (\(error.localizedDescription)).")
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return unclean(url, note: "The saved session was not a readable JSON object.")
        }

        var notes = [String]()

        // Current project: a missing or wrong-typed value is unclean but never
        // discards a queue that can stand in for it.
        var project: GameProject?
        if let rawProject = root["project"] {
            if let dict = rawProject as? [String: Any], let decoded = decodeObject(GameProject.self, from: dict) {
                project = decoded
            } else {
                notes.append("The saved current project could not be read.")
            }
        } else {
            notes.append("The saved session had no current project.")
        }

        // Queue: read members individually. A genuinely empty array is clean; a
        // missing or wrongly-typed container is damage, not an empty queue.
        // Every recovered member — decoded, migrated, salvaged or placeholder —
        // is then normalized through one path so identifiers are always unique.
        var entries = [RecoveredEntry]()
        if let rawJobs = root["jobs"] {
            if let members = rawJobs as? [Any] {
                for (index, member) in members.enumerated() {
                    guard let dict = member as? [String: Any] else {
                        entries.append(.placeholder(placeholderJob()))
                        notes.append("Queue item \(index + 1) was not a saved job object. It was preserved as an unconfirmed placeholder so the queue is not silently shortened; review or remove it.")
                        continue
                    }
                    var jobDict = dict
                    let migrated = migrateQueuedIdentity(&jobDict)
                    if let job = decodeObject(BuildJob.self, from: jobDict) {
                        if migrated {
                            notes.append("Queue item \(index + 1) was written by an earlier version; its artwork fit setting was recovered from its own saved project.")
                        }
                        entries.append(.decoded(job))
                    } else {
                        entries.append(.salvaged(salvageJob(dict)))
                        notes.append("Queue item \(index + 1) could not be read completely. It was preserved as unconfirmed so its destination and status are not lost.")
                    }
                }
            } else {
                notes.append("The saved queue had an unexpected type and was not read as a list. No queue items were loaded; the original session was preserved.")
            }
        } else {
            notes.append("The saved session had no queue list. No queue items were loaded; the original session was preserved.")
        }
        let jobs = normalize(entries, notes: &notes)

        if project == nil {
            if let first = jobs.first(where: { !$0.project.title.isEmpty })?.project {
                project = first
                notes.append("The current project could not be read; the first queue item's saved project was restored instead.")
            } else {
                notes.append("The current project could not be read. A blank project was opened; the original session was preserved.")
            }
        }

        // CONFIG library and artwork folder: typed, validated, never a network
        // lookup, and never required to exist just to restore the rest of the
        // session.
        let configLibrary = readFolder(root["configLibrary"], label: "CONFIG library", notes: &notes)
        let artworkLibrary = readFolder(root["artworkLibrary"], label: "artwork folder", notes: &notes)

        let session = StudioSession(project: project ?? GameProject(), jobs: jobs,                                    configLibrary: configLibrary, artworkLibrary: artworkLibrary)
        var outcome = Outcome(session: session, notes: notes)
        if outcome.didRecover {
            outcome.backup = try? copyAside(url)
            outcome.locked = outcome.backup == nil
        }
        return outcome
    }

    /// Reads an optional saved folder location. A URL is persisted by
    /// `JSONEncoder` as its absolute string; a bare absolute path is accepted
    /// for older or hand-written sessions. Anything else is cleared with a
    /// note. No filesystem or network access is performed.
    private static func readFolder(_ value: Any?, label: String, notes: inout [String]) -> URL? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            if let parsed = urlFromSessionString(string) { return parsed }
            notes.append("The saved \(label) location was not a usable path and was cleared. Everything else was restored.")
        } else {
            notes.append("The saved \(label) location had an unexpected type and was cleared. Everything else was restored.")
        }
        return nil
    }

    /// Builds an outcome for an unreadable file, preserving it whenever a
    /// byte-identical copy can be made.
    private static func unclean(_ url: URL, note: String) -> Outcome {
        let backup = try? copyAside(url)
        let suffix = backup == nil ? " It was left untouched and will not be overwritten." : " A recoverable copy was saved as \(backup!.lastPathComponent)."
        return Outcome(notes: [note + suffix], backup: backup, locked: backup == nil)
    }

    /// Derives the missing `cropArtwork` on a pre-0.8.1 queue identity from the
    /// job's own saved project — data the app wrote, not a guess. A value of
    /// the wrong type is treated as missing and recovered the same way rather
    /// than failing the whole entry. Returns whether a migration was applied.
    private static func migrateQueuedIdentity(_ job: inout [String: Any]) -> Bool {
        guard var identity = job["queuedIdentity"] as? [String: Any],
              (identity["cropArtwork"] as? Bool) == nil else { return false }
        var crop = false
        if let project = job["project"] as? [String: Any], let value = project["cropArtwork"] as? Bool {
            crop = value
        }
        identity["cropArtwork"] = crop
        job["queuedIdentity"] = identity
        return true
    }

    private static func salvageJob(_ raw: [String: Any]) -> BuildJob {
        var project = (raw["project"] as? [String: Any]).flatMap { decodeObject(GameProject.self, from: $0) } ?? GameProject()
        if project.title.isEmpty, let title = raw["project"] as? [String: Any], let value = title["title"] as? String {
            project.title = value
        }
        let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let note = "This queue item was written by an older or damaged session and could not be read completely. It is preserved but cannot be confirmed; review or remove it."
        return BuildJob(id: id, project: project, status: "Interrupted", detail: note)
    }

    private static func placeholderJob() -> BuildJob {
        let note = "This queue position held a value that was not a saved job object. It is preserved as an unconfirmed placeholder so the queue is not silently shortened; review or remove it."
        return BuildJob(project: GameProject(), status: "Interrupted", detail: note)
    }

    /// A recovered queue member and how much of it was understood.
    private enum RecoveredEntry {
        case decoded(BuildJob)      // fully decoded (including a successful migration)
        case salvaged(BuildJob)     // a dictionary that could not be decoded
        case placeholder(BuildJob)  // not a dictionary at all
        var job: BuildJob {
            switch self {
            case .decoded(let job), .salvaged(let job), .placeholder(let job): return job
            }
        }
        var isDecoded: Bool { if case .decoded = self { return true }; return false }
    }

    /// The single normalization path for every recovered queue member.
    ///
    /// Identifiers are made unique regardless of ordering. A fully-decoded entry
    /// keeps its identifier in preference to a salvaged/placeholder duplicate,
    /// so recoverable recovery evidence is preserved wherever possible. When an
    /// identifier has to change, the entry's queue/attempt evidence refers to
    /// the old identity and is cleared rather than left trusted or fabricated:
    /// the row stays preserved but unconfirmed for recovery. Original order is
    /// never changed.
    private static func normalize(_ entries: [RecoveredEntry], notes: inout [String]) -> [BuildJob] {
        // Reserve identifiers for fully-decoded entries, first occurrence each.
        var reserved = Set<UUID>()
        var reservedDecodedIndex = Set<Int>()
        for (index, entry) in entries.enumerated() where entry.isDecoded {
            if !reserved.contains(entry.job.id) {
                reserved.insert(entry.job.id)
                reservedDecodedIndex.insert(index)
            }
        }
        var seen = Set<UUID>()
        var jobs = [BuildJob]()
        for (index, entry) in entries.enumerated() {
            var job = entry.job
            let idIsFree = !seen.contains(job.id) && !reserved.contains(job.id)
            let keepsID = (reservedDecodedIndex.contains(index) && !seen.contains(job.id))
                || (!entry.isDecoded && idIsFree)
            if !keepsID {
                job.id = UUID()
                job.queuedIdentity = nil
                job.attempt = nil
                notes.append("Queue item \(index + 1) repeated another item's identifier; a new identifier was assigned and its recovery evidence was cleared so it cannot match the wrong row. Both items are kept.")
            }
            seen.insert(job.id)
            jobs.append(job)
        }
        return jobs
    }

    /// Decodes a typed value from an already-parsed JSON object. Only objects
    /// and arrays reach `JSONSerialization` here; `.fragmentsAllowed` makes the
    /// boundary structurally safe even if a scalar is ever passed.
    private static func decodeObject<T: Decodable>(_ type: T.Type, from object: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// A URL is persisted by `JSONEncoder` as its absolute string. Older or
    /// hand-written sessions may hold a bare path. Anything else is rejected
    /// without any filesystem or network access.
    static func urlFromSessionString(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return nil
    }

    /// Copies the current file aside so a later write can never destroy it.
    /// Never moves or deletes the original, and never overwrites an earlier
    /// backup.
    private static func copyAside(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var counter = 0
        while true {
            let suffix = counter == 0 ? "" : "-\(counter)"
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)\(suffix).json")
            if !fm.fileExists(atPath: candidate.path) {
                try fm.copyItem(at: url, to: candidate)
                return candidate
            }
            counter += 1
            if counter > 1000 { throw ConversionFailure(message: "Could not choose a backup name.") }
        }
    }
}
