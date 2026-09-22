// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import PS2ClassicsCore

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: ps2-build PROJECT.ps2project /path/to/ps2-convert\n",stderr); exit(2)
}
do {
    let project = try JSONDecoder().decode(GameProject.self,from:FileDigest.small(URL(fileURLWithPath:CommandLine.arguments[1]),maximum:1024*1024))
    let result = try PackageBuilder().build(project,helper:URL(fileURLWithPath:CommandLine.arguments[2])) { update in
        print("\(update.stage): \(Int(update.fraction*100))%")
    }
    print(result.message)
} catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
