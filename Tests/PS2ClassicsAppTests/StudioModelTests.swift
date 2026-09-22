// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Darwin
import PS2ClassicsCore
@testable import PS2ClassicsApp

/// Entry-point ownership and cancellation regressions for the actual app
/// models. Every test runs against an isolated temporary state/helper/attempt
/// directory, so no real user session, queue, settings or game image is touched.
@MainActor
final class StudioModelTests: XCTestCase {
    private func makeModel(_ folder: URL) -> StudioModel {
        StudioModel(stateURL: folder.appendingPathComponent("session.json"),
                    helperURL: folder.appendingPathComponent("helper"),
                    attemptDirectory: folder.appendingPathComponent("attempts"))
    }

    /// Deterministic short sleep-based poll: long synthetic work means we never
    /// depend on sub-second click timing.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func syntheticISO(named: String = "disc.iso", in folder: URL) throws -> URL {
        var data = Data(repeating: 0, count: 24 * 2048)
        let offset = 16 * 2048
        data[offset] = 1
        data.replaceSubrange((offset + 1)..<(offset + 6), with: Data("CD001".utf8))
        data[offset + 6] = 1
        data[offset + 80] = 24
        data[offset + 87] = 24
        data[offset + 129] = 8
        data[offset + 130] = 8
        let url = folder.appendingPathComponent(named)
        try data.write(to: url)
        return url
    }

    /// A helper that stays alive until terminated, so contention windows are
    /// wide and deterministic instead of relying on sub-second clicks.
    private func sleepingHelper(in folder: URL, seconds: Int = 10) throws -> URL {
        let url = folder.appendingPathComponent("sleeping-helper")
        try "#!/bin/sh\nexec sleep \(seconds)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A helper that records its PID and keeps running for a while after
    /// SIGTERM, so we can prove the operation slot is held until it truly exits.
    private func delayedTerminationHelper(in folder: URL, marker: URL, delay: Int = 2) throws -> URL {
        let url = folder.appendingPathComponent("delayed-helper")
        let script = "#!/bin/sh\necho $$ > \"\(marker.path)\"\ntrap 'sleep \(delay); exit 0' TERM\nwhile true; do sleep 0.2; done\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func realHelper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PS2_TEST_HELPER"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("set PS2_TEST_HELPER to run real-helper lifecycle tests")
        }
        return URL(fileURLWithPath: path)
    }

    private func supportFiles(in folder: URL) throws {
        try Data(repeating: 1, count: 16).write(to: folder.appendingPathComponent("klic.bin"))
        try Data(repeating: 2, count: 16).write(to: folder.appendingPathComponent("license.rap"))
        try Data([3]).write(to: folder.appendingPathComponent("PS3LOGO.DAT"))
        var card = Data(repeating: 0, count: 8650752)
        card.replaceSubrange(0..<28, with: Data("Sony PS2 Memory Card Format  ".utf8).prefix(28))
        try card.write(to: folder.appendingPathComponent("SCEVMC0.VMC"))
    }

    private func makeValidProject(in folder: URL, output: String) throws -> GameProject {
        try supportFiles(in: folder)
        let iso = try syntheticISO(in: folder)
        var project = GameProject()
        project.title = "Lifecycle Test"; project.titleID = "SLUS12345"
        project.discs = [GameDisc(source: iso, gameID: "SLUS12345")]
        project.support.key = folder.appendingPathComponent("klic.bin")
        project.support.rap = folder.appendingPathComponent("license.rap")
        project.support.logo = folder.appendingPathComponent("PS3LOGO.DAT")
        project.support.card = folder.appendingPathComponent("SCEVMC0.VMC")
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        project.output = folder.appendingPathComponent(output)
        return project
    }

    // MARK: - addDiscs uses the shared ownership slot

    /// Reproduces the review's bypass: while a build/utility owns the app,
    /// importing discs must be refused, must not add discs, and must leave the
    /// owning token intact.
    func testAddDiscsIsRefusedWhileAnotherOperationOwnsTheApp() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let iso = try syntheticISO(in: folder)
            guard let build = model.beginUtility(.build, cancel: {}) else { return XCTFail("setup claim failed") }
            // The build owns the app; an import must not steal or bypass it.
            model.addDiscs([iso])
            _ = await waitUntil(timeout: 2) { !model.inspecting }
            XCTAssertTrue(model.project.discs.isEmpty, "an import must not run while a build owns the app")
            XCTAssertTrue(model.ownsUtility(build), "the build's token must remain owned")
            XCTAssertTrue(model.working, "the app must still report busy")
            model.endUtility(build)
            XCTAssertFalse(model.working)
        }
    }

    /// The reverse direction: an in-flight import owns the slot, so a queued
    /// build must wait rather than start beside it.
    func testImportBlocksAQueuedBuild() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.helperURL = try sleepingHelper(in: folder)
            let chd = folder.appendingPathComponent("slow.chd")
            try Data([0]).write(to: chd)
            model.addDiscs([chd])
            let claimed = await waitUntil { model.inspecting && model.utilityBusy }
            XCTAssertTrue(claimed, "the import must claim the shared slot")

            var project = GameProject()
            project.output = folder.appendingPathComponent("queued.pkg")
            model.jobs = [BuildJob(project: project)]
            model.runQueue = true
            model.next()
            XCTAssertNil(model.active, "a build must not start while an import owns the slot")

            // Stop the import before the queue can continue.
            model.runQueue = false
            model.cancelUtilityOperation()
            let released = await waitUntil { !model.inspecting && !model.working }
            XCTAssertTrue(released, "cancelling the import must release the slot")
            XCTAssertTrue(model.project.discs.isEmpty, "a cancelled import must not add discs")
        }
    }

    /// The happy path still imports through the shared slot and releases it.
    func testAddDiscsImportsAndReleasesTheSlot() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let iso = try syntheticISO(in: folder)
            model.addDiscs([iso])
            let finished = await waitUntil { !model.inspecting }
            XCTAssertTrue(finished)
            XCTAssertEqual(model.project.discs.count, 1)
            XCTAssertFalse(model.working, "the slot must be released after import")
            XCTAssertFalse(model.utilityBusy)
        }
    }

    // MARK: - verifyPublished cancellation is not a verification failure

    func testVerifyPublishedCancellationIsReportedAsCancelled() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.helperURL = try verifyHelper(in: folder)
            let output = folder.appendingPathComponent("out.pkg")
            try Data(repeating: 7, count: 8192).write(to: output)
            var project = GameProject()
            project.title = "Cancel Test"; project.titleID = "SLUS12345"
            project.output = output
            var job = BuildJob(project: project)
            job.status = "Interrupted"
            model.jobs = [job]
            let report: [String: Any] = ["jobID": job.id.uuidString, "title": "Cancel Test",
                                         "titleID": "SLUS12345",
                                         "contentID": "UP0001-SLUS12345_00-0000000000000001",
                                         "packageSHA256": String(repeating: "a", count: 64),
                                         "discs": [["index": 0, "gameID": "SLUS12345", "source": "/disc.iso"]]]
            try JSONSerialization.data(withJSONObject: report)
                .write(to: URL(fileURLWithPath: output.path + ".report.json"))

            model.verifyPublished(job.id)
            let started = await waitUntil { model.busyJob == job.id }
            XCTAssertTrue(started, "the check must start")
            // Cancel during the helper phase (the sleeping helper holds it open).
            try? await Task.sleep(nanoseconds: 300_000_000)
            model.cancelUtilityOperation()
            let settle = await waitUntil { model.busyJob == nil }
            XCTAssertTrue(settle, "the check must finish after cancellation")

            XCTAssertEqual(model.jobs.first?.status, "Interrupted")
            let detail = (model.jobs.first?.detail ?? "").lowercased()
            XCTAssertTrue(detail.contains("cancelled"), "expected a cancellation message, got: \(detail)")
            XCTAssertFalse(detail.contains("did not verify"), "a cancellation must not be reported as a verification failure: \(detail)")
            XCTAssertFalse(model.working, "the owning token must be released exactly once")
        }
    }

    // MARK: - Image-tools detection cancels a launched helper

    func testWorkspaceDetectCancellationStopsTheHelper() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.helperURL = try sleepingHelper(in: folder)
            let workspace = WorkspaceModel(studio: model)
            workspace.source = folder.appendingPathComponent("image.enc")
            try Data(repeating: 3, count: 256).write(to: workspace.source!)
            workspace.detectProfile()
            let detecting = await waitUntil { workspace.detecting }
            XCTAssertTrue(detecting, "detection must claim a runner")
            workspace.cancel()
            let stopped = await waitUntil { !workspace.busy }
            XCTAssertTrue(stopped, "cancel must stop the detection helper")
            XCTAssertNil(workspace.detection)
            XCTAssertFalse(model.working, "the detection slot must be released")
        }
    }

    /// A helper for verification: emits one progress event, then stays alive
    /// until terminated.
    private func verifyHelper(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("verify-helper")
        try "#!/bin/sh\nprintf '{\"stage\":\"verifying\",\"completed\":1,\"total\":100}\\n'\nexec sleep 10\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Session migration through the real model

    /// The review's session-loss reproduction: a 0.8 queue identity without
    /// `cropArtwork` must not discard the project and queue, and an ordinary
    /// New Project action must not silently destroy the original bytes.
    func testLegacySessionMigrationPreservesProjectQueueAndBackup() async throws {
        try await withTemporaryAsync { folder in
            var project = GameProject()
            project.title = "Preserve my 0.8 project"; project.titleID = "SLUS12345"
            project.cropArtwork = true
            project.discs = [GameDisc(source: folder.appendingPathComponent("original.iso"), gameID: "SLUS12345")]
            project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
            var job = BuildJob(project: project, status: "Failed")
            job.queuedIdentity = QueuedJobIdentity(jobID: job.id, project: project)
            var jobJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
            var identity = jobJSON["queuedIdentity"] as! [String: Any]
            identity.removeValue(forKey: "cropArtwork") // exact 0.8 representation
            jobJSON["queuedIdentity"] = identity
            let projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
            let state = folder.appendingPathComponent("session.json")
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [jobJSON]]).write(to: state)
            let originalBytes = try Data(contentsOf: state)

            let model = StudioModel(stateURL: state, helperURL: folder.appendingPathComponent("helper"),
                                    attemptDirectory: folder.appendingPathComponent("attempts"))
            XCTAssertEqual(model.project.title, "Preserve my 0.8 project")
            XCTAssertEqual(model.jobs.count, 1)
            XCTAssertEqual(model.jobs[0].status, "Failed")
            XCTAssertEqual(model.jobs[0].queuedIdentity?.cropArtwork, true)
            XCTAssertNotNil(model.message)

            model.newProject()
            XCTAssertEqual(model.project.title, "")
            let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("session.json.unreadable-") }
            XCTAssertEqual(backups.count, 1, "the pre-migration session must be recoverable")
            XCTAssertEqual(try Data(contentsOf: backups[0]), originalBytes)
        }
    }

    /// When the session cannot be backed up, the model must refuse to overwrite
    /// it rather than silently destroying the unreadable file.
    func testLockedSessionIsNotOverwritten() async throws {
        try await withTemporaryAsync { folder in
            let state = folder.appendingPathComponent("session.json")
            let original = Data("not valid json {".utf8)
            try original.write(to: state)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            let model = StudioModel(stateURL: state, helperURL: folder.appendingPathComponent("helper"),
                                    attemptDirectory: folder.appendingPathComponent("attempts"))
            model.newProject()
            XCTAssertEqual(try Data(contentsOf: state), original, "a locked session must be left untouched")
            XCTAssertNotNil(model.message)
        }
    }

    /// Populate every persisted setting through the real model, persist, then
    /// load it again through a fresh model — the production encoder/loader path.
    func testFullModelPersistenceRoundTrip() async throws {
        try await withTemporaryAsync { folder in
            let state = folder.appendingPathComponent("session.json")
            let attempts = folder.appendingPathComponent("attempts")
            @MainActor func make() -> StudioModel {
                StudioModel(stateURL: state, helperURL: folder.appendingPathComponent("helper"), attemptDirectory: attempts)
            }
            let model = make()
            var project = GameProject()
            project.title = "Everything"; project.titleID = "SLUS12345"; project.cropArtwork = true
            var disc = GameDisc(source: folder.appendingPathComponent("disc.iso"), gameID: "SLUS12345")
            disc.config = folder.appendingPathComponent("SLUS12345.CONFIG")
            disc.configHash = String(repeating: "c", count: 64)
            disc.configSource = "Local library: CUSTOM/SLUS12345.CONFIG"
            project.discs = [disc]
            project.support.key = folder.appendingPathComponent("klic.bin")
            project.support.rap = folder.appendingPathComponent("license.rap")
            project.support.logo = folder.appendingPathComponent("PS3LOGO.DAT")
            project.support.card = folder.appendingPathComponent("SCEVMC0.VMC")
            project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
            project.support.sourceFolder = folder
            project.icon = folder.appendingPathComponent("icon.png")
            project.background = folder.appendingPathComponent("bg.png")
            project.sound = folder.appendingPathComponent("snd.at3")
            project.output = folder.appendingPathComponent("out.pkg")
            model.project = project
            model.configLibrary = folder.appendingPathComponent("configs")
            var job = BuildJob(project: project, status: "Interrupted", detail: "kept",
                               report: folder.appendingPathComponent("out.pkg.report.json"))
            job.queuedIdentity = QueuedJobIdentity(jobID: job.id, project: project)
            job.attempt = BuildAttemptIdentity(attemptID: "a1", jobID: job.id.uuidString,
                                               buildFingerprint: String(repeating: "f", count: 64),
                                               title: project.title, titleID: project.titleID,
                                               contentID: project.support.contentID, cropArtwork: true,
                                               discs: [QueuedDiscIdentity(index: 0, gameID: "SLUS12345",
                                                                          source: disc.source.path,
                                                                          sourceSHA256: String(repeating: "a", count: 64),
                                                                          configHash: disc.configHash)],
                                               supportHashes: ["key": "k"], assetHashes: ["icon": "i"])
            model.jobs = [job]
            model.persist()

            let reloaded = make()
            XCTAssertNil(reloaded.message, "a clean round trip must not report recovery")
            XCTAssertEqual(reloaded.project, project, "every project setting must survive")
            XCTAssertEqual(reloaded.configLibrary, model.configLibrary, "the CONFIG library selection must survive")
            XCTAssertEqual(reloaded.jobs.count, 1)
            XCTAssertEqual(reloaded.jobs[0], job, "every persisted job setting must survive")
        }
    }

    /// A damaged queue must not lose evidence: the backup is made before any
    /// later save, survives New Project, and the next launch is clean.
    func testDamagedQueueBackupSurvivesNewProjectAndRelaunch() async throws {
        try await withTemporaryAsync { folder in
            let state = folder.appendingPathComponent("session.json")
            let attempts = folder.appendingPathComponent("attempts")
            var project = GameProject()
            project.title = "Damaged"; project.titleID = "SLUS12345"
            project.discs = [GameDisc(source: folder.appendingPathComponent("disc.iso"), gameID: "SLUS12345")]
            project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
            var job = BuildJob(project: project, status: "Failed")
            job.queuedIdentity = QueuedJobIdentity(jobID: job.id, project: project)
            let jobJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job))
            let projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [jobJSON, NSNull()]]).write(to: state)
            let originalBytes = try Data(contentsOf: state)

            let model = StudioModel(stateURL: state, helperURL: folder.appendingPathComponent("helper"), attemptDirectory: attempts)
            XCTAssertEqual(model.jobs.count, 2, "the valid job and a placeholder must both load")
            XCTAssertNotNil(model.recoveryBackupURL, "an unclean load must expose a recoverable backup")
            XCTAssertNotNil(model.message)

            model.newProject()
            let backupURL = try XCTUnwrap(model.recoveryBackupURL)
            XCTAssertEqual(try Data(contentsOf: backupURL), originalBytes, "the backup must remain byte-identical")

            let relaunched = StudioModel(stateURL: state, helperURL: folder.appendingPathComponent("helper"), attemptDirectory: attempts)
            XCTAssertNil(relaunched.message, "the repaired session must load cleanly")
            XCTAssertEqual(relaunched.jobs.count, 2)
        }
    }

    // MARK: - Operation ownership during project replacement

    func testInvalidateImportHoldsSlotUntilHelperStops() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let marker = folder.appendingPathComponent("helper.pid")
            model.helperURL = try delayedTerminationHelper(in: folder, marker: marker, delay: 2)
            let chd = folder.appendingPathComponent("slow.chd")
            try Data([0]).write(to: chd)
            model.addDiscs([chd])
            let helperRunning = await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
            XCTAssertTrue(helperRunning,
                          "the import helper must be running")
            let pid = Int32(((try? String(contentsOf: marker, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            XCTAssertGreaterThan(pid, 0)
            XCTAssertEqual(kill(pid, 0), 0, "the helper must be alive")

            model.newProject()
            // The old helper is still stopping, so the slot must stay owned.
            XCTAssertNil(model.beginUtility(.verify, cancel: {}),
                         "a new operation must not start while the old helper is alive")

            let released = await waitUntil(timeout: 10) { !model.working }
            XCTAssertTrue(released, "the slot must release once the helper exits")
            XCTAssertNotEqual(kill(pid, 0), 0, "the helper must have exited before the slot was released")
            XCTAssertNotNil(model.beginUtility(.verify, cancel: {}), "the slot must reopen after the helper stops")
        }
    }

    func testQueuedBuildWaitsBehindImportThroughReplacement() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let marker = folder.appendingPathComponent("helper.pid")
            model.helperURL = try delayedTerminationHelper(in: folder, marker: marker, delay: 2)
            let chd = folder.appendingPathComponent("slow.chd")
            try Data([0]).write(to: chd)
            model.addDiscs([chd])
            let helperRunning = await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
            XCTAssertTrue(helperRunning)

            var project = GameProject()
            project.output = folder.appendingPathComponent("queued.pkg")
            model.jobs = [BuildJob(project: project)]
            model.runQueue = true
            model.next()
            XCTAssertNil(model.active, "a queued build must wait while the import owns the slot")

            model.newProject() // replacement while the helper is stopping
            XCTAssertNil(model.active, "replacement must not release the import's slot early")
            // The seeded project is deliberately invalid, so the build starts
            // and fails quickly; observe the durable status change rather than
            // the transient `active` value.
            let ran = await waitUntil(timeout: 10) { model.jobs.first?.status != "Waiting" }
            XCTAssertTrue(ran, "the queued build should run once the import has fully stopped")
            let stopped = await waitUntil(timeout: 10) { !model.working }
            XCTAssertTrue(stopped)
        }
    }

    // MARK: - Recovery lifecycle with the real helper

    func testRecoveryAfterRelaunchConfirmsGenuineOutput() async throws {
        let helper = try realHelper()
        try await withTemporaryAsync { folder in
            let state = folder.appendingPathComponent("session.json")
            let attempts = folder.appendingPathComponent("attempts")
            let model = StudioModel(stateURL: state, helperURL: helper, attemptDirectory: attempts)
            model.project = try makeValidProject(in: folder, output: "recover.pkg")
            model.enqueue(start: true)
            let built = await waitUntil(timeout: 60) { model.jobs.first?.status == "Locally verified" }
            XCTAssertTrue(built, model.jobs.first?.detail ?? "build did not finish")

            // Simulate a crash after publication but before the queue update.
            var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
            var jobs = saved["jobs"] as! [[String: Any]]
            jobs[0]["status"] = "Building"
            saved["jobs"] = jobs
            try JSONSerialization.data(withJSONObject: saved).write(to: state)

            let relaunched = StudioModel(stateURL: state, helperURL: helper, attemptDirectory: attempts)
            XCTAssertEqual(relaunched.jobs.first?.status, "Interrupted")
            let id = try XCTUnwrap(relaunched.jobs.first?.id)
            relaunched.verifyPublished(id)
            let recovered = await waitUntil(timeout: 60) { relaunched.jobs.first?.status == "Locally verified (recovered)" }
            XCTAssertTrue(recovered, relaunched.jobs.first?.detail ?? "recovery did not confirm")
        }
    }

    func testRecoveryStaysUnconfirmedWithoutAttemptOrReport() async throws {
        let helper = try realHelper()
        try await withTemporaryAsync { folder in
            let state = folder.appendingPathComponent("session.json")
            let attempts = folder.appendingPathComponent("attempts")
            let model = StudioModel(stateURL: state, helperURL: helper, attemptDirectory: attempts)
            model.project = try makeValidProject(in: folder, output: "edges.pkg")
            model.enqueue(start: true)
            let built = await waitUntil(timeout: 60) { model.jobs.first?.status == "Locally verified" }
            XCTAssertTrue(built, model.jobs.first?.detail ?? "build did not finish")
            let id = try XCTUnwrap(model.jobs.first?.id)
            let output = try XCTUnwrap(model.project.output)
            let attemptURL = attempts.appendingPathComponent(id.uuidString + ".json")
            let reportURL = URL(fileURLWithPath: output.path + ".report.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: attemptURL.path))
            let attemptBytes = try Data(contentsOf: attemptURL)
            let reportBytes = try Data(contentsOf: reportURL)

            // Reload as Interrupted so recovery is offered.
            var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
            var jobs = saved["jobs"] as! [[String: Any]]
            jobs[0]["status"] = "Interrupted"
            saved["jobs"] = jobs
            try JSONSerialization.data(withJSONObject: saved).write(to: state)

            @MainActor func reload() -> StudioModel { StudioModel(stateURL: state, helperURL: helper, attemptDirectory: attempts) }

            // Missing durable attempt.
            try FileManager.default.removeItem(at: attemptURL)
            var probe = reload()
            probe.verifyPublished(id)
            _ = await waitUntil(timeout: 60) { probe.busyJob == nil && probe.jobs.first?.detail != "" }
            XCTAssertTrue((probe.jobs.first?.detail ?? "").contains("no durable build attempt"), probe.jobs.first?.detail ?? "")
            try attemptBytes.write(to: attemptURL)

            // Missing completion report.
            try FileManager.default.removeItem(at: reportURL)
            probe = reload()
            probe.verifyPublished(id)
            _ = await waitUntil(timeout: 60) { probe.busyJob == nil && probe.jobs.first?.detail != "" }
            XCTAssertTrue((probe.jobs.first?.detail ?? "").contains("no completion record"), probe.jobs.first?.detail ?? "")
            try reportBytes.write(to: reportURL)

            // Foreign report: same job id but a different attempt identity.
            var report = try JSONSerialization.jsonObject(with: reportBytes) as! [String: Any]
            report["attemptID"] = UUID().uuidString
            try JSONSerialization.data(withJSONObject: report).write(to: reportURL)
            probe = reload()
            probe.verifyPublished(id)
            _ = await waitUntil(timeout: 60) { probe.busyJob == nil && probe.jobs.first?.detail != "" }
            XCTAssertTrue((probe.jobs.first?.detail ?? "").contains("does not name this build attempt"), probe.jobs.first?.detail ?? "")
        }
    }

    func testAttemptSaveFailureFailsBuildBeforeConversion() async throws {
        let helper = try realHelper()
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.helperURL = helper
            // A regular file where the attempts folder should be makes the
            // durable attempt write fail before any encryption begins.
            let blocker = folder.appendingPathComponent("attempts-blocker")
            try Data([1]).write(to: blocker)
            model.attemptDirectory = blocker
            model.project = try makeValidProject(in: folder, output: "no-attempt.pkg")
            model.enqueue(start: true)
            let failed = await waitUntil(timeout: 30) { model.jobs.first?.status == "Failed" }
            XCTAssertTrue(failed, model.jobs.first?.detail ?? "build should fail")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("no-attempt.pkg").path),
                           "a failed attempt write must publish nothing")
        }
    }

    func testRetryInvalidatesStaleAttempt() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let id = UUID()
            var project = GameProject()
            project.title = "Retry"; project.titleID = "SLUS12345"
            project.output = folder.appendingPathComponent("retry.pkg")
            var job = BuildJob(id: id, project: project, status: "Failed")
            job.queuedIdentity = QueuedJobIdentity(jobID: id, project: project)
            job.attempt = BuildAttemptIdentity(attemptID: UUID().uuidString, jobID: id.uuidString,
                                               buildFingerprint: "f", title: "Retry", titleID: "SLUS12345",
                                               contentID: "UP0001-SLUS12345_00-0000000000000001",
                                               cropArtwork: false, discs: [], supportHashes: [:], assetHashes: [:])
            model.jobs = [job]
            let attemptURL = model.attemptDirectory.appendingPathComponent(id.uuidString + ".json")
            try FileManager.default.createDirectory(at: model.attemptDirectory, withIntermediateDirectories: true)
            try AttemptStore.save(job.attempt!, to: attemptURL)

            model.retry(id)
            XCTAssertNil(model.jobs.first?.attempt)
            XCTAssertEqual(model.jobs.first?.status, "Waiting")
            XCTAssertFalse(FileManager.default.fileExists(atPath: attemptURL.path),
                           "a retry must invalidate the previous attempt")
        }
    }

    // MARK: - P1: recovered duplicate rows are addressed individually

    func testRemovingOrRetryingRecoveredDuplicateRowAffectsOnlyThatRow() async throws {
        try await withTemporaryAsync { folder in
            let state = folder.appendingPathComponent("session.json")
            let attempts = folder.appendingPathComponent("attempts")
            var project = GameProject(); project.title = "Dup"; project.titleID = "SLUS12345"
            project.discs = [GameDisc(source: folder.appendingPathComponent("d.iso"), gameID: "SLUS12345")]
            project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
            let id = UUID()
            var good = BuildJob(id: id, project: project, status: "Failed")
            good.queuedIdentity = QueuedJobIdentity(jobID: id, project: project)
            let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as! [String: Any]
            var badJSON = goodJSON; badJSON["status"] = 42   // same id, undecodable status
            let projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
            try JSONSerialization.data(withJSONObject: ["project": projectJSON, "jobs": [goodJSON, badJSON]]).write(to: state)

            let model = StudioModel(stateURL: state, helperURL: folder.appendingPathComponent("helper"), attemptDirectory: attempts)
            XCTAssertEqual(model.jobs.count, 2)
            XCTAssertEqual(Set(model.jobs.map(\.id)).count, 2, "recovered rows must have unique identifiers")
            XCTAssertNotNil(model.recoveryBackupURL, "the damaged session must be backed up")
            let salvaged = try XCTUnwrap(model.jobs.first { $0.status == "Interrupted" })
            let valid = try XCTUnwrap(model.jobs.first { $0.status == "Failed" })

            model.retry(salvaged.id)
            XCTAssertEqual(model.jobs.first { $0.id == salvaged.id }?.status, "Waiting")
            XCTAssertEqual(model.jobs.first { $0.id == valid.id }?.status, "Failed", "retry must not touch the neighbouring row")

            model.remove(salvaged.id)
            XCTAssertEqual(model.jobs.count, 1, "removing one recovered row must not remove another")
            XCTAssertEqual(model.jobs.first?.id, valid.id)
            XCTAssertEqual(model.jobs.first?.status, "Failed")
        }
    }

    // MARK: - P2: artwork/CONFIG search ownership

    /// A scanner whose per-folder completion is released explicitly by the
    /// test, so out-of-order completion is deterministic rather than timed.
    private final class GatedScanner<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [String: DispatchSemaphore] = [:]
        private var values: [String: [T]] = [:]
        private var failures: [String: Error] = [:]
        func arm(_ key: String, result: [T]) { lock.lock(); gates[key] = DispatchSemaphore(value: 0); values[key] = result; failures[key] = nil; lock.unlock() }
        func arm(_ key: String, error: Error) { lock.lock(); gates[key] = DispatchSemaphore(value: 0); failures[key] = error; values[key] = nil; lock.unlock() }
        func release(_ key: String) { lock.lock(); let gate = gates[key]; lock.unlock(); gate?.signal() }
        func scan(_ key: String) throws -> [T] {
            lock.lock(); let gate = gates[key]; let value = values[key]; let failure = failures[key]; lock.unlock()
            gate?.wait()
            if let failure { throw failure }
            return value ?? []
        }
    }

    /// A thread-safe completion count, bumped by the model's test-only
    /// `searchCompletionHook` so a test can await the real handler finishing
    /// (rather than a condition that an invalidation already made true).
    private final class CompletionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func artworkCandidate(_ folder: URL, _ name: String) -> ArtworkCandidate {
        ArtworkCandidate(url: folder.appendingPathComponent(name), relativePath: name, pixelWidth: 10, pixelHeight: 10)
    }
    private func configCandidate(_ folder: URL, _ name: String) -> ConfigCandidate {
        ConfigCandidate(url: folder.appendingPathComponent(name), relativePath: name, sha256: "hash-\(name)")
    }

    private func projectWithDisc(in folder: URL) -> GameProject {
        var project = GameProject(); project.title = "Search"; project.titleID = "SLUS12345"
        project.discs = [GameDisc(source: folder.appendingPathComponent("d.iso"), gameID: "SLUS12345")]
        project.support.contentID = "UP0001-SLUS12345_00-0000000000000001"
        return project
    }

    func testArtworkFolderChangeDiscardsSlowOlderSearch() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let a = folder.appendingPathComponent("artA"), b = folder.appendingPathComponent("artB")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            scanner.arm(b.path, result: [artworkCandidate(b, "B.png")])

            model.useArtworkLibrary(a)
            model.findArtwork(0)                 // search A (gated)
            model.useArtworkLibrary(b)           // change folder: supersede A
            model.findArtwork(0)                 // search B (gated)
            scanner.release(b.path)              // B completes first
            let gotB = await waitUntil { model.artworkCandidates.map(\.relativePath) == ["B.png"] }
            XCTAssertTrue(gotB, "the newest folder's results must appear")
            scanner.release(a.path)              // slow A completes last
            let settle = await waitUntil(timeout: 2) { !model.findingArtwork }
            XCTAssertTrue(settle)
            XCTAssertEqual(model.artworkCandidates.map(\.relativePath), ["B.png"],
                           "a superseded search must not overwrite newer results")
        }
    }

    func testDismissingArtworkSheetDuringScanDiscardsResults() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let counter = CompletionCounter()
            model.searchCompletionHook = { _ in counter.bump() }
            let a = folder.appendingPathComponent("artA")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            model.useArtworkLibrary(a)
            model.findArtwork(0)
            model.dismissArtworkSheet()
            scanner.release(a.path)
            let completed = await waitUntil { counter.value >= 1 }
            XCTAssertTrue(completed, "the dismissed scan handler must actually complete")
            XCTAssertNil(model.artworkDisc, "a dismissed sheet must not reopen")
            XCTAssertTrue(model.artworkCandidates.isEmpty, "a dismissed search must not repopulate the sheet")
        }
    }

    func testArtworkSearchIsDiscardedOnProjectReplacement() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let counter = CompletionCounter()
            model.searchCompletionHook = { _ in counter.bump() }
            let a = folder.appendingPathComponent("artA")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            model.useArtworkLibrary(a)
            model.findArtwork(0)
            model.newProject()
            scanner.release(a.path)
            let completed = await waitUntil { counter.value >= 1 }
            XCTAssertTrue(completed, "the replaced-project scan handler must actually complete")
            XCTAssertTrue(model.artworkCandidates.isEmpty, "a replaced project must not receive stale results")
            XCTAssertNil(model.artworkDisc)
        }
    }

    func testArtworkFolderChangeRescansOpenSheetAndErrorClearsResults() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let a = folder.appendingPathComponent("artA"), b = folder.appendingPathComponent("artB")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)

            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            model.useArtworkLibrary(a)
            model.findArtwork(0)
            scanner.release(a.path)
            let gotA = await waitUntil { model.artworkCandidates.map(\.relativePath) == ["A.png"] }
            XCTAssertTrue(gotA)
            XCTAssertEqual(model.artworkDisc, model.project.discs[0].id)   // sheet open

            // Changing folder with the sheet open must re-scan immediately.
            scanner.arm(b.path, result: [artworkCandidate(b, "B.png")])
            model.useArtworkLibrary(b)
            scanner.release(b.path)
            let gotB = await waitUntil { model.artworkCandidates.map(\.relativePath) == ["B.png"] }
            XCTAssertTrue(gotB, "changing the folder must immediately replace the old matches")
            XCTAssertTrue(model.artworkCandidates.allSatisfy { $0.relativePath == "B.png" })

            // A failing scan must clear results, not leave the old folder's matches.
            scanner.arm(b.path, error: ConversionFailure(message: "artwork folder unreadable"))
            model.useArtworkLibrary(b)
            scanner.release(b.path)
            let cleared = await waitUntil { model.artworkCandidates.isEmpty && model.message != nil }
            XCTAssertTrue(cleared, "a failed scan must not keep stale matches")
            XCTAssertTrue(model.message?.contains("unreadable") ?? false)
        }
    }

    func testConfigFolderChangeDiscardsSlowOlderSearch() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ConfigCandidate>()
            model.configCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let a = folder.appendingPathComponent("cfgA"), b = folder.appendingPathComponent("cfgB")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [configCandidate(a, "SLUS12345.CONFIG")])
            scanner.arm(b.path, result: [configCandidate(b, "SLUS12345.CONFIG")])

            model.useConfigLibrary(a)
            model.findConfigs(0)
            model.useConfigLibrary(b)
            model.findConfigs(0)
            scanner.release(b.path)
            let gotB = await waitUntil { model.configCandidates.count == 1 && model.configLibrary == b }
            XCTAssertTrue(gotB)
            let bURL = model.configCandidates.first?.url
            scanner.release(a.path)
            let settle = await waitUntil(timeout: 2) { !model.findingConfigs }
            XCTAssertTrue(settle)
            XCTAssertEqual(model.configCandidates.first?.url, bURL, "a superseded CONFIG search must not overwrite newer results")
        }
    }

    // MARK: - P1: stuck search control when the disc context changes mid-scan

    /// The exact review reproduction: editing a game ID while a CONFIG scan is
    /// pending must not leave `findingConfigs` stuck true. The context mutation
    /// is applied directly (as the editable binding does), and the test awaits
    /// the real completion handler via the completion hook.
    func testConfigGameIDEditDuringScanClearsBusyAndDiscardsMatches() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ConfigCandidate>()
            model.configCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let counter = CompletionCounter()
            model.searchCompletionHook = { _ in counter.bump() }
            let a = folder.appendingPathComponent("cfg")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [configCandidate(a, "SLUS12345.CONFIG")])
            model.useConfigLibrary(a)
            model.findConfigs(0)
            XCTAssertTrue(model.findingConfigs)

            model.project.discs[0].gameID = "SLUS54321"   // direct edit, no invalidation call
            scanner.release(a.path)
            let finished = await waitUntil { counter.value >= 1 }
            XCTAssertTrue(finished, "the old scan handler must actually complete")
            XCTAssertFalse(model.findingConfigs, "a pending scan must not leave the search control disabled")
            XCTAssertTrue(model.configCandidates.isEmpty, "matches for the old game ID must not be published")
            XCTAssertNil(model.configDisc, "the results sheet must not open for a stale game ID")

            // Recovery without restart: a fresh search works afterwards.
            scanner.arm(a.path, result: [configCandidate(a, "SLUS54321.CONFIG")])
            model.findConfigs(0)
            scanner.release(a.path)
            let recovered = await waitUntil { model.configCandidates.count == 1 && !model.findingConfigs }
            XCTAssertTrue(recovered, "searching again after the edit must work")
        }
    }

    func testArtworkDiscRemovalDuringScanClearsBusyAndDiscardsMatches() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let counter = CompletionCounter()
            model.searchCompletionHook = { _ in counter.bump() }
            let a = folder.appendingPathComponent("art")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            model.useArtworkLibrary(a)
            model.findArtwork(0)
            XCTAssertTrue(model.findingArtwork)

            model.project.discs.removeAll()               // direct removal, no invalidation call
            scanner.release(a.path)
            let finished = await waitUntil { counter.value >= 1 }
            XCTAssertTrue(finished, "the old scan handler must actually complete")
            XCTAssertFalse(model.findingArtwork, "a pending scan must not leave the search control disabled")
            XCTAssertTrue(model.artworkCandidates.isEmpty)
            XCTAssertNil(model.artworkDisc)
        }
    }

    /// Explicit invalidation (the real UI path) must also leave the control
    /// usable and never publish the removed disc's matches.
    func testRemoveDiscAndGameIDEditedInvalidateSearches() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let a = folder.appendingPathComponent("art")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            model.useArtworkLibrary(a)
            model.findArtwork(0)
            model.removeDisc(0)
            XCTAssertTrue(model.project.discs.isEmpty)
            XCTAssertFalse(model.findingArtwork)
            XCTAssertTrue(model.artworkCandidates.isEmpty)
            scanner.release(a.path)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(model.artworkCandidates.isEmpty, "a superseded removal search must not publish")

            // A game-ID edit invalidates a CONFIG search for that disc.
            model.project = projectWithDisc(in: folder)
            let cscanner = GatedScanner<ConfigCandidate>()
            model.configCandidatesProvider = { _, url in try cscanner.scan(url.path) }
            cscanner.arm(a.path, result: [configCandidate(a, "SLUS12345.CONFIG")])
            model.useConfigLibrary(a)
            model.findConfigs(0)
            model.project.discs[0].gameID = "SLUS99999"
            model.gameIDEdited(0)
            XCTAssertFalse(model.findingConfigs)
            cscanner.release(a.path)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(model.configCandidates.isEmpty)
        }
    }

    /// An older completion must never clear a newer search's busy state.
    func testOlderCompletionDoesNotClearNewerSearchBusy() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ArtworkCandidate>()
            model.artworkCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let counter = CompletionCounter()
            model.searchCompletionHook = { _ in counter.bump() }
            let a = folder.appendingPathComponent("artA"), b = folder.appendingPathComponent("artB")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, result: [artworkCandidate(a, "A.png")])
            scanner.arm(b.path, result: [artworkCandidate(b, "B.png")])
            model.useArtworkLibrary(a)
            model.findArtwork(0)                 // older search (A), gated
            model.useArtworkLibrary(b)
            model.findArtwork(0)                 // newer search (B), gated

            scanner.release(a.path)              // older completes while newer is blocked
            let olderDone = await waitUntil { counter.value >= 1 }
            XCTAssertTrue(olderDone)
            XCTAssertTrue(model.findingArtwork, "an older completion must not clear the newer search's busy state")
            XCTAssertTrue(model.artworkCandidates.isEmpty, "older results must not be published")

            scanner.release(b.path)
            let newerDone = await waitUntil { model.artworkCandidates.map(\.relativePath) == ["B.png"] && !model.findingArtwork }
            XCTAssertTrue(newerDone)
        }
    }

    func testErrorCompletionClearsBusyAndMatches() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let scanner = GatedScanner<ConfigCandidate>()
            model.configCandidatesProvider = { _, url in try scanner.scan(url.path) }
            let counter = CompletionCounter()
            model.searchCompletionHook = { _ in counter.bump() }
            let a = folder.appendingPathComponent("cfg")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            model.project = projectWithDisc(in: folder)
            scanner.arm(a.path, error: ConversionFailure(message: "boom"))
            model.useConfigLibrary(a)
            model.findConfigs(0)
            scanner.release(a.path)
            let done = await waitUntil { counter.value >= 1 }
            XCTAssertTrue(done)
            XCTAssertFalse(model.findingConfigs)
            XCTAssertTrue(model.configCandidates.isEmpty)
            XCTAssertTrue(model.message?.contains("boom") ?? false)
        }
    }

    // MARK: - Optional WAV→AT3 conversion utility

    private func writeTestWAV(_ url: URL, channels: Int = 2, rate: Int = 44100, seconds: Double = 0.4) throws -> URL {
        let frames = Int(Double(rate) * seconds); let blockAlign = channels * 2
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func le(_ v: Int, _ n: Int) { for i in 0..<n { data.append(UInt8((v >> (8*i)) & 0xff)) } }
        ascii("RIFF"); le(36 + frames*blockAlign, 4); ascii("WAVE")
        ascii("fmt "); le(16,4); le(1,2); le(channels,2); le(rate,4); le(rate*blockAlign,4); le(blockAlign,2); le(16,2)
        ascii("data"); le(frames*blockAlign, 4)
        for i in 0..<frames {
            let s = Int16(12000 * sin(2 * Double.pi * 1000 * Double(i) / Double(rate)))
            for _ in 0..<channels { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        }
        try data.write(to: url); return url
    }

    func testAudioConversionUtilityPathProducesValidAT3() async throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"],
              FileManager.default.isExecutableFile(atPath: helper) else {
            throw XCTSkip("set PS2_TEST_AT3_HELPER to run the audio conversion path")
        }
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.at3HelperURL = URL(fileURLWithPath: helper)
            let wav = try writeTestWAV(folder.appendingPathComponent("tone.wav"))
            let out = folder.appendingPathComponent("SND0.AT3")
            model.convertAudio(source: wav, destination: out)
            let done = await waitUntil(timeout: 20) { model.audioOutput != nil || model.audioError != nil }
            XCTAssertTrue(done, "conversion must finish")
            XCTAssertNil(model.audioError, model.audioError ?? "")
            XCTAssertEqual(model.project.sound, out, "a successful conversion becomes the package sound")
            XCTAssertFalse(model.working, "the utility slot must be released")
            let bytes = try Data(contentsOf: out)
            XCTAssertNoThrow(try PackageMetadata.validateSound(bytes))
        }
    }

    func testAudioCompletionDoesNotAttachToReplacementProject() async throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"] else {
            throw XCTSkip("set PS2_TEST_AT3_HELPER")
        }
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.at3HelperURL = URL(fileURLWithPath: helper)
            let wav = try writeTestWAV(folder.appendingPathComponent("tone.wav"))
            let out = folder.appendingPathComponent("converted.at3")
            model.convertAudio(source: wav, destination: out)
            // No await: replace the project before the conversion task can complete.
            model.newProject()
            let chosen = folder.appendingPathComponent("new-project.at3")
            model.project.sound = chosen
            let done = await waitUntil(timeout: 20) { !model.convertingAudio }
            XCTAssertTrue(done)
            XCTAssertNil(model.audioError)
            XCTAssertEqual(model.audioOutput, out, "the exported audio remains available")
            XCTAssertEqual(model.project.sound, chosen, "a different project must not inherit this conversion")
            XCTAssertFalse(model.working)
        }
    }

    func testRetryExistingOutputDoesNotInheritPendingAudio() async throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"] else {
            throw XCTSkip("set PS2_TEST_AT3_HELPER")
        }
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.at3HelperURL = URL(fileURLWithPath: helper)
            let wav = try writeTestWAV(folder.appendingPathComponent("tone.wav"))
            let out = folder.appendingPathComponent("converted.at3")
            var queued = GameProject(); queued.title = "Retried project"
            queued.output = folder.appendingPathComponent("existing.pkg")
            try Data([1]).write(to: queued.output!)
            let job = BuildJob(project: queued)
            model.jobs = [job]
            model.convertAudio(source: wav, destination: out)
            model.retry(job.id)
            let done = await waitUntil(timeout: 20) { !model.convertingAudio }
            XCTAssertTrue(done)
            XCTAssertNil(model.audioError)
            XCTAssertEqual(model.audioOutput, out)
            XCTAssertEqual(model.project.title, "Retried project")
            XCTAssertNil(model.project.sound)
            XCTAssertNil(model.project.output)
        }
    }

    func testAudioCompletionPreservesNewerSoundSelection() async throws {
        guard let helper = ProcessInfo.processInfo.environment["PS2_TEST_AT3_HELPER"] else {
            throw XCTSkip("set PS2_TEST_AT3_HELPER")
        }
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            model.at3HelperURL = URL(fileURLWithPath: helper)
            let wav = try writeTestWAV(folder.appendingPathComponent("tone.wav"))
            model.convertAudio(source: wav, destination: folder.appendingPathComponent("converted.at3"))
            let selected = folder.appendingPathComponent("chosen.at3")
            model.project.sound = selected
            let done = await waitUntil(timeout: 20) { !model.convertingAudio }
            XCTAssertTrue(done)
            XCTAssertNil(model.audioError)
            XCTAssertEqual(model.project.sound, selected)
        }
    }

    func testAudioConversionRejectsUnsupportedInputAndReleasesSlot() async throws {
        try await withTemporaryAsync { folder in
            let model = makeModel(folder)
            let bad = folder.appendingPathComponent("bad.wav")
            try Data("not a wav".utf8).write(to: bad)
            model.convertAudio(source: bad, destination: folder.appendingPathComponent("x.at3"))
            let done = await waitUntil(timeout: 10) { model.audioError != nil || model.audioOutput != nil }
            XCTAssertTrue(done)
            XCTAssertNotNil(model.audioError)
            XCTAssertNil(model.audioOutput)
            XCTAssertFalse(model.working)
        }
    }

    private func withTemporaryAsync(_ body: @MainActor (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path); try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }
}
