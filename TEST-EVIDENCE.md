# Local native SDK validation

## Environment

- Xcode 27.1, build 27A9275; Apple Swift 6.4 in Swift 5 language mode.
- Rust 1.99.1 and UniFFI 0.32.2.
- Runtime: `com.apple.CoreSimulator.SimRuntime.iOS-27-0`, iPhone 17,
  simulator UUID `6F942E02-918E-449C-BB96-EFD115C514FF`.
- Consumer build target: `arm64-apple-ios15.0-simulator`.

## Artifact and compile checks

From the core checkout:

```sh
bash scripts/build-ios.sh
bash scripts/verify-ios.sh target/sdk/TinkleSDKFFI.xcframework.zip
python3 scripts/sdk-ci.py stage --sdk swift \
  --destination ../tinkle-sdk-swift --artifacts target/sdk --bootstrap
```

Passed: device arm64, simulator arm64, simulator x86_64; headers and generated
binding parity; 88 matching native FFI exports per architecture; all inspected
Mach-O object minimums at or below iOS 15.0 (686 device arm64, 686 simulator
arm64, 597 simulator x86_64). Generated Swift typechecked for all three targets.
Both release ZIPs were created and the XCFramework ZIP reverified after creation.

Fresh 2026-10-23 build artifacts (`target/sdk`):
`TinkleSDKFFI.xcframework.zip` sha256
`295761ac813d0150a7f2c4229c629b5e9aea2105a30a1804e0d49ce264b7190a`;
`swift-bindings.zip` sha256
`f183c525e1fbcae99d148c4499ad5467607578fa9389c8c8787b9d440fdd347d`.

Apple's `nm` cannot decode some Rust compiler-builtins LLVM bitcode produced by
this Rust release. Verification uses `nm --no-llvm-bc` to examine native ABI
symbols. Native object platform/minimum checks remain enabled.

All three native builds reported `-liconv -lSystem -lc -lm`; the Swift package
explicitly links `iconv`, with the remaining libraries supplied by the toolchain.
The linked test bundle has platform `IOSSIMULATOR` and minimum OS `15.0`; its
dynamic dependencies are Apple system/Swift libraries and XCTest, with no
separate Rust dylib.

## Runtime checks

```sh
python3 scripts/sdk-ci.py swift-test --destination ../tinkle-sdk-swift
```

The original three-test suite passed. After adding the actual foreign callback
fixture, these four tests passed on the runtime above:

- `testRuntimeInitializationAndRustStoreConstruction`: exported initialization,
  binding checksum checks, Rust object creation/release.
- `testClientAsyncErrorsAndLifecycle`: client construction, insecure URL
  rejection, typed Rust codec/not-connected errors, asynchronous suspend/close
  and event completion. These calls cross the Swift/Rust ABI.
- `testInMemoryCursorStoreIsolation`: direct Swift actor calls only.
- `testRustCallsSwiftAsyncCursorStore`: real loopback WebSocket/Syntra connect,
  Rust-to-Swift actor `load` calls with an explicit suspension, optional UInt64
  result returned to Rust, and cursor 42 echoed by the gateway after Rust sends
  it in the subscription RPC. This exercises foreign async-future completion.

### Core callback-error blocker

The additional `testSwiftAsyncStoreErrorPropagatesThroughRust` regression test
exposed a shared-core boundary failure. Throwing `FfiError.Storage` from Swift
causes the Rust `#[uniffi(flat_error)]` conversion to panic:

```text
thread '<unnamed>' panicked at crates/tinkle-ffi/src/error.rs:8:42:
Can't lift flat errors
caught error: rustPanic("Can't lift flat errors")
```

The five-test run reported four passes and one unexpected failure. The test is
kept enabled as a reproducer; foreign error propagation is not accepted as
passing. Fixing the core error representation and regenerating/rebuilding its
bindings is outside this package's ownership. The successful callback test
does not prove callback error propagation, cursor saving after notifications,
callback cancellation, or callback release races.

2026-10-23 rerun via `scripts/sdk-ci.py swift-test` reproduced the same
outcome (4 passed, 1 failed on `testSwiftAsyncStoreErrorPropagatesThroughRust`
with `rustPanic("Can't lift flat errors")`). A positive-only rerun with that
single reproducer skipped passed 4/4 on iPhone 17 (ID
`6F942E02-918E-449C-BB96-EFD115C514FF`, iOS 27.0), result bundle
`.build/ci-results-20261023-positive.xcresult`; `xcresulttool` summary reports
`passedTests: 4, failedTests: 0`.

## Remaining platform evidence

Xcode's XCTest binaries require iOS 17 and emit linker warnings when this test
bundle is built with an iOS 15 minimum. These warnings concern Apple's test
frameworks; the SDK's native-object checks still enforce iOS 15. This run proves
execution on iOS 27, not iOS 15. Xcode 27 cannot execute an iOS 15 runtime.
Minimum-OS runtime testing, physical-device execution/signing, and Intel
simulator execution remain unverified. Intel and device slices were built and
their Swift bindings typechecked, not run.

No remote release artifact has been published or downloaded. Bootstrap staging
did not fabricate `sdk-artifact.json`, a package version, or a release URL.
