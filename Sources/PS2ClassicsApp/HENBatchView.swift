// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PS2ClassicsCore

/// Super Slim / HEN batch export. The page is deliberately limited to the
/// standalone `.iso` -> `.BIN.ENC` preset: no PKG and no CFW-only choices are
/// offered here, and nothing on it performs an FTP transfer.
struct HENBatchView: View {
    @StateObject private var model = HENBatchModel()
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                queue
                settings
                actions
                if let plan = model.plan { review(plan) }
                if !model.notes.isEmpty { notes }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange).textSelection(.enabled) }
                disclosure
            }
            .padding(26)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Super Slim / HEN").font(.largeTitle.bold())
            Text("Prepare separate PS2 games as encrypted .BIN.ENC images for webMAN MOD on a HEN console.")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Queue

    private var queue: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Games").font(.headline)
                    Spacer()
                    Text("\(model.items.count) / \(HENBatchExporter.maxBatchSize)")
                        .foregroundColor(.secondary)
                    Button("Add ISO files…") { model.pickISOs() }
                        .disabled(model.locked || model.items.count >= HENBatchExporter.maxBatchSize)
                    if !model.items.isEmpty {
                        Button("Remove all") { model.removeAll() }.disabled(model.locked)
                    }
                }
                if model.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "opticaldiscdrive").font(.system(size: 30))
                        Text("Drop 1–50 .iso files here").foregroundColor(.secondary)
                        Text("Your original ISO files are never modified or moved.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                }
                ForEach(model.items) { row in
                    rowView(row)
                }
            }
            .padding(8)
        }
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(dropping ? Color.accentColor : .clear, lineWidth: 2))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            Task { @MainActor in
                var urls = [URL]()
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
                    }
                    if let url { urls.append(url) }
                }
                if !urls.isEmpty { model.add(urls) }
            }
            return true
        }
    }

    private func rowView(_ row: HENBatchItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(row.status)).foregroundColor(color(row.status))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.source.lastPathComponent).lineLimit(1)
                    if let gameID = row.gameID {
                        Text(gameID).font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                Text(row.detail).font(.caption)
                    .foregroundColor(row.status == .failed ? .orange : .secondary)
                    .lineLimit(3).textSelection(.enabled)
                if let config = row.config {
                    Text("CONFIG: \(config.lastPathComponent)").font(.caption)
                        .foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.status == .published, let folder = row.publishedFolder {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: {
                    Image(systemName: "folder")
                }.accessibilityLabel("Show published folder")
            }
            if !model.locked {
                if row.status != .published {
                    Button(row.config == nil ? "Add CONFIG…" : "Change CONFIG…") { model.chooseConfig(row.id) }
                    if row.config != nil { Button("Clear") { model.clearConfig(row.id) } }
                }
                if row.status.isRetryable {
                    Button("Retry") { model.retry(row.id) }
                }
                Button { model.remove(row.id) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove \(row.source.lastPathComponent)")
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(7)
    }

    private func symbol(_ status: HENBatchStatus) -> String {
        switch status {
        case .queued: return "circle"
        case .ready: return "checkmark.circle"
        case .converting: return "arrow.triangle.2.circlepath"
        case .published: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .interrupted: return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private func color(_ status: HENBatchStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .ready: return .accentColor
        case .converting: return .accentColor
        case .published: return .green
        case .failed: return .orange
        case .cancelled, .interrupted: return .secondary
        }
    }

    // MARK: - Settings

    private var settings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export settings").font(.headline)
                HStack {
                    Button("Choose klicensee…") { model.chooseKey() }.disabled(model.locked)
                    Text(model.keyFile?.lastPathComponent ?? "No key selected")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Text("The matching 16-byte binary klicensee, usually named klic.bin. A RAP or RIF is a different file and will be refused. The key must match the console's support files.")
                    .font(.caption).foregroundColor(.secondary)
                HStack(alignment: .top) {
                    Text("Content ID").frame(width: 90, alignment: .leading)
                    TextField("36-character ID from Setup", text: Binding(get: { model.contentID },
                        set: { model.setContentID($0) }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.setContentID(model.contentID) }
                    .disabled(model.locked)
                }
                HStack {
                    Button("Choose output folder…") { model.chooseDestination() }.disabled(model.locked)
                    Text(model.destination?.path ?? "No output folder selected")
                        .font(.caption).foregroundColor(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Toggle("Nest folders for the console path (dev_hdd0/PS2ISO)",
                       isOn: Binding(get: { model.folderLayout },
                                     set: { model.setFolderLayout($0) }))
                    .disabled(model.locked)
                Text("Output goes to “\(HENBatchExporter.readyFolderName)” under the folder you chose, one folder per game holding its .BIN.ENC and, when selected, its plain CONFIG. This workflow arranges files only: it does not connect to the console, transfer anything over FTP, or save FTP credentials. Use “Send to PS3” for FTP transfers.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - The two steps

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.busy {
                    ProgressView(value: model.fraction).frame(width: 160)
                    Button("Cancel") { model.cancel() }
                }
                Spacer()
                if model.canReveal { Button("Show output folder") { model.reveal() } }
                Button("1. Check batch") { model.checkBatch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCheck)
                Button("2. Start batch") { model.startBatch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            }
            Text(model.busy
                 ? model.stage
                 : (model.stage.isEmpty ? "Add ISO files, choose a key and output folder, then check the whole batch before anything is converted." : model.stage))
                .font(.caption).foregroundColor(.secondary).lineLimit(3)
            if model.plan != nil {
                Text("Step 1 finished. Nothing has been converted yet — review the checked list below, then choose Start batch.")
                    .font(.caption).foregroundColor(.accentColor)
            }
        }
    }

    /// The review surface: everything the user is approving, per game.
    /// Built from HStack/VStack rather than `Grid`, which needs macOS 13.
    private func review(_ plan: HENBatchPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Checked output (\(plan.items.count) game\(plan.items.count == 1 ? "" : "s"))").font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    Text("Source").font(.caption.bold()).frame(width: 220, alignment: .leading)
                    Text("Game ID").font(.caption.bold()).frame(width: 96, alignment: .leading)
                    Text("Image size").font(.caption.bold()).frame(width: 88, alignment: .leading)
                    Text("Output folder").font(.caption.bold())
                }
                Divider()
                ForEach(plan.items, id: \.id) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.source.lastPathComponent).font(.caption).lineLimit(1)
                            .frame(width: 220, alignment: .leading)
                        Text(item.displayGameID).font(.caption.monospaced())
                            .frame(width: 96, alignment: .leading)
                        Text(HENBatchExporter.formatted(item.estimatedOutputBytes)).font(.caption)
                            .frame(width: 88, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.folderName).font(.caption).lineLimit(1)
                            if let sidecar = item.configSidecarName {
                                Text("+ \(sidecar)").font(.caption)
                                    .foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Needs about \(HENBatchExporter.formatted(plan.requiredBytes))")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Free at destination: \(HENBatchExporter.formatted(plan.freeBytes)) (\(plan.fileSystem))")
                        .font(.caption).foregroundColor(.secondary)
                }
                if plan.folderLayout {
                    Text("Copy the contents of each game folder into /dev_hdd0/PS2ISO on the console, then launch with the PS2 Classics Launcher.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Copy each game folder's .BIN.ENC (and its .CONFIG, if present) into /dev_hdd0/PS2ISO on the console, then launch with the PS2 Classics Launcher.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var notes: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before you start").font(.headline)
                ForEach(model.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    private var disclosure: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("What this does not establish").font(.headline)
                Text("This preset creates standalone encrypted images only. It does not create PKGs, and it does not make raw .iso files work — those are CFW-only. Checking an ISO is a structural read of its header and SYSTEM.CNF game ID; it is not proof of disc integrity or console compatibility. Whether these images appear and launch on a HEN console, including the exact folder layout, has not been tested on hardware. A batch of separate games does not imply multi-disc support or disc switching.")
                    .font(.caption).foregroundColor(.orange).textSelection(.enabled)
            }
            .padding(8)
        }
    }
}
