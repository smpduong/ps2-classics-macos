// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct PackageBuildResult: Sendable {
    public let output: URL
    public let report: URL?
    public let message: String
}

public final class PackageBuilder: @unchecked Sendable {
    public static let version = "1.0.0"
    public static let cacheBudget: UInt64 = 16 * 1024 * 1024 * 1024
    public static let cacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Test-only deterministic barrier, invoked synchronously in-flow just
    /// before each disc's unchanged-source check. Always nil in production, so
    /// normal builds are unaffected. Lets regressions mutate an input at an
    /// exact point instead of racing progress callbacks.
    public var testMutationHook: ((String) -> Void)? = nil
    private let runner = ConversionRunner()
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock(); runner.cancel() }
    private func check() throws {
        lock.lock(); let stop = cancelled; lock.unlock()
        if stop { throw ConversionFailure(message: "Cancelled. Originals are unchanged.") }
    }
    public func build(_ project: GameProject, helper: URL,
                      jobID: UUID? = nil,
                      onAttemptPrepared: (@Sendable (BuildAttemptIdentity) throws -> Void)? = nil,
                      progress: @escaping @Sendable (ConversionProgress) -> Void) throws -> PackageBuildResult {
        try project.validate(); try check()
        let fm = FileManager.default
        let output = project.output!
        let parent = output.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw ConversionFailure(message: "The destination folder is missing or disconnected: \(parent.path). Reconnect it or choose a new destination.")
        }
        guard fm.isWritableFile(atPath: parent.path) else {
            throw ConversionFailure(message: "The destination folder is read-only: \(parent.lastPathComponent). Choose a writable destination.")
        }
        try DestinationCheck.probeWritable(folder: parent)
        func requireFile(_ url: URL?, label: String) throws -> URL {
            guard let url = url, url.isFileURL, fm.fileExists(atPath: url.path) else {
                throw ConversionFailure(message: "\(label) is missing or was moved: \(url?.lastPathComponent ?? "not selected"). Re-select it before building.")
            }
            return url
        }
        _ = try requireFile(project.support.key, label: "The klicensee file")
        _ = try requireFile(project.support.rap, label: "The RAP file")
        _ = try requireFile(project.support.logo, label: "PS3LOGO.DAT")
        _ = try requireFile(project.support.card, label: "The blank memory card")
        for disc in project.discs where disc.source.isFileURL {
            let resolved = (try? DiscInput.resolve(disc.source)) ?? disc.source
            guard fm.fileExists(atPath: resolved.path) else {
                throw ConversionFailure(message: "A disc image is missing or was moved: \(disc.source.lastPathComponent). Re-add it before building.")
            }
        }
        let workspace = output.deletingLastPathComponent().appendingPathComponent(".ps2-build-"+UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        // The queue-owned job identity travels with the build into workspace
        // claims, cache records and the completion report, so recovery can
        // prove a published package belongs to the queued job that ordered it.
        let jobID = jobID ?? UUID()
        let claim = WorkspaceClaim(directory: workspace, kind: "build", jobID: jobID,
                                   output: output, source: project.discs.first?.source,
                                   profile: nil, disc: nil)
        defer {
            claim?.release()
            try? fm.removeItem(at: workspace)
        }
        let root = workspace.appendingPathComponent("package")
        let usr = root.appendingPathComponent("USRDIR")
        let saves = usr.appendingPathComponent("SAVEDATA")
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        func write(_ data: Data, _ url: URL) throws { try check(); try data.write(to:url,options:.withoutOverwriting) }
        func snapshot(_ source: URL, _ name: String, _ limit: Int) throws -> URL {
            let target = workspace.appendingPathComponent(name)
            try write(FileDigest.small(source, maximum:limit),target); return target
        }
        progress(ConversionProgress(stage:"Checking support files",fraction:0))
        let key = try snapshot(project.support.key!,"klicensee.bin",16)
        let rap = try snapshot(project.support.rap!,"license.rap",16)
        guard (try Data(contentsOf:key)).count == 16, (try Data(contentsOf:rap)).count == 16 else { throw ConversionFailure(message:"Both licensing files must contain exactly 16 bytes.") }
        guard !["rap","rif"].contains(project.support.key!.pathExtension.lowercased()) else { throw ConversionFailure(message:"A RAP/RIF file is not a klicensee. Select the matching binary key.") }
        let card = try snapshot(project.support.card!,"blank.vmc",70*1024*1024)
        let logoBytes = try FileDigest.small(project.support.logo!,maximum:1024*1024)
        try write(logoBytes,root.appendingPathComponent("PS3LOGO.DAT"))
        try write(PackageMetadata.sfo(title:project.title,titleID:project.titleID),root.appendingPathComponent("PARAM.SFO"))
        let iconPNG = try PackageMetadata.artwork(source:project.icon,width:320,height:176,crop:project.cropArtwork,title:project.title)
        try write(iconPNG,root.appendingPathComponent("ICON0.PNG"))
        let backgroundPNG = try PackageMetadata.artwork(source:project.background,width:1920,height:1080,crop:project.cropArtwork,title:project.title)
        try write(backgroundPNG,root.appendingPathComponent("PIC1.PNG"))
        var soundHash = ""
        if let sound = project.sound {
            let bytes = try FileDigest.small(sound,maximum:2_500_000)
            try PackageMetadata.validateSound(bytes)
            try write(bytes,root.appendingPathComponent("SND0.AT3"))
            soundHash = FileDigest.sha256(data: bytes)
        }
        // Fingerprint the exact immutable snapshot bytes — never a second read
        // of the original paths, so a file swapped mid-build cannot rebind the
        // cache identity away from the bytes actually used for encryption.
        let keyHash = FileDigest.sha256(data: try Data(contentsOf: key))
        let rapHash = FileDigest.sha256(data: try Data(contentsOf: rap))
        let cardHash = try FileDigest.sha256(card)
        let logoHash = FileDigest.sha256(data: logoBytes)
        var assets = ["icon": FileDigest.sha256(data: iconPNG),
                      "background": FileDigest.sha256(data: backgroundPNG),
                      "sound": soundHash]
        if let manual = project.manual {
            let hashes = try SoftwareManual.build(source: manual, directory: root.appendingPathComponent("USRDIR/CONTENT"),
                cancelled: { try self.runner.checkCancellation() }, progress: progress)
            assets.merge(hashes) { _, new in new }
        }
        let support = ["key": keyHash, "rap": rapHash, "logo": logoHash, "card": cardHash]
        var sources = [URL](); var total: UInt64 = 0; var expansion: UInt64 = 0
        var payloads = [UInt64]()
        progress(ConversionProgress(stage:"Fingerprinting sources",fraction:0))
        var stageKeys = [DiscStageKey]()
        var configBytes = [Data?]()
        for (i,disc) in project.discs.enumerated() {
            try check()
            let source = try DiscInput.resolve(disc.source)
            // A parent selection only makes sense on a CHD source, and the
            // parent itself must be a directly referenced CHD file.
            let parent: URL?
            if let selected = disc.chdParent {
                guard disc.source.pathExtension.lowercased() == "chd" else {
                    throw ConversionFailure(message:"Disc \(i+1) names a parent CHD but is not a CHD image. Clear the parent selection.")
                }
                guard selected.pathExtension.lowercased() == "chd",
                      FileManager.default.fileExists(atPath: selected.path) else {
                    throw ConversionFailure(message:"Disc \(i+1) parent CHD is missing or is not a CHD file (\(selected.lastPathComponent)). Choose the exact parent CHD before building.")
                }
                parent = selected
            } else { parent = nil }
            let inspection = try DiscInspector.inspect(source, parent: parent, helper: helper, runner: runner)
            guard inspection.isSupported else {
                if inspection.requiresParent {
                    throw ConversionFailure(message:"Disc \(i+1) (\(source.lastPathComponent)) stores differences against a parent CHD. Choose the exact parent file beside the disc before building.")
                }
                throw ConversionFailure(message:"Unsupported disc image: \(disc.source.lastPathComponent)")
            }
            if let detected = inspection.gameID, detected != disc.gameID {
                throw ConversionFailure(message:"\(disc.source.lastPathComponent) identifies as \(detected), not \(disc.gameID). Correct its disc ID before building.")
            }
            // A selected CONFIG is mandatory data, never an optional hint: a
            // missing, unreadable, empty or oversized file fails the build here,
            // before any expensive conversion. Only a cleared selection omits it.
            var rawConfig: Data?
            var configHash: String?
            if let configURL = disc.config {
                let bytes: Data
                do {
                    bytes = try FileDigest.small(configURL, maximum: 1024*1024)
                } catch {
                    throw ConversionFailure(message: "Disc \(i+1) CONFIG could not be read (\(configURL.lastPathComponent)): \(error.localizedDescription). Clear the selection to build without a CONFIG, or choose a readable file under 1 MiB.")
                }
                let hash = FileDigest.sha256(data: bytes)
                guard hash == disc.configHash else { throw ConversionFailure(message:"CONFIG changed since it was selected for disc \(i+1). Select it again to accept the new version.") }
                rawConfig = bytes
                configHash = hash
            }
            configBytes.append(rawConfig)
            // The parent's exact bytes join the stage identity, so swapping
            // the parent file invalidates every dependent stage and attempt.
            let parentSHA256 = try parent.map { try FileDigest.sha256($0, cancelled: check) }
            stageKeys.append(DiscStageKey(index: i, sourcePath: source.path,
                                          sourceSHA256: try FileDigest.sha256(source, cancelled: check),
                                          gameID: disc.gameID, configSHA256: configHash,
                                          parentSHA256: parentSHA256, parentPath: parent?.path))
            sources.append(source); total += inspection.expandedByteCount ?? inspection.byteCount
            expansion += inspection.expandedByteCount ?? 0
            payloads.append(inspection.expandedByteCount ?? inspection.byteCount)
        }
        let attributes = try fm.attributesOfFileSystem(forPath:workspace.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        let needed = total*2 + expansion + total/100 + 256*1024*1024
        // Per-file filesystem limits must cover encrypted images and the final
        // package including their overhead, not just the source bytes.
        let limits = try DestinationCheck.validate(path: output,
                                                   requiredBytes: BuildEstimates.largestSingleFile(imageSizes: payloads),
                                                   folder: parent)
        guard available > needed else {
            throw ConversionFailure(message:"This build needs about \(ByteCountFormatter.string(fromByteCount:Int64(needed),countStyle:.file)) free at the package destination for temporary files and the finished package, but only \(ByteCountFormatter.string(fromByteCount:Int64(available),countStyle:.file)) is available\(limits.fileSystem == "msdos" ? " on this FAT volume" : "").")
        }
        // A verified stage cache lets a retry or rebuild reuse encrypted images.
        // The fingerprint binds the immutable snapshot bytes hashed above.
        let helperHash = (try? FileDigest.sha256(helper)) ?? ""
        let fingerprint = JobFingerprint(appVersion: PackageBuilder.version, helperSHA256: helperHash,
                                         title: project.title, titleID: project.titleID,
                                         contentID: project.support.contentID, cropArtwork: project.cropArtwork,
                                         assets: assets, support: support, discs: stageKeys)
        // Immutable identity of this attempt, built from the exact snapshot
        // hashes above (never a second read of a mutable path). It is handed to
        // the queue-owned side and persisted before any encryption begins, so a
        // crash still leaves recovery something durable to compare against.
        let attempt = BuildAttemptIdentity(
            attemptID: UUID().uuidString,
            jobID: jobID.uuidString,
            buildFingerprint: fingerprint.digest,
            title: project.title, titleID: project.titleID,
            contentID: project.support.contentID,
            cropArtwork: project.cropArtwork,
            discs: zip(project.discs, stageKeys).map { disc, key in
                QueuedDiscIdentity(index: key.index, gameID: disc.gameID,
                                   source: disc.source.path,
                                   sourceSHA256: key.sourceSHA256,
                                   configHash: key.configSHA256,
                                   parentSource: key.parentPath,
                                   parentSHA256: key.parentSHA256)
            },
            supportHashes: support, assetHashes: assets)
        try onAttemptPrepared?(attempt)
        var cache: StageCache?
        var cacheClaim: CacheWriteClaim?
        var cacheNote = ""
        do {
            let opened = try StageCache.open(destinationFolder: parent, fingerprint: fingerprint)
            cacheClaim = try opened.acquire(jobID: jobID)
            cache = opened
        } catch {
            cacheNote = "Stage cache disabled for this build: \(error.localizedDescription)"
        }
        defer { cacheClaim?.release() }
        let cacheEnabled = cache != nil && cacheClaim != nil
        func binding(for i: Int, profile: String) -> StageBinding {
            StageBinding(disc: i, profile: profile, sourceSHA256: stageKeys[i].sourceSHA256,
                         configSHA256: stageKeys[i].configSHA256, keySHA256: keyHash, rapSHA256: rapHash,
                         contentID: project.support.contentID, helperSHA256: helperHash,
                         parentSHA256: stageKeys[i].parentSHA256)
        }
        var reusedStages = 0
        let jobEnvironment = ["PS2_WORKSPACE": workspace.path, "PS2_JOB_ID": jobID.uuidString]
        func run(_ args: [String], label: String) throws {
            try check()
            try runner.run(arguments:args,helper:helper,environment:jobEnvironment) { update in
                progress(ConversionProgress(stage:label+" · "+update.stage,fraction:update.fraction))
            }
        }
        try run(["vmc-encrypt",card.path,saves.appendingPathComponent("SCEVMC0.VME").path],label:"Memory card")
        try fm.copyItem(at:saves.appendingPathComponent("SCEVMC0.VME"),to:saves.appendingPathComponent("SCEVMC1.VME"))
        try run(["edat",project.titleID,usr.appendingPathComponent("ISO.BIN.EDAT").path,key.path,rap.path,project.support.contentID],label:"Title record")
        if sources.count>1 { try write(Data([UInt8(sources.count),0]),usr.appendingPathComponent("DISC.IDX")) }
        var discReports = [[String:Any]]()
        for (i,disc) in project.discs.enumerated() {
            try check()
            let before = stageKeys[i].sourceSHA256
            let name = "ISO.BIN.ENC"+(i==0 ? "" : String(i+1))
            var report: [String:Any] = ["source":disc.source.path,"gameID":disc.gameID,"disc":i+1,"index":i,"sha256":before,"sourceSHA256":before]
            if let parent = disc.chdParent {
                report["parentSource"] = parent.path
                report["parentSHA256"] = stageKeys[i].parentSHA256 ?? ""
            }
            // The exact CONFIG bytes selected earlier; never re-read the original.
            let config = configBytes[i]
            if let bytes = config {
                if bytes.prefix(4) == Data([80,83,50,0]) || bytes.prefix(4) == Data([78,80,68,0]) {
                    throw ConversionFailure(message:"The selected CONFIG is already encrypted. Choose its unencrypted source.")
                }
                let hash = FileDigest.sha256(data:bytes)
                guard hash == disc.configHash else { throw ConversionFailure(message:"CONFIG changed since it was selected for disc \(i+1). Select it again to accept the new version.") }
                report["configSHA256"] = hash; report["configSource"] = disc.configSource
            }
            if let data = try PackageMetadata.config(config,gameID:disc.gameID,count:sources.count,discIndex:i) {
                let plain = workspace.appendingPathComponent("config-\(i)")
                try write(data,plain)
                let configName = "CONFIG"+(i==0 ? "" : String(i+1))
                try run(["encrypt-raw",plain.path,usr.appendingPathComponent(configName).path,key.path,project.support.contentID,String(i+1),configName],label:"CONFIG \(i+1)")
            }
            let imageTarget = usr.appendingPathComponent(name)
            let required = binding(for: i, profile: name)
            var imageSHA = ""
            var reused = false
            if let cache = cache, let claim = cacheClaim,
               let reusable = cache.reusableImage(name, binding: required, claim: claim, isCancelled: { (try? self.check()) == nil }) {
                progress(ConversionProgress(stage:"Reusing verified image \(i+1)",fraction:0))
                try? fm.removeItem(at: imageTarget)
                do { try fm.linkItem(at: reusable, to: imageTarget) }
                catch { try fm.copyItem(at: reusable, to: imageTarget) }
                reusedStages += 1
                report["reusedVerifiedStage"] = true
                reused = true
            } else {
                var image = sources[i]
                if image.pathExtension.lowercased()=="chd" {
                    let expanded=workspace.appendingPathComponent("disc-\(i).image")
                    var extract=["extract-chd",image.path,expanded.path]
                    if let parent = disc.chdParent { extract.append(parent.path) }
                    try run(extract,label:"Disc \(i+1)")
                    image=expanded
                }
                try run(["encrypt-iso",image.path,imageTarget.path,key.path,project.support.contentID,String(i+1),name],label:"Disc \(i+1) of \(sources.count)")
                if image != sources[i] { try fm.removeItem(at:image) }
            }
            // The same documented stability invariant governs fresh and reused
            // stages: re-hash the source and only claim unchanged when checked.
            // A parent CHD is re-hashed too: swapping it mid-build must fail
            // rather than silently expand against different bytes.
            testMutationHook?("checking-original-\(i)")
            progress(ConversionProgress(stage:"Checking original disc \(i+1)",fraction:0))
            guard try FileDigest.sha256(sources[i],cancelled:check)==before else { throw ConversionFailure(message:"An input changed during this build. Package was not published.") }
            if let parent = disc.chdParent, let expected = stageKeys[i].parentSHA256 {
                guard try FileDigest.sha256(parent,cancelled:check)==expected else { throw ConversionFailure(message:"The parent CHD changed during this build. Package was not published.") }
            }
            if reused {
                imageSHA = try FileDigest.sha256(imageTarget, cancelled: check)
                if let cache = cache, let claim = cacheClaim { try? cache.checkpoint(claim) }
            } else if let cache = cache, let claim = cacheClaim {
                // Checkpoint only after the final unchanged-source check passes.
                do { imageSHA = try cache.store(imageTarget, as: name, binding: required, claim: claim, cancelled: check) }
                catch { cacheNote = "A verified stage could not be cached: \(error.localizedDescription)" }
            } else {
                imageSHA = (try? FileDigest.sha256(imageTarget, cancelled: check)) ?? ""
            }
            report["imageSHA256"] = imageSHA
            report["originalUnchanged"] = true; discReports.append(report)
        }
        try run(["package",root.path,output.path,project.support.contentID],label:"Package")
        // The published package digest binds the recovery record to these bytes.
        let packageSHA256 = (try? FileDigest.sha256(output, cancelled: check)) ?? ""
        if let cache = cache, let claim = cacheClaim {
            try? cache.checkpoint(claim)
            cacheClaim?.release(); cacheClaim = nil
            StageCache.prune(in: parent, maxBytes: PackageBuilder.cacheBudget, maxAge: PackageBuilder.cacheMaxAge)
            _ = cache
        }
        var report: [String:Any] = ["appVersion":PackageBuilder.version,"title":project.title,"titleID":project.titleID,
            "contentID":project.support.contentID,
            "created":ISO8601DateFormatter().string(from:Date()),"locallyVerified":true,"consoleTested":false,
            "multiDiscExperimental":sources.count>1,"discs":discReports,
            "fingerprint":fingerprint.digest,"packageSHA256":packageSHA256,
            "attemptID":attempt.attemptID,"buildFingerprint":attempt.buildFingerprint,
            "cropArtwork":project.cropArtwork,"supportHashes":support,"assetHashes":assets,
            "jobID":jobID.uuidString,
            "supportPaths":["key":project.support.key?.standardizedFileURL.path ?? "",
                            "rap":project.support.rap?.standardizedFileURL.path ?? "",
                            "logo":project.support.logo?.standardizedFileURL.path ?? "",
                            "card":project.support.card?.standardizedFileURL.path ?? ""],
            "assetPaths":["icon":project.icon?.standardizedFileURL.path ?? "",
                          "background":project.background?.standardizedFileURL.path ?? "",
                          "sound":project.sound?.standardizedFileURL.path ?? ""],
            "reusedStages":reusedStages,"stageCacheUsed":cacheEnabled,
            "checks":["Image segment integrity and prepared-payload round trip","Original SHA-256 unchanged","Memory-card round trip","Package decrypted-payload read-back"]]
        if let manual = project.manual {
            var paths = report["assetPaths"] as! [String:String]
            paths["manual"] = manual.standardizedFileURL.path; report["assetPaths"] = paths
        }
        if !cacheNote.isEmpty { report["cacheNote"] = cacheNote }
        let reportURL = URL(fileURLWithPath:output.path+".report.json")
        do {
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.withoutOverwriting)
            return PackageBuildResult(output:output,report:reportURL,message:"Package created and locally verified. PS3 testing is still required.")
        } catch {
            return PackageBuildResult(output:output,report:nil,message:"Package created and locally verified. The separate report could not be saved: \(error.localizedDescription)")
        }
    }
}
