// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import PS2ClassicsCore

/// Image-tools operation state. One operation owns the busy slot and a token;
/// stale completions from a superseded token can never publish results or
/// clear a newer operation's state.
@MainActor
final class WorkspaceModel: ObservableObject {
    enum Operation: Equatable { case idle, inspecting, converting, verifying, detecting }

    @Published var source: URL?
    @Published var key: URL?
    @Published var inspection: DiscInspection?
    /// Explicitly chosen parent CHD when the source stores differences
    /// against one. Reset whenever the source changes.
    @Published var parent: URL?
    @Published var action = ConversionAction.encrypt
    @Published var contentID = ""
    @Published var discNumber = 1 {
        // Keep single-image encryption consistent with package disc numbering.
        didSet { if action == .encrypt { logicalName = EncryptedProfile.forDisc(discNumber) } }
    }
    @Published var logicalName = EncryptedProfile.forDisc(1)
    @Published private(set) var operation: Operation = .idle
    @Published var stage = ""
    @Published var fraction = 0.0
    @Published var error: String?
    @Published var output: URL?
    @Published var detection: EncryptedProfile.Detection?
    @Published var notice: String?
    private var token = UUID()
    private var runner: ConversionRunner?
    private let studio: StudioModel
    private let helper: URL

    var busy: Bool { operation != .idle }
    var detecting: Bool { operation == .detecting }

    /// Decrypt-mode guidance for files generic ISO inspection cannot parse.
    /// An unrecognized file in decrypt mode may be a sealed CEX image, which
    /// only Detect profile / decrypt / verify handle — the inspector text
    /// alone must not read as "encrypted images are unsupported".
    static func decryptModeNotice(action: ConversionAction, inspection: DiscInspection?) -> String? {
        guard action == .decrypt, let inspection, !inspection.isSupported else { return nil }
        return "Generic inspection does not parse this file. If it is a sealed CEX image, use Detect profile, then decrypt or verify with its disc number."
    }
    var verifying: Bool { operation == .verifying }

    init(studio: StudioModel? = nil) {
        let studio = studio ?? .shared
        self.studio = studio
        self.helper = studio.helperURL
        key = studio.project.support.key
        contentID = studio.project.support.contentID
    }

    /// Ends an operation only if its token still owns the model.
    private func finish(_ owned: UUID) {
        guard token == owned else { return }
        operation = .idle
        runner = nil
        studio.endUtility(owned)
    }

