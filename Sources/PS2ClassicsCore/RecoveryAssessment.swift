// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What a completed job recorded about its published package. All fields come
/// from the build report written at publication time — never from the file
/// being reconciled.
public struct PackageIdentity: Sendable, Equatable {
    public var packageSHA256: String
    public var contentID: String
    public var titleID: String
    public var imageNames: [String]
    public init(packageSHA256: String, contentID: String, titleID: String, imageNames: [String]) {
        self.packageSHA256 = packageSHA256; self.contentID = contentID
        self.titleID = titleID; self.imageNames = imageNames.sorted()
    }
}

/// What read-only package verification actually established: generic container
/// integrity plus the content the container declares about itself.
public struct VerifiedPackage: Sendable, Equatable {
    public var entries: Int
    public var payloadBytes: UInt64
    public var contentID: String
    public var titleID: String
    public var names: [String]
    public init(entries: Int, payloadBytes: UInt64, contentID: String, titleID: String, names: [String]) {
        self.entries = entries; self.payloadBytes = payloadBytes
        self.contentID = contentID; self.titleID = titleID; self.names = names
    }
}

public enum RecoveryVerdict: Equatable {
    case confirmedOutput(entries: Int, payloadBytes: UInt64)
    case containerOnly(reason: String)
    case failed(reason: String)
}

/// Decides whether a verified package is confirmed output of a specific job.
/// Generic integrity alone yields at most `containerOnly` — never recovery.
public enum RecoveryAssessment {
    public static func assess(expectation: PackageIdentity?,
                              actualDigest: String?,
                              verification: Result<VerifiedPackage, ConversionFailure>) -> RecoveryVerdict {
        guard case .success(let verified) = verification else {
            if case .failure(let failure) = verification { return .failed(reason: failure.message) }
            return .failed(reason: "verification did not complete")
        }
        guard let expectation = expectation else {
            return .containerOnly(reason: "no completion record exists for this job")
        }
        guard !expectation.packageSHA256.isEmpty, let digest = actualDigest, !digest.isEmpty else {
            return .containerOnly(reason: "this job recorded no package digest to compare against")
        }
        guard digest.lowercased() == expectation.packageSHA256.lowercased() else {
            return .containerOnly(reason: "the file at the destination is not the package this job published")
        }
        guard verified.contentID == expectation.contentID else {
            return .containerOnly(reason: "the package content ID (\(verified.contentID)) is not this job's (\(expectation.contentID))")
        }
        guard !verified.titleID.isEmpty, verified.titleID == expectation.titleID else {
            return .containerOnly(reason: "the package title ID (\(verified.titleID)) is not this job's (\(expectation.titleID))")
        }
        let actualImages = verified.names.filter { $0.hasPrefix("USRDIR/ISO.BIN.ENC") }
            .map { String($0.dropFirst("USRDIR/".count)) }.sorted()
        guard actualImages == expectation.imageNames else {
            return .containerOnly(reason: "the package disc images (\(actualImages.joined(separator: ", "))) do not match this job's (\(expectation.imageNames.joined(separator: ", ")))")
        }
        return .confirmedOutput(entries: verified.entries, payloadBytes: verified.payloadBytes)
    }

    /// Decides whether a verified package is confirmed output of a specific
    /// QUEUED job. Two independent bindings must hold: the durable build
    /// attempt persisted by the queue matches the completion record on
    /// immutable hashes/settings, and the queued reference matches on paths and
    /// IDs. A job with no durable attempt — legacy, or a crash before the
    /// attempt was written — stays explicitly unconfirmed; matching two
    /// adjacent files never establishes either.
    public static func assessJob(queued: QueuedJobIdentity?,
                                 attempt: BuildAttemptIdentity? = nil,
                                 record: BuildCompletionRecord?,
                                 actualDigest: String?,
                                 verification: Result<VerifiedPackage, ConversionFailure>) -> RecoveryVerdict {
        guard case .success = verification else {
            if case .failure(let failure) = verification { return .failed(reason: failure.message) }
            return .failed(reason: "verification did not complete")
        }
        guard let queued = queued else {
            return .containerOnly(reason: "this queue item has no recorded build identity")
        }
        guard let record = record else {
            return .containerOnly(reason: "no completion record exists for this job")
        }
        guard let attempt = attempt else {
            return .containerOnly(reason: "this job has no durable build attempt on record, so its output cannot be confirmed")
        }
        if let mismatch = attempt.mismatch(against: record) {
            return .containerOnly(reason: mismatch)
        }
        if let mismatch = queued.mismatch(against: record) {
            return .containerOnly(reason: mismatch)
        }
        let identity = PackageIdentity(packageSHA256: record.packageSHA256, contentID: record.contentID,
                                       titleID: record.titleID,
                                       imageNames: record.discs.enumerated().map { "ISO.BIN.ENC" + ($0.offset == 0 ? "" : String($0.offset + 1)) })
        return assess(expectation: identity, actualDigest: actualDigest, verification: verification)
    }
}

