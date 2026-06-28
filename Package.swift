// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KFKV",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "KFKV",
            targets: ["KFKV"]
        ),
        .library(
            name: "KFKVAPI",
            targets: ["KFKVAPI"]
        ),
        .library(
            name: "KFKVSwift",
            targets: ["KFKVSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/kernelflux/kfservice.git", from: "1.0.0"),
    ],
    targets: [
        // OpenSSL AES
        .target(
            name: "KFKVCoreOpenSSL",
            path: "Sources/Core/aes/openssl",
            publicHeadersPath: ".",
            cxxSettings: [
            ]
        ),

        // C++ core
        .target(
            name: "KFKVCore",
            dependencies: ["KFKVCoreOpenSSL"],
            path: "Sources/Core",
            exclude: [
                "aes/openssl",
                "crc32/zlib",
                "crc32/crc32_armv8.mm",
            ],
            publicHeadersPath: "fakeinclude",
            cSettings: [
                .define("NDEBUG", .when(configuration: .release)),
            ],
            cxxSettings: [
                .headerSearchPath("fakeinclude/KFKVCore"),
                .headerSearchPath("."),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),

        // ObjC wrapper
        .target(
            name: "KFKV",
            dependencies: ["KFKVCore"],
            path: "Sources/KFKV",
            publicHeadersPath: "fakeinclude",
            cxxSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),

        // Swift extensions
        .target(
            name: "KFKVSwift",
            dependencies: ["KFKV", "KFKVAPI", .product(name: "KFService", package: "KFService")],
            path: "Sources/KFKVSwift"
        ),

        // Protocol-only API (zero dependency)
        .target(
            name: "KFKVAPI",
            path: "Sources/KFKVAPI"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