    func chooseSource() {
        guard operation == .idle else { notice = "Wait for the current image operation to finish."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let session = ConversionRunner()
        guard let owned = studio.beginUtility(.inspect, cancel: { session.cancel() }) else {
            notice = "Another operation is already running."; return
        }
        token = owned; runner = session
        source = (try? DiscInput.resolve(url)) ?? url
        parent = nil
        inspection = nil; error = nil; output = nil; detection = nil; notice = nil
        operation = .inspecting; stage = "Inspecting"; fraction = 0
        Task {
            do {
                let inspected = try await Task.detached(priority: .userInitiated) {
                    try DiscInspector.inspect(url, helper: self.helper, runner: session)
                }.value
                guard token == owned else { return }
                inspection = inspected
                if inspected.requiresParent {
                    notice = nil
                    error = "This CHD stores differences against a parent image. Choose the exact parent CHD below; both originals stay unchanged."
                } else if let guidance = Self.decryptModeNotice(action: action, inspection: inspected) {
                    notice = guidance
                }
            } catch { if token == owned { self.error = error.localizedDescription } }
            finish(owned)
        }
    }

    /// Clears the parent and re-inspects the source standalone so the shown
    /// state always matches the pair that would be converted.
    func clearParent() {
        guard operation == .idle, let source = source else { return }
        let session = ConversionRunner()
        guard let owned = studio.beginUtility(.inspect, cancel: { session.cancel() }) else {
            notice = "Another operation is already running."; return
        }
        token = owned; runner = session
        parent = nil
        inspection = nil; error = nil; output = nil; detection = nil; notice = nil
        operation = .inspecting; stage = "Inspecting"; fraction = 0
        Task {
            do {
                let inspected = try await Task.detached(priority: .userInitiated) {
                    try DiscInspector.inspect(source, helper: self.helper, runner: session)
                }.value
                guard token == owned else { return }
                inspection = inspected
                if inspected.requiresParent {
                    error = "This CHD stores differences against a parent image. Choose the exact parent CHD below; both originals stay unchanged."
                } else if let guidance = Self.decryptModeNotice(action: action, inspection: inspected) {
                    notice = guidance
                }
            } catch { if token == owned { self.error = error.localizedDescription } }
            finish(owned)
        }
    }

    /// Chooses the explicit parent CHD and re-inspects the pair, so a wrong
    /// file fails here with its precise reason instead of during conversion.
    func chooseParent() {
        guard operation == .idle, let source = source else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the exact parent CHD this image was derived from."
        panel.prompt = "Use parent"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "chd" else {
            error = "The parent must be a CHD file (\(url.lastPathComponent))."; return
        }
        guard url.standardizedFileURL != source.standardizedFileURL else {
            error = "The parent and the image are the same file."; return
        }
        let session = ConversionRunner()
        guard let owned = studio.beginUtility(.inspect, cancel: { session.cancel() }) else {
            notice = "Another operation is already running."; return
        }
        token = owned; runner = session
        operation = .inspecting; stage = "Checking parent"; fraction = 0
        error = nil; output = nil; detection = nil; notice = nil
        Task {
            do {
                let inspected = try await Task.detached(priority: .userInitiated) {
                    try DiscInspector.inspect(source, parent: url, helper: self.helper, runner: session)
                }.value
                guard token == owned else { return }
                if inspected.isSupported {
                    parent = url; inspection = inspected
                    notice = "Parent accepted. Both originals stay unchanged."
                } else {
                    error = "The selected file is not this image's parent. Choose the exact parent CHD."
                }
            } catch { if token == owned { self.error = error.localizedDescription } }
            finish(owned)
        }
    }

    func chooseKey() {
        guard operation == .idle else { notice = "Wait for the current image operation to finish."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the 16-byte binary klicensee for this content. A RAP or RIF file is not a klicensee."
        panel.prompt = "Use key"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        token = UUID(); key = url; detection = nil; notice = nil; error = nil
    }

    func convert() {
        guard operation == .idle else { notice = "Wait for the current image operation to finish."; return }
        guard let source = source, let key = key else { return }
        do {
            _ = try ConversionRequest(action: action, source: source, destination: URL(fileURLWithPath: "/placeholder"),
                                      keyFile: key, contentID: contentID, discNumber: discNumber,
                                      logicalName: logicalName).arguments()
        } catch { self.error = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.title = action == .encrypt ? "Save encrypted image" : "Save decrypted payload"
        panel.nameFieldStringValue = action == .encrypt ? logicalName : "Decrypted image.iso"
        panel.message = "Choose a new output filename. Existing files will not be replaced."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            error = "The destination already exists. Choose a new filename; existing files are never replaced."
            return
        }
        let request = ConversionRequest(action: action, source: source, destination: destination,
                                        keyFile: key, contentID: contentID, discNumber: discNumber,
                                        logicalName: logicalName, parentSource: parent)
        let session = ConversionRunner()
        guard let owned = studio.beginUtility(.convert, cancel: { session.cancel() }) else {
            notice = "Another operation is already running."; return
        }
        token = owned; runner = session
        operation = .converting; error = nil; output = nil; notice = nil; fraction = 0; stage = "Starting"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try session.run(request, helper: self.helper) { update in
                        Task { @MainActor in
                            guard self.token == owned else { return }
                            self.stage = update.stage.capitalized
                            self.fraction = update.fraction
                        }
                    }
                }.value
                if token == owned { output = destination }
            } catch { if token == owned { self.error = error.localizedDescription } }
            finish(owned)
        }
    }

    func cancel() {
        guard operation != .idle else { return }
        runner?.cancel()
        studio.cancelUtility?()
        stage = "Cancelling…"
    }

    /// Identifies the sealing profile of an encrypted image without decrypting it.
    /// Detection uses fixed header-authentication keys, so no klicensee is needed.
    func detectProfile() {
        guard operation == .idle else { notice = "Wait for the current image operation to finish."; return }
        guard let source = source else { return }
        let session = ConversionRunner()
        guard let owned = studio.beginUtility(.detect, cancel: { session.cancel() }) else {
            notice = "Another operation is already running."; return
        }
        token = owned; runner = session
        operation = .detecting; error = nil; notice = nil; detection = nil; stage = "Detecting profile"; fraction = 0
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try session.inspectEncrypted(source, helper: self.helper)
                }.value
                if token == owned {
                    detection = found
                    if EncryptedProfile.isImage(found.logicalName) {
                        logicalName = found.logicalName
                        if let disc = EncryptedProfile.disc(forImage: found.logicalName) { discNumber = disc }
                        if !found.complete {
                            notice = "Profile \(found.logicalName) detected, but the file length does not match its declared payload. Verification will fail; the file may be truncated."
                        }
                    } else {
                        notice = "This file is sealed as \(found.logicalName), a CONFIG record rather than an installable image. CONFIG handling stays in the package workflow."
                    }
                }
            } catch { if token == owned { self.error = error.localizedDescription } }
            finish(owned)
        }
    }

    /// Verifies header authentication, segment hashes and disc numbering
    /// without writing any output file.
    func verifyOnly() {
        guard operation == .idle else { notice = "Wait for the current image operation to finish."; return }
        guard let source = source, let key = key else { return }
        let disc = discNumber, profile = logicalName
        let session = ConversionRunner()
        guard let owned = studio.beginUtility(.verify, cancel: { session.cancel() }) else {
            notice = "Another operation is already running."; return
        }
        token = owned; runner = session
        operation = .verifying; error = nil; notice = nil; output = nil; fraction = 0; stage = "Verifying"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try session.verify(source: source, keyFile: key, discNumber: disc,
                                       logicalName: profile, helper: self.helper) { update in
                        Task { @MainActor in
                            guard self.token == owned else { return }
                            self.stage = "Verifying"
                            self.fraction = update.fraction
                        }
                    }
                }.value
                if token == owned {
                    notice = "Verification passed for profile \(profile), disc \(disc). No files were written."
                }
            } catch { if token == owned { self.error = error.localizedDescription } }
            finish(owned)
        }
    }
}