/// Identity a queued job carries from enqueue time: cheap stable fields only
/// (IDs, ordered discs, paths, selection hashes). Never raw secrets or bytes.
public struct QueuedDiscIdentity: Codable, Equatable, Sendable {
    /// Position in the ordered disc list. Recorded when the attempt is
    /// snapshotted; nil for the cheap enqueue-time reference.
    public var index: Int?
    public var gameID: String
    public var source: String
    /// SHA-256 of the exact source bytes used. Recorded on the build-attempt
    /// side, so recovery never reconstructs a historical fingerprint by
    /// re-reading a mutable path.
    public var sourceSHA256: String?
    public var configHash: String?
    public init(index: Int? = nil, gameID: String, source: String,
                sourceSHA256: String? = nil, configHash: String?) {
        self.index = index; self.gameID = gameID; self.source = source
        self.sourceSHA256 = sourceSHA256; self.configHash = configHash
    }
}

public struct QueuedJobIdentity: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var title: String
    public var titleID: String
    public var contentID: String
    /// Whether artwork was cropped to fill. Output-affecting, so it is part of
    /// the queued identity gate as well as the durable attempt.
    public var cropArtwork: Bool
    public var discs: [QueuedDiscIdentity]
    public var supportPaths: [String: String]
    public var assetPaths: [String: String]
    public init(jobID: UUID, project: GameProject) {
        self.jobID = jobID
        self.title = project.title
        self.titleID = project.titleID
        self.contentID = project.support.contentID
        self.cropArtwork = project.cropArtwork
        self.discs = project.discs.map {
            QueuedDiscIdentity(gameID: $0.gameID,
                               source: $0.source.standardizedFileURL.path,
                               configHash: $0.configHash)
        }
        func path(_ url: URL?) -> String { url?.standardizedFileURL.path ?? "" }
        self.supportPaths = ["key": path(project.support.key), "rap": path(project.support.rap),
                             "logo": path(project.support.logo), "card": path(project.support.card)]
        self.assetPaths = ["icon": path(project.icon), "background": path(project.background),
                           "sound": path(project.sound)]
        if let manual = project.manual { self.assetPaths["manual"] = path(manual) }
    }

    static func standardizing(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    enum CodingKeys: String, CodingKey {
        case jobID, title, titleID, contentID, cropArtwork, discs, supportPaths, assetPaths
    }

    /// Explicitly tolerant decoding. `cropArtwork` was added after 0.8, so a
    /// queue identity written by an earlier supported version lacks it; default
    /// it rather than failing the whole session. Recovery still never infers
    /// confirmation from a migrated identity — the durable attempt and the
    /// saved project remain the authority.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        title = try container.decode(String.self, forKey: .title)
        titleID = try container.decode(String.self, forKey: .titleID)
        contentID = try container.decode(String.self, forKey: .contentID)
        cropArtwork = try container.decodeIfPresent(Bool.self, forKey: .cropArtwork) ?? false
        discs = try container.decode([QueuedDiscIdentity].self, forKey: .discs)
        supportPaths = try container.decode([String: String].self, forKey: .supportPaths)
        assetPaths = try container.decode([String: String].self, forKey: .assetPaths)
    }

    /// Returns a human-readable mismatch reason, or nil when the completion
    /// record belongs to this queued job.
    public func mismatch(against record: BuildCompletionRecord) -> String? {
        guard record.jobID.lowercased() == jobID.uuidString.lowercased(), !record.jobID.isEmpty else {
            return "the completion record belongs to a different queued job"
        }
        guard record.title == title, record.titleID == titleID, record.contentID == contentID else {
            return "the completion record's title, title ID or content ID does not match this queued job"
        }
        guard record.cropArtwork == cropArtwork else {
            return "the completion record's artwork fit setting does not match this queued job"
        }
        guard record.discs.count == discs.count else {
            return "the completion record lists \(record.discs.count) discs but this queued job has \(discs.count)"
        }
        for (i, (recorded, expected)) in zip(record.discs, discs).enumerated() {
            guard recorded.gameID == expected.gameID,
                  Self.standardizing(recorded.source) == Self.standardizing(expected.source),
                  recorded.configHash == expected.configHash,
                  expected.sourceSHA256 == nil || recorded.sourceSHA256 == expected.sourceSHA256 else {
                return "the completion record's disc \(i + 1) (game ID, source, source bytes or CONFIG) does not match this queued job"
            }
        }
        guard record.supportPaths == supportPaths else {
            return "the completion record's support files do not match this queued job"
        }
        guard record.assetPaths == assetPaths else {
            return "the completion record's artwork, sound or manual does not match this queued job"
        }
        return nil
    }
}

