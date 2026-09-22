// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PS2ClassicsCore

@main
struct PS2ClassicsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("PS2 Classics for Mac") { StudioView().onOpenURL { url in
            if url.pathExtension.lowercased()=="ps2project" { StudioModel.shared.openProject(url) }
            else { StudioModel.shared.addDiscs([url]) }
        }}
        .commands {
            CommandGroup(replacing:.help) {
                Button("PS2 Classics User Guide") {
                    if let url = Bundle.main.url(forResource:"User Guide",withExtension:"md") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(after:.appInfo) {
                Button("License and source information") {
                    if let url = Bundle.main.url(forResource:"Licensing",withExtension:"md") { NSWorkspace.shared.open(url) }
                }
                Button("View GNU GPL v3") {
                    if let url = Bundle.main.url(forResource:"LICENSE",withExtension:"txt") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(replacing:.newItem) {
                Button("New project") { StudioModel.shared.newProject() }.keyboardShortcut("n")
                Button("Open project…") { StudioModel.shared.openProject() }.keyboardShortcut("o")
                Button("Save project…") { StudioModel.shared.saveProject() }.keyboardShortcut("s")
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single-window utility app: never linger with no windows, where there
    /// would be no way to reopen the interface.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = StudioModel.shared; model.persist()
        guard model.working else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "A package is still building"
        alert.informativeText = "Keep the app open to finish, or cancel the current build and quit. Your queue will be saved."
        alert.addButton(withTitle:"Keep open"); alert.addButton(withTitle:"Cancel build and quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.cancel()
        Task { @MainActor in
            while model.working { try? await Task.sleep(nanoseconds:100_000_000) }
            sender.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }
}

struct StudioView: View {
    @ObservedObject private var model = StudioModel.shared
    private let pages = [("Build a package","shippingbox"),("Build queue","list.bullet.rectangle"),("Image tools","opticaldisc"),("Memory cards","externaldrive"),("Online CONFIGs","network"),("Send to PS3","arrow.up.doc"),("Setup","slider.horizontal.3")]
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:22) {
                Image(systemName:"opticaldisc").font(.system(size:42)).foregroundColor(.accentColor)
                Text("PS2 Classics").font(.title2.bold())
                Text("FOR MAC").font(.caption).tracking(3).foregroundColor(.secondary)
                Divider()
                VStack(spacing:6) {
                ForEach(pages,id:\.0) { page in
                    Button { model.page = page.0 } label: {
                        HStack { Label(page.0,systemImage:page.1); Spacer() }.padding(10)
                            .background(model.page == page.0 ? Color.accentColor.opacity(0.15) : Color.clear).cornerRadius(8)
                    }.buttonStyle(.plain).disabled((model.utilityBusy && model.page != page.0) || (model.busy && ["Image tools","Memory cards"].contains(page.0)))
                }
                }
                Spacer()
                if model.busy { ProgressView(value:model.fraction); Text(model.stage).font(.caption).lineLimit(3) }
                Text("1.0 RC8 • Release candidate\nIntel + Apple Silicon\nmacOS 12 and later").font(.caption).foregroundColor(.secondary)
            }.padding(22).frame(width:195).frame(maxHeight:.infinity).background(Color(NSColor.controlBackgroundColor))
            Divider()
            Group {
                switch model.page {
                case "Build queue": QueueView(model:model)
                case "Image tools": ImageWorkspaceView()
                case "Memory cards": CardView()
                case "Online CONFIGs": OnlineConfigView()
                case "Send to PS3": ConsoleTransferView()
                case "Setup": SetupView(model:model)
                default: PackageView(model:model)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:980,minHeight:640)
        .alert("Please review",isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message=nil}})) {
            if model.recoveryBackupURL != nil { Button("Reveal backup") { model.revealRecoveryFolder() } }
            Button("OK") { model.message=nil }
        } message: { Text(model.message ?? "") }
    }
}

struct PackageView: View {
    @ObservedObject var model: StudioModel
    @State private var dropping = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Build your collection").font(.largeTitle.bold())
                        Text("Bring your discs together in a PS2 Classics package.").foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Open…") { model.openProject() }; Button("Save project…") { model.saveProject() }
                }
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Text("Discs").font(.headline); Spacer()
                            if model.inspecting { ProgressView().controlSize(.small); Button("Cancel import") { model.cancelUtilityOperation() }.controlSize(.small) }
                            Button("Add discs…") { model.addDiscs() }.disabled(model.inspecting || model.working)
                        }
                        if model.project.discs.isEmpty {
                            VStack(spacing:10) {
                                Image(systemName:"opticaldiscdrive").font(.system(size:32))
                                Text("Drop ISO, BIN, CUE or CHD files here")
                                Text("Your original images are opened read-only.").font(.caption).foregroundColor(.secondary)
                            }.frame(maxWidth:.infinity).padding(28)
                        }
                        ForEach(Array(model.project.discs.indices),id:\.self) { i in
                            VStack(alignment:.leading,spacing:8) {
                                HStack {
                                    Text("\(i+1)").font(.headline).frame(width:28,height:28).background(Color.accentColor.opacity(0.15)).clipShape(Circle())
                                    Text(model.project.discs[i].source.lastPathComponent).lineLimit(2)
                                    Spacer()
                                    Button { model.moveDisc(i,-1) } label: { Image(systemName:"arrow.up") }.disabled(i==0).accessibilityLabel("Move disc \(i+1) earlier")
                                    Button { model.moveDisc(i,1) } label: { Image(systemName:"arrow.down") }.disabled(i==model.project.discs.count-1).accessibilityLabel("Move disc \(i+1) later")
                                    Button { model.removeDisc(i) } label: { Image(systemName:"minus.circle") }.accessibilityLabel("Remove disc \(i+1)")
                                }
                                HStack {
                                    Text("Game ID").foregroundColor(.secondary)
                                    TextField("SLUS12345",text:$model.project.discs[i].gameID).frame(width:120).onChange(of:model.project.discs[i].gameID) { _ in model.gameIDEdited(i) }
                                    Button("Choose CONFIG…") { model.setConfig(i) }
                                    Button("Find matches…") { model.findConfigs(i) }.disabled(model.findingConfigs || !GameProject.validGameID(model.project.discs[i].gameID))
                                    Text(model.project.discs[i].config?.lastPathComponent ?? "No CONFIG selected").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    if model.project.discs[i].config != nil { Button("Clear") { model.project.discs[i].config=nil; model.project.discs[i].configHash=nil; model.persist() } }
                                }
                                if model.project.discs[i].config != nil {
                                    TextField("CONFIG source / version",text:$model.project.discs[i].configSource).font(.caption)
                                    Text("SHA-256: \(model.project.discs[i].configHash ?? "")").font(.system(size:10,design:.monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                                }
                            }.padding(10).background(Color(NSColor.textBackgroundColor)).cornerRadius(8)
                        }
                        if model.project.discs.count>1 { Text("Multiple discs: order and game IDs are saved explicitly. Packages use DISC.IDX and per-disc CONFIG records. Disc switching is experimental until tested on your PS3.").font(.caption).foregroundColor(.orange) }
                    }.padding(10)
                }.overlay(RoundedRectangle(cornerRadius:8).stroke(dropping ? Color.accentColor : .clear,lineWidth:2))
                    .onDrop(of:[UTType.fileURL],isTargeted:$dropping) { providers in
                        Task { @MainActor in
                            var urls=[URL]()
                            for provider in providers {
                                let url: URL? = await withCheckedContinuation { continuation in
                                    _ = provider.loadObject(ofClass:URL.self) { value,_ in continuation.resume(returning:value) }
                                }
                                if let url=url { urls.append(url) }
                            }
                            if !urls.isEmpty { model.addDiscs(urls) }
                        }
                        return true
                    }
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Package details").font(.headline)
                        TextField("Display title",text:$model.project.title)
                        HStack { Text("Title ID").frame(width:75,alignment:.leading); TextField("SLUS12345",text:$model.project.titleID).frame(width:150); Text("Identifies this installation and its saves.").font(.caption).foregroundColor(.secondary) }
                        HStack { Button("Choose destination…") { model.destination() }; Text(model.project.output?.path ?? "No destination selected").font(.caption).foregroundColor(.secondary).lineLimit(2).textSelection(.enabled) }
                    }.padding(10)
                }
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Artwork & sound").font(.headline)
                        HStack(alignment:.top,spacing:16) {
                            artworkButton("Icon",url:$model.project.icon)
                            artworkButton("Background",url:$model.project.background)
                            VStack(alignment:.leading,spacing:10) {
                                Toggle("Crop artwork to fill",isOn:$model.project.cropArtwork)
                                Text("Otherwise, artwork is fitted without distortion. A title card is generated when no image is selected.").font(.caption).foregroundColor(.secondary)
                                Button(model.findingArtwork ? "Finding artwork…" : "Find artwork…") { model.findArtwork(0) }
                                    .disabled(model.project.discs.isEmpty || model.findingArtwork)
                                Button("Choose manual PDF or image…") { if let manual = model.chooseFile("Choose a PDF (up to 100 pages) or a single PNG/JPEG page, up to 32 MB.") { model.project.manual=manual; model.persist() } }
                                if let manual=model.project.manual { HStack { Text(manual.lastPathComponent).font(.caption); Button("Clear manual") { model.project.manual=nil; model.persist() } } }
                                Text("Manual pages are fitted to the console format. PS3 display acceptance remains pending.").font(.caption).foregroundColor(.secondary)
                                Button("Choose AT3 sound…") { if let sound = model.chooseFile("Choose an existing SND0.AT3 audio file (at most 2.5 MB).") { model.project.sound=sound } }
                                if let sound=model.project.sound { HStack { Text(sound.lastPathComponent).font(.caption); Button("Clear") { model.project.sound=nil } } }
                                Button(model.convertingAudio ? "Converting audio…" : "Convert audio to AT3…") { model.convertAudioToAT3() }.disabled(model.busy)
                                if model.convertingAudio {
                                    HStack { ProgressView().controlSize(.small); Text(model.audioConversionStage).font(.caption); Button("Cancel") { model.cancelUtilityOperation() } }
                                }
                                if let output = model.audioOutput {
                                    HStack {
                                        Text("Exported: \(output.lastPathComponent)").font(.caption)
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                                    }
                                }
                                if let err = model.audioError {
                                    Label(err, systemImage:"exclamationmark.triangle").foregroundColor(.orange).font(.caption).textSelection(.enabled)
                                }
                                Text("Converts mono/stereo WAV, AIFF, MP3, M4A, or FLAC audio to AT3. Maximum length: 2 minutes 30 seconds.").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }.padding(10)
                }
                HStack {
                    if model.project.support.missing.isEmpty { Label("Support files selected",systemImage:"checkmark.circle").foregroundColor(.green) }
                    else { Button("Finish setup (\(model.project.support.missing.count) items)") { model.page="Setup" } }
                    Spacer()
                    Button("Add to queue") { model.enqueue(start:false) }.disabled(model.inspecting || model.working)
                    Button("Build package") { model.enqueue(start:true) }.buttonStyle(.borderedProminent).disabled(model.inspecting || model.working).keyboardShortcut(.return, modifiers: [.command])
                }
                Text("Local verification checks file integrity. Installation, launch, saving and disc switching still require testing on a compatible modified PS3. No game images or licensing files are bundled.").font(.caption).foregroundColor(.secondary)
            }.textFieldStyle(.roundedBorder).padding(28)
        }.onDisappear { model.persist() }
        .sheet(isPresented:Binding(get:{model.configDisc != nil},set:{if !$0 {model.dismissConfigSheet()}})) {
            VStack(alignment:.leading,spacing:16) {
                Text("Matching CONFIG files").font(.title2.bold())
                Text("Matches use the disc ID. Review the source and version; a filename match is not proof of compatibility.").foregroundColor(.secondary)
                if model.configCandidates.isEmpty { Text("No matching unencrypted CONFIG files were found in this folder.") }
                ScrollView {
                    ForEach(model.configCandidates) { candidate in
                        GroupBox {
                            VStack(alignment:.leading,spacing:8) {
                                HStack { Text(candidate.relativePath).font(.headline);Spacer();Button("Use this CONFIG") {model.applyConfig(candidate)} }
                                Text(candidate.sha256).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
                                HStack(spacing:12) {
                                    if let bytes = candidate.byteCount { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption).foregroundColor(.secondary) }
                                    if let modified = candidate.modified { Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundColor(.secondary) }
                                }
                            }.padding(8)
                        }
                    }
                }
                HStack { Button("Change library…") {model.chooseConfigLibrary()};Spacer();Button("Close") {model.dismissConfigSheet()} }
            }.padding(24).frame(width:650,height:440)
        }
        .sheet(isPresented:Binding(get:{model.artworkDisc != nil},set:{if !$0 {model.dismissArtworkSheet()}})) {
            VStack(alignment:.leading,spacing:16) {
                Text("Matching artwork").font(.title2.bold())
                Text("Images in your chosen folder whose name begins with the disc's exact game ID. Nothing is applied until you choose it.").foregroundColor(.secondary)
                if model.findingArtwork { ProgressView().controlSize(.small) }
                else if model.artworkCandidates.isEmpty { Text("No matching images were found. Add PNG or JPEG files named with the game ID, or choose another folder.") }
                ScrollView {
                    ForEach(model.artworkCandidates) { candidate in
                        GroupBox {
                            HStack(spacing:12) {
                                if let image = ArtworkLibrary.thumbnail(of: candidate.url) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode:.fit)
                                        .frame(width:112,height:63).clipped().background(Color(NSColor.controlBackgroundColor)).cornerRadius(4)
                                }
                                VStack(alignment:.leading,spacing:4) {
                                    Text(candidate.relativePath).font(.headline).lineLimit(1)
                                    Text(candidate.dimensions).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Use as icon") { model.applyArtwork(candidate, asBackground:false) }
                                Button("Use as background") { model.applyArtwork(candidate, asBackground:true) }
                            }.padding(6)
                        }
                    }
                }
                HStack {
                    Button(model.artworkLibrary == nil ? "Choose folder…" : "Change folder…") { model.chooseArtworkLibrary() }
                    Spacer()
                    Button("Close") { model.dismissArtworkSheet() }
                }
            }.padding(24).frame(width:680,height:460)
        }
    }
    private func artworkButton(_ title: String,url: Binding<URL?>) -> some View {
        VStack(spacing:8) {
            Group {
                if let location=url.wrappedValue, let image=NSImage(contentsOf:location) { Image(nsImage:image).resizable().aspectRatio(contentMode:model.project.cropArtwork ? .fill : .fit) }
                else { Image(systemName:"photo").font(.largeTitle).foregroundColor(.secondary) }
            }.frame(width:130,height:74).clipped().background(Color(NSColor.controlBackgroundColor)).cornerRadius(6)
            Button("\(title)…") { url.wrappedValue=model.chooseFile("Choose a PNG or JPEG \(title.lowercased()) image.") }
            if url.wrappedValue != nil { Button("Clear") { url.wrappedValue=nil }.font(.caption) }
        }
    }
}