struct ImageWorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Prepare your image").font(.largeTitle.bold())
                    Text("Inspect, encrypt or decrypt while preserving your original. Use Build a package for installable package creation.")
                        .foregroundColor(.secondary)
                    Button("Choose image…", action: model.chooseSource).disabled(model.busy)
                    if let source = model.source {
                        Text(source.lastPathComponent).font(.title3.bold()).textSelection(.enabled)
                    }
                    if let result = model.inspection {
                        VStack(alignment: .leading, spacing: 8) {
                            row("Size", ByteCountFormatter.string(fromByteCount: Int64(result.byteCount), countStyle: .file))
                            row("Format", result.format)
                            if let expanded = result.expandedByteCount { row("Expanded",ByteCountFormatter.string(fromByteCount:Int64(expanded),countStyle:.file)) }
                            if let label = result.volumeLabel, !label.isEmpty { row("Volume", label) }
                            ForEach(result.notes, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    if model.inspection?.requiresParent == true {
                        HStack {
                            Button("Choose parent CHD…", action: model.chooseParent).disabled(model.busy)
                            if let parent = model.parent {
                                Text(parent.lastPathComponent).font(.caption).foregroundColor(.secondary)
                                Button("Clear") { model.clearParent() }.disabled(model.busy)
                            } else if let sha1 = model.inspection?.parentSHA1 {
                                Text("Needs parent \(String(sha1.prefix(16)))…").font(.system(size:10,design:.monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    Divider()
                    Picker("Operation", selection: $model.action) {
                        ForEach(ConversionAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.busy)
                     Text(model.action == .encrypt
                          ? "Supports ISO, single-track BIN and supported DVD/CD CHD images, including parent-dependent CHDs once their exact parent is chosen. CHD expansion uses temporary space beside the output. Preparation adds padding and LIMG to the output stream. Each encrypted image is read back and checked before it is published."
                         : "Supports CEX images sealed with any numbered ISO.BIN.ENC profile. Use Detect profile for a packaged later disc, then decrypt with its disc number. The decrypted payload retains any preparation padding and LIMG; it is not automatically stripped back to the original ISO.")
                        .font(.callout).foregroundColor(.secondary)
                    HStack {
                        Button("Choose klicensee…", action: model.chooseKey).disabled(model.busy)
                        Text(model.key?.lastPathComponent ?? "16-byte binary key required")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if model.action == .encrypt {
                        TextField("Content ID (36 characters)", text: $model.contentID)
                            .textFieldStyle(.roundedBorder).disabled(model.busy)
                    }
                    Stepper("Disc number: \(model.discNumber)", value: $model.discNumber, in: 1...9).disabled(model.busy)
                    HStack {
                        Picker("Image profile", selection: $model.logicalName) {
                            ForEach(EncryptedProfile.imageOptions, id: \.self) { Text($0).tag($0) }
                        }.frame(maxWidth: 320).disabled(model.busy)
                        if model.action == .decrypt {
                            Button(model.detecting ? "Detecting…" : "Detect profile") { model.detectProfile() }
                                .disabled(model.busy || model.source == nil)
                        }
                    }
                    if let detection = model.detection, let payload = detection.payloadBytes {
                        Text("Detected \(detection.logicalName) sealing a \(ByteCountFormatter.string(fromByteCount:Int64(payload),countStyle:.file)) payload. The disc number is checked against per-segment records during decryption.").font(.caption).foregroundColor(.secondary)
                    } else if let detection = model.detection, !detection.complete {
                        Text("Detected \(detection.logicalName), but the file does not match its declared payload length. It may be truncated; verification will fail.").font(.caption).foregroundColor(.orange)
                    }
                    Text("Use the package workspace to group multiple discs. Disc switching still needs console testing.")
                        .font(.caption).foregroundColor(.secondary)
                    if model.busy {
                        HStack {
                            ProgressView(value: model.fraction).frame(maxWidth: 300)
                            Text(model.stage).font(.caption)
                            Button("Cancel", action: model.cancel)
                        }
                    } else {
                        Button(model.action == .encrypt ? "Encrypt and verify…" : "Decrypt and verify…", action: model.convert)
                            .disabled(model.source == nil || model.key == nil ||
                                      (model.action == .encrypt && (model.contentID.count != 36 || model.inspection?.isSupported != true)))
                        if model.action == .decrypt {
                            Button("Verify only (no output file)") { model.verifyOnly() }
                                .disabled(model.source == nil || model.key == nil)
                        }
                    }
                    if let message = model.notice {
                        Label(message, systemImage: "checkmark.circle.fill").foregroundColor(.green).textSelection(.enabled)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.orange).textSelection(.enabled)
                    }
                    if let output = model.output {
                        Label("Output created and locally verified", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        Text("This confirms the implemented format and payload checks. PS3 operation has not been tested.")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Show output in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    }
                    Text("Target: macOS 12+ • Intel and Apple Silicon • Originals opened read-only")
                        .font(.caption).foregroundColor(.secondary)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}
