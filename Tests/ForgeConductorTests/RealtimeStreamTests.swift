// RealtimeStreamTests.swift
// Verifies continuous native sampling, listener delivery, and advancing timestamps.
// Rate and ordering checks distinguish a live stream from repeated cached snapshots.

import XCTest
import Darwin
@testable import ForgeConductorCore

/// Proves host telemetry is a continuous stream — not a multi-second snapshot product.
final class RealtimeStreamTests: XCTestCase {
    func testHeadlessSnapshotsRemainFreshWithoutRecurringCollectors() throws {
        let home = URL(fileURLWithPath: "/private/tmp/forge-serve-telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home, startTelemetry: false)
        defer { app.shutdown() }
        XCTAssertFalse(app.telemetry.realtimeEngine.isRunning)
        let sampleDelivery = expectation(description: "idle engine does not publish recurring samples")
        sampleDelivery.isInverted = true
        let listener = app.telemetry.realtimeEngine.addListener { _ in sampleDelivery.fulfill() }
        defer { app.telemetry.realtimeEngine.removeListener(listener) }

        let first = try app.telemetry.snapshotTyped()
        Thread.sleep(forTimeInterval: 0.02)
        let second = try app.telemetry.snapshotTyped()
        XCTAssertGreaterThan(second.system.ts, first.system.ts)
        XCTAssertEqual(second.updated, second.system.ts)
        XCTAssertEqual(app.telemetry.currentFrame().system.ts, second.system.ts)
        let system = try app.telemetry.systemOnly()
        XCTAssertGreaterThan(try XCTUnwrap(system["ts"] as? Double), second.system.ts)
        let snapshot = try app.telemetry.snapshot(force: true)
        XCTAssertTrue(TelemetryContract.validate(snapshot: snapshot).isEmpty)
        XCTAssertFalse((snapshot["history"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual(app.telemetry.healthDictionary()["stream_running"] as? Bool, false)
        XCTAssertFalse(app.telemetry.realtimeEngine.isRunning)
        wait(for: [sampleDelivery], timeout: 0.15)
    }

    func testDefaultBootstrapRetainsContinuousGUIAndManagerTelemetry() throws {
        let home = URL(fileURLWithPath: "/private/tmp/forge-telemetry-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        XCTAssertTrue(app.telemetry.realtimeEngine.isRunning)
        XCTAssertEqual(app.telemetry.realtimeEngine.targetSampleHz, 30)
        let delivered = expectation(description: "default bootstrap maintains continuous sampling")
        let deliveryLock = NSLock()
        var didDeliver = false
        let listener = app.telemetry.realtimeEngine.addListener { _ in
            deliveryLock.lock()
            let first = !didDeliver
            didDeliver = true
            deliveryLock.unlock()
            if first { delivered.fulfill() }
        }
        defer { app.telemetry.realtimeEngine.removeListener(listener) }
        wait(for: [delivered], timeout: 2)
        app.telemetry.stopBackgroundRefresh()
        XCTAssertFalse(app.telemetry.realtimeEngine.isRunning)
    }

    func testStoppedCurrentFrameReadDoesNotCollectOnMainActor() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/forge-frame-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home, startTelemetry: false)
        defer { app.shutdown() }
        let collector = SingleSampleSystemCollector()
        let engine = RealtimeMetricsEngine(systemCollector: collector)
        let telemetry = TelemetryService(
            paths: app.paths, store: app.store, catalog: app.catalog, realtimeEngine: engine
        )
        collector.resetObservations()
        let fresh = try await Task.detached { try telemetry.snapshotTyped() }.value
        XCTAssertEqual(collector.observations.calls, 1)
        XCTAssertFalse(collector.observations.collectedOnMainThread)
        let cached = await MainActor.run { telemetry.currentFrame() }
        XCTAssertEqual(cached.system.ts, fresh.system.ts)
        XCTAssertEqual(collector.observations.calls, 1)
        XCTAssertFalse(engine.isRunning)
    }

    func testColdCurrentFrameOnMainActorUsesPlaceholderUntilExplicitOffMainSample() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/forge-cold-frame-\(UUID().uuidString)")
        let system = SingleSampleSystemCollector()
        let forge = CountingForgeCollector(home: home.path)
        let telemetry = TelemetryService(paths: AppPaths(home: home), systemCollector: system,
            forgeCollector: forge)
        system.resetObservations()
        let cold = await MainActor.run { telemetry.currentFrame() }
        XCTAssertEqual(forge.observations.calls, 0)
        XCTAssertEqual(system.observations.calls, 0)
        XCTAssertEqual(cold.forge.home, home.path)
        XCTAssertEqual(cold.forge.presenceCount, 0)
        XCTAssertFalse(cold.forge.files.storeSQLite)
        XCTAssertTrue(TelemetryContract.validate(snapshot: cold.asDictionary()).isEmpty)
        XCTAssertFalse(telemetry.realtimeEngine.isRunning)

        let fresh = try await Task.detached { try telemetry.snapshotTyped() }.value
        XCTAssertEqual(forge.observations.calls, 1)
        XCTAssertFalse(forge.observations.collectedOnMainThread)
        XCTAssertEqual(system.observations.calls, 1)
        XCTAssertFalse(system.observations.collectedOnMainThread)
        XCTAssertEqual(fresh.forge.presenceCount, 7)
        XCTAssertTrue(fresh.forge.files.storeSQLite)
        let cached = await MainActor.run { telemetry.currentFrame() }
        XCTAssertEqual(cached.forge, fresh.forge)
        XCTAssertEqual(forge.observations.calls, 1)
        XCTAssertFalse(telemetry.realtimeEngine.isRunning)
    }

    func testConcurrentSingleSamplesAreSerializedAndDoNotStartAStream() {
        let collector = SingleSampleSystemCollector()
        let engine = RealtimeMetricsEngine(systemCollector: collector)
        collector.resetObservations()
        let finished = expectation(description: "bounded concurrent single samples complete")
        finished.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = engine.collectCurrentMetrics()
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(collector.observations.calls, 8)
        XCTAssertEqual(collector.observations.maximumConcurrentCalls, 1)
        XCTAssertFalse(collector.observations.collectedOnMainThread)
        XCTAssertFalse(engine.isRunning)
        engine.stop()
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(collector.observations.calls, 8)
    }

    func testHostStreamAdvancesWithoutSnapshotAPI() {
        let engine = RealtimeMetricsEngine()
        let requiredSamples = 8
        let delivered = expectation(description: "realtime samples delivered")
        delivered.expectedFulfillmentCount = requiredSamples
        var samples: [TimeInterval] = []
        let lock = NSLock()
        let id = engine.addListener { m in
            lock.lock()
            samples.append(m.ts)
            let shouldFulfill = samples.count <= requiredSamples
            lock.unlock()
            if shouldFulfill {
                delivered.fulfill()
            }
        }
        engine.start(targetHz: 30)
        defer {
            engine.stop()
            engine.removeListener(id)
        }

        wait(for: [delivered], timeout: 2.0)
        lock.lock()
        let count = samples.count
        let unique = Set(samples.map { Int($0 * 100) })
        lock.unlock()

        XCTAssertGreaterThanOrEqual(count, requiredSamples, "tiered engine must push many samples; got \(count)")
        XCTAssertGreaterThanOrEqual(unique.count, 5, "timestamps must advance; unique=\(unique.count)")
        XCTAssertTrue(engine.isRunning)
        XCTAssertGreaterThanOrEqual(engine.targetSampleHz, 20)
    }

    func testTelemetryServicePublishesOnEverySample() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }

        let requiredFrames = 8
        let delivered = expectation(description: "continuous telemetry frames delivered")
        var frames = 0
        var lastTs: TimeInterval = 0
        let lock = NSLock()
        let id = app.telemetry.addListener { frame in
            lock.lock()
            frames += 1
            lastTs = frame.updated
            let reachedRequiredFrames = frames == requiredFrames
            lock.unlock()
            if reachedRequiredFrames {
                delivered.fulfill()
            }
        }
        defer { app.telemetry.removeListener(id) }
        app.telemetry.startBackgroundRefresh(intervalSec: 0.5)

        wait(for: [delivered], timeout: 2.0)
        lock.lock()
        let frameCount = frames
        let ts = lastTs
        lock.unlock()

        XCTAssertGreaterThanOrEqual(frameCount, requiredFrames, "listeners must receive continuous frames; got \(frameCount)")
        XCTAssertGreaterThan(ts, 0)

        let a = app.telemetry.currentFrame().system.ts
        Thread.sleep(forTimeInterval: 0.08)
        let b = app.telemetry.currentFrame().system.ts
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testContinuousSSESendsMultipleEvents() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-sse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        app.telemetry.startBackgroundRefresh(intervalSec: 0.5)

        let port = UInt16.random(in: 19_000...29_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.12)

        // Current-frame endpoint (compat name /api/snapshot still works).
        let liveURL = URL(string: "http://127.0.0.1:\(port)/api/live")!
        let (liveData, liveHTTP) = try HTTPTestHelpers.fetch(liveURL)
        XCTAssertEqual(liveHTTP.statusCode, 200)
        let liveJSON = try JSONSerialization.jsonObject(with: liveData) as? [String: Any]
        XCTAssertEqual(liveJSON?["stream"] as? String, "realtime")
        XCTAssertNotNil(liveJSON?["system"])

        // Raw TCP client — reliable for keep-alive SSE (URLSession often waits on EOS).
        let text = try Self.readSSE(host: "127.0.0.1", port: Int(port), durationSec: 0.9)
        let dataEvents = text.components(separatedBy: "data: ").count - 1
        XCTAssertTrue(text.contains("text/event-stream") || text.contains("200"), "headers: \(text.prefix(120))")
        XCTAssertGreaterThanOrEqual(
            dataEvents, 3,
            "SSE must push multiple live frames, not one-shot. events=\(dataEvents) body=\(text.prefix(280))"
        )
        XCTAssertTrue(
            text.contains("system") || text.contains("realtime"),
            "expected realtime payload content"
        )
    }

