// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PS2ClassicsCore

/// Drives the standalone PS2 Classic webMAN MOD on HEN batch workflow.
///
/// Two deliberate steps, never fused: `checkBatch` validates the whole batch
/// and shows it for review, and only `startBatch` converts anything. A plan is
/// discarded the moment any input to it changes, so review can never approve a
/// different batch from the one that runs.
@MainActor
final class HENBatchModel: ObservableObject {
    @Published var items = [HENBatchItem]()
    @Published var keyFile: URL?
    @Published var destination: URL?
    @Published var contentID = ""
    @Published var folderLayout = false
    /// The reviewed plan. Present only after a successful check.
    @Published private(set) var plan: HENBatchPlan?
    @Published private(set) var busy = false
    @Published private(set) var stage = ""
    @Published var fraction = 0.0
    @Published var error: String?
    @Published private(set) var notes: [String] = []
    @Published private(set) var recoveryLocked = false

    private let storeURL: URL
    private var session: ConversionRunner?
    private var owner: UUID?
    /// Settings the current plan was checked against, so an edit invalidates it.
    private var planSignature = ""

    init(storeURL: URL = HENBatchStore.defaultURL()) {
        self.storeURL = storeURL
        let outcome = HENBatchStore.load(from: storeURL)
        recoveryLocked = outcome.locked
        items = outcome.state.items
        keyFile = outcome.state.keyFile
        destination = outcome.state.destination
        contentID = outcome.state.contentID.isEmpty ? StudioModel.shared.project.support.contentID : outcome.state.contentID
        folderLayout = outcome.state.folderLayout
        if outcome.didRecover { error = outcome.notes.joined(separator: "\n\n") }
    }

    // MARK: - Derived state

    var locked: Bool { busy || recoveryLocked }
    var canCheck: Bool { !locked && pendingCount > 0 }
    var canStart: Bool { !locked && plan != nil }
    var canRetry: Bool { !locked && items.contains { $0.status.isRetryable } }
    var pendingCount: Int { items.filter { $0.status != .published }.count }
    var publishedCount: Int { items.filter { $0.status == .published }.count }
    var canReveal: Bool {
        guard let destination else { return false }
        return FileManager.default.fileExists(atPath: destination.appendingPathComponent(HENBatchExporter.readyFolderName).path)
    }

    private func invalidatePlan() {
        plan = nil; planSignature = ""; notes = []
    }

    private func signature() -> String {
        let inputs = items.map { "\($0.source.path)|\($0.config?.path ?? "")|\($0.configSHA256 ?? "")" }
        return ([keyFile?.path ?? "", destination?.path ?? "", contentID, folderLayout ? "1" : "0"] + inputs).joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Saves the queue. A file that could not be read is never overwritten, so
    /// an unreadable original is preserved for recovery.
    private func save() {
        guard !recoveryLocked else {
            error = "The saved HEN queue could not be recovered and was left untouched at \(storeURL.path). Move it aside and reopen the app before editing this queue."
            return
        }
        do { try HENBatchStore.save(HENBatchState(items: items, keyFile: keyFile, destination: destination,
                                                   contentID: contentID, folderLayout: folderLayout),
                                    to: storeURL) }
        catch { self.error = "Could not save this queue: \(error.localizedDescription)" }
    }

    private func setGameID(_ id: UUID, _ gameID: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].gameID = gameID
    }

