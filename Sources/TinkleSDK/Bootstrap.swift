// The release/bootstrap process copies the matching UniFFI-generated
// TinkleSDK.swift into this directory. Keep that file generated, not handwritten.
#if !os(iOS)
#error("TinkleSDK currently supports iOS devices and iOS simulators only.")
#endif
