// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ConversionAction: String, CaseIterable, Sendable {
    case encrypt = "Encrypt image"
    case decrypt = "Decrypt image"
}

public struct ConversionRequest: Sendable {
    public let action: ConversionAction
    public let source: URL
    public let destination: URL
    public let keyFile: URL
    public let contentID: String
    public let discNumber: Int
    public let logicalName: String

    public init(action: ConversionAction, source: URL, destination: URL, keyFile: URL,
                contentID: String, discNumber: Int = 1, logicalName: String? = nil) {
        self.action = action; self.source = source; self.destination = destination
        self.keyFile = keyFile; self.contentID = contentID; self.discNumber = discNumber
        self.logicalName = logicalName ?? EncryptedProfile.forDisc(discNumber)
    }

    /// Helper argument vector, validated before any process starts.
    /// `source` overrides the request source when a CHD has been expanded first.
    public func arguments(source: URL? = nil) throws -> [String] {
        guard (1...9).contains(discNumber) else {
            throw ConversionFailure(message: "Disc number must be 1 through 9.")
        }
        guard EncryptedProfile.imageNames.contains(logicalName) else {
            throw ConversionFailure(message: "Unsupported image profile \(logicalName). Image tools uses ISO.BIN.ENC with an optional disc digit; CONFIG profiles belong to the package workflow.")
        }
        var arguments = [action == .encrypt ? "encrypt-iso" : "decrypt",
                         (source ?? self.source).path, destination.path, keyFile.path]
        if action == .encrypt {
            guard contentID.range(of: #"^[A-Z0-9]{6}-[A-Z0-9]{9}_[A-Z0-9]{2}-[A-Z0-9]{16}$"#, options: .regularExpression) != nil else {
                throw ConversionFailure(message: "Enter the 36-character content ID that matches your support files.")
            }
            arguments.append(contentID)
        }
        arguments.append(String(discNumber))
        arguments.append(logicalName)
        return arguments
    }
}

/// Logical filenames seal encrypted payloads. Disc 1 uses the base profile;
/// later discs use numbered profiles (ISO.BIN.ENC2 … ISO.BIN.ENC9).
public enum EncryptedProfile: Sendable {
    public static let imageNames = ["ISO.BIN.ENC"] + (2...9).map { "ISO.BIN.ENC\($0)" }
    public static let configNames = ["CONFIG"] + (2...9).map { "CONFIG\($0)" }
    public static var allNames: [String] { imageNames + configNames }
    public static var imageOptions: [String] { imageNames }

    public static func forDisc(_ disc: Int) -> String {
        guard (2...9).contains(disc) else { return "ISO.BIN.ENC" }
        return "ISO.BIN.ENC\(disc)"
    }

    /// Case-sensitive, matching the helper's own exact allowlist.
    public static func isSupported(_ name: String) -> Bool {
        allNames.contains(name)
    }
    public static func isConfig(_ name: String) -> Bool { configNames.contains(name) }
    public static func isImage(_ name: String) -> Bool { imageNames.contains(name) }

    /// Disc number implied by an image profile, or nil for CONFIG profiles.
    public static func disc(forImage name: String) -> Int? {
        guard let index = imageNames.firstIndex(of: name) else { return nil }
        return index + 1
    }

    public struct Detection: Sendable {
        public let logicalName: String
        /// Present only when the whole file exactly matches the declared,
        /// bounded payload length. The size field is not authenticated.
        public let payloadBytes: UInt64?
        public let complete: Bool
    }
}

public struct ConversionProgress: Sendable {
    public let stage: String
    public let fraction: Double
}

