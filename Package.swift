// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PS2ClassicsMac",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PS2ClassicsCore", targets: ["PS2ClassicsCore"]),
        .executable(name: "PS2ClassicsApp", targets: ["PS2ClassicsApp"]),
        .executable(name: "ps2-inspect", targets: ["PS2Inspect"]),
        .executable(name: "ps2-build", targets: ["PS2Build"]),
        .executable(name: "ps2-convert", targets: ["PS2Convert"])
    ],
    targets: [
        .target(name: "PS2ClassicsCore"),
        .target(name: "CLibCHDR", path: "ThirdParty/libchdr", sources: [
                "deps/lzma-26.02/src/LzmaDec.c",
                "deps/miniz-3.1.2/miniz.c",
                "deps/zstd-1.5.7/zstddeclib.c",
                "src/libchdr_bitstream.c",
                "src/libchdr_cdrom.c",
                "src/libchdr_chd.c",
                "src/libchdr_codec_avhuff.c",
                "src/libchdr_codec_cdfl.c",
                "src/libchdr_codec_cdlz.c",
                "src/libchdr_codec_cdzl.c",
                "src/libchdr_codec_cdzs.c",
                "src/libchdr_codec_flac.c",
                "src/libchdr_codec_huff.c",
                "src/libchdr_codec_lzma.c",
                "src/libchdr_codec_zlib.c",
                "src/libchdr_codec_zstd.c",
                "src/libchdr_flac.c",
                "src/libchdr_huffman.c"
            ], publicHeadersPath: "include", cSettings: [.define("LOWRAM_TARGET", to: "1"), .define("MINIZ_NO_ARCHIVE_APIS"), .define("MINIZ_NO_DEFLATE_APIS"), .define("MINIZ_NO_STDIO"), .define("MINIZ_NO_TIME")]),
        .executableTarget(name: "PS2Convert", dependencies: ["CLibCHDR"], cSettings: [.unsafeFlags(["-Wno-deprecated-declarations"])]),
        .executableTarget(name: "PS2ClassicsApp", dependencies: ["PS2ClassicsCore"]),
        .executableTarget(name: "PS2Inspect", dependencies: ["PS2ClassicsCore"]),
        .executableTarget(name: "PS2Build", dependencies: ["PS2ClassicsCore"]),
        .testTarget(name: "PS2ClassicsCoreTests", dependencies: ["PS2ClassicsCore"]),
        .testTarget(name: "PS2ClassicsAppTests", dependencies: ["PS2ClassicsApp"])
    ]
)
