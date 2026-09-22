// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import PS2ClassicsCore

@MainActor
final class StudioModel: ObservableObject {
    static let shared = StudioModel()
    private var projectGeneration = UUID()
    @Published var project = GameProject()
    @Published var configLibrary: URL?
    @Published var configLibraryStatus: ConfigLibrary.Availability = .notSelected
    @Published var configCandidates = [ConfigCandidate]()
    @Published var artworkLibrary: URL?
    @Published var artworkCandidates = [ArtworkCandidate]()
    @Published var artworkDisc: UUID?
    @Published var findingArtwork = false
    /// Ownership tokens for in-flight CONFIG/artwork searches. A completion may
    /// only publish when its token is still current, so a superseded, dismissed
    /// or project-replaced search can never overwrite newer results. The target
    /// disc id lets an explicit edit/removal invalidate only the affected search.
    private var configSearchGeneration = UUID()
    private var artworkSearchGeneration = UUID()
    private var configSearchTarget: UUID?
    private var artworkSearchTarget: UUID?
    /// Test-only observer invoked at the end of a search completion handler
    /// (after any state change), identified by "config" or "artwork". Always nil
    /// in production; lets regressions await the real handler rather than a
    /// condition that may already be satisfied.
    var searchCompletionHook: (@Sendable (String) -> Void)?
    /// Injectable scanners. Production uses the real folder scans; tests supply
    /// controlled providers so out-of-order completion is deterministic.
    var configCandidatesProvider: @Sendable (String, URL) throws -> [ConfigCandidate] = { try ConfigLibrary.candidates(for: $0, in: $1) }
    var artworkCandidatesProvider: @Sendable (String, URL) throws -> [ArtworkCandidate] = { try ArtworkLibrary.candidates(for: $0, in: $1) }
    @Published var configDisc: UUID?
    @Published var findingConfigs = false
    private var importGeneration = UUID()
    @Published var jobs = [BuildJob]()
    @Published var page = "Build a package"
    @Published var message: String?
    @Published var active: UUID?
    @Published var stage = ""
    @Published var fraction = 0.0
    @Published var runQueue = false
    @Published var inspecting = false
    @Published var utilityBusy = false
    @Published var abandoned = [OwnedWorkspace]()
    @Published var scanningAbandoned = false
    @Published var showingCleanup = false
    private let utilities = OperationCoordinator()
    private(set) var cancelUtility: (() -> Void)?
    private var buildToken: UUID?
    private var importToken: UUID?
    private var importRunner: ConversionRunner?
    var working: Bool { busy || utilityBusy }
    /// Utility operations claim the shared busy/cancel slot through a token, so
    /// a stale completion can never clear a newer operation's state. A running
    /// package build owns the app, so utilities are refused while it runs —
    /// mirroring how `next()` refuses to build while a utility runs.
    func beginUtility(_ kind: OperationCoordinator.Kind, cancel: @escaping () -> Void) -> UUID? {
        guard buildToken == nil else { return nil }
        guard let token = utilities.begin(kind) else { return nil }
        cancelUtility = cancel; utilityBusy = true
        return token
    }
    func endUtility(_ token: UUID) {
        guard utilities.end(token) else { return }
        cancelUtility = nil; utilityBusy = false
        if runQueue { next() }
    }
    func ownsUtility(_ token: UUID) -> Bool { utilities.isOwner(token) }
    @Published var cacheBytes: UInt64? = nil
    @Published var busyJob: UUID?
    @Published var supportProfiles = [NamedSupportProfile]()
    @Published var namingProfile = false
    @Published var profileName = ""
    private var profileStore: SupportProfileStore?
    private var builder: PackageBuilder?
    private let stateURL: URL
    /// Helper location. A `var` only so isolated model tests can point at a
    /// controlled helper; production code sets it once at construction.
    var helperURL: URL
    /// Optional ATRAC3 encoder helper. Defaults to `ps2-at3` beside the disc
    /// helper; a `var` so isolated tests can point at a controlled location.
    var at3HelperURL: URL
    @Published var convertingAudio = false
    @Published var audioConversionStage = ""
    @Published var audioOutput: URL?
    @Published var audioError: String?
    /// Attempt-record folder. A `var` only so isolated model tests can point it
    /// at a controlled location; production sets it once at construction.
    var attemptDirectory: URL
    /// Set when the saved session needed migration/recovery and could not be
    /// copied aside, so persisting must not overwrite the unreadable original.
    private var sessionLocked = false
    /// A recoverable copy of a session that was not read cleanly, if one was
    /// made. Exposed so the interface can offer to reveal it.
    @Published var recoveryBackupURL: URL?
    var busy: Bool { active != nil }