/// Immutable, durable identity of one concrete build attempt, snapshotted from
/// the exact bytes the builder used and persisted on the queue-owned side
/// *before* encryption starts. It carries every output-affecting setting so
/// recovery compares hashes and settings rather than mutable paths. Raw secrets
/// and file bytes are never stored — only one-way hashes.
public struct BuildAttemptIdentity: Codable, Equatable, Sendable {
    public var attemptID: String
    public var jobID: String
    public var buildFingerprint: String
    public var title: String
    public var titleID: String
    public var contentID: String
    public var cropArtwork: Bool
    public var discs: [QueuedDiscIdentity]
    public var supportHashes: [String: String]
    public var assetHashes: [String: String]
    public init(attemptID: String, jobID: String, buildFingerprint: String, title: String,
                titleID: String, contentID: String, cropArtwork: Bool,
                discs: [QueuedDiscIdentity], supportHashes: [String: String],
                assetHashes: [String: String]) {
        self.attemptID = attemptID; self.jobID = jobID; self.buildFingerprint = buildFingerprint
        self.title = title; self.titleID = titleID; self.contentID = contentID
        self.cropArtwork = cropArtwork; self.discs = discs
        self.supportHashes = supportHashes; self.assetHashes = assetHashes
    }

    /// Returns a human-readable mismatch reason, or nil when the completion
    /// record is proven to be this exact attempt. Every field must match.
    public func mismatch(against record: BuildCompletionRecord) -> String? {
        guard !record.attemptID.isEmpty, record.attemptID == attemptID else {
            return "the completion record does not name this build attempt"
        }
        guard !record.buildFingerprint.isEmpty, record.buildFingerprint == buildFingerprint else {
            return "the completion record's build fingerprint does not match this attempt"
        }
        guard record.title == title, record.titleID == titleID, record.contentID == contentID else {
            return "the completion record's title, title ID or content ID does not match this attempt"
        }
        guard record.cropArtwork == cropArtwork else {
            return "the completion record's artwork fit setting does not match this attempt"
        }
        guard record.discs.count == discs.count else {
            return "the completion record lists \(record.discs.count) discs but this attempt has \(discs.count)"
        }
        for (i, (recorded, expected)) in zip(record.discs, discs).enumerated() {
            guard recorded.index == expected.index,
                  recorded.gameID == expected.gameID,
                  QueuedJobIdentity.standardizing(recorded.source) == QueuedJobIdentity.standardizing(expected.source),
                  recorded.sourceSHA256 == expected.sourceSHA256,
                  recorded.configHash == expected.configHash else {
                return "the completion record's disc \(i + 1) (order, game ID, source bytes or CONFIG) does not match this attempt"
            }
        }
        guard record.supportHashes == supportHashes else {
            return "the completion record's support-file hashes do not match this attempt"
        }
        guard record.assetHashes == assetHashes else {
            return "the completion record's artwork, sound or manual hashes do not match this attempt"
        }
        return nil
    }
}

