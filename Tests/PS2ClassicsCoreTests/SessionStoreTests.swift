// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import PS2ClassicsCore

final class SessionStoreTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path); try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func project(title: String = "Preserved Project", crop: Bool = false) -> GameProject {
        var project = GameProject()
        project.title = title; project.titleID = "SLUS12345"
        project.cropArtwork = crop
        project.discs = [GameDisc(source: URL(fileURLWithPath: "/games/disc1.iso"), gameID: "SLUS12345")]
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        return project
    }

    private func legacySessionJSON(project: GameProject, includeCrop: Bool, status: String = "Waiting") throws -> Data {
        var job = BuildJob(project: project, status: status)
        job.queuedIdentity = QueuedJobIdentity(jobID: job.id, project: project)
        var jobJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        if !includeCrop {
            var identity = jobJSON["queuedIdentity"] as! [String: Any]
            identity.removeValue(forKey: "cropArtwork")
            jobJSON["queuedIdentity"] = identity
        }
        let projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
        return try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [jobJSON]])
    }

    func testLegacyQueueIdentityWithoutCropArtworkLoads() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            try legacySessionJSON(project: project(crop: true), includeCrop: false).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.project.title, "Preserved Project")
            XCTAssertEqual(outcome.session.jobs.count, 1)
            // The missing setting is recovered from the job's own saved project.
            XCTAssertEqual(outcome.session.jobs[0].queuedIdentity?.cropArtwork, true)
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup, "an unclean load must leave a recoverable copy")
            XCTAssertFalse(outcome.locked)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.backup!.path))
        }
    }

    func testCleanSessionLoadsWithoutNotesOrBackup() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            try legacySessionJSON(project: project(crop: true), includeCrop: true).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.jobs.count, 1)
            XCTAssertFalse(outcome.didRecover)
            XCTAssertNil(outcome.backup)
            XCTAssertFalse(outcome.locked)
        }
    }

    func testMalformedJobIsSalvagedWithoutDiscardingValidOnes() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            var valid = BuildJob(project: project(title: "Valid"), status: "Failed")
            valid.queuedIdentity = QueuedJobIdentity(jobID: valid.id, project: valid.project)
            let validJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
            var broken = BuildJob(project: project(title: "Broken"), status: "Waiting")
            broken.queuedIdentity = QueuedJobIdentity(jobID: broken.id, project: broken.project)
            var brokenJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(broken)) as! [String: Any]
            // A structurally broken second entry: project is not an object.
            brokenJSON["project"] = "not an object"
            let projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project(title: "Current")))
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [validJSON, brokenJSON]]).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.project.title, "Current")
            XCTAssertEqual(outcome.session.jobs.count, 2, "a broken entry must be preserved, not dropped")
            XCTAssertEqual(outcome.session.jobs[0].status, "Failed")
            XCTAssertEqual(outcome.session.jobs[0].project.title, "Valid")
            XCTAssertEqual(outcome.session.jobs[1].status, "Interrupted")
            XCTAssertTrue(outcome.session.jobs[1].detail.contains("could not be read"))
            XCTAssertTrue(outcome.didRecover)
        }
    }

    func testMixedOldAndNewJobsBothLoad() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            var modern = BuildJob(project: project(title: "Modern"))
            modern.queuedIdentity = QueuedJobIdentity(jobID: modern.id, project: modern.project)
            var modernJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as! [String: Any]
            _ = modernJSON
            var legacyJob = BuildJob(project: project(title: "Legacy"))
            legacyJob.queuedIdentity = QueuedJobIdentity(jobID: legacyJob.id, project: legacyJob.project)
            var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyJob)) as! [String: Any]
            var identity = legacyJSON["queuedIdentity"] as! [String: Any]
            identity.removeValue(forKey: "cropArtwork")
            legacyJSON["queuedIdentity"] = identity
            let projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project()))
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [modernJSON, legacyJSON]]).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertEqual(outcome.session.jobs[0].project.title, "Modern")
            XCTAssertEqual(outcome.session.jobs[1].project.title, "Legacy")
            XCTAssertEqual(outcome.session.jobs[1].queuedIdentity?.cropArtwork, false)
        }
    }

    func testUnreadableJSONIsBackedUpAndOriginalPreserved() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let original = Data("this is not json {".utf8)
            try original.write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertTrue(outcome.didRecover)
            XCTAssertFalse(outcome.locked)
            XCTAssertNotNil(outcome.backup)
            XCTAssertEqual(try Data(contentsOf: url), original, "the original bytes must be untouched")
            XCTAssertEqual(try Data(contentsOf: outcome.backup!), original, "the backup must be byte-identical")
        }
    }

    func testOversizedSessionIsRejectedAndBackedUp() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            try Data(repeating: 0x20, count: SessionStore.maxBytes + 1).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup)
            XCTAssertFalse(outcome.locked)
        }
    }

    /// When the original cannot be copied aside, the session must be locked so
    /// a later save cannot silently destroy it.
    func testBackupFailureLocksTheSession() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            try Data("not json".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            let outcome = SessionStore.load(from: url)
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNil(outcome.backup)
            XCTAssertTrue(outcome.locked, "a session that cannot be backed up must be locked")
        }
    }

    // MARK: - P1: duplicate identifiers after queue salvage

    /// Builds a job dictionary whose `status` is a number, so decoding the job
    /// fails and the salvage path runs while preserving the raw identifier.
    private func damagedDuplicateJobJSON(id: UUID, project: GameProject) throws -> [String: Any] {
        var job = BuildJob(id: id, project: project, status: "Waiting")
        job.queuedIdentity = QueuedJobIdentity(jobID: id, project: project)
        var json = try jobDictionary(job)
        json["status"] = 42
        return json
    }

    private func loadJobs(_ jobs: [Any], project: GameProject, into folder: URL) throws -> (SessionStore.Outcome, URL) {
        let bytes = try JSONSerialization.data(withJSONObject: try sessionDictionary(project: project, jobs: jobs))
        let url = folder.appendingPathComponent("session.json")
        try bytes.write(to: url)
        return (SessionStore.load(from: url), url)
    }

    func testValidThenSalvagedDuplicateIsNormalized() throws {
        try temporary { folder in
            let id = UUID(); let project = fullProject()
            let valid = BuildJob(id: id, project: project, status: "Failed")
            let (outcome, _) = try loadJobs([try jobDictionary(valid), try damagedDuplicateJobJSON(id: id, project: project)], project: project, into: folder)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertEqual(Set(outcome.session.jobs.map(\.id)).count, 2, "every recovered entry must have a unique identifier")
            XCTAssertEqual(outcome.session.jobs[0].id, id, "the valid row keeps its identifier")
            XCTAssertEqual(outcome.session.jobs[0].status, "Failed")
            XCTAssertEqual(outcome.session.jobs[1].status, "Interrupted")
            XCTAssertNotNil(outcome.backup)
        }
    }

    func testSalvagedThenValidDuplicateIsNormalized() throws {
        try temporary { folder in
            let id = UUID(); let project = fullProject()
            let valid = BuildJob(id: id, project: project, status: "Failed")
            let (outcome, _) = try loadJobs([try damagedDuplicateJobJSON(id: id, project: project), try jobDictionary(valid)], project: project, into: folder)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertEqual(Set(outcome.session.jobs.map(\.id)).count, 2)
            XCTAssertEqual(outcome.session.jobs[0].status, "Interrupted")
            XCTAssertEqual(outcome.session.jobs[1].id, id)
        }
    }

    func testTwoSalvagedDuplicatesAreDistinct() throws {
        try temporary { folder in
            let id = UUID(); let project = fullProject()
            let (outcome, _) = try loadJobs([try damagedDuplicateJobJSON(id: id, project: project),
                                             try damagedDuplicateJobJSON(id: id, project: project)], project: project, into: folder)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertEqual(Set(outcome.session.jobs.map(\.id)).count, 2)
            XCTAssertTrue(outcome.session.jobs.allSatisfy { $0.status == "Interrupted" })
        }
    }

    func testTwoDecodedDuplicatesAreDistinctAndEvidenceCleared() throws {
        try temporary { folder in
            let id = UUID(); let project = fullProject()
            func withEvidence(_ status: String) -> BuildJob {
                var job = BuildJob(id: id, project: project, status: status)
                job.queuedIdentity = QueuedJobIdentity(jobID: id, project: project)
                job.attempt = BuildAttemptIdentity(attemptID: "a", jobID: id.uuidString,
                                                   buildFingerprint: "f", title: project.title, titleID: project.titleID,
                                                   contentID: project.support.contentID, cropArtwork: false,
                                                   discs: [], supportHashes: [:], assetHashes: [:])
                return job
            }
            let (outcome, _) = try loadJobs([try jobDictionary(withEvidence("Waiting")), try jobDictionary(withEvidence("Failed"))], project: project, into: folder)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertEqual(Set(outcome.session.jobs.map(\.id)).count, 2)
            let reassigned = try XCTUnwrap(outcome.session.jobs.first { $0.id != id })
            XCTAssertNil(reassigned.queuedIdentity, "a reassigned row must not keep evidence for the old identity")
            XCTAssertNil(reassigned.attempt, "a reassigned row must not keep an attempt for the old identity")
            let kept = try XCTUnwrap(outcome.session.jobs.first { $0.id == id })
            XCTAssertNotNil(kept.queuedIdentity, "the first row keeps its evidence")
        }
    }

    func testMixedMalformedQueueKeepsEveryPosition() throws {
        try temporary { folder in
            let id = UUID(); let project = fullProject()
            let valid = BuildJob(id: id, project: project, status: "Failed")
            let (outcome, _) = try loadJobs([try jobDictionary(valid), NSNull(), try damagedDuplicateJobJSON(id: id, project: project)], project: project, into: folder)
            XCTAssertEqual(outcome.session.jobs.count, 3, "positions must not be silently dropped")
            XCTAssertEqual(Set(outcome.session.jobs.map(\.id)).count, 3)
        }
    }

    func testWrongTypedCropArtworkIsRecoveredNotSalvaged() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            var project = fullProject()               // cropArtwork = true
            var job = BuildJob(project: project)
            job.queuedIdentity = QueuedJobIdentity(jobID: job.id, project: project)
            var jobJSON = try jobDictionary(job)
            var identity = jobJSON["queuedIdentity"] as! [String: Any]
            identity["cropArtwork"] = "yes"           // wrong type from a damaged writer
            jobJSON["queuedIdentity"] = identity
            let root = try sessionDictionary(project: project, jobs: [jobJSON])
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.jobs.count, 1)
            XCTAssertEqual(outcome.session.jobs[0].status, job.status, "the entry must be decoded, not replaced by a placeholder")
            XCTAssertEqual(outcome.session.jobs[0].queuedIdentity?.cropArtwork, true,
                           "a wrong-typed setting is recovered from the saved project")
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup)
        }
    }

    func testQueuedJobIdentityDecodesWithoutCropArtwork() throws {
        let json = """
        {"jobID":"\(UUID().uuidString)","title":"T","titleID":"SLUS12345","contentID":"UP0001-SLUS12345_00-0000000000000001","discs":[],"supportPaths":{},"assetPaths":{}}
        """
        let identity = try JSONDecoder().decode(QueuedJobIdentity.self, from: Data(json.utf8))
        XCTAssertFalse(identity.cropArtwork)
    }

    func testBoundedFileRejectsSymlinkMissingAndOversize() throws {
        try temporary { folder in
            let real = folder.appendingPathComponent("real.json")
            try Data("{}".utf8).write(to: real)
            XCTAssertEqual(try BoundedFile.read(real, maximum: 1024), Data("{}".utf8))
            XCTAssertThrowsError(try BoundedFile.read(folder.appendingPathComponent("missing.json"), maximum: 1024))
            let link = folder.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            XCTAssertThrowsError(try BoundedFile.read(link, maximum: 1024))
            let big = folder.appendingPathComponent("big.json")
            try Data(repeating: 0x20, count: 2048).write(to: big)
            XCTAssertThrowsError(try BoundedFile.read(big, maximum: 1024))
        }
    }

    // MARK: - P1: ordinary saved CONFIG-library selection (was a hard crash)

    private func fullProject(title: String = "Round Trip") -> GameProject {
        var project = GameProject()
        project.title = title; project.titleID = "SLUS12345"
        project.cropArtwork = true
        var disc = GameDisc(source: URL(fileURLWithPath: "/games/a b/日本 disc.iso"), gameID: "SLUS12345")
        disc.config = URL(fileURLWithPath: "/configs/SLUS12345.CONFIG")
        disc.configHash = String(repeating: "c", count: 64)
        disc.configSource = "Local library: CUSTOM/SLUS12345.CONFIG"
        project.discs = [disc]
        project.support.key = URL(fileURLWithPath: "/support/klic.bin")
        project.support.rap = URL(fileURLWithPath: "/support/license.rap")
        project.support.logo = URL(fileURLWithPath: "/support/PS3LOGO.DAT")
        project.support.card = URL(fileURLWithPath: "/support/SCEVMC0.VMC")
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        project.support.sourceFolder = URL(fileURLWithPath: "/support")
        project.icon = URL(fileURLWithPath: "/art/icon.png")
        project.background = URL(fileURLWithPath: "/art/background.jpg")
        project.sound = URL(fileURLWithPath: "/art/sound.at3")
        project.output = URL(fileURLWithPath: "/out/Game.pkg")
        return project
    }

    private func writeSession(_ session: StudioSession, to url: URL) throws {
        try JSONEncoder().encode(session).write(to: url)
    }

    func testConfigLibraryURLRoundTripsThroughProductionEncoder() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let library = URL(fileURLWithPath: "/Users/someone/My CONFIG 日本")
            try writeSession(StudioSession(project: fullProject(), jobs: [BuildJob(project: fullProject())], configLibrary: library), to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.configLibrary, library, "a normal saved CONFIG library must load without crashing")
            XCTAssertFalse(outcome.didRecover, "a clean round trip must not need a backup")
            XCTAssertNil(outcome.backup)
            XCTAssertFalse(outcome.locked)
            XCTAssertEqual(outcome.session.jobs.count, 1)
            XCTAssertEqual(outcome.session.project.discs.first?.configHash, String(repeating: "c", count: 64))
        }
    }

    func testConfigLibraryNilNullAndWrongTypeAreHandled() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            var projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullProject()))
            // nil is simply absent.
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": []]).write(to: url)
            XCTAssertNil(SessionStore.load(from: url).session.configLibrary)
            // explicit null.
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [], "configLibrary": NSNull()]).write(to: url)
            var outcome = SessionStore.load(from: url)
            XCTAssertNil(outcome.session.configLibrary)
            XCTAssertFalse(outcome.didRecover)
            // wrong scalar type: cleared, unrelated data retained, backed up.
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [], "configLibrary": 42]).write(to: url)
            outcome = SessionStore.load(from: url)
            XCTAssertNil(outcome.session.configLibrary)
            XCTAssertEqual(outcome.session.project.title, "Round Trip")
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup)
            // malformed relative string: cleared, not invented into a file path.
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [], "configLibrary": "not a path"]).write(to: url)
            outcome = SessionStore.load(from: url)
            XCTAssertNil(outcome.session.configLibrary)
            XCTAssertTrue(outcome.didRecover)
            // a bare absolute path (older/hand-written) is accepted as a file URL.
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [], "configLibrary": "/Users/someone/local configs"]).write(to: url)
            outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.configLibrary?.path, "/Users/someone/local configs")
            // the library need not exist to restore the rest of the session.
            XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.session.configLibrary?.path ?? ""))
        }
    }

    func testURLFromSessionStringValidates() {
        XCTAssertEqual(SessionStore.urlFromSessionString("file:///a%20b/c")?.path, "/a b/c")
        XCTAssertEqual(SessionStore.urlFromSessionString("/absolute/path")?.path, "/absolute/path")
        XCTAssertNil(SessionStore.urlFromSessionString(""))
        XCTAssertNil(SessionStore.urlFromSessionString("   "))
        XCTAssertNil(SessionStore.urlFromSessionString("relative/thing"))
    }

    // MARK: - P1: one malformed queue element must not discard the queue

    private func sessionDictionary(project: GameProject, jobs: [Any], configLibrary: Any? = nil) throws -> [String: Any] {
        var root: [String: Any] = ["project": try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)), "jobs": jobs]
        if let value = configLibrary { root["configLibrary"] = value }
        return root
    }

    private func jobDictionary(_ job: BuildJob) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
    }

    func testHeterogeneousJobMembersAreSalvagedIndividually() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let project = fullProject()
            var valid = BuildJob(project: project); valid.status = "Failed"
            let validJSON = try jobDictionary(valid)
            for malformed in [NSNull(), "a string", [1, 2, 3], 7] as [Any] {
                let root = try sessionDictionary(project: project, jobs: [validJSON, malformed])
                try JSONSerialization.data(withJSONObject: root).write(to: url)
                let outcome = SessionStore.load(from: url)
                XCTAssertEqual(outcome.session.jobs.count, 2, "a malformed member must not drop the valid job")
                XCTAssertEqual(outcome.session.jobs[0].id, valid.id)
                XCTAssertEqual(outcome.session.jobs[0].status, "Failed")
                XCTAssertEqual(outcome.session.jobs[1].status, "Interrupted")
                XCTAssertTrue(outcome.didRecover, "a malformed member must be reported")
                XCTAssertNotNil(outcome.backup, "an unclean load must be recoverable")
                XCTAssertFalse(outcome.locked)
            }
        }
    }

    func testMalformedDictionaryMemberIsSalvaged() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let project = fullProject()
            var valid = BuildJob(project: project)
            var broken = BuildJob(project: project)
            var brokenJSON = try jobDictionary(broken)
            brokenJSON["project"] = "not an object"   // decode fails, salvage path
            brokenJSON["id"] = broken.id.uuidString
            let root = try sessionDictionary(project: project, jobs: [try jobDictionary(valid), brokenJSON])
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertEqual(outcome.session.jobs[0].id, valid.id)
            XCTAssertEqual(outcome.session.jobs[1].id, broken.id, "a salvaged job keeps its identifier")
            XCTAssertEqual(outcome.session.jobs[1].status, "Interrupted")
            XCTAssertTrue(outcome.didRecover)
        }
    }

    func testWrongOrMissingJobsContainerIsDamageNotAnEmptyQueue() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let project = fullProject()
            for bad in ["a string", 42, ["nested": true], NSNull()] as [Any] {
                var root = try sessionDictionary(project: project, jobs: [])
                root["jobs"] = bad
                try JSONSerialization.data(withJSONObject: root).write(to: url)
                let outcome = SessionStore.load(from: url)
                XCTAssertEqual(outcome.session.jobs.count, 0)
                XCTAssertTrue(outcome.didRecover, "a wrong-typed jobs container must be reported, not treated as empty")
                XCTAssertNotNil(outcome.backup)
            }
            // Missing container is damage too.
            let missing = ["project": try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))]
            try JSONSerialization.data(withJSONObject: missing).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup)
        }
    }

    func testGenuinelyEmptyQueueIsClean() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            try JSONSerialization.data(withJSONObject: try sessionDictionary(project: fullProject(), jobs: [])).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.jobs.count, 0)
            XCTAssertEqual(outcome.session.project.title, "Round Trip")
            XCTAssertFalse(outcome.didRecover, "an empty queue is a clean session")
            XCTAssertNil(outcome.backup)
            XCTAssertFalse(outcome.locked)
        }
    }

    func testDuplicateJobIdentifiersAreKeptDistinct() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let project = fullProject()
            let id = UUID()
            let first = BuildJob(id: id, project: project, status: "Waiting")
            let second = BuildJob(id: id, project: project, status: "Failed")
            let root = try sessionDictionary(project: project, jobs: [try jobDictionary(first), try jobDictionary(second)])
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.jobs.count, 2)
            XCTAssertNotEqual(outcome.session.jobs[0].id, outcome.session.jobs[1].id, "duplicate identifiers must be made distinct")
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup)
        }
    }

    func testUnreadableProjectWithValidQueueRestoresFromQueue() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            let queuedProject = fullProject(title: "From the queue")
            let job = BuildJob(project: queuedProject, status: "Waiting")
            var root = try sessionDictionary(project: fullProject(title: "Current"), jobs: [try jobDictionary(job)])
            root["project"] = "not an object"
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertEqual(outcome.session.project.title, "From the queue")
            XCTAssertEqual(outcome.session.jobs.count, 1)
            XCTAssertTrue(outcome.didRecover)
            XCTAssertNotNil(outcome.backup)
        }
    }

    // MARK: - Full typed round trip: every persisted setting

    func testFullSessionRoundTripPreservesEverySetting() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            var project = fullProject(title: "Everything")
            let jobID = UUID()
            var job = BuildJob(id: jobID, project: project, status: "Interrupted",
                               detail: "kept", report: URL(fileURLWithPath: "/out/Game.pkg.report.json"))
            job.queuedIdentity = QueuedJobIdentity(jobID: jobID, project: project)
            job.attempt = BuildAttemptIdentity(attemptID: "attempt-1", jobID: jobID.uuidString,
                                               buildFingerprint: String(repeating: "f", count: 64),
                                               title: project.title, titleID: project.titleID,
                                               contentID: project.support.contentID, cropArtwork: true,
                                               discs: [QueuedDiscIdentity(index: 0, gameID: "SLUS12345",
                                                                          source: project.discs[0].source.path,
                                                                          sourceSHA256: String(repeating: "a", count: 64),
                                                                          configHash: project.discs[0].configHash)],
                                               supportHashes: ["key": "k"], assetHashes: ["icon": "i"])
            let library = URL(fileURLWithPath: "/Users/someone/My CONFIG 日本")
            let original = StudioSession(project: project, jobs: [job], configLibrary: library)
            try writeSession(original, to: url)
            let outcome = SessionStore.load(from: url)
            XCTAssertFalse(outcome.didRecover)
            XCTAssertEqual(outcome.session.configLibrary, library)
            XCTAssertEqual(outcome.session.project, original.project)
            XCTAssertEqual(outcome.session.jobs.count, 1)
            XCTAssertEqual(outcome.session.jobs[0], original.jobs[0], "every persisted job setting must survive the round trip")
        }
    }

    func testRepeatedCleanLoadDoesNotCreateNeedlessBackups() throws {
        try temporary { folder in
            let url = folder.appendingPathComponent("session.json")
            try writeSession(StudioSession(project: fullProject(), jobs: [BuildJob(project: fullProject())],
                                           configLibrary: URL(fileURLWithPath: "/libs")), to: url)
            for _ in 0..<3 {
                let outcome = SessionStore.load(from: url)
                XCTAssertFalse(outcome.didRecover)
                XCTAssertNil(outcome.backup)
            }
            let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains("unreadable") }
            XCTAssertTrue(backups.isEmpty, "clean files must not accumulate backups")
        }
    }
}
