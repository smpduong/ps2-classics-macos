// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class RecoveryAssessmentTests: XCTestCase {
    private func expectation() -> PackageIdentity {
        PackageIdentity(packageSHA256: String(repeating: "a", count: 64),
                        contentID: "UP0001-SLUS12345_00-0000000000000001",
                        titleID: "SLUS12345",
                        imageNames: ["ISO.BIN.ENC", "ISO.BIN.ENC2"])
    }

    private func verified() -> VerifiedPackage {
        VerifiedPackage(entries: 14, payloadBytes: 1000,
                        contentID: "UP0001-SLUS12345_00-0000000000000001",
                        titleID: "SLUS12345",
                        names: ["PARAM.SFO", "USRDIR/ISO.BIN.ENC", "USRDIR/ISO.BIN.ENC2", "USRDIR/ISO.BIN.EDAT"])
    }

    func testConfirmedOutputRequiresEverything() {
        XCTAssertEqual(
            RecoveryAssessment.assess(expectation: expectation(),
                                      actualDigest: String(repeating: "a", count: 64),
                                      verification: .success(verified())),
            .confirmedOutput(entries: 14, payloadBytes: 1000))
    }

    func testUnrelatedValidPackageIsContainerOnly() {
        // The review's repro: a valid notes-only package with a different CID.
        let other = VerifiedPackage(entries: 1, payloadBytes: 96,
                                    contentID: "UP0001-SLUS99999_00-0000000000000002",
                                    titleID: "", names: ["notes.txt"])
        XCTAssertEqual(
            RecoveryAssessment.assess(expectation: expectation(),
                                      actualDigest: String(repeating: "a", count: 64),
                                      verification: .success(other)),
            .containerOnly(reason: "the package content ID (UP0001-SLUS99999_00-0000000000000002) is not this job's (UP0001-SLUS12345_00-0000000000000001)"))
    }

    func testReplacedOutputTitleAndDiscMismatches() {
        var wrongTitle = verified()
        wrongTitle.titleID = "SLUS99999"
        XCTAssertEqual(RecoveryAssessment.assess(expectation: expectation(),
                                                 actualDigest: String(repeating: "a", count: 64),
                                                 verification: .success(wrongTitle)),
                       .containerOnly(reason: "the package title ID (SLUS99999) is not this job's (SLUS12345)"))
        var wrongDiscs = verified()
        wrongDiscs.names = ["PARAM.SFO", "USRDIR/ISO.BIN.ENC"]
        XCTAssertEqual(RecoveryAssessment.assess(expectation: expectation(),
                                                 actualDigest: String(repeating: "a", count: 64),
                                                 verification: .success(wrongDiscs)),
                       .containerOnly(reason: "the package disc images (ISO.BIN.ENC) do not match this job's (ISO.BIN.ENC, ISO.BIN.ENC2)"))
        XCTAssertEqual(RecoveryAssessment.assess(expectation: expectation(),
                                                 actualDigest: String(repeating: "b", count: 64),
                                                 verification: .success(verified())),
                       .containerOnly(reason: "the file at the destination is not the package this job published"))
    }

    func testMissingReportOrDigestIsNeverConfirmed() {
        XCTAssertEqual(RecoveryAssessment.assess(expectation: nil,
                                                 actualDigest: String(repeating: "a", count: 64),
                                                 verification: .success(verified())),
                       .containerOnly(reason: "no completion record exists for this job"))
        var noDigest = expectation()
        noDigest.packageSHA256 = ""
        XCTAssertEqual(RecoveryAssessment.assess(expectation: noDigest,
                                                 actualDigest: String(repeating: "a", count: 64),
                                                 verification: .success(verified())),
                       .containerOnly(reason: "this job recorded no package digest to compare against"))
    }

    func testFailedVerificationFails() {
        XCTAssertEqual(RecoveryAssessment.assess(expectation: expectation(), actualDigest: "x",
                                                 verification: .failure(ConversionFailure(message: "Package content digest (QA) mismatch"))),
                       .failed(reason: "Package content digest (QA) mismatch"))
    }

    // MARK: - Job-bound recovery with the durable attempt (assessJob)

    private let attemptID = "11111111-1111-1111-1111-111111111111"
    private let fingerprint = String(repeating: "f", count: 64)

    private func queuedJob(jobID: UUID = UUID()) -> QueuedJobIdentity {
        var project = GameProject()
        project.title = "Queue Test"; project.titleID = "SLUS12345"
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        project.support.key = URL(fileURLWithPath: "/jobs/keyA.bin")
        project.support.rap = URL(fileURLWithPath: "/jobs/license.rap")
        project.support.logo = URL(fileURLWithPath: "/jobs/PS3LOGO.DAT")
        project.support.card = URL(fileURLWithPath: "/jobs/card.vmc")
        project.icon = URL(fileURLWithPath: "/jobs/icon.png")
        project.cropArtwork = false
        var first = GameDisc(source: URL(fileURLWithPath: "/jobs/disc1.iso"), gameID: "SLUS12345")
        first.config = URL(fileURLWithPath: "/jobs/a.CONFIG"); first.configHash = "cfg1"
        var second = GameDisc(source: URL(fileURLWithPath: "/jobs/disc2.iso"), gameID: "SLUS21133")
        second.configHash = nil
        project.discs = [first, second]
        return QueuedJobIdentity(jobID: jobID, project: project)
    }

    private func discs() -> [QueuedDiscIdentity] {
        [QueuedDiscIdentity(index: 0, gameID: "SLUS12345", source: "/jobs/disc1.iso",
                            sourceSHA256: "sha-disc-1", configHash: "cfg1"),
         QueuedDiscIdentity(index: 1, gameID: "SLUS21133", source: "/jobs/disc2.iso",
                            sourceSHA256: "sha-disc-2", configHash: nil)]
    }

    private func supportHashes() -> [String: String] {
        ["key": "k1", "rap": "r1", "logo": "l1", "card": "c1"]
    }
    private func assetHashes() -> [String: String] {
        ["icon": "i1", "background": "", "sound": ""]
    }

    private func matchingAttempt(jobID: UUID) -> BuildAttemptIdentity {
        BuildAttemptIdentity(attemptID: attemptID, jobID: jobID.uuidString, buildFingerprint: fingerprint,
                             title: "Queue Test", titleID: "SLUS12345",
                             contentID: "UP0001-SLUS12345_00-0000000000000001",
                             cropArtwork: false, discs: discs(),
                             supportHashes: supportHashes(), assetHashes: assetHashes())
    }

    private func matchingRecord(jobID: UUID) -> BuildCompletionRecord {
        BuildCompletionRecord(
            jobID: jobID.uuidString,
            title: "Queue Test", titleID: "SLUS12345",
            contentID: "UP0001-SLUS12345_00-0000000000000001",
            packageSHA256: String(repeating: "a", count: 64),
            discs: discs(),
            supportPaths: ["key": "/jobs/keyA.bin", "rap": "/jobs/license.rap",
                           "logo": "/jobs/PS3LOGO.DAT", "card": "/jobs/card.vmc"],
            assetPaths: ["icon": "/jobs/icon.png", "background": "", "sound": ""],
            attemptID: attemptID, buildFingerprint: fingerprint, cropArtwork: false,
            supportHashes: supportHashes(), assetHashes: assetHashes())
    }

    private func twoDiscVerified() -> VerifiedPackage {
        VerifiedPackage(entries: 14, payloadBytes: 2000,
                        contentID: "UP0001-SLUS12345_00-0000000000000001",
                        titleID: "SLUS12345",
                        names: ["PARAM.SFO", "USRDIR/CONFIG", "USRDIR/CONFIG2",
                                "USRDIR/ISO.BIN.ENC", "USRDIR/ISO.BIN.ENC2", "USRDIR/ISO.BIN.EDAT"])
    }

    func testAssessJobConfirmsOnlyItsOwnAttempt() {
        let jobID = UUID()
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: queuedJob(jobID: jobID), attempt: matchingAttempt(jobID: jobID),
                                         record: matchingRecord(jobID: jobID),
                                         actualDigest: String(repeating: "a", count: 64),
                                         verification: .success(twoDiscVerified())),
            .confirmedOutput(entries: 14, payloadBytes: 2000))
    }

    /// Legacy jobs — queued before the attempt contract, or interrupted before
    /// the attempt was written — are never confirmed.
    func testAssessJobWithoutDurableAttemptIsUnconfirmed() {
        let jobID = UUID()
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: queuedJob(jobID: jobID), attempt: nil,
                                         record: matchingRecord(jobID: jobID),
                                         actualDigest: String(repeating: "a", count: 64),
                                         verification: .success(twoDiscVerified())),
            .containerOnly(reason: "this job has no durable build attempt on record, so its output cannot be confirmed"))
    }

    func testAssessJobRejectsForeignGenuinePair() {
        // Another job's genuine package AND report: same visible metadata, but a
        // different attempt identity and different underlying inputs.
        let queued = queuedJob()
        var foreignRecord = matchingRecord(jobID: UUID())
        foreignRecord.attemptID = UUID().uuidString
        let verdict = RecoveryAssessment.assessJob(queued: queued, attempt: matchingAttempt(jobID: queued.jobID),
                                                   record: foreignRecord,
                                                   actualDigest: foreignRecord.packageSHA256,
                                                   verification: .success(twoDiscVerified()))
        guard case .containerOnly(let reason) = verdict else {
            return XCTFail("a foreign pair must never confirm, got \(verdict)")
        }
        XCTAssertTrue(reason.contains("does not name this build attempt"), reason)
    }

    func testAssessJobRejectsChangedInputsAndSettings() {
        let jobID = UUID()
        let queued = queuedJob(jobID: jobID)
        let attempt = matchingAttempt(jobID: jobID)

        func rejected(_ record: BuildCompletionRecord) -> String? {
            guard case .containerOnly(let reason) = RecoveryAssessment.assessJob(
                queued: queued, attempt: attempt, record: record,
                actualDigest: String(repeating: "a", count: 64),
                verification: .success(twoDiscVerified())) else { return nil }
            return reason
        }

        var record = matchingRecord(jobID: jobID)
        record.discs[0].sourceSHA256 = "different-bytes"
        XCTAssertTrue(rejected(record)?.contains("disc 1") == true, rejected(record) ?? "not rejected")

        record = matchingRecord(jobID: jobID)
        record.discs[1].configHash = "changed"
        XCTAssertTrue(rejected(record)?.contains("disc 2") == true, rejected(record) ?? "not rejected")

        record = matchingRecord(jobID: jobID)
        record.cropArtwork = true
        XCTAssertEqual(rejected(record), "the completion record's artwork fit setting does not match this attempt")

        record = matchingRecord(jobID: jobID)
        record.buildFingerprint = String(repeating: "0", count: 64)
        XCTAssertEqual(rejected(record), "the completion record's build fingerprint does not match this attempt")

        record = matchingRecord(jobID: jobID)
        record.supportHashes = ["key": "tampered"]
        XCTAssertEqual(rejected(record), "the completion record's support-file hashes do not match this attempt")

        record = matchingRecord(jobID: jobID)
        record.assetHashes = ["icon": "tampered"]
        XCTAssertEqual(rejected(record), "the completion record's artwork, sound or manual hashes do not match this attempt")

        record = matchingRecord(jobID: jobID)
        record.discs = Array(record.discs.prefix(1))
        XCTAssertEqual(rejected(record), "the completion record lists 1 discs but this attempt has 2")
    }

    /// The cheap queued reference is still checked after the attempt matches, so
    /// a copied attempt with altered reference paths is rejected.
    func testAssessJobQueuedGateStillRejectsPathMismatch() {
        let jobID = UUID()
        var queued = queuedJob(jobID: jobID)
        queued.supportPaths["key"] = "/somewhere/else/key.bin"
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: queued, attempt: matchingAttempt(jobID: jobID),
                                         record: matchingRecord(jobID: jobID),
                                         actualDigest: String(repeating: "a", count: 64),
                                         verification: .success(twoDiscVerified())),
            .containerOnly(reason: "the completion record's support files do not match this queued job"))
    }

    func testAssessJobRejectsAlteredReportAndMissingPieces() {
        let jobID = UUID()
        let queued = queuedJob(jobID: jobID)
        let attempt = matchingAttempt(jobID: jobID)
        var altered = matchingRecord(jobID: jobID)
        altered.title = "Something else"
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: queued, attempt: attempt, record: altered,
                                         actualDigest: String(repeating: "a", count: 64),
                                         verification: .success(twoDiscVerified())),
            .containerOnly(reason: "the completion record's title, title ID or content ID does not match this attempt"))
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: nil, attempt: attempt, record: matchingRecord(jobID: jobID),
                                         actualDigest: String(repeating: "a", count: 64),
                                         verification: .success(twoDiscVerified())),
            .containerOnly(reason: "this queue item has no recorded build identity"))
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: queued, attempt: attempt, record: nil,
                                         actualDigest: String(repeating: "a", count: 64),
                                         verification: .success(twoDiscVerified())),
            .containerOnly(reason: "no completion record exists for this job"))
        XCTAssertEqual(
            RecoveryAssessment.assessJob(queued: queued, attempt: attempt, record: matchingRecord(jobID: jobID),
                                         actualDigest: String(repeating: "b", count: 64),
                                         verification: .success(twoDiscVerified())),
            .containerOnly(reason: "the file at the destination is not the package this job published"))
    }

    func testCompletionRecordParsesAttemptFields() {
        let jobID = UUID()
        let json: [String: Any] = [
            "jobID": jobID.uuidString, "title": "T", "titleID": "SLUS12345",
            "contentID": "UP0001-SLUS12345_00-0000000000000001",
            "packageSHA256": String(repeating: "c", count: 64),
            "attemptID": attemptID, "buildFingerprint": fingerprint, "cropArtwork": true,
            "discs": [["index": 0, "gameID": "SLUS12345", "source": "/a.iso",
                       "sourceSHA256": "sha-a", "configSHA256": "cfg"]],
            "supportPaths": ["key": "/k"], "assetPaths": ["icon": "/i"],
            "supportHashes": ["key": "hk"], "assetHashes": ["icon": "hi"]]
        let record = try? XCTUnwrap(BuildCompletionRecord(json: json))
        XCTAssertEqual(record?.discs.first?.configHash, "cfg")
        XCTAssertEqual(record?.discs.first?.sourceSHA256, "sha-a")
        XCTAssertEqual(record?.discs.first?.index, 0)
        XCTAssertEqual(record?.attemptID, attemptID)
        XCTAssertEqual(record?.buildFingerprint, fingerprint)
        XCTAssertEqual(record?.cropArtwork, true)
        XCTAssertEqual(record?.supportHashes?["key"], "hk")
        XCTAssertEqual(record?.assetHashes?["icon"], "hi")
        // A legacy report without attempt fields still parses, but never confirms.
        let legacy = try? XCTUnwrap(BuildCompletionRecord(json: [
            "jobID": jobID.uuidString, "title": "T", "titleID": "SLUS12345",
            "contentID": "UP0001-SLUS12345_00-0000000000000001",
            "packageSHA256": String(repeating: "c", count: 64),
            "discs": [["gameID": "SLUS12345", "source": "/a.iso"]]]))
        XCTAssertEqual(legacy?.attemptID, "")
        XCTAssertNil(legacy?.cropArtwork)
        XCTAssertNil(BuildCompletionRecord(json: ["title": "T"]),
                     "a report without identity fields must not parse into a record")
    }

    // MARK: - Durable attempt store and bounded report reader

    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    func testAttemptStoreRoundTripAndBounds() throws {
        try temporary { folder in
            let jobID = UUID()
            let url = folder.appendingPathComponent("attempt.json")
            let attempt = matchingAttempt(jobID: jobID)
            try AttemptStore.save(attempt, to: url)
            XCTAssertEqual(AttemptStore.load(at: url), attempt)

            // Missing and malformed records are simply unconfirmed.
            XCTAssertNil(AttemptStore.load(at: folder.appendingPathComponent("missing.json")))
            let malformed = folder.appendingPathComponent("malformed.json")
            try Data("not json".utf8).write(to: malformed)
            XCTAssertNil(AttemptStore.load(at: malformed))

            // Oversized records are refused before allocation.
            let oversized = folder.appendingPathComponent("oversized.json")
            try Data(repeating: 0x20, count: AttemptStore.maxBytes + 1).write(to: oversized)
            XCTAssertNil(AttemptStore.load(at: oversized))

            // A symlink is never followed.
            let link = folder.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertNil(AttemptStore.load(at: link))
        }
    }

    func testReportReaderBoundsAndSymlinks() throws {
        try temporary { folder in
            let jobID = UUID()
            let json: [String: Any] = [
                "jobID": jobID.uuidString, "title": "Queue Test", "titleID": "SLUS12345",
                "contentID": "UP0001-SLUS12345_00-0000000000000001",
                "packageSHA256": String(repeating: "a", count: 64),
                "discs": [["index": 0, "gameID": "SLUS12345", "source": "/jobs/disc1.iso"]],
                "attemptID": attemptID, "buildFingerprint": fingerprint, "cropArtwork": false,
                "supportHashes": supportHashes(), "assetHashes": assetHashes()]
            let url = folder.appendingPathComponent("out.pkg.report.json")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            XCTAssertEqual(ReportReader.readCompletionRecord(at: url)?.attemptID, attemptID)
            XCTAssertNil(ReportReader.readCompletionRecord(at: folder.appendingPathComponent("nope.json")))
            let oversized = folder.appendingPathComponent("big.json")
            try Data(repeating: 0x20, count: ReportReader.maxBytes + 1).write(to: oversized)
            XCTAssertNil(ReportReader.readCompletionRecord(at: oversized))
            let link = folder.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertNil(ReportReader.readCompletionRecord(at: link))
        }
    }
}
