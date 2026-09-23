// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum NativeHelper {
    public static func locate() throws -> URL {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ps2-convert"),
            URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ps2-convert")]
        guard let helper=candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0.path)}) else {
            throw ConversionFailure(message:"The bundled disc helper is missing. Open the assembled application.")
        }
        return helper
    }
}
public enum CHDImporter {
    private struct Probe: Decodable {
        let expandedByteCount: UInt64?
        let sectorBytes: Int?
        let gameID: String?
        let requiresParent: Bool?
        let parentSHA1: String?
    }
    /// Inspects a CHD through the shared cancellable process runner. A
    /// parent-dependent image reports its requirement (plus the exact parent
    /// identity it declares) when no parent is given; pass the explicitly
    /// chosen parent to resolve the full probe. Callers that can be cancelled
    /// (the app's import and image-tool paths) pass their runner so Cancel
    /// terminates the helper; command-line callers may omit it.
    public static func inspect(_ url: URL, parent: URL? = nil, helper: URL? = nil, runner: ConversionRunner? = nil) throws -> DiscInspection {
        let resolved = try helper ?? NativeHelper.locate()
        let active = runner ?? ConversionRunner()
        var arguments = ["inspect-chd",url.path]
        if let parent { arguments.append(parent.path) }
        let data=try active.capture(arguments:arguments,helper:resolved)
        let result=try JSONDecoder().decode(Probe.self,from:data)
        let bytes=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        if result.requiresParent == true {
            guard let sha1=result.parentSHA1, sha1.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil else {
                throw ConversionFailure(message:"The parent-dependent CHD did not declare a usable parent identity.")
            }
            return DiscInspection(filename:url.lastPathComponent,byteCount:UInt64(bytes),
                format:"CHD v5 (parent required)",volumeLabel:nil,declaredVolumeBytes:nil,
                notes:["This image stores only differences against its parent CHD. Choose the exact parent file before building; both originals stay unchanged."],
                gameID:nil,expandedByteCount:nil,requiresParent:true,parentSHA1:sha1)
        }
        guard let expanded=result.expandedByteCount, let sector=result.sectorBytes else {
            throw ConversionFailure(message:"The CHD inspection report was unreadable.")
        }
        return DiscInspection(filename:url.lastPathComponent,byteCount:UInt64(bytes),format:"CHD v5 (\(sector)-byte disc sectors)",volumeLabel:nil,declaredVolumeBytes:nil,
            notes:["The original CHD stays unchanged. The disc is expanded into the build workspace.","Decompression checks CHD block integrity and the recorded raw SHA-1 when present."],
            gameID:(result.gameID ?? "").isEmpty ? nil : result.gameID,expandedByteCount:expanded)
    }
}