struct QueueView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("Build queue").font(.largeTitle.bold())
                Text("One job at a time keeps memory and disk usage predictable. A retry restarts the job but reuses already-verified encrypted stages when every input (source bytes, support files, content ID, settings and helper) is unchanged.").foregroundColor(.secondary)
                HStack {
                    Button("Export diagnostics…") { model.exportDiagnostics() }
                    Button("Start queue") { model.start() }.disabled(model.busy || !model.jobs.contains(where:{$0.status=="Waiting"})).keyboardShortcut("r", modifiers: [.command])
                    if model.busy { Button("Cancel current build") { model.cancel() }.keyboardShortcut(".", modifiers: [.command]); Button("Pause after this build") { model.runQueue=false } }
                    Spacer()
                    Button("Review interrupted work…") { model.scanAbandoned() }.disabled(model.busy)
                }
                HStack(spacing:12) {
                    Text(model.cacheBytes == nil
                         ? "Verified stage cache: not measured"
                         : "Verified stage cache: \(ByteCountFormatter.string(fromByteCount: Int64(model.cacheBytes ?? 0), countStyle: .file))").font(.caption).foregroundColor(.secondary)
                    Button("Measure") { model.refreshCacheInfo() }.controlSize(.small).disabled(model.busy)
                    Button("Clear stage cache") { model.clearStageCache() }.controlSize(.small).disabled(model.busy || (model.cacheBytes ?? 0) == 0)
                }
                Text("Measuring or clearing the cache reads only your known package folders and may prompt for access. Nothing is uploaded.").font(.caption2).foregroundColor(.secondary)
                if model.jobs.isEmpty { Text("Add a project to start your queue.").foregroundColor(.secondary).padding(.vertical,30) }
                Text("A forced quit can leave an isolated workspace behind; it never replaces a finished package. Use Review interrupted work to inspect and remove leftovers explicitly.").font(.caption).foregroundColor(.secondary)
                ForEach(model.jobs) { job in
                    GroupBox {
                        VStack(alignment:.leading,spacing:10) {
                            HStack { Text(job.project.title).font(.headline); Spacer(); Text(job.status).foregroundColor(job.status.hasPrefix("Locally verified") ? .green : .secondary) }
                            Text(job.project.output?.path ?? "").font(.caption).textSelection(.enabled)
                            if job.id==model.active { ProgressView(value:model.fraction); Text(model.stage).font(.caption) }
                            if job.id==model.busyJob {
                                ProgressView(value:model.fraction); Text(model.stage).font(.caption)
                                Button("Cancel check") { model.cancelUtilityOperation() }.font(.caption)
                            }
                            if !job.detail.isEmpty { Text(job.detail).font(.callout).textSelection(.enabled) }
                            HStack {
                                if job.status.hasPrefix("Locally verified"), let output=job.project.output { Button("Show package") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                                if let report=job.report { Button("Show report") { NSWorkspace.shared.activateFileViewerSelecting([report]) } }
                                if let output=job.project.output, FileManager.default.fileExists(atPath: output.path),
                                   ["Failed","Cancelled","Interrupted"].contains(job.status) {
                                    Button(model.busyJob==job.id ? "Checking…" : "Check published package") { model.verifyPublished(job.id) }
                                        .disabled(model.busyJob != nil && model.busyJob != job.id)
                                }
                                if ["Failed","Cancelled","Interrupted"].contains(job.status) { Button("Retry") { model.retry(job.id) }.disabled(model.busyJob == job.id) }
                                if job.id != model.active { Button("Edit a copy") { model.editCopy(job) }.disabled(model.busyJob == job.id); Spacer(); Button("Remove from queue") { model.remove(job.id) }.disabled(model.busyJob == job.id) }
                            }
                        }.padding(12)
                    }
                }
            }.padding(28)
        }.sheet(isPresented:$model.showingCleanup) {
            VStack(alignment:.leading,spacing:16) {
                Text("Interrupted work").font(.title2.bold())
                Text("Only entries this app can prove it created are removable, and removal moves them to Trash. Anything that merely resembles app naming is shown for manual review and is never deleted here.").foregroundColor(.secondary)
                if model.scanningAbandoned { ProgressView().controlSize(.small) }
                else if model.abandoned.isEmpty { Text("Nothing to review.") }
                ScrollView {
                    ForEach(model.abandoned) { entry in
                        GroupBox {
                            VStack(alignment:.leading,spacing:6) {
                                HStack {
                                    Text(entry.url.lastPathComponent).font(.headline).lineLimit(1)
                                    Spacer()
                                    if entry.isRemovable {
                                        Button("Move to Trash") { model.removeAbandoned(entry) }.disabled(model.busy)
                                    } else {
                                        Label("Review manually", systemImage:"exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                                    }
                                }
                                Text(entry.kind).font(.caption).foregroundColor(.secondary)
                                Text(entry.detail).font(.caption).foregroundColor(.secondary)
                                Text("\(entry.url.deletingLastPathComponent().path) • \(ByteCountFormatter.string(fromByteCount:Int64(entry.bytes),countStyle:.file))").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }.font(.caption)
                            }.padding(8)
                        }
                    }
                }
                HStack {
                    Button("Check another folder…") { model.scanCustomFolder() }.disabled(model.busy || model.scanningAbandoned)
                    Spacer()
                    Button("Close") { model.showingCleanup=false }
                }
            }.padding(24).frame(width:700,height:480)
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("Support files").font(.largeTitle.bold())
                Text("Select a matching set from your existing PS2 Classics workflow. These files stay on your Mac; projects store their locations.").foregroundColor(.secondary)
                Button("Import support folder…") { model.importSupport() }
                if let folder = model.project.support.sourceFolder {
                    Text("Imported as one set from \(folder.lastPathComponent). Files picked individually afterwards are marked as a mixed selection.").font(.caption).foregroundColor(.secondary)
                } else if model.project.support.mixedSelection {
                    Text("Mixed selection: files were picked individually. Confirm they belong to the same content ID.").font(.caption).foregroundColor(.orange)
                }
                ForEach(model.project.support.diagnostics(), id:\.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundColor(.orange).font(.callout)
                }
                supportRow("Binary klicensee",url:$model.project.support.key,detail:"Exactly 16 bytes; this is different from a RAP or RIF.")
                supportRow("Matching RAP",url:$model.project.support.rap,detail:"Exactly 16 bytes. Used for the EDAT title record.")
                supportRow("PS3LOGO.DAT",url:$model.project.support.logo,detail:"Your existing PS2 Classics logo resource.")
                supportRow("Blank memory card",url:$model.project.support.card,detail:"A formatted SCEVMC0.VMC, with ECC. Use a blank template rather than your personal saves.")
                TextField("Matching 36-character content ID",text:$model.project.support.contentID).textFieldStyle(.roundedBorder)
                Text("Folder import looks for klic.bin, one .rap file, PS3LOGO.DAT and SCEVMC0.VMC. The content ID comes from the RAP filename or content-id.txt. If there are several RAP files, select the correct one explicitly.").font(.callout).foregroundColor(.secondary)
                GroupBox {
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Text("Saved support profiles").font(.headline); Spacer(); Button("Save current as profile…") { model.namingProfile = true }.disabled(model.project.support.missing.count > 0) }
                        if model.supportProfiles.isEmpty {
                            Text("No saved profiles. A profile stores file locations and the content ID, never key bytes.").font(.caption).foregroundColor(.secondary)
                        }
                        ForEach(model.supportProfiles) { profile in
                            HStack {
                                VStack(alignment:.leading,spacing:2) {
                                    Text(profile.name).font(.body)
                                    Text("\(profile.importedTogether ? "Imported as one set" : "Files selected individually") • \(profile.contentID)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Use") { model.applySupportProfile(profile) }
                                Button("Delete") { model.deleteSupportProfile(profile) }
                            }.padding(6)
                        }
                        Text("Applying a profile checks that each file is present and the expected size. It does not prove the assets match your console.").font(.caption).foregroundColor(.secondary)
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                }
                GroupBox {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text("CONFIG library").font(.headline); Spacer()
                            Button("Choose folder…") {model.chooseConfigLibrary()}
                            if model.configLibrary != nil {
                                Button("Refresh") {model.refreshConfigLibraryStatus()}
                                Button("Reveal") {model.revealConfigLibrary()}
                                Button("Clear library") {model.clearConfigLibrary()}
                            }
                        }
                        Text(model.configLibrary?.path ?? "No local library selected").font(.caption).textSelection(.enabled)
                        switch model.configLibraryStatus {
                        case .missing, .notADirectory, .unreadable:
                            Label(ConfigLibrary.describe(model.configLibraryStatus, folder: model.configLibrary), systemImage:"exclamationmark.triangle").foregroundColor(.orange).font(.callout)
                        case .available:
                            Label("Library folder available.", systemImage:"checkmark.circle").foregroundColor(.green).font(.caption)
                        case .notSelected:
                            EmptyView()
                        }
                        Text("Use Find matches beside a disc to review matching variants by exact game ID. A selected CONFIG is read strictly at build time; files are never replaced automatically.").font(.caption).foregroundColor(.secondary)
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                }
                Divider()
                Text("Before sharing a build").font(.headline)
                Text("This beta creates debug packages for modified-console workflows. Verify installation, launch and saving on your PS3. Test the same app on the Intel Monterey MacBook Air and the M4 Mac mini. Local checks and Universal binaries do not replace those hardware tests.").foregroundColor(.secondary)
                Button("Export diagnostics…") { model.exportDiagnostics() }
                Button("Back to project") { model.persist(); model.page="Build a package" }
            }.padding(28)
        }.onDisappear { model.persist() }
        .sheet(isPresented:$model.namingProfile) {
            VStack(alignment:.leading,spacing:16) {
                Text("Save support profile").font(.title2.bold())
                Text("Give this support set a name. Only file locations and the content ID are stored; key bytes are never written.").foregroundColor(.secondary)
                TextField("Profile name", text:$model.profileName).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { model.namingProfile=false; model.profileName="" }; Button("Save") { model.saveSupportProfile() }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width:460)
        }
    }
    private func supportRow(_ title:String,url:Binding<URL?>,detail:String) -> some View {
        GroupBox {
            VStack(alignment:.leading,spacing:8) {
                HStack { Text(title).font(.headline); Spacer(); Button("Choose…") { url.wrappedValue=model.chooseFile(detail); model.project.support.sourceFolder=nil; model.persist() } }
                Text(url.wrappedValue?.path ?? "Not selected").font(.caption).textSelection(.enabled)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

struct CardView: View {
    @State private var encrypt = true
    @State private var source: URL?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var message = ""
    @State private var output: URL?
    @State private var runner: ConversionRunner?
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            Text("Memory cards").font(.largeTitle.bold())
            Text("Convert between unencrypted VMC and CEX VME files. A new copy is created and checked by reversing the conversion; the original is preserved.").foregroundColor(.secondary)
            Picker("Operation",selection:$encrypt) { Text("VMC → VME").tag(true); Text("VME → VMC").tag(false) }.pickerStyle(.segmented).disabled(busy)
            Button("Choose memory card…") { source=StudioModel.shared.chooseFile("Choose an 8, 16, 32 or 64 MiB PS2 card with ECC."); output=nil; message="" }.disabled(busy)
            Text(source?.path ?? "No card selected").font(.callout).textSelection(.enabled)
            HStack {
                Button("Create verified backup…") { backupCard() }.disabled(busy || source == nil)
                Button("Restore backup to new file…") { restoreCard() }.disabled(busy)
            }
            if busy { ProgressView(value:progress); Button("Cancel") { runner?.cancel() } }
            else { Button("Convert and verify…",action:convert).disabled(source==nil) }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
            if let output=output { Button("Show result") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
            Text("CEX cards only. This checks conversion integrity, not the internal health of every save or per-console protected card formats.").font(.caption).foregroundColor(.secondary)
            Spacer()
        }.padding(30)
    }
    private func backupCard() {
        guard let source else { return }
        let panel=NSSavePanel();panel.nameFieldStringValue=source.deletingPathExtension().lastPathComponent+".ps2cardbackup"
        panel.message="Create a new verified backup. Existing backups are never replaced."
        guard panel.runModal() == .OK, let target=panel.url else { return }
        cardBackupOperation(source:source,target:target,restore:false)
    }
    private func restoreCard() {
        let picker=NSOpenPanel();picker.canChooseDirectories=true;picker.canChooseFiles=false
        picker.message="Choose a .ps2cardbackup folder. Restoration creates a new file."
        guard picker.runModal() == .OK, let backup=picker.url else{return}
        do {
            let record=try MemoryCardBackup.record(in:backup)
            let panel=NSSavePanel();panel.nameFieldStringValue="Restored."+URL(fileURLWithPath:record.file).pathExtension
            guard panel.runModal() == .OK,let target=panel.url else{return}
            cardBackupOperation(source:backup,target:target,restore:true)
        } catch {message=error.localizedDescription}
    }
    private func cardBackupOperation(source:URL,target:URL,restore:Bool) {
        let session=ConversionRunner()
        guard let owned=StudioModel.shared.beginUtility(.convert,cancel:{session.cancel()}) else {message="Another operation is already running.";return}
        runner=session;busy=true;output=nil;message="";progress=0
        let helper=StudioModel.shared.helperURL
        Task {
            do {
                try await Task.detached {
                    let update: @Sendable (ConversionProgress)->Void = { value in Task { @MainActor in guard busy, runner === session else{return};progress=value.fraction } }
                    if restore { try MemoryCardBackup.restore(backup:source,destination:target,helper:helper,runner:session,progress:update) }
                    else { try MemoryCardBackup.create(source:source,destination:target,helper:helper,runner:session,progress:update) }
                }.value
                output=target;message=restore ? "Restored copy verified. Existing cards were preserved." : "Backup verified byte-for-byte. Individual saved-game health is not checked."
            } catch {message=error.localizedDescription}
            busy=false;runner=nil;StudioModel.shared.endUtility(owned)
        }
    }
    private func convert() {
        guard let source=source else { return }
        let panel=NSSavePanel(); panel.nameFieldStringValue=encrypt ? "Converted.VME" : "Converted.VMC"
        guard panel.runModal() == .OK, let target=panel.url else { return }
        let session=ConversionRunner()
        guard let owned=StudioModel.shared.beginUtility(.convert, cancel:{session.cancel()}) else { message="Another operation is already running."; return }
        runner=session; busy=true; output=nil; message=""; progress=0
        let command=encrypt ? "vmc-encrypt" : "vmc-decrypt"
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ps2-convert")
        Task {
            do {
                try await Task.detached {
                    try session.run(arguments:[command,source.path,target.path],helper:helper) { update in Task { @MainActor in guard busy, runner === session else{return};progress=update.fraction } }
                }.value
                output=target; message="Converted card created; round-trip verification passed."
            } catch { message=error.localizedDescription }
            busy=false; runner=nil; StudioModel.shared.endUtility(owned)
        }
    }
}