/// Durable, bounded storage for one job's current build attempt. Written on the
/// build thread before encryption and read off the main actor during recovery.
public enum AttemptStore {
    public static let maxBytes = 1024 * 1024
    public static func save(_ attempt: BuildAttemptIdentity, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(attempt)
        try data.write(to: url, options: [.atomic])
    }
    /// Reads a regular, non-symlink file within a hard size cap using a single
    /// bounded read. Missing, malformed or oversized records are simply
    /// "unconfirmed", never trusted.
    public static func load(at url: URL) -> BuildAttemptIdentity? {
        guard let data = try? BoundedFile.read(url, maximum: maxBytes) else { return nil }
        return try? JSONDecoder().decode(BuildAttemptIdentity.self, from: data)
    }
}

/// Bounded, off-the-main-actor reader for a neighboring completion report. An
/// editable JSON file is evidence to compare, not tamper-proof provenance.
public enum ReportReader {
    public static let maxBytes = 4 * 1024 * 1024
    public static func readCompletionRecord(at url: URL) -> BuildCompletionRecord? {
        guard let data = try? BoundedFile.read(url, maximum: maxBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return BuildCompletionRecord(json: json)
    }
}

/// The completion-record half of a recovery comparison, parsed from the
/// neighboring report. Absent fields mean "unknown", never "match". The record
/// is an editable local file used as evidence to compare, not tamper-proof
/// provenance.
public struct BuildCompletionRecord: Sendable, Equatable {
    public var jobID: String
    public var title: String
    public var titleID: String
    public var contentID: String
    public var packageSHA256: String
    public var discs: [QueuedDiscIdentity]
    public var supportPaths: [String: String]
    public var assetPaths: [String: String]
    /// Durable attempt identity carried in the report. Empty/absent on reports
    /// written before this contract existed; those never confirm.
    public var attemptID: String
    public var buildFingerprint: String
    public var cropArtwork: Bool?
    public var supportHashes: [String: String]?
    public var assetHashes: [String: String]?
    public init(jobID: String, title: String, titleID: String, contentID: String,
                packageSHA256: String, discs: [QueuedDiscIdentity],
                supportPaths: [String: String], assetPaths: [String: String],
                attemptID: String = "", buildFingerprint: String = "",
                cropArtwork: Bool? = nil, supportHashes: [String: String]? = nil,
                assetHashes: [String: String]? = nil) {
        self.jobID = jobID; self.title = title; self.titleID = titleID; self.contentID = contentID
        self.packageSHA256 = packageSHA256; self.discs = discs
        self.supportPaths = supportPaths; self.assetPaths = assetPaths
        self.attemptID = attemptID; self.buildFingerprint = buildFingerprint
        self.cropArtwork = cropArtwork; self.supportHashes = supportHashes; self.assetHashes = assetHashes
    }
    public init?(json: [String: Any]) {
        guard let jobID = json["jobID"] as? String,
              let title = json["title"] as? String,
              let titleID = json["titleID"] as? String,
              let contentID = json["contentID"] as? String,
              let packageSHA256 = json["packageSHA256"] as? String,
              let discs = json["discs"] as? [[String: Any]] else { return nil }
        self.jobID = jobID; self.title = title; self.titleID = titleID
        self.contentID = contentID; self.packageSHA256 = packageSHA256
        self.discs = discs.map {
            QueuedDiscIdentity(index: ($0["index"] as? NSNumber)?.intValue,
                               gameID: $0["gameID"] as? String ?? "",
                               source: $0["source"] as? String ?? "",
                               sourceSHA256: ($0["sourceSHA256"] as? String) ?? ($0["sha256"] as? String),
                               configHash: $0["configSHA256"] as? String)
        }
        self.supportPaths = json["supportPaths"] as? [String: String] ?? [:]
        self.assetPaths = json["assetPaths"] as? [String: String] ?? [:]
        self.attemptID = json["attemptID"] as? String ?? ""
        self.buildFingerprint = json["buildFingerprint"] as? String ?? ""
        self.cropArtwork = json["cropArtwork"] as? Bool
        self.supportHashes = json["supportHashes"] as? [String: String]
        self.assetHashes = json["assetHashes"] as? [String: String]
    }
}