    private func setStatus(_ id: UUID, _ status: HENBatchStatus, _ detail: String, folder: URL? = nil, persist: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].detail = detail
        if let folder { items[index].publishedFolder = folder }
        if persist { save() }
    }

    // MARK: - Queue editing

    func add(_ urls: [URL]) {
        guard !locked else { return }
        let iso = urls.filter { $0.pathExtension.lowercased() == "iso" }
        var seen = Set(items.map { $0.source.standardizedFileURL.path })
        var added = 0
        for url in iso where items.count < HENBatchExporter.maxBatchSize {
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            items.append(HENBatchItem(source: url))
            added += 1
        }
        if urls.count != iso.count {
            error = "Only .iso files can be added to this batch. This workflow creates encrypted .BIN.ENC images for HEN, not PKGs."
        } else if added == 0 && !iso.isEmpty {
            error = "These ISO files are already in the batch."
        } else if added < iso.count {
            error = "A batch holds at most \(HENBatchExporter.maxBatchSize) games."
        }
        invalidatePlan(); save()
    }

    func pickISOs() {
        let panel = NSOpenPanel()
        panel.message = "Choose 1–50 PS2 .iso files."
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseKey() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the matching binary 16-byte klicensee (usually klic.bin)."
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { keyFile = panel.url; invalidatePlan(); save() }
    }

    func chooseDestination() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose an existing folder to hold the “Ready for Super Slim” output."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK { destination = panel.url; invalidatePlan(); save() }
    }

    func chooseConfig(_ id: UUID) {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose an optional unencrypted CONFIG for this game."
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        do {
            items[index].configSHA256 = try HENBatchExporter.configFingerprint(url)
            items[index].config = url
            invalidatePlan(); save()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearConfig(_ id: UUID) {
        guard !locked else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].config = nil; items[index].configSHA256 = nil
        invalidatePlan(); save()
    }

    func remove(_ id: UUID) {
        guard !locked else { return }
        items.removeAll { $0.id == id }
        invalidatePlan(); save()
    }

    func removeAll() {
        guard !locked else { return }
        items.removeAll()
        invalidatePlan(); save()
    }

    func setContentID(_ value: String) {
        guard !locked else { return }
        contentID = value
        // The content ID is sealed into every header, so an edit invalidates
        // the reviewed plan.
        invalidatePlan(); save()
    }

    func setFolderLayout(_ value: Bool) {
        guard !locked else { return }
        folderLayout = value
        invalidatePlan(); save()
    }

    // MARK: - Step 1: check the whole batch

    /// Validates every ISO, CONFIG, key, output path and the destination
    /// capacity, then stops for review. It never converts anything.
    func checkBatch() {
        guard !locked else { return }
        guard let destination, let keyFile else { error = "Choose an output folder and klicensee first."; return }
        guard pendingCount > 0 else { error = "All queued games are already published. Add another ISO to make a new batch."; return }
        let inputs = items.filter { $0.status != .published }.map { $0.input }
        let cid = contentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = folderLayout
        let runner = ConversionRunner()
        guard let token = StudioModel.shared.beginUtility(.convert, cancel: { runner.cancel() }) else {
            error = "Another operation is already running. Finish or cancel it first."; return
        }
        session = runner; owner = token; busy = true; error = nil; notes = []
        invalidatePlan()
        stage = "Checking every ISO, CONFIG, key and output path…"
        let signature = signature()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try HENBatchExporter.preflight(inputs: inputs, destinationParent: destination,
                                                   ftpLayout: layout, keyFile: keyFile, contentID: cid,
                                                   cancelled: { try runner.checkCancellation() })
                }.value
                guard StudioModel.shared.ownsUtility(token) else { return }
                busy = false; session = nil; owner = nil
                StudioModel.shared.endUtility(token)
                guard signature == self.signature() else {
                    self.error = "The batch changed while it was being checked. Check it again."
                    return
                }
                self.plan = result; planSignature = signature; notes = result.notes
                for item in result.items { self.setGameID(item.id, item.gameID) }
                self.stage = "All \(result.items.count) game\(result.items.count == 1 ? "" : "s") passed the check. Review the list, then start the batch."
                // Marked in one pass, then saved once: a 50-game batch must not
                // rewrite the queue file 50 times.
                for item in result.items {
                    self.setStatus(item.id, .ready,
                                   "Checked. Output: \(item.folderName)/\(item.imageName)", persist: false)
                }
                save()
            } catch {
                guard StudioModel.shared.ownsUtility(token) else { return }
                self.error = error.localizedDescription
                stage = ""
                // A check that did not pass leaves nothing claiming to be
                // checked, so the queue never shows a stale approval.
                for index in self.items.indices where self.items[index].status == .ready {
                    self.items[index].status = .queued
                    self.items[index].detail = "Waiting to be checked again."
                }
                save()
                busy = false; session = nil; owner = nil
                StudioModel.shared.endUtility(token)
            }
        }
    }

    // MARK: - Step 2: start the batch

    func startBatch() {
        guard !locked, let plan else { return }
        guard planSignature == signature() else {
            error = "The batch changed after it was checked. Check it again before starting."
            invalidatePlan(); return
        }
        run(plan.items.filter { item in
            items.first { $0.id == item.id }?.status != .published
        }, plan: plan)
    }

    /// Re-checks and re-runs a single game. Failed, cancelled and interrupted
    /// rows are retryable; a published row is finished work and is not retried.
    func retry(_ id: UUID) {
        guard !locked, let index = items.firstIndex(where: { $0.id == id }),
              items[index].status.isRetryable else { return }
        guard let destination, let keyFile else { error = "Choose an output folder and klicensee first."; return }
        let runner = ConversionRunner()
        guard let token = StudioModel.shared.beginUtility(.convert, cancel: { runner.cancel() }) else {
            error = "Another operation is already running. Finish or cancel it first."; return
        }
        let input = items[index].input
        let cid = contentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = folderLayout
        let name = items[index].source.lastPathComponent
        busy = true; error = nil
        session = runner; owner = token
        invalidatePlan()
        stage = "Re-checking \(name)…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try HENBatchExporter.preflight(inputs: [input], destinationParent: destination,
                                                   ftpLayout: layout, keyFile: keyFile,
                                                   contentID: cid,
                                                   cancelled: { try runner.checkCancellation() })
                }.value
                guard StudioModel.shared.ownsUtility(token) else { return }
                self.plan = result; planSignature = self.signature(); notes = result.notes
                self.setGameID(id, result.items[0].gameID)
                // The same token carries the retry straight into conversion, so
                // another operation cannot claim the slot between the two.
                self.run([result.items[0]], plan: result, token: token)
            } catch {
                guard StudioModel.shared.ownsUtility(token) else { return }
                StudioModel.shared.endUtility(token)
                self.error = error.localizedDescription
                stage = ""
                busy = false; session = nil; owner = nil
            }
        }
    }

    /// Games convert one at a time, in queue order. A failure is recorded for
    /// that game and the batch continues; a cancel stops the rest.
    private func run(_ work: [HENPreparedItem], plan: HENBatchPlan, token existing: UUID? = nil) {
        guard !work.isEmpty else {
            if let existing { StudioModel.shared.endUtility(existing) }
            busy = false; session = nil; owner = nil; fraction = 1
            stage = "Nothing to convert. Every game in this batch is already published."
            invalidatePlan()
            return
        }
        let runner: ConversionRunner
        let token: UUID
        if let existing {
            guard let active = session else {
                StudioModel.shared.endUtility(existing)
                busy = false; owner = nil
                error = "The retry lost its cancellation owner. Check the game again."
                return
            }
            token = existing
            runner = active
        } else {
            runner = ConversionRunner()
            guard let claimed = StudioModel.shared.beginUtility(.convert, cancel: { runner.cancel() }) else {
                busy = false; session = nil; owner = nil
                error = "Another operation is already running. Finish or cancel it first."
                return
            }
            token = claimed
            session = runner
        }
        busy = true; error = nil; fraction = 0
        owner = token
        let helper = StudioModel.shared.helperURL
        let total = work.count
        Task {
            for (offset, item) in work.enumerated() {
                guard StudioModel.shared.ownsUtility(token) else { break }
                setStatus(item.id, .converting, "Converting game \(offset + 1) of \(total)…")
                stage = "Game \(offset + 1) of \(total): \(item.source.lastPathComponent)"
                do {
                    let folder = try await Task.detached(priority: .userInitiated) {
                        try HENBatchExporter.export(item, plan: plan, helper: helper, runner: runner) { update in
                            Task { @MainActor in
                                if StudioModel.shared.ownsUtility(token) {
                                    self.fraction = Double(offset) / Double(total) + update.fraction / Double(total)
                                    self.stage = "Game \(offset + 1) of \(total): \(update.stage)"
                                }
                            }
                        }
                    }.value
                    setStatus(item.id, .published, "Verified and published to \(folder.lastPathComponent)", folder: folder)
                } catch {
                    let cancelled = HENBatchExporter.isCancellation(error)
                    setStatus(item.id, cancelled ? .cancelled : .failed,
                              cancelled ? "Cancelled. No partial game folder was published."
                                        : (error as? ConversionFailure)?.message ?? error.localizedDescription)
                    if cancelled {
                        for remaining in work.dropFirst(offset + 1) {
                            setStatus(remaining.id, .cancelled, "Not started because the batch was cancelled.")
                        }
                        break
                    }
                }
                fraction = Double(offset + 1) / Double(total)
            }
            busy = false; session = nil; owner = nil
            stage = "Finished: \(publishedCount) of \(items.count) game\(items.count == 1 ? "" : "s") published."
            StudioModel.shared.endUtility(token)
            invalidatePlan()
            save()
        }
    }

    func cancel() { session?.cancel() }

    func reveal() {
        guard let destination else { return }
        let ready = destination.appendingPathComponent(HENBatchExporter.readyFolderName)
        if FileManager.default.fileExists(atPath: ready.path) {
            NSWorkspace.shared.activateFileViewerSelecting([ready])
        }
    }
}
