# TinkleSDK for iOS

Headless Swift bindings for the [Tinkle Rust messaging engine](https://github.com/tinklehq/libtinkle).
The Swift package product and module are **`TinkleSDK`**. Its internal C FFI
module is **`TinkleSDKFFI`**. Requires iOS 15 or later and Swift tools 5.9 or later.
The XCFramework contains arm64 devices, arm64 simulators, and x86_64 simulators.

## Bootstrap status

This repository is awaiting the first native core release. There is no invented
release version or placeholder download URL. Until a real `sdk-artifact.json`
is committed, use a locally built XCFramework. Package resolution gives a clear
bootstrap error when neither is present.

## Local development

Use a matching checkout of `libtinkle`, with its pinned Rust toolchain, lockfile,
native bindings, and `ios-release` profile. Xcode and its iOS SDKs are required.

```sh
# In libtinkle:
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
bash scripts/generate-bindings.sh --write
bash scripts/build-ios.sh
bash scripts/verify-ios.sh target/sdk/TinkleSDKFFI.xcframework.zip
```

`SDK_OUTPUT_DIR` overrides `<libtinkle>/target/sdk`; relative paths are resolved
from the invoking directory. Cargo output paths come from `cargo metadata`, so
`CARGO_TARGET_DIR` is respected. If deployment settings changed, use a fresh
`CARGO_TARGET_DIR` to prevent stale native objects from entering the package.
The build fails if any object's deployment minimum exceeds iOS 15.

In this Swift repository, extract the XCFramework and copy the generated Swift
from the **same build** (replace these paths with your checkout locations):

```sh
mkdir -p Artifacts
ditto -x -k ../libtinkle/target/sdk/TinkleSDKFFI.xcframework.zip Artifacts
cp ../libtinkle/bindings/swift/TinkleSDK.swift Sources/TinkleSDK/TinkleSDK.swift
TINKLE_SDK_LOCAL=1 swift package dump-package
```

`Artifacts/` is ignored. `Package.swift` uses the local XCFramework automatically
when it exists; `TINKLE_SDK_LOCAL=1` explicitly requires it and fails if missing.
Open the package in Xcode or add this directory as a local package dependency.
Use an iOS destination; a plain host `swift test` would target macOS, which this
SDK does not support.

```swift
import TinkleSDK

// Once during application startup (idempotent).
tinkleFfiInit()
```

The generated API includes `TinkleClient`, `ClientConfigFfi`, `FfiCursorStore`,
and `FfiError`. Implement `FfiCursorStore` using your application's durable
storage; keep cursor values isolated by principal and stream. The test target
includes an actor-backed, in-memory implementation. No SwiftUI or app lifecycle
policy is included in the SDK.

### Compile and simulator runtime checks

The core packaging script verifies the XCFramework and typechecks generated
Swift at iOS 15 for all three target architectures. Those are compile checks.
Execute the package's XCTest suite separately:

```sh
xcrun simctl list devices available
# Choose a real installed simulator UUID and runtime; do not use a guessed ID.
TINKLE_SDK_LOCAL=1 xcodebuild test -scheme TinkleSDK \
  -destination 'platform=iOS Simulator,id=<installed-simulator-uuid>' \
  -derivedDataPath build/DerivedData -resultBundlePath build/Smoke.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Use a new result-bundle path on each run. Tests initialize Rust, construct a
client, exercise async error/lifecycle paths, and check in-memory cursor
isolation without contacting an external server. A simulator result proves
runtime linkage on that simulator, not physical-device behavior. The loopback
fixture performs a real WebSocket upgrade and Syntra handshake. Its subscription
test proves that Rust awaits the Swift actor's asynchronous `load` callback and
uses the returned cursor in the outgoing RPC. The direct store-isolation test
exercises Swift code only.

Xcode 27 cannot run an iOS 15 simulator. Test the declared minimum separately
using an appropriate older Xcode/runtime lane or physical device, and record
that evidence independently of a newer-runtime run. Physical-device signing
and installation are release acceptance steps.

## Release consumption

After a real core release and Swift package tag exist, add this repository's
URL in Xcode's **Add Package Dependencies**, select the desired published tag,
and link the `TinkleSDK` product. Import `TinkleSDK` from application code.

The committed `sdk-artifact.json` is an unchanged copy of that core release's
`sdk-release.json` (schema version 1). The manifest reads
`artifacts.ios.filename`, `artifacts.ios.url`, and `artifacts.ios.sha256`, checks
the core provenance (`source_repository: "tinklehq/libtinkle"`,
`source_tag: "tinkle-ffi-v<version>"`), then declares a remote binary target.
SwiftPM verifies the ZIP checksum. Generated `Sources/TinkleSDK/TinkleSDK.swift`
must come from that release's `swift-bindings.zip`.

Release automation must verify both downloads against the shared manifest,
copy the release manifest to `sdk-artifact.json`, and copy the matching Swift
source before tagging this package. Avoid a local `Artifacts/` directory when
validating remote resolution: local artifacts intentionally take precedence.
Do not recompress the core XCFramework ZIP after its checksum is published.

## License

The included `LICENSE` matches the Rust repository's license file.
