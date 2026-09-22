// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

/// System curl on Monterey supports these options. No curl configuration file,
/// proxy settings, redirects or user credentials are inherited from the shell.
enum NetworkCurl {
    static func quote(_ value: String) throws -> String {
        guard value.utf8.count <= 2048, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConversionFailure(message: "Network settings contain unsupported characters or are too long.")
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func run(_ options: [(String,String)], flags: [String] = [], maximum: Int,
                    runner: ConversionRunner, consume: ((Data) throws -> Void)? = nil) throws -> Data {
        var config = "silent\nftp-skip-pasv-ip\ngloboff\nconnect-timeout = 15\nspeed-limit = 1\nspeed-time = 60\nmax-time = 86400\nproxy = \"\"\n"
        for flag in flags { config += flag + "\n" }
        for (key,value) in options { config += key + " = " + (try quote(value)) + "\n" }
        do {
            return try runner.capture(arguments: ["--disable","--config","-"], helper: URL(fileURLWithPath:"/usr/bin/curl"),
                                      input: Data(config.utf8), maximumOutput: maximum, consume: consume)
        } catch {
            try runner.checkCancellation()
            // Never echo server-controlled replies, the config, or credentials.
            throw ConversionFailure(message: "Network operation failed or exceeded its size limit. Check the address, login, destination, and server availability.")
        }
    }
}

public struct FTPDestination: Sendable {
    public let host: String, port: Int, directory: String, username: String, password: String
    public init(host: String, port: Int = 21, directory: String, username: String = "anonymous", password: String = "") throws {
        guard host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$", options: .regularExpression) != nil,
              (1...65535).contains(port), directory.hasPrefix("/"), directory.utf8.count < 1024,
              !directory.split(separator:"/").contains(where: { $0 == "." || $0 == ".." }),
              !username.isEmpty, !username.contains(":"), username.count <= 128, password.count <= 256 else {
            throw ConversionFailure(message: "Enter a host name or IPv4 address, port 1–65535, and an absolute FTP folder such as /dev_hdd0/packages. Enter login details separately.")
        }
        _ = try NetworkCurl.quote(directory); _ = try NetworkCurl.quote(username); _ = try NetworkCurl.quote(password)
        self.host=host; self.port=port; self.directory=directory == "/" ? "" : directory.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        self.username=username; self.password=password
    }
    var base: String { "ftp://\(host):\(port)/" }
    func url(_ path: String) throws -> String {
        // Extra leading slash requests an absolute server path, independent of login directory.
        let encoded = path.split(separator:"/", omittingEmptySubsequences:false).map {
            String($0).addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? ""
        }.joined(separator:"/")
        return base + encoded
    }
}

public enum ConsoleTransfer {
    /// Creates a private remote namespace. MKD must succeed (not 'already exists').
    /// Only a fully read-back verified upload is renamed from .part to .pkg.
    /// Failed/cancelled transfers leave that identified directory for inspection.
    @discardableResult
    public static func send(package: URL, destination: FTPDestination, helper: URL, runner: ConversionRunner,
                            progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) throws -> String {
        guard package.isFileURL, let identity = FileIdentity.of(package), identity.isRegularFile, !identity.isSymbolicLink,
              let size = (try? package.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,
              size > 0, size <= 274_877_906_944 else { throw ConversionFailure(message:"Choose a local package file, up to 256 GiB.") }
        progress(ConversionProgress(stage:"Checking local package",fraction:0))
        _ = try runner.verifyPackage(package, helper:helper)
        let hash = try FileDigest.sha256(package, cancelled:{try runner.checkCancellation()})
        let folder = "/" + ([destination.directory,"PS2-"+UUID().uuidString].filter{!$0.isEmpty}.joined(separator:"/"))
        let partial = folder + "/package.part", final = folder + "/package.pkg"
        let common = [("proto","=ftp"),("user",destination.username+":"+destination.password)]
        var created = false
        do {
            _ = try NetworkCurl.run(common + [("url",destination.base),("quote","MKD "+folder)], flags:["head"], maximum:65536, runner:runner)
            created=true
            progress(ConversionProgress(stage:"Uploading into \(folder)",fraction:0.2))
            _ = try NetworkCurl.run(common + [("url",try destination.url(partial)),("upload-file",package.path)], maximum:65536, runner:runner)
            progress(ConversionProgress(stage:"Reading back uploaded package",fraction:0.5))
            var received = 0, lastPercent = -1, digest = SHA256()
            _ = try NetworkCurl.run(common + [("url",try destination.url(partial))], flags:["ignore-content-length"], maximum:size, runner:runner) { data in
                try runner.checkCancellation(); digest.update(data:data); received += data.count
                let percent=Int(Double(received)*100/Double(size))
                if percent != lastPercent { lastPercent=percent;progress(ConversionProgress(stage:"Reading back uploaded package",fraction:0.5+0.4*Double(received)/Double(size))) }
            }
            let remoteHash=digest.finalize().map {String(format:"%02x",$0)}.joined()
            guard received == size, remoteHash == hash,
                  try FileDigest.sha256(package,cancelled:{try runner.checkCancellation()}) == hash else {
                throw ConversionFailure(message:"The transferred bytes did not match the unchanged local package.")
            }
            try runner.checkCancellation()
            _ = try NetworkCurl.run(common + [("url",destination.base),("quote","RNFR "+partial),("quote","RNTO "+final)], flags:["head"], maximum:65536, runner:runner)
            progress(ConversionProgress(stage:"Transfer read-back verified",fraction:1))
            return final
        } catch {
            let detail = error.localizedDescription
            throw ConversionFailure(message: detail + (created ? " Remote folder: \(folder). It may contain a partial file; a lost connection during final rename needs inspection. No existing console folder was replaced." : " No upload was started."))
        }
    }
}

public struct OnlineConfigCatalog: Codable, Sendable {
    public struct Entry: Codable, Identifiable, Sendable {
        public var id: String { gameID + ":" + sha256 }
        public let gameID: String, title: String, url: URL, sha256: String
        public let bytes: Int
    }
    public let version: Int
    public let source: String, revision: String, license: String
    public let entries: [Entry]
    public static func validateURL(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.absoluteString.count <= 2048 else { throw ConversionFailure(message:"Use a direct HTTPS URL without credentials or a fragment.") }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2*1024*1024 else {throw ConversionFailure(message:"CONFIG catalog exceeds 2 MB.")}
        let result = try JSONDecoder().decode(Self.self,from:data)
        guard result.version == 1, (1...10000).contains(result.entries.count),
              [result.source,result.revision,result.license].allSatisfy({!$0.isEmpty && $0.count <= 512}) else {
            throw ConversionFailure(message:"Unsupported CONFIG catalog or missing publisher, revision or license information.")
        }
        var identifiers=Set<String>()
        for entry in result.entries {
            try validateURL(entry.url)
            guard GameProject.validGameID(entry.gameID), entry.title.count <= 256,
                  entry.sha256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                  (1...1024*1024).contains(entry.bytes), identifiers.insert(entry.id).inserted else {
                throw ConversionFailure(message:"CONFIG catalog contains an invalid or duplicate entry.")
            }
        }
        return result
    }
    public static func fetch(_ url: URL, runner: ConversionRunner) throws -> Self {
        try validateURL(url)
        return try decode(NetworkCurl.run([("proto","=https"),("url",url.absoluteString),("max-time","60")],flags:["fail"],maximum:2*1024*1024,runner:runner))
    }
    /// Exact approved entry only. A downloaded catalog never replaces CONFIGs
    /// already selected by a project. Each import uses a fresh local directory.
    public func download(_ entry: Entry, into parent: URL, runner: ConversionRunner) throws -> URL {
        guard GameProject.validGameID(entry.gameID), (1...1024*1024).contains(entry.bytes), entries.contains(where:{$0.id==entry.id && $0.url==entry.url && $0.bytes==entry.bytes}) else {
            throw ConversionFailure(message:"The CONFIG selection no longer belongs to this catalog.")
        }
        try Self.validateURL(entry.url)
        let data=try NetworkCurl.run([("proto","=https"),("url",entry.url.absoluteString),("max-time","60")],flags:["fail"],maximum:entry.bytes,runner:runner)
        return try store(data,entry:entry,into:parent,runner:runner)
    }
    func store(_ data: Data, entry: Entry, into parent: URL, runner: ConversionRunner) throws -> URL {
        guard GameProject.validGameID(entry.gameID), (1...1024*1024).contains(entry.bytes),
              data.count == entry.bytes, FileDigest.sha256(data:data) == entry.sha256,
              ![Data([80,83,50,0]),Data([78,80,68,0])].contains(Data(data.prefix(4))) else {
            throw ConversionFailure(message:"Downloaded CONFIG does not match the catalog or is already encrypted.")
        }
        try runner.checkCancellation()
        let directory=parent.appendingPathComponent("CONFIG-"+UUID().uuidString)
        guard mkdir(directory.path, 0o700) == 0 else { throw ConversionFailure(message:"Cannot create a new CONFIG download folder.") }
        var complete=false;defer{if !complete{try? FileManager.default.removeItem(at:directory)}}
        let output=directory.appendingPathComponent(entry.gameID+".CONFIG")
        try data.write(to:output,options:.withoutOverwriting)
        let receipt=try JSONEncoder().encode(self)
        try receipt.write(to:directory.appendingPathComponent("catalog.json"),options:.withoutOverwriting)
        let downloaded: [String:Any] = ["version":1,"retrievedAt":ISO8601DateFormatter().string(from:Date()),
            "url":entry.url.absoluteString,"sha256":entry.sha256,"bytes":entry.bytes]
        try JSONSerialization.data(withJSONObject:downloaded,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("download.json"),options:.withoutOverwriting)
        try runner.checkCancellation();complete=true;return output
    }
}
