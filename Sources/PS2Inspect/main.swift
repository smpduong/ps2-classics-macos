// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import PS2ClassicsCore

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: ps2-inspect <disc-image>\nRead-only inspection; emits JSON without the source directory.\n".utf8))
    exit(2)
}
do {
    let result = try DiscInspector.inspect(URL(fileURLWithPath: CommandLine.arguments[1]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(result))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Inspection failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
