import TinkleSDK
import XCTest

/// Tests the generated Swift API against the real Rust binary, without a server.
final class TinkleSDKTests: XCTestCase {
    func testRuntimeInitializationAndRustStoreConstruction() {
        tinkleFfiInit()
        tinkleFfiInit()
        // Construction and release cross the ABI and check binding checksums.
        _ = InMemoryFfiStore()
    }

    func testInMemoryCursorStoreIsolation() async throws {
        let store = MemoryCursorStore()
        try await store.save(principal: "alice", stream: "room:1", cursor: 42)
        try await store.save(principal: "bob", stream: "room:1", cursor: 9)
        try await store.save(principal: "alice", stream: "room:2", cursor: 7)
        let alice = try await store.load(principal: "alice", stream: "room:1")
        let bob = try await store.load(principal: "bob", stream: "room:1")
        XCTAssertEqual(alice, 42)
        XCTAssertEqual(bob, 9)

        try await store.removeStream(principal: "alice", stream: "room:1")
        let removed = try await store.load(principal: "alice", stream: "room:1")
        let otherStream = try await store.load(principal: "alice", stream: "room:2")
        XCTAssertNil(removed)
        XCTAssertEqual(otherStream, 7)
        try await store.clearPrincipal(principal: "alice")
        let cleared = try await store.load(principal: "alice", stream: "room:2")
        let retained = try await store.load(principal: "bob", stream: "room:1")
        XCTAssertNil(cleared)
        XCTAssertEqual(retained, 9)
    }

    func testClientAsyncErrorsAndLifecycle() async throws {
        tinkleFfiInit()
        let store = MemoryCursorStore()
        // Insecure WebSockets are rejected before opening any connection.
        let client = TinkleClient(
            config: ClientConfigFfi(
                url: "ws://127.0.0.1:9/syntra/v1/ws",
                allowInsecure: false,
                userAgent: "TinkleSDKTests"
            ),
            credential: "local-smoke-test",
            store: store
        )
        do {
            try await client.connect()
            XCTFail("An insecure URL must be rejected")
        } catch FfiError.Network(let message) {
            XCTAssertFalse(message.isEmpty)
        }
        do {
            _ = try await client.sendMessage(roomId: 0, text: "", randomId: 1)
            XCTFail("A zero room ID must fail validation")
        } catch FfiError.Codec(let message) {
            XCTAssertTrue(message.contains("room_id"))
        }
        do {
            _ = try await client.sendMessage(roomId: 1, text: "offline", randomId: 1)
            XCTFail("A disconnected client must reject writes")
        } catch FfiError.NotConnected {
            // Typed Rust errors and async completion crossed the ABI.
        }
        await client.suspend()
        await client.shutdown()
        let event = await client.nextEvent()
        XCTAssertNil(event)
    }

    func testRustCallsSwiftAsyncCursorStore() async throws {
        let gateway = try LoopbackGateway()
        defer { try? gateway.finish() }
        let store = MemoryCursorStore()
        try await store.save(principal: "user:42", stream: "user:42", cursor: 42)
        try await store.save(principal: "other-user", stream: "user:42", cursor: 999)
        let client = makeLoopbackClient(gateway, store: store)
        do {
            try await client.connect()
            let subscription = try await client.subscribe(rooms: [], watch: [])
            // The gateway echoes the cursor sent in the RPC by Rust. This can
            // only be 42 if Rust invoked Swift load(), awaited it, and decoded
            // the returned optional UInt64 before constructing its request.
            XCTAssertEqual(subscription.stream, "user:42")
            XCTAssertEqual(subscription.afterCursor, 42)
            let reads = await store.loadCalls
            XCTAssertGreaterThanOrEqual(reads.count, 2)
            XCTAssertTrue(reads.allSatisfy { $0.principal == "user:42" && $0.stream == "user:42" })
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
        try gateway.finish()
    }

    func testSwiftAsyncStoreErrorPropagatesThroughRust() async throws {
        let gateway = try LoopbackGateway()
        defer { try? gateway.finish() }
        let store = MemoryCursorStore(failLoads: true)
        let client = makeLoopbackClient(gateway, store: store)
        do {
            try await client.connect()
            do {
                _ = try await client.subscribe(rooms: [], watch: [])
                XCTFail("The foreign store failure must propagate")
            } catch FfiError.Storage(let message) {
                XCTAssertTrue(message.contains("deliberate fixture failure"))
                let reads = await store.loadCalls
                XCTAssertGreaterThanOrEqual(reads.count, 2)
            }
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
        try gateway.finish()
    }

    private func makeLoopbackClient(_ gateway: LoopbackGateway, store: MemoryCursorStore) -> TinkleClient {
        TinkleClient(
            config: ClientConfigFfi(
                url: "ws://127.0.0.1:\(gateway.port)/syntra/v1/ws",
                allowInsecure: true,
                userAgent: "TinkleSDKLoopbackTests"
            ),
            credential: "local-smoke-test",
            store: store
        )
    }
}

/// Conforms to the actual generated foreign-store protocol. Production apps
/// provide durable storage; this actor is intentionally test-only and ephemeral.
private actor MemoryCursorStore: FfiCursorStore {
    private var cursors: [String: [String: UInt64]] = [:]
    private let failLoads: Bool
    private(set) var loadCalls: [(principal: String, stream: String)] = []

    init(failLoads: Bool = false) { self.failLoads = failLoads }

    func load(principal: String, stream: String) async throws -> UInt64? {
        // Force suspension so the foreign-future completion path is exercised.
        await Task.yield()
        loadCalls.append((principal, stream))
        if failLoads { throw FfiError.Storage("deliberate fixture failure") }
        return cursors[principal]?[stream]
    }

    func save(principal: String, stream: String, cursor: UInt64) async throws {
        cursors[principal, default: [:]][stream] = cursor
    }

    func removeStream(principal: String, stream: String) async throws {
        cursors[principal]?[stream] = nil
    }

    func clearPrincipal(principal: String) async throws {
        cursors[principal] = nil
    }
}