    /// Blocking read of SSE stream over a plain TCP socket for ~durationSec.
    private static func readSSE(host: String, port: Int, durationSec: TimeInterval) throws -> String {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw NSError(domain: "sse", code: 1) }
        defer { close(sock) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr(host))

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "sse", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect failed errno=\(errno)"])
        }

        let req =
            "GET /api/stream?hz=20 HTTP/1.1\r\n" +
            "Host: \(host):\(port)\r\n" +
            "Accept: text/event-stream\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        _ = req.withCString { write(sock, $0, strlen($0)) }

        var collected = Data()
        let deadline = Date().addingTimeInterval(durationSec)
        var buf = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline {
            let n = read(sock, &buf, buf.count)
            if n > 0 {
                collected.append(contentsOf: buf[0..<n])
                let soFar = String(data: collected, encoding: .utf8) ?? ""
                if soFar.components(separatedBy: "data: ").count - 1 >= 3 {
                    break
                }
            } else if n == 0 {
                break
            } else {
                // EAGAIN / timeout — keep waiting until deadline
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    func testStreamHzParserUpgradesLegacyInterval() {
        XCTAssertEqual(TelemetryRoutes.parseStreamHz(query: "hz=25"), 25)
        // Legacy interval=2 must not force 0.5 Hz product behavior.
        let upgraded = TelemetryRoutes.parseStreamHz(query: "interval=2")
        XCTAssertGreaterThanOrEqual(upgraded, 10)
        XCTAssertEqual(TelemetryRoutes.parseStreamHz(query: ""), 20)
    }

    func testHealthReportsContinuousMode() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-health-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        app.telemetry.startBackgroundRefresh(intervalSec: 0.5)
        Thread.sleep(forTimeInterval: 0.2)
        let h = app.telemetry.healthDictionary()
        let mode = h["mode"] as? String ?? ""
        XCTAssertTrue(mode.contains("continuous-native"), "mode=\(mode)")
        XCTAssertEqual(h["stream"] as? String, "realtime")
        XCTAssertEqual(h["runtime"] as? String, "swift-native-realtime")
        XCTAssertEqual(h["ok"] as? Bool, true)
    }
}

