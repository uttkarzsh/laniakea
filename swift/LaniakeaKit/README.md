# LaniakeaKit (Swift package template)

`Package.swift.template` is the manifest for the package that wraps the Rust prover.
The package itself is **assembled**, not checked in, because it contains generated
files:

```
scripts/package-xcframework.sh      # needs full Xcode
# -> <cargo target dir>/uniffi/ios-<min>/LaniakeaKit/   (<min> = IPHONEOS_DEPLOYMENT_TARGET)
```

Requirements and caveats

- **Swift 5 language mode** (`swiftLanguageVersions: [.v5]`): the code UniFFI 0.28.3
  generates does not type-check in Swift 6 mode. Do not upgrade the mode without
  upgrading UniFFI and re-verifying.
- Minimum iOS: `IPHONEOS_DEPLOYMENT_TARGET` (default 14.0), substituted for the
  `@IOS_MIN@` placeholder when the package is assembled. Libraries for each
  deployment target are built in their own Cargo target directory (`<target>/ios-<min>`).
- The binary target and the XCFramework are both named `laniakeaFFI`; the module the
  generated Swift imports (`import laniakeaFFI`) is defined by the `module.modulemap`
  inside the XCFramework.
- Never edit the generated `laniakea.swift`; regenerate it.
- The manifest and the XCFramework have not been built or consumed by SwiftPM or
  Xcode in this repository's current environment.
