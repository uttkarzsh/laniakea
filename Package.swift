// swift-tools-version:6.0
//
// Laniakea: on-device Circom/Groth16 proving for iOS. The supported API is the product
// `LaniakeaKit` (`import LaniakeaKit`): Circuit, Prover, Proof, Input, LaniakeaError.
//
// Targets, from the bottom:
//   LaniakeaRustLib   binary: the Rust static libraries (ios-arm64 and ios-arm64-simulator),
//                     with no C headers and no module maps. Built locally by
//                     scripts/package-xcframework.sh into Binaries/ (git-ignored). A release
//                     would replace `path:` with a versioned `url:` and `checksum:`; none
//                     is published yet.
//   laniakeaFFI       C: owns the generated header; SwiftPM derives the module map from it.
//   _LaniakeaBindings Swift: the UniFFI-generated binding (committed, never edited by hand;
//                     scripts/check-bindings.sh compares it with a fresh generation).
//                     An implementation detail: it is not a product, and LaniakeaKit imports it
//                     with `internal import`. SwiftPM cannot make it unimportable by app
//                     code; its underscore name marks it as not API.
//   LaniakeaKit       Swift: the handwritten API.
//
// swift-tools-version 6.0 means consumers need a Swift 6.0+ toolchain (Xcode 16.0+); the
// handwritten sources also use `internal import` (SE-0409, Swift 6.0). The language mode
// stays Swift 5 (see the end of this manifest).
//
// The deployment target below must equal IPHONEOS_DEPLOYMENT_TARGET used to build the
// libraries (scripts/package-xcframework.sh checks this). 15.0 is the lowest the iOS 27.1
// SDK accepts for these Swift targets; the oldest iOS this has actually been run on is
// recorded in README.md, not implied here.
import PackageDescription

let package = Package(
    name: "Laniakea",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "LaniakeaKit", targets: ["LaniakeaKit"]),
    ],
    targets: [
        .binaryTarget(name: "LaniakeaRustLib", url: "https://github.com/uttkarzsh/laniakea/releases/download/0.1.0-rc.1/LaniakeaRustLib-0.1.0-rc.1.xcframework.zip", checksum: "5ce93db7f901c349d6c0c6ae0598134012b829891d977f6fcb4bbd09d0fe21e9"),
        .target(
            name: "laniakeaFFI",
            path: "swift/LaniakeaKit/Sources/laniakeaFFI",
            exclude: ["README.md"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "_LaniakeaBindings",
            dependencies: ["laniakeaFFI", "LaniakeaRustLib"],
            path: "swift/LaniakeaKit/Sources/_LaniakeaBindings"
        ),
        .target(
            name: "LaniakeaKit",
            dependencies: ["_LaniakeaBindings"],
            path: "swift/LaniakeaKit/Sources/LaniakeaKit",
            // Apple privacy manifest; it lands in the app as Laniakea_LaniakeaKit.bundle.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
    ],
    // UniFFI 0.28.3's generated code does not compile in Swift 6 language mode.
    swiftLanguageModes: [.v5]
)