private final class CountingForgeCollector: ForgeMetricsCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private let home: String
    private var calls = 0
    private var collectedOnMainThread = false
    init(home: String) { self.home = home }
    var observations: (calls: Int, collectedOnMainThread: Bool) {
        lock.lock(); defer { lock.unlock() }; return (calls, collectedOnMainThread)
    }
    func collect() -> ForgeSnapshot {
        lock.lock()
        calls += 1
        collectedOnMainThread = collectedOnMainThread || Thread.isMainThread
        lock.unlock()
        var result = ForgeSnapshot.empty(home: home)
        result.presenceCount = 7
        result.files = ForgeFilesPresence(storeSQLite: true, auditJSONL: false, managerState: false)
        return result
    }
}

private final class SingleSampleSystemCollector: SystemMetricsCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private let template = SystemCollector().collectMetrics()
    private var calls = 0
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0
    private var collectedOnMainThread = false

    var observations: (calls: Int, maximumConcurrentCalls: Int, collectedOnMainThread: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (calls, maximumConcurrentCalls, collectedOnMainThread)
    }

    func resetObservations() {
        lock.lock(); defer { lock.unlock() }
        calls = 0
        maximumConcurrentCalls = 0
        collectedOnMainThread = false
    }

    func collectMetrics() -> SystemMetrics {
        lock.lock()
        calls += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        collectedOnMainThread = collectedOnMainThread || Thread.isMainThread
        let timestamp = Double(calls)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.005)
        var result = template
        result.ts = timestamp
        lock.lock()
        activeCalls -= 1
        lock.unlock()
        return result
    }
}