    /// Production model: state, helper and attempt records live under the
    /// user's Application Support folder and the assembled bundle. Tests build
    /// an isolated instance with temporary paths so no real user state is read
    /// or written.
    convenience init() {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("PS2 Classics for Mac")
        self.init(stateURL: support.appendingPathComponent("session.json"),
                  helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ps2-convert"),
                  attemptDirectory: support.appendingPathComponent("attempts"))
    }

    init(stateURL: URL, helperURL: URL, attemptDirectory: URL) {
        self.stateURL = stateURL
        self.helperURL = helperURL
        self.at3HelperURL = helperURL.deletingLastPathComponent().appendingPathComponent("ps2-at3")
        self.attemptDirectory = attemptDirectory
        profileStore = SupportProfileStore(url: stateURL.deletingLastPathComponent().appendingPathComponent("support-profiles.json"))
        supportProfiles = profileStore?.profiles ?? []
        let outcome = SessionStore.load(from: stateURL)
        sessionLocked = outcome.locked
        recoveryBackupURL = outcome.backup
        configLibrary = outcome.session.configLibrary
        configLibraryStatus = ConfigLibrary.availability(of: configLibrary)
        artworkLibrary = outcome.session.artworkLibrary
        project = outcome.session.project
        jobs = outcome.session.jobs.map { job in
            var job = job
            if job.status == "Building" {
                job.status = "Interrupted"
                if let output = job.project.output, FileManager.default.fileExists(atPath: output.path) {
                    job.detail = "The app closed during this job, but a package exists at the destination. It is not assumed valid: use Check published package to verify it read-only."
                } else {
                    job.detail = "The app closed during this job. Retry reuses already-verified stages when the inputs are unchanged."
                }
            }
            return job
        }
        if outcome.didRecover {
            var text = outcome.notes.joined(separator: " ")
            if let backup = outcome.backup { text += " A recoverable copy of the previous session was saved as \(backup.lastPathComponent)." }
            if outcome.locked { text += " The session file was left untouched because it could not be copied aside; move or remove it before the app can save again." }
            message = text
        }
    }
    func persist() {
        guard !sessionLocked else {
            message = "The saved session could not be read and was left untouched to avoid data loss. Move or remove \(stateURL.lastPathComponent) in Application Support, then reopen the app."
            return
        }
        do {
            try FileManager.default.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            let data = try JSONEncoder().encode(StudioSession(project:project,jobs:jobs,configLibrary:configLibrary,artworkLibrary:artworkLibrary))
            try data.write(to:stateURL,options:.atomic)
        } catch { message = "Could not save this session: \(error.localizedDescription)" }
    }
    /// Reveals the session folder (or the backup itself) so the user never has
    /// to discover a hidden path from a vague message.
    func revealRecoveryFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([recoveryBackupURL ?? stateURL])
    }
    func chooseFile(_ title: String, directory: Bool = false) -> URL? {
        let panel = NSOpenPanel(); panel.message = title; panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func addDiscs(_ urls: [URL]? = nil) {
        guard active == nil, buildToken == nil else { message="Wait for the current operation to finish before adding discs.";return }
        var selected = urls ?? []
        if urls == nil {
            let panel = NSOpenPanel(); panel.message = "Select ISO, BIN, CHD or single-track CUE images. Add discs in playback order."
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }; selected = panel.urls
        }
        guard project.discs.count + selected.count <= 9 else { message = "A package can contain up to nine discs."; return }
        let inputs = selected
        // Import and inspection own the shared operation slot exactly like a
        // build or utility, so a CHD inspection can never launch beside a
        // running build. All in-flight work is bound to this token and can be
        // cancelled; a stale completion is discarded by token and generation.
        let runner = ConversionRunner()
        guard let token = beginUtility(.inspect, cancel: { runner.cancel() }) else {
            message = "Another operation is already running. Finish or cancel it before importing discs."; return
        }
        let generation = importGeneration
        importToken = token; importRunner = runner
        inspecting = true
        let helper = helperURL
        Task {
            do {
                let discs = try await Task.detached(priority:.userInitiated) { try inputs.map { url -> GameDisc in
                    let result = try DiscInspector.inspect(url, helper: helper, runner: runner)
                    guard result.isSupported else { throw ConversionFailure(message:"Unsupported image: \(url.lastPathComponent). Choose ISO, BIN, CHD or a single data-track CUE.") }
                    return GameDisc(source:url,gameID:result.gameID ?? "")
                }}.value
                // Results are applied only for the still-current generation; a
                // replaced project never receives stale discs. The slot is
                // released below on every path, so invalidation cannot leak it.
                if generation == importGeneration, ownsUtility(token) {
                    for disc in discs where !project.discs.contains(where:{$0.source.standardizedFileURL==disc.source.standardizedFileURL}) { project.discs.append(disc) }
                    if project.title.isEmpty, let first = project.discs.first {
                        project.title = first.source.deletingPathExtension().lastPathComponent
                        project.titleID = first.gameID
                    }
                    persist()
                }
            } catch {
                if generation == importGeneration, ownsUtility(token) { message = error.localizedDescription }
            }
            if generation == importGeneration { inspecting = false }
            if importToken == token { importToken = nil; importRunner = nil }
            // Released exactly once, and only after the inspection (and any
            // helper it launched) has actually finished.
            endUtility(token)
        }
    }
    /// Invalidates any in-flight disc import so its results cannot land in a
    /// replaced project. Cancellation only *requests* termination; the operation
    /// token stays owned until the import's asynchronous work and helper have
    /// actually stopped, at which point the import's own completion path
    /// releases it. This prevents a new operation from starting while the old
    /// helper is still alive.
    private func invalidateImport() {
        importGeneration = UUID()
        inspecting = false
        importRunner?.cancel()
    }
    func editCopy(_ job: BuildJob) {
        projectGeneration = UUID()
        invalidateImport();invalidateSearches();project=job.project;page="Build a package";persist()
    }
    func chooseConfigLibrary() {
        guard let folder=chooseFile("Choose a local CONFIG library.",directory:true) else { return }
        useConfigLibrary(folder)
    }
    /// Applies a CONFIG library folder: validates it, clears stale results,
    /// supersedes any in-flight search and re-scans the open sheet if there is
    /// one. Separated from the panel so it can be driven deterministically.
    func useConfigLibrary(_ folder: URL) {
        let status = ConfigLibrary.availability(of: folder)
        guard status == .available else { message = ConfigLibrary.describe(status, folder: folder); return }
        configLibrary=folder; configLibraryStatus=status
        configCandidates=[]; configSearchGeneration=UUID(); configSearchTarget=nil; findingConfigs=false
        persist()
        if let id = configDisc, let disc = project.discs.first(where: { $0.id == id }) {
            startConfigSearch(disc: disc, folder: folder)
        }
    }
    func refreshConfigLibraryStatus() {
        configLibraryStatus = ConfigLibrary.availability(of: configLibrary)
        if !configLibraryStatus.isUsable { configCandidates=[] }
    }
    func clearConfigLibrary() {
        configLibrary=nil; configLibraryStatus = .notSelected; configCandidates=[]
        configSearchGeneration=UUID(); configSearchTarget=nil; findingConfigs=false; configDisc=nil; persist()
    }
    func revealConfigLibrary() {
        guard let folder=configLibrary else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    /// Closing the results sheet cancels the in-flight search so it cannot
    /// reopen the sheet or repopulate it later.
    func dismissConfigSheet() {
        configDisc=nil; configSearchGeneration=UUID(); configSearchTarget=nil; findingConfigs=false
    }
    func newProject() {
        let support=project.support
        projectGeneration = UUID()
        invalidateImport();invalidateSearches();project=GameProject();project.support=support;persist()
    }
    func findConfigs(_ index: Int) {
        guard project.discs.indices.contains(index) else { message = "Add a disc before searching for a CONFIG."; return }
        if configLibrary == nil { chooseConfigLibrary() }
        guard let folder=configLibrary else { return }
        refreshConfigLibraryStatus()
        guard configLibraryStatus == .available else { message = ConfigLibrary.describe(configLibraryStatus, folder: folder); return }
        startConfigSearch(disc: project.discs[index], folder: folder)
    }
    /// A search belongs to its folder, disc identity and project generation:
    /// only the newest request for a still-current context may publish results.
    /// The owning generation always finishes its own lifecycle, so a disc that
    /// is edited or removed while the scan runs cannot leave the control stuck.
    private func startConfigSearch(disc: GameDisc, folder: URL) {
        let generation = UUID()
        configSearchGeneration = generation
        configSearchTarget = disc.id
        configCandidates=[]; findingConfigs=true
        let gameID = disc.gameID, discID = disc.id
        let provider = configCandidatesProvider
        Task {
            defer { self.searchCompletionHook?("config") }
            do {
                let results = try await Task.detached { try provider(gameID, folder) }.value
                // A superseded search must not touch the newer search's state.
                guard self.configSearchGeneration == generation else { return }
                self.configSearchTarget = nil
                self.findingConfigs = false
                if self.configLibrary == folder,
                   self.project.discs.contains(where: { $0.id == discID && $0.gameID == gameID }) {
                    self.configCandidates=results; self.configDisc=discID; self.persist()
                } else {
                    // Context changed during the scan: discard matches, never
                    // publish them and never reopen the sheet.
                    self.configCandidates=[]
                }
            } catch {
                guard self.configSearchGeneration == generation else { return }
                self.configSearchTarget = nil
                self.findingConfigs = false
                self.configCandidates=[]
                self.message=error.localizedDescription
            }
        }
    }
    func chooseArtworkLibrary() {
        guard let folder=chooseFile("Choose a local artwork folder (optional). Images whose name begins with the disc's exact game ID are offered; nothing is applied automatically.",directory:true) else { return }
        useArtworkLibrary(folder)
    }
    /// Applies an artwork folder with the same semantics as the CONFIG library:
    /// clear stale matches, supersede in-flight work, re-scan an open sheet.
    func useArtworkLibrary(_ folder: URL) {
        let status = ConfigLibrary.availability(of: folder)
        guard status == .available else { message = ConfigLibrary.describe(status, folder: folder); return }
        artworkLibrary=folder
        artworkCandidates=[]; artworkSearchGeneration=UUID(); artworkSearchTarget=nil; findingArtwork=false
        persist()
        if let id = artworkDisc, let disc = project.discs.first(where: { $0.id == id }) {
            startArtworkSearch(disc: disc, folder: folder)
        }
    }
    func clearArtworkLibrary() {
        artworkLibrary=nil; artworkCandidates=[]
        artworkSearchGeneration=UUID(); artworkSearchTarget=nil; findingArtwork=false; artworkDisc=nil; persist()
    }
    func dismissArtworkSheet() {
        artworkDisc=nil; artworkSearchGeneration=UUID(); artworkSearchTarget=nil; findingArtwork=false
    }
    func findArtwork(_ index: Int) {
        guard project.discs.indices.contains(index) else { message = "Add a disc before searching for artwork."; return }
        if artworkLibrary == nil { chooseArtworkLibrary() }
        guard let folder=artworkLibrary else { return }
        startArtworkSearch(disc: project.discs[index], folder: folder)
    }
    private func startArtworkSearch(disc: GameDisc, folder: URL) {
        let generation = UUID()
        artworkSearchGeneration = generation
        artworkSearchTarget = disc.id
        artworkCandidates=[]; findingArtwork=true
        let gameID = disc.gameID, discID = disc.id
        let provider = artworkCandidatesProvider
        Task {
            defer { self.searchCompletionHook?("artwork") }
            do {
                let results = try await Task.detached { try provider(gameID, folder) }.value
                guard self.artworkSearchGeneration == generation else { return }
                self.artworkSearchTarget = nil
                self.findingArtwork = false
                if self.artworkLibrary == folder,
                   self.project.discs.contains(where: { $0.id == discID && $0.gameID == gameID }) {
                    self.artworkCandidates=results; self.artworkDisc=discID
                } else {
                    self.artworkCandidates=[]
                }
            } catch {
                guard self.artworkSearchGeneration == generation else { return }
                self.artworkSearchTarget = nil
                self.findingArtwork = false
                self.artworkCandidates=[]
                self.message=error.localizedDescription
            }
        }
    }
    /// Discards any in-flight CONFIG/artwork search when the project is
    /// replaced, so stale results cannot land in the new project.
    private func invalidateSearches() {
        configSearchGeneration=UUID(); artworkSearchGeneration=UUID()
        configSearchTarget=nil; artworkSearchTarget=nil
        configCandidates=[]; artworkCandidates=[]
        configDisc=nil; artworkDisc=nil
        findingConfigs=false; findingArtwork=false
    }
    /// Removes a disc, invalidating any search that targeted it so a pending
    /// scan cannot leave the search control disabled or reopen a stale sheet.
    func removeDisc(_ index: Int) {
        guard project.discs.indices.contains(index) else { return }
        invalidateSearch(targeting: project.discs[index].id)
        project.discs.remove(at: index)
        persist()
    }
    /// Called after a disc's game ID is edited: any search that targeted it is
    /// invalidated, because its results would now be for the wrong ID.
    func gameIDEdited(_ index: Int) {
        guard project.discs.indices.contains(index) else { return }
        invalidateSearch(targeting: project.discs[index].id)
    }
    private func invalidateSearch(targeting discID: UUID) {
        if configSearchTarget == discID || configDisc == discID {
            configSearchGeneration=UUID(); configSearchTarget=nil
            configCandidates=[]; findingConfigs=false
            if configDisc == discID { configDisc=nil }
        }
        if artworkSearchTarget == discID || artworkDisc == discID {
            artworkSearchGeneration=UUID(); artworkSearchTarget=nil
            artworkCandidates=[]; findingArtwork=false
            if artworkDisc == discID { artworkDisc=nil }
        }
    }
    func applyArtwork(_ candidate: ArtworkCandidate, asBackground: Bool) {
        guard FileManager.default.fileExists(atPath: candidate.url.path) else {
            message="That image is no longer available. Search again."; return
        }
        if asBackground { project.background = candidate.url } else { project.icon = candidate.url }
        dismissArtworkSheet(); persist()
    }
    /// Optional conversion of local mono/stereo audio to an ATRAC3 (AT3) file for
    /// the package sound. Runs as a normal utility operation: one heavy task at a
    /// time, cancellable, and it never overwrites its source or destination.
    func convertAudioToAT3() {
        guard !working else { message = "Finish the current operation before converting audio."; return }
        guard let source = chooseFile("Choose WAV, AIFF, MP3, M4A, or FLAC audio (up to 2 minutes 30 seconds).") else { return }
        do { _ = try AudioNormalizer.inspect(source) } catch { message = error.localizedDescription; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SND0.AT3"
        panel.message = "Choose a new filename. Existing files are never replaced."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        convertAudio(source: source, destination: destination)
    }
    /// Testable core of the audio conversion (no panels).
    func convertAudio(source: URL, destination: URL) {
        guard !working else { message = "Finish the current operation before converting audio."; return }
        let session = ConversionRunner()
        guard let token = beginUtility(.convert, cancel: { session.cancel() }) else {
            message = "Another operation is already running."; return
        }
        audioOutput = nil; audioError = nil; convertingAudio = true; audioConversionStage = "Preparing audio"
        let helper = at3HelperURL
        let generation = projectGeneration
        let originalSound = project.sound
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try AT3Converter.convert(source: source, destination: destination, helper: helper, runner: session) { update in
                        Task { @MainActor in if self.ownsUtility(token) { self.audioConversionStage = update.stage } }
                    }
                }.value
                if ownsUtility(token) {
                    audioOutput = destination
                    // Export survives a project switch, but automatic selection belongs
                    // only to the originating project and unchanged sound selection.
                    if projectGeneration == generation, project.sound == originalSound {
                        project.sound = destination; persist()
                    }
                }
            } catch {
                if ownsUtility(token) { audioError = error.localizedDescription }
            }
            convertingAudio = false
            endUtility(token)
        }
    }
    func applyConfig(_ candidate: ConfigCandidate) {
        guard let index=project.discs.firstIndex(where:{$0.id==configDisc}) else { return }
        do {
            guard try FileDigest.sha256(candidate.url)==candidate.sha256 else { throw ConversionFailure(message:"This CONFIG changed after the search. Search again before selecting it.") }
            project.discs[index].config=candidate.url;project.discs[index].configHash=candidate.sha256
            project.discs[index].configSource="Local library: "+candidate.relativePath
            dismissConfigSheet();persist()
        } catch { message=error.localizedDescription }
    }
    func setConfig(_ index: Int) {
        guard let url = chooseFile("Choose an unencrypted CONFIG for disc \(index+1). Its fingerprint will be saved with this project.") else { return }
        do {
            let bytes = try FileDigest.small(url,maximum:1024*1024)
            project.discs[index].config = url; project.discs[index].configHash = FileDigest.sha256(data:bytes); project.discs[index].configSource = "Manually selected"; persist()
        } catch { message = error.localizedDescription }
    }
    func importSupport() {
        guard let url = chooseFile("Select your support folder: klic.bin, matching RAP, PS3LOGO.DAT and SCEVMC0.VMC.",directory:true) else { return }
        do { try project.support.importFolder(url); persist() }
        catch { message = error.localizedDescription }
    }
    func exportDiagnostics() {
        let panel=NSSavePanel();panel.nameFieldStringValue="PS2 Classics diagnostics.json"
        panel.message="Save a local troubleshooting report. It includes system version, game IDs, file names and errors, but no game data or key bytes. Nothing is uploaded."
        guard panel.runModal() == .OK, let url=panel.url else { return }
        func summary(_ project: GameProject) -> [String:Any] {
            var result: [String:Any] = ["title":project.title,"titleID":project.titleID,
                "missingSupport":project.support.missing,
                "discs":project.discs.map { ["filename":$0.source.lastPathComponent,"gameID":$0.gameID,
                    "config":$0.config?.lastPathComponent ?? "","configSHA256":$0.configHash ?? "",
                    "configSource":$0.configSource] }]
            result["destinationFilename"]=project.output?.lastPathComponent ?? ""
            return result
        }
        #if arch(arm64)
        let architecture="arm64"
        #else
        let architecture="x86_64"
        #endif
        let report: [String:Any] = ["appVersion":"1.0.0","created":ISO8601DateFormatter().string(from:Date()),
            "system":ProcessInfo.processInfo.operatingSystemVersionString,"architecture":architecture,
            "consoleTested":false,"currentProject":summary(project),
            "jobs":jobs.map { ["status":$0.status,"detail":$0.detail,"project":summary($0.project)] as [String:Any] }]
        do {
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { message=error.localizedDescription }
    }
    func saveProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (project.title.isEmpty ? "Game" : project.title)+".ps2project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try encoder.encode(project).write(to:url,options:.atomic); persist() }
        catch { message = error.localizedDescription }
    }
    func openProject(_ provided: URL? = nil) {
        guard let url = provided ?? chooseFile("Open a saved .ps2project file.") else { return }
        do {
            let loaded = try JSONDecoder().decode(GameProject.self,from:FileDigest.small(url,maximum:1024*1024))
            guard loaded.version == 1, loaded.discs.count <= 9 else { throw ConversionFailure(message:"Unsupported project version or disc count.") }
            projectGeneration = UUID()
            invalidateImport();invalidateSearches()
            project = loaded; page = "Build a package"; persist()
        } catch let DecodingError.keyNotFound(key, _) {
            message = "The file is missing the project field '\(key.stringValue)'. Choose a .ps2project file created by this app."
        } catch { message = error.localizedDescription }
    }
    func destination() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (project.titleID.isEmpty ? "PS2 Game" : project.titleID)+".pkg"
        panel.message = "Choose a new filename. Existing packages are never overwritten."
        if panel.runModal() == .OK { project.output = panel.url; persist() }
    }
    func enqueue(start: Bool) {
        if project.output == nil { destination(); if project.output == nil { return } }
        do {
            try project.validate()
            guard !jobs.contains(where: { ["Waiting","Building"].contains($0.status) && $0.project.output == project.output }) else { throw ConversionFailure(message:"That destination is already assigned to a queued job.") }
            var job = BuildJob(project:project)
            job.queuedIdentity = QueuedJobIdentity(jobID: job.id, project: project)
            jobs.append(job); persist(); page = "Build queue"
            if start { runQueue = true; next() }
        } catch { message = error.localizedDescription }
    }
    func start() { runQueue = true; next() }
    func next() {
        guard runQueue, active == nil, buildToken == nil,
              let index = jobs.firstIndex(where:{$0.status=="Waiting"}) else { return }
        guard let claimed = utilities.begin(.build) else { return }
        buildToken = claimed
        let id = jobs[index].id, snapshot = jobs[index].project
        active = id; jobs[index].status = "Building"; jobs[index].detail = ""; fraction = 0; stage = "Starting"; persist()
        let session = PackageBuilder(); builder = session
        let helper = helperURL
        let attemptURL = attemptPath(for: id)
        try? FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true)
        Task {
            do {
                let result = try await Task.detached(priority:.userInitiated) {
                    try session.build(snapshot,helper:helper,jobID:id,onAttemptPrepared: { attempt in
                        // Durable queue-owned binding, written before encryption:
                        // a crash after this point leaves an attempt recovery
                        // can compare instead of trusting a neighboring report.
                        try AttemptStore.save(attempt, to: attemptURL)
                        Task { @MainActor in
                            if let i = self.jobs.firstIndex(where:{$0.id==id}), self.jobs[i].status == "Building" {
                                self.jobs[i].attempt = attempt; self.persist()
                            }
                        }
                    }) { update in
                        Task { @MainActor in if self.active == id { self.stage = update.stage; self.fraction = update.fraction } }
                    }
                }.value
                if let i = jobs.firstIndex(where:{$0.id==id}) { jobs[i].status = "Locally verified"; jobs[i].detail = result.message; jobs[i].report = result.report }
            } catch {
                if let i = jobs.firstIndex(where:{$0.id==id}) { jobs[i].status = error.localizedDescription.lowercased().contains("cancel") ? "Cancelled" : "Failed"; jobs[i].detail = error.localizedDescription }
            }
            active = nil; builder = nil
            if utilities.end(claimed) { buildToken = nil }
            persist(); next()
        }
    }
    func cancel() { runQueue = false; builder?.cancel(); cancelUtility?(); stage = "Cancelling…" }
    func cancelUtilityOperation() { cancelUtility?() }
    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where:{$0.id==id}), id != active, id != busyJob else { return }
        if let output = jobs[i].project.output, FileManager.default.fileExists(atPath:output.path) {
            editCopy(jobs[i]); project.output = nil; persist()
            message = "An output already exists. Choose a new destination before rebuilding."; return
        }
        // A retry is a fresh attempt: drop stale evidence so recovery can never
        // confirm a previous attempt's package against changed inputs.
        try? FileManager.default.removeItem(at: attemptPath(for: id))
        jobs[i].attempt = nil
        jobs[i].status = "Waiting"; jobs[i].detail = ""; persist()
    }
    func remove(_ id: UUID) { guard active != id, busyJob != id else { return }; jobs.removeAll { $0.id==id }; persist() }
    func moveDisc(_ i: Int, _ delta: Int) {
        let target = i+delta; guard project.discs.indices.contains(target) else { return }
        project.discs.swapAt(i,target); persist()
    }
    /// Folders owned by known queue snapshots. Cleanup only ever scans these
    /// (plus one explicitly picked folder), never the whole disk.
    func cleanupFolders() -> [URL] {
        var folders = [URL]()
        for job in jobs {
            if let output = job.project.output {
                let folder = output.deletingLastPathComponent()
                if !folders.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
                    folders.append(folder)
                }
            }
        }
        if let output = project.output {
            let folder = output.deletingLastPathComponent()
            if !folders.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
                folders.append(folder)
            }
        }
        return folders
    }
    func scanAbandoned() {
        guard let token = beginUtility(.inspect, cancel: {}) else { message = "Another operation is already running. Finish it before reviewing interrupted work."; return }
        guard !cleanupFolders().isEmpty else { endUtility(token); message = "No package destinations are known yet, so there is nothing to review."; return }
        scanningAbandoned = true
        showingCleanup = true
        let folders = cleanupFolders()
        let active = activeWorkspacePaths()
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([OwnedWorkspace], Int) in
                var found = [OwnedWorkspace](); var failures = 0
                for folder in folders {
                    if Task.isCancelled { break }
                    do { found.append(contentsOf: try WorkspaceCleanup.find(in: folder, activePaths: active, isCancelled: { Task.isCancelled })) }
                    catch is CancellationError { break }
                    catch { failures += 1 }
                }
                return (found, failures)
            }.value
            abandoned = result.0.sorted { $0.url.path < $1.url.path }
            scanningAbandoned = false
            if abandoned.isEmpty, result.1 == 0 {
                message = "No interrupted work was found in the known package folders."
            } else if result.1 > 0 {
                message = "Some folders could not be read (they may be disconnected). Showing what was found."
            }
            endUtility(token)
        }
    }
    func scanCustomFolder() {
        guard let folder = chooseFile("Choose a folder to review for interrupted PS2 Classics work.", directory: true) else { return }
        guard let token = beginUtility(.inspect, cancel: {}) else { message = "Another operation is already running. Finish it before reviewing interrupted work."; return }
        scanningAbandoned = true
        let active = activeWorkspacePaths()
        Task {
            do {
                abandoned = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceCleanup.find(in: folder, activePaths: active, isCancelled: { Task.isCancelled })
                }.value
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
            scanningAbandoned = false
            if abandoned.isEmpty { message = "No interrupted work was found in that folder." }
            endUtility(token)
        }
    }
    func removeAbandoned(_ candidate: OwnedWorkspace) {
        guard !working else { message = "Pause or finish the running job before removing anything."; return }
        let active = activeWorkspacePaths()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WorkspaceCleanup.remove(candidate, activePaths: active)
                }.value
                abandoned.removeAll { $0.id == candidate.id }
                message = "Moved \(candidate.url.lastPathComponent) to Trash. Finished packages and originals are never touched by cleanup."
            } catch { message = error.localizedDescription }
        }
    }
    private func activeWorkspacePaths() -> Set<String> {
        var paths = Set<String>()
        for job in jobs {
            if let output = job.project.output {
                paths.insert(output.deletingLastPathComponent().standardizedFileURL.path)
            }
        }
        return paths
    }
    private func attemptPath(for id: UUID) -> URL {
        attemptDirectory.appendingPathComponent(id.uuidString + ".json")
    }
    /// Reconciles an interrupted job that may have published a package before
    /// the crash. Verification is read-only and never overwrites the output.
    /// A job is relabelled as recovered only when the published bytes match the
    /// completion record AND that record is proven to belong to this job's own
    /// durable build attempt; anything less stays explicitly unconfirmed. The
    /// neighboring report is read with a hard size cap off the main actor. One
    /// cancellation signal covers both the digest pass and the helper, and a
    /// user cancellation is normalized to a cancellation outcome, never a
    /// verification failure.
    func verifyPublished(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), id != active, active == nil else { return }
        guard let output = jobs[index].project.output, FileManager.default.fileExists(atPath: output.path) else {
            message = "No published package is present at this job's destination."; return
        }
        let session = ConversionRunner()
        let flag = CancelFlag()
        guard let token = beginUtility(.verify, cancel: { flag.cancel(); session.cancel() }) else { message = "Another operation is already running."; return }
        busyJob = id; fraction = 0; stage = "Hashing published package"
        let helper = helperURL
        let queued = jobs[index].queuedIdentity
        let reportURL = URL(fileURLWithPath: output.path + ".report.json")
        let attemptURL = attemptPath(for: id)
        Task {
            let verdict: RecoveryVerdict
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try flag.check()
                    // Bounded and off the main actor: a huge, malformed or
                    // symlinked neighbor is never read on the UI thread.
                    let attempt = AttemptStore.load(at: attemptURL)
                    let record = ReportReader.readCompletionRecord(at: reportURL)
                    let digest = try FileDigest.sha256(output, cancelled: { try flag.check() }) { done, total in
                        Task { @MainActor in
                            if self.busyJob == id, self.ownsUtility(token) {
                                self.stage = "Hashing published package"
                                self.fraction = total > 0 ? 0.5 * Double(done) / Double(total) : 0
                            }
                        }
                    }
                    try flag.check()
                    let verified: Result<VerifiedPackage, ConversionFailure>
                    do {
                        let result = try session.verifyPackage(output, helper: helper, progress: { update in
                            Task { @MainActor in
                                if self.busyJob == id, self.ownsUtility(token) {
                                    self.stage = "Checking published package"; self.fraction = 0.5 + 0.5 * update.fraction
                                }
                            }
                        })
                        verified = .success(VerifiedPackage(entries: result.entries, payloadBytes: result.payloadBytes,
                                                            contentID: result.contentID, titleID: result.titleID, names: result.names))
                    } catch {
                        // A user cancellation must never be reported as a
                        // verification failure; rethrow so the outer handler
                        // normalizes it and leaves the package untouched.
                        if flag.isCancelled { throw CancellationError() }
                        verified = .failure((error as? ConversionFailure) ?? ConversionFailure(message: error.localizedDescription))
                    }
                    return (digest, attempt, record, verified)
                }.value
                if flag.isCancelled { throw CancellationError() }
                verdict = RecoveryAssessment.assessJob(queued: queued, attempt: outcome.1, record: outcome.2,
                                                       actualDigest: outcome.0, verification: outcome.3)
            } catch {
                if flag.isCancelled {
                    if let i = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[i].status = "Interrupted"
                        jobs[i].detail = "Package check cancelled. The package was left untouched."
                    }
                    busyJob = nil; endUtility(token); persist()
                    return
                }
                verdict = .failed(reason: error.localizedDescription)
            }
            if let i = jobs.firstIndex(where: { $0.id == id }) {
                switch verdict {
                case .confirmedOutput(let entries, let payload):
                    jobs[i].status = "Locally verified (recovered)"
                    jobs[i].detail = "Confirmed output of this job: the completion record matches this job's durable build attempt (ordered source/CONFIG/support/artwork hashes and fit setting), and the package digest, content ID, title ID and disc images all match (\(entries) entries, \(ByteCountFormatter.string(fromByteCount: Int64(payload), countStyle: .file)) payload)."
                case .containerOnly(let reason):
                    jobs[i].status = "Interrupted"
                    jobs[i].detail = "The package is structurally intact, but it is not confirmed as this job's output: \(reason). It was left untouched."
                case .failed(let reason):
                    jobs[i].status = "Interrupted"
                    jobs[i].detail = "The published package did not verify and was left untouched: \(reason)"
                }
            }
            busyJob = nil; endUtility(token); persist()
        }
    }
    func refreshCacheInfo() {
        let folders = cleanupFolders()
        guard !folders.isEmpty else { cacheBytes = 0; return }
        Task {
            let total = await Task.detached(priority: .utility) {
                folders.reduce(UInt64(0)) { $0 + StageCache.totalSize(in: $1) }
            }.value
            cacheBytes = total
        }
    }
    func clearStageCache() {
        guard !working else { message = "Finish the running job before clearing the stage cache."; return }
        guard let token = beginUtility(.build, cancel: {}) else { message = "Another operation is already running."; return }
        let folders = cleanupFolders()
        Task {
            let removed = await Task.detached(priority: .utility) {
                folders.reduce(UInt64(0)) { $0 + StageCache.clear(in: $1) }
            }.value
            cacheBytes = 0
            endUtility(token)
            message = "Removed \(ByteCountFormatter.string(fromByteCount: Int64(removed), countStyle: .file)) of verified stage cache. Original images and finished packages were not touched."
        }
    }
    func saveSupportProfile() {
        guard let store = profileStore else { return }
        do {
            try store.add(name: profileName, support: project.support)
            supportProfiles = store.profiles
            profileName = ""; namingProfile = false
            message = "Saved support profile. It stores file locations and the content ID, never key bytes."
        } catch { message = error.localizedDescription }
    }
    func applySupportProfile(_ profile: NamedSupportProfile) {
        let problems = profileStore?.validate(profile) ?? []
        if !problems.isEmpty {
            message = "This profile cannot be used as saved: " + problems.joined(separator: ", ") + ". Re-select the files in Setup."
            return
        }
        var support = profile.support
        support.sourceFolder = nil
        project.support = support
        persist()
        message = "Applied support profile \(profile.name). Confirm the content ID matches your console installation."
    }
    func deleteSupportProfile(_ profile: NamedSupportProfile) {
        do { try profileStore?.remove(id: profile.id); supportProfiles = profileStore?.profiles ?? [] }
        catch { message = error.localizedDescription }
    }
}
