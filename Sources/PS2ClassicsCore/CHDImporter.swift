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
    private struct Probe: Decodable { let expandedByteCount: UInt64; let sectorBytes: Int; let gameID: String }
    /// Inspects a CHD through the shared cancellable process runner. Callers
    /// that can be cancelled (the app's import and image-tool paths) pass their
    /// runner so Cancel terminates the helper; command-line callers may omit it.
    public static func inspect(_ url: URL, helper: URL? = nil, runner: ConversionRunner? = nil) throws -> DiscInspection {
        let resolved = try helper ?? NativeHelper.locate()
        let active = runner ?? ConversionRunner()
        let data=try active.capture(arguments:["inspect-chd",url.path],helper:resolved)
        let result=try JSONDecoder().decode(Probe.self,from:data)
        let bytes=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        return DiscInspection(filename:url.lastPathComponent,byteCount:UInt64(bytes),format:"CHD v5 (\(result.sectorBytes)-byte disc sectors)",volumeLabel:nil,declaredVolumeBytes:nil,
            notes:["The original CHD stays unchanged. The disc is expanded into the build workspace.","Decompression checks CHD block integrity and the recorded raw SHA-1 when present."],
            gameID:result.gameID.isEmpty ? nil : result.gameID,expandedByteCount:result.expandedByteCount)
    }
}