public struct ConversionFailure: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One helper process per job. Filenames are passed as arguments, never shell text.
/// The helper owns exclusive output creation, source preservation and verification.
public final class ConversionRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}

    /// Allows multi-stage clients to honor cancellation after a helper exits
    /// and before publishing their independently validated output.
    public func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw ConversionFailure(message: "Cancelled. No output was published.") }
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process = process, process.isRunning { process.terminate() }
    }

    public func run(_ request: ConversionRequest, helper: URL,
                    progress: @escaping @Sendable (ConversionProgress) -> Void) throws {
        var source = request.source
        var workspace: URL?
        var claim: WorkspaceClaim?
        defer {
            claim?.release()
            if let workspace = workspace { try? FileManager.default.removeItem(at:workspace) }
        }
        if request.action == .encrypt && source.pathExtension.lowercased() == "chd" {
            let info = try CHDImporter.inspect(source,helper:helper,runner:self)
            let folder = request.destination.deletingLastPathComponent()
            let attrs = try FileManager.default.attributesOfFileSystem(forPath:folder.path)
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            guard free > (info.expandedByteCount ?? 0)*2 + 256*1024*1024 else {
                throw ConversionFailure(message:"Not enough free space at the destination to expand and encrypt this CHD.")
            }
            let temp = folder.appendingPathComponent(".ps2-image-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            workspace = temp
            claim = WorkspaceClaim(directory: temp, kind: "image", jobID: UUID(),
                                   output: request.destination, source: request.source,
                                   profile: request.logicalName, disc: request.discNumber)
            source = temp.appendingPathComponent("expanded.image")
            try run(arguments:["extract-chd",request.source.path,source.path],helper:helper,
                    environment: environment(for: claim), progress:progress)
        }
        let arguments = try request.arguments(source: source)
        try run(arguments: arguments, helper: helper, environment: environment(for: claim), progress: progress)
    }

    private func environment(for claim: WorkspaceClaim?) -> [String: String] {
        guard let claim = claim else { return [:] }
        return ["PS2_WORKSPACE": claim.directory.path, "PS2_JOB_ID": claim.manifestJobID]
    }

    /// Read-only check of an encrypted image: header profile, segment hashes
    /// and disc numbering are verified without writing any output file.
    public func verify(source: URL, keyFile: URL, discNumber: Int, logicalName: String,
                       helper: URL, progress: @escaping @Sendable (ConversionProgress) -> Void) throws {
        guard (1...9).contains(discNumber), EncryptedProfile.isImage(logicalName) else {
            throw ConversionFailure(message: "Choose a disc number 1–9 and a supported image profile.")
        }
        try run(arguments: ["verify", source.path, keyFile.path, String(discNumber), logicalName],
                helper: helper, progress: progress)
    }

    /// Runs a helper command that prints a single structured result and returns
    /// its combined output. The process is registered for cancellation exactly
    /// like a conversion, so Cancel terminates an in-flight inspection instead
    /// of leaving it running. A mid-run cancellation is surfaced as a
    /// cancellation, never as a malformed-result decode error.
    public func capture(arguments: [String], helper: URL,
                        environment: [String: String] = [:], input: Data? = nil,
                        maximumOutput: Int = 8 * 1024 * 1024,
                        consume: ((Data) throws -> Void)? = nil) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: helper.path), maximumOutput >= 0,
              (input?.count ?? 0) <= 4096 else {
            throw ConversionFailure(message: "Invalid helper or bounded process request.")
        }
        let task = Process(); task.executableURL = helper; task.arguments = arguments
        if !environment.isEmpty { task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let pipe = Pipe(), stdin = Pipe()
        task.standardOutput = pipe; task.standardError = pipe
        task.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        // A short input fits in the pipe before the child starts; no secrets on
        // disk, in arguments or in the environment, and no broken-pipe race.
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        lock.lock()
        if cancelled { lock.unlock(); throw ConversionFailure(message: "Cancelled before the operation started.") }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); process = nil; lock.unlock() }
        var data = Data(), total = 0, failure: Error?
        while true {
            let ended = autoreleasepool { () -> Bool in
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { return true }
                if failure != nil { return false } // Drain while terminated child exits.
                do {
                    guard chunk.count <= maximumOutput - total else {
                        throw ConversionFailure(message: "The helper response exceeded its size limit.")
                    }
                    total += chunk.count
                    if let consume { try consume(chunk) } else { data.append(chunk) }
                } catch { failure = error; if task.isRunning { task.terminate() } }
                return false
            }
            if ended { break }
        }
        task.waitUntilExit(); try checkCancellation()
        if let failure { throw failure }
        guard task.terminationStatus == 0 else {
            let detail = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionFailure(message: detail.isEmpty ? "The helper stopped before it produced a result." : detail)
        }
        return data
    }

    /// Reports which logical profile seals an encrypted image, without decrypting it.
    /// The payload length is treated as untrusted: it is bounded and only
    /// surfaced when the whole file matches it. Uses the shared cancellable
    /// process path, so an inspection can be cancelled like any other operation.
    public func inspectEncrypted(_ source: URL, helper: URL) throws -> EncryptedProfile.Detection {
        let data = try capture(arguments: ["inspect-encrypted", source.path], helper: helper)
        let detail = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["logicalName"] as? String,
              EncryptedProfile.isSupported(name),
              let complete = json["complete"] as? Bool else {
            throw ConversionFailure(message: detail.isEmpty
                ? "This file is not a recognized encrypted image."
                : detail)
        }
        var payload: UInt64?
        if complete {
            guard let number = json["payloadBytes"] as? NSNumber else {
                throw ConversionFailure(message: "The helper reported a complete image without a payload length.")
            }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= 274_877_906_944, value == value.rounded(),
                  number.uint64Value == UInt64(value) else {
                throw ConversionFailure(message: "The helper reported an out-of-range payload length; the file is not a usable image.")
            }
            payload = number.uint64Value
        }
        return EncryptedProfile.Detection(logicalName: name, payloadBytes: payload, complete: complete)
    }

    public struct PackageVerification: Sendable {
        public let entries: Int
        public let payloadBytes: UInt64
        public let contentID: String
        public let titleID: String
        public let names: [String]
    }

    /// Read-only verification of an already-published package: header digests,
    /// index, encrypted payload and QA/license fields are recomputed without
    /// writing anything. Runs through the shared cancellable process runner
    /// with progress, and optionally binds the result to the expected content
    /// and title IDs. Generic integrity alone never proves job identity — the
    /// caller must compare the returned fields against its own record.
    public func verifyPackage(_ package: URL, helper: URL,
                              expectedContentID: String? = nil,
                              expectedTitleID: String? = nil,
                              progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> PackageVerification {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConversionFailure(message: "The bundled conversion helper is missing.")
        }
        var arguments = ["verify-package", package.path]
        if let expected = expectedContentID { arguments.append(expected) }
        if let expected = expectedTitleID { arguments.append(expected) }
        var verified: [String: Any]?
        try run(arguments: arguments, helper: helper, progress: progress, onEvent: { event in
            if event["verified"] as? Bool == true { verified = event }
        }, requiresCompletion: false)
        guard let result = verified,
              let entries = result["entries"] as? NSNumber,
              let bytes = result["payloadBytes"] as? NSNumber,
              let contentID = result["contentID"] as? String,
              let titleID = result["titleID"] as? String,
              let names = result["names"] as? [String],
              bytes.doubleValue.isFinite, bytes.doubleValue >= 0, bytes.doubleValue <= 274_877_906_944 else {
            throw ConversionFailure(message: "The package verified structurally but its report was unreadable.")
        }
        return PackageVerification(entries: entries.intValue, payloadBytes: bytes.uint64Value,
                                   contentID: contentID, titleID: titleID, names: names)
    }

    public func run(arguments: [String], helper: URL,
                    environment: [String: String] = [:],
                    progress: @escaping @Sendable (ConversionProgress) -> Void,
                    onEvent: (([String: Any]) -> Void)? = nil,
                    requiresCompletion: Bool = true) throws {        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConversionFailure(message: "The bundled conversion helper is missing.")
        }
        let task = Process()
        task.executableURL = helper
        task.arguments = arguments
        if !environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw ConversionFailure(message: "Cancelled before conversion started.") }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); process = nil; lock.unlock() }
        var buffer = Data()
        var messages = [String]()
        var completed = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let stage = event["stage"] as? String {
                    onEvent?(event)
                    if stage == "complete" { completed = event["locallyVerified"] as? Bool == true }
                    if let done = event["completed"] as? Double, let total = event["total"] as? Double, total > 0 {
                        progress(ConversionProgress(stage: stage, fraction: min(1, max(0, done / total))))
                    }
                } else if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    // Structured non-progress output (e.g. package verification).
                    onEvent?(event)
                } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                    messages.append(String(text.prefix(1000)))
                    if messages.count > 8 { messages.removeFirst() }
                }
            }
            if buffer.count > 8192 { buffer.removeAll() }
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0, (!requiresCompletion || completed) else {
            throw ConversionFailure(message: messages.isEmpty ? "Conversion stopped before a verified output was published." : messages.joined(separator: "\n"))
        }
    }
}
