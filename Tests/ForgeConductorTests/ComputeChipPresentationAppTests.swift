#if !SWIFT_PACKAGE
  import AppKit
  import ApplicationServices
  import CryptoKit
  import Darwin
  import MetalKit
  import ImageIO
  import SwiftUI
  import XCTest
  import ForgeConductorCore
  @testable import Forge_Conductor

  /// Typed fixtures mount the production component; they never replace application telemetry.
  @MainActor
  final class ComputeChipPresentationAppTests: XCTestCase, @unchecked Sendable {
    private var fixtures: [ComputePresentationWindow] = []
    private var originalVisibleWindows: [NSWindow] = []
    private let accessibilityProbe = ComputePresentationAXProbe()
    private let directEvidence = DirectNativeFixtureEvidenceWriter()

    nonisolated override func setUp() async throws {
      try await prepareHost()
    }

    private func prepareHost() throws {
      continueAfterFailure = true
      guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty
      else {
        throw ComputePresentationFailure(
          "Run these component fixtures in the native application host with a display.")
      }
      try directEvidence.configure(testName: name)
      if NSApp.isHidden { NSApp.unhideWithoutActivation() }
      originalVisibleWindows = NSApp.windows.filter(\.isVisible)
      for window in originalVisibleWindows { window.orderOut(nil) }
    }

    nonisolated override func tearDown() async throws {
      await restoreHost()
    }

    private func restoreHost() async {
      for fixture in fixtures { fixture.close() }
      fixtures.removeAll()
      accessibilityProbe.clear()
      await allowNativeEvents(for: 0.25)
      for window in originalVisibleWindows { window.orderFront(nil) }
      originalVisibleWindows.removeAll()
    }

    func testProductionMetalTraceMotionRecordsTwentyGenuineDrawableFrames() async throws {
      // This fixture exercises real shader/clock output from typed samples; it is not host telemetry.
      let motionReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      retainText(
        "actual_system_reduce_motion=\(motionReduced); no_system_preference_changes=true",
        name: "compute-motion-capability-prerequisite")
      XCTAssertFalse(
        motionReduced, "A moving-trace recording requires the actual motion capability")
      guard !motionReduced else {
        throw ComputePresentationFailure(
          "The current system Reduce Motion preference forbids motion")
      }

      let fixture = try await mount(snapshot: snapshot(cpu: [0, 0, 20, 0, 0, 0], gpu: 82))
      let baseline = try await readback(from: fixture, name: "compute-motion-static-reference")
      let renderer = try XCTUnwrap(fixture.metalViews.only?.renderer)
      let layout = try XCTUnwrap(renderer.layout)
      XCTAssertEqual(layout.cpuRegions.count, 6)
      XCTAssertEqual(layout.routes.count, 64)
      let samplers = try layout.routes.map { try motionSamples(for: $0, pixels: baseline) }
      fixture.model.motionEnabled = true
      let running = await waitUntil { fixture.diagnostics.snapshot().activeClocks == 1 }
      XCTAssertTrue(running, "The genuine mounted production renderer must own one active clock")
      guard running else {
        throw ComputePresentationFailure("The production motion clock did not start")
      }
      await allowNativeEvents(for: 0.5)
      let before = fixture.diagnostics.snapshot()
      let started = ProcessInfo.processInfo.systemUptime
      let deadline = started + 25
      var frameReceipts: [[String: Any]] = []
      var routePositions = Array(repeating: [Double](), count: layout.routes.count)
      var routePeaks = Array(repeating: [Double](), count: layout.routes.count)
      var firstCPU: (rgb: Data, luminance: Double)?
      var lastCPU: (rgb: Data, luminance: Double)?
      var firstOtherCPU: [Data] = []
      var lastOtherCPU: [Data] = []
      var firstFrameBytes: Data?
      var lastFrameBytes: Data?

      for frameIndex in 0..<20 {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw ComputePresentationFailure("The bounded 20-frame recording exceeded 25 seconds")
        }
        let target = started + Double(frameIndex) * 0.32
        let remaining = target - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { await allowNativeEvents(for: remaining) }
        fixture.model.snapshot = snapshot(
          cpu: [0, 0, frameIndex < 10 ? 20 : 85, 0, 0, 0], gpu: 82)
        let name = String(format: "compute-motion-frame-%03d", frameIndex + 1)
        let requested = ProcessInfo.processInfo.systemUptime
        let pixels = try await readback(from: fixture, name: name)
        let completed = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(pixels.width, baseline.width)
        XCTAssertEqual(pixels.height, baseline.height)
        XCTAssertEqual(pixels.pointSize, baseline.pointSize)
        XCTAssertEqual(pixels.bytesPerRow, baseline.bytesPerRow)
        guard pixels.width == baseline.width, pixels.height == baseline.height,
          pixels.bytesPerRow == baseline.bytesPerRow, pixels.pointSize == baseline.pointSize
        else {
          throw ComputePresentationFailure(
            "Every actual motion frame must retain the reference drawable geometry")
        }
        XCTAssertEqual(renderer.layout?.cpuRegions, layout.cpuRegions)
        XCTAssertEqual(renderer.layout?.routes, layout.routes)
        var traceReceipts: [[String: Any]] = []
        for routeIndex in layout.routes.indices {
          let brightest = motionPeak(
            samples: samplers[routeIndex], baseline: baseline, frame: pixels)
          routePeaks[routeIndex].append(brightest.delta)
          if brightest.delta > 0.08 { routePositions[routeIndex].append(brightest.arc) }
          traceReceipts.append([
            "route": routeIndex, "channel": layout.routes[routeIndex].channel,
            "length_points": layout.routes[routeIndex].length,
            "peak_excess_luminance": brightest.delta, "arc_position_points": brightest.arc,
            "point_x": brightest.x, "point_y": brightest.y,
          ])
        }
        if frameIndex == 0 || frameIndex == 19 {
          let selected = try interiorPixels(in: layout.cpuRegions[2], from: pixels)
          let other = try layout.cpuRegions.enumerated().filter { $0.offset != 2 }.map {
            try interiorPixels(in: $0.element, from: pixels).rgb
          }
          if frameIndex == 0 {
            firstCPU = selected
            firstOtherCPU = other
            firstFrameBytes = pixels.bytes
          } else {
            lastCPU = selected
            lastOtherCPU = other
            lastFrameBytes = pixels.bytes
          }
        }
        frameReceipts.append([
          "index": frameIndex + 1, "attachment_name": name,
          "request_uptime": requested, "completion_uptime": completed,
          "elapsed_seconds": completed - started,
          "wall_time": Date().timeIntervalSince1970,
          "width": pixels.width, "height": pixels.height,
          "bytes_per_row": pixels.bytesPerRow, "byte_count": pixels.bytes.count,
          "raw_bgra_sha256": SHA256.hash(data: pixels.bytes).map { String(format: "%02x", $0) }
            .joined(),
          "typed_cpu_region_2_percent": frameIndex < 10 ? 20 : 85,
          "typed_gpu_aggregate_percent": 82, "trace_pixels": traceReceipts,
        ])
      }
      let finished = ProcessInfo.processInfo.systemUptime
      let after = fixture.diagnostics.snapshot()
      let travelReceipts = layout.routes.indices.map { index -> [String: Any] in
        let positions = routePositions[index]
        let span = (positions.max() ?? 0) - (positions.min() ?? 0)
        return [
          "route": index, "channel": layout.routes[index].channel,
          "positive_frame_count": positions.count,
          "unique_rounded_arc_positions": Set(positions.map { Int($0.rounded()) }).count,
          "travel_span_points": span,
          "peak_excess_luminance": routePeaks[index].max() ?? 0,
          "polyline_points": layout.routes[index].points.map { [Double($0.x), Double($0.y)] },
        ]
      }
      let receipt: [String: Any] = [
        "classification":
          "Genuine production Metal drawable frames from typed native XCTest inputs; not a screen recording or host telemetry",
        "frame_count": frameReceipts.count, "elapsed_seconds": finished - started,
        "clock_before": before.activeClocks, "clock_after": after.activeClocks,
        "animation_frames_before": before.animationFrames,
        "animation_frames_after": after.animationFrames,
        "completed_commands_before": before.completedCommands,
        "completed_commands_after": after.completedCommands,
        "geometry_rebuilds_before": before.geometryRebuilds,
        "geometry_rebuilds_after": after.geometryRebuilds,
        "route_detection":
          "Actual frame-minus-static-reference luminance on a bounded 4-point corridor of the existing production polyline geometry; no alternative shader or predicted pulse image",
        "frames": frameReceipts, "route_travel": travelReceipts,
        "encoding":
          "A separate bounded native AVAssetWriter encoder may use these exact retained PNGs at the recorded completion timestamps; original PNG hashes remain authoritative",
      ]
      let json = try JSONSerialization.data(
        withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      retainText(
        try XCTUnwrap(String(data: json, encoding: .utf8)),
        name: "compute-motion-frame-timestamps-and-pixels")
      XCTAssertEqual(frameReceipts.count, 20)
      XCTAssertGreaterThanOrEqual(finished - started, 6)
      XCTAssertLessThan(finished - started, 25)
      XCTAssertNotEqual(firstFrameBytes, lastFrameBytes)
      XCTAssertGreaterThan(
        try XCTUnwrap(lastCPU).luminance, try XCTUnwrap(firstCPU).luminance + 0.02)
      XCTAssertEqual(
        lastOtherCPU, firstOtherCPU,
        "Only the changed logical processor may change its local die-region pixels")
      for channel in 0..<2 {
        let movingRoutes = layout.routes.indices.filter { index in
          guard layout.routes[index].channel == channel else { return false }
          let positions = routePositions[index]
          return positions.count >= 8
            && Set(positions.map { Int($0.rounded()) }).count >= 6
            && (positions.max() ?? 0) - (positions.min() ?? 0) >= 12
        }
        XCTAssertFalse(
          movingRoutes.isEmpty,
          "Each active channel must show actual bright-pixel travel along at least one production route"
        )
      }
      XCTAssertGreaterThan(after.animationFrames, before.animationFrames + 20)
      XCTAssertGreaterThanOrEqual(after.completedCommands, before.completedCommands + 20)
      XCTAssertEqual(after.geometryRebuilds, before.geometryRebuilds)
      XCTAssertEqual(after.activeClocks, 1)
      try await requireState("High activity", id: "compute-cpu-activity-state", in: fixture)
      let provenance = try await semanticValue("compute-activity-provenance", in: fixture)
      XCTAssertTrue(provenance.contains("GPU regions illustrative"))
      XCTAssertTrue(provenance.contains("Trace flow simulated"))
      try await requireNativeLabelContainment(in: fixture)
      _ = try await retainNativeViewAndSemantics(
        fixture, name: "compute-motion-whole-native-structure")
      try requireCompletedMetal(in: fixture)
    }

    private struct MotionSample {
      let byteOffset: Int
      let arc: Double
      let x: Double
      let y: Double
    }

    private func motionSamples(for route: ComputeTraceRoute, pixels: ComputeChipPixels) throws
      -> [MotionSample]
    {
      let scaleX = Double(pixels.width) / pixels.pointSize.width
      let scaleY = Double(pixels.height) / pixels.pointSize.height
      XCTAssertEqual(scaleX, scaleY, accuracy: 0.02)
      guard route.points.count >= 2, route.length > 12 else {
        throw ComputePresentationFailure(
          "The genuine production route must contain a nonzero polyline")
      }
      var byPixel: [Int: MotionSample] = [:]
      for segment in 1..<route.points.count {
        let a = route.points[segment - 1]
        let b = route.points[segment]
        let dx = Double(b.x - a.x)
        let dy = Double(b.y - a.y)
        let length = hypot(dx, dy)
        guard length > 0 else { continue }
        let stepCount = max(1, Int(ceil(length / 0.5)))
        for step in 0...stepCount {
          let distance = length * Double(step) / Double(stepCount)
          for normal in -8...8 {
            let perpendicular = Double(normal) * 0.5
            let x = Double(a.x) + dx * distance / length - dy * perpendicular / length
            let y = Double(a.y) + dy * distance / length + dx * perpendicular / length
            let pixelX = Int((x * scaleX).rounded(.down))
            let pixelY = Int((y * scaleY).rounded(.down))
            guard pixelX >= 0, pixelY >= 0, pixelX < pixels.width, pixelY < pixels.height else {
              throw ComputePresentationFailure(
                "The real trace-pixel corridor must remain inside the drawable")
            }
            let offset = pixelY * pixels.bytesPerRow + pixelX * 4
            if byPixel[offset] == nil {
              byPixel[offset] = MotionSample(
                byteOffset: offset, arc: Double(route.cumulativeLengths[segment - 1]) + distance,
                x: x, y: y)
            }
          }
        }
      }
      XCTAssertLessThanOrEqual(byPixel.count, 8_192)
      guard !byPixel.isEmpty, byPixel.count <= 8_192 else {
        throw ComputePresentationFailure(
          "The route's actual-pixel sampling work must be nonempty and bounded")
      }
      return byPixel.values.sorted { $0.byteOffset < $1.byteOffset }
    }

    private func motionPeak(
      samples: [MotionSample], baseline: ComputeChipPixels, frame: ComputeChipPixels
    )
      -> (delta: Double, arc: Double, x: Double, y: Double)
    {
      var result = (delta: 0.0, arc: 0.0, x: 0.0, y: 0.0)
      for sample in samples {
        let offset = sample.byteOffset
        let old =
          (0.2126 * Double(baseline.bytes[offset + 2]) + 0.7152 * Double(baseline.bytes[offset + 1])
            + 0.0722 * Double(baseline.bytes[offset])) / 255
        let new =
          (0.2126 * Double(frame.bytes[offset + 2]) + 0.7152 * Double(frame.bytes[offset + 1])
            + 0.0722 * Double(frame.bytes[offset])) / 255
        if new - old > result.delta { result = (new - old, sample.arc, sample.x, sample.y) }
      }
      return result
    }

    func testOneLogicalCPUChangesOnlyItsMappedProductionMetalRegion() async throws {
      let fixture = try await mount(snapshot: snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: 0))
      try await requireState("Idle", id: "compute-cpu-activity-state", in: fixture)
      let idle = try await readback(from: fixture, name: "compute-native-six-cpu-idle")
      let layout = try XCTUnwrap(fixture.metalViews.first?.renderer?.layout)
      XCTAssertEqual(layout.cpuRegions.count, 6)

      fixture.model.snapshot = snapshot(cpu: [0, 0, 85, 0, 0, 0], gpu: 0)
      try await requireState("High activity", id: "compute-cpu-activity-state", in: fixture)
      let busy = try await readback(from: fixture, name: "compute-native-one-logical-cpu-85")
      XCTAssertEqual(busy.pointSize, idle.pointSize)
      XCTAssertEqual(fixture.metalViews.first?.renderer?.layout?.cpuRegions, layout.cpuRegions)
      var measurements: [String] = []
      var comparisons:
        [(index: Int, before: Data, after: Data, beforeLuminance: Double, afterLuminance: Double)] =
          []
      for (index, region) in layout.cpuRegions.enumerated() {
        let before = try interiorPixels(in: region, from: idle)
        let after = try interiorPixels(in: region, from: busy)
        measurements.append(
          "logical_region=\(index); idle_luminance=\(before.luminance); busy_luminance=\(after.luminance); samples=\(before.rgb.count / 3)"
        )
        comparisons.append((index, before.rgb, after.rgb, before.luminance, after.luminance))
      }
      retainText(
        measurements.joined(separator: "\n"),
        name: "compute-native-one-logical-cpu-pixel-comparison")
      for comparison in comparisons {
        if comparison.index == 2 {
          XCTAssertGreaterThan(
            comparison.afterLuminance, comparison.beforeLuminance + 0.02,
            "The genuine Metal fragment output must brighten logical region 2")
        } else {
          XCTAssertEqual(
            comparison.after, comparison.before,
            "Changing logical processor 2 must leave every other mapped CPU region unchanged")
        }
      }
      try requireCompletedMetal(in: fixture)
    }

    func testAggregateGPUProductionMetalIlluminationIncreasesWithoutMeasuredCoreClaims()
      async throws
    {
      let fixture = try await mount(snapshot: snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: 0))
      try await requireState("Idle", id: "compute-gpu-activity-state", in: fixture)
      let idle = try await readback(from: fixture, name: "compute-native-gpu-aggregate-0")
      fixture.model.snapshot = snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: 12)
      try await requireState("Active", id: "compute-gpu-activity-state", in: fixture)
      let medium = try await readback(from: fixture, name: "compute-native-gpu-aggregate-12")
      fixture.model.snapshot = snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: 82)
      try await requireState("High activity", id: "compute-gpu-activity-state", in: fixture)
      let high = try await readback(from: fixture, name: "compute-native-gpu-aggregate-82")
      let layout = try XCTUnwrap(fixture.metalViews.first?.renderer?.layout)
      let regions = layout.instances.filter {
        Int($0.properties.x) == 4 && Int($0.properties.y) >= 256
      }
      XCTAssertEqual(regions.count, ComputeChipSnapshot.gpuRegionCount)
      var receipts: [String] = []
      var comparisons: [(zero: Double, low: Double, high: Double)] = []
      for region in regions.prefix(ComputeChipSnapshot.gpuRegionCount) {
        let rect = CGRect(
          x: CGFloat(region.rect.x - region.rect.z / 2),
          y: CGFloat(region.rect.y - region.rect.w / 2),
          width: CGFloat(region.rect.z), height: CGFloat(region.rect.w))
        let zero = try interiorPixels(in: rect, from: idle).luminance
        let low = try interiorPixels(in: rect, from: medium).luminance
        let busy = try interiorPixels(in: rect, from: high).luminance
        receipts.append(
          "illustrative_region=\(Int(region.properties.y) - 256); idle=\(zero); aggregate12=\(low); aggregate82=\(busy)"
        )
        comparisons.append((zero, low, busy))
      }
      retainText(
        receipts.joined(separator: "\n"), name: "compute-native-gpu-aggregate-pixel-comparison")
      for comparison in comparisons {
        XCTAssertGreaterThan(comparison.low, comparison.zero)
        XCTAssertGreaterThan(comparison.high, comparison.low + 0.02)
      }
      fixture.model.snapshot = snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: nil)
      try await requireState("Activity unavailable", id: "compute-gpu-activity-state", in: fixture)
      let unavailable = try await readback(
        from: fixture, name: "compute-native-gpu-aggregate-unavailable")
      for region in regions {
        let rect = CGRect(
          x: CGFloat(region.rect.x - region.rect.z / 2),
          y: CGFloat(region.rect.y - region.rect.w / 2),
          width: CGFloat(region.rect.z), height: CGFloat(region.rect.w))
        let zero = try interiorPixels(in: rect, from: idle)
        let missing = try interiorPixels(in: rect, from: unavailable)
        let mean = actualPixelMean(zero.rgb)
        XCTAssertLessThan(zero.luminance, 0.16, "Measured zero must remain genuinely unlit")
        XCTAssertLessThan(
          max(mean.red, max(mean.green, mean.blue)) - min(mean.red, min(mean.green, mean.blue)),
          0.10)
        XCTAssertNotEqual(zero.rgb, missing.rgb)
      }
      let provenance = try await semanticValue("compute-activity-provenance", in: fixture)
      XCTAssertTrue(provenance.contains("GPU regions illustrative"))
      XCTAssertTrue(provenance.contains("Trace flow simulated"))
      try requireCompletedMetal(in: fixture)
    }

    func testProductionMaterialAssetsReuseThreeTexturesWhileGPUHueAndBrightnessFollowActivity()
      async throws
    {
      let initializationStart = ProcessInfo.processInfo.systemUptime
      let resources = ComputeChipResources.shared
      let initializationSeconds = ProcessInfo.processInfo.systemUptime - initializationStart
      retainText(
        "native_resource_lookup_seconds=\(initializationSeconds); shared_owner_may_already_be_initialized_by_prior_tests=true; classify_cold_using_first_process_lookup_only=true",
        name: "compute-native-reference-resource-initialization-timing")
      let cpuTexture = try XCTUnwrap(resources.cpuMaterialTexture)
      let gpuTexture = try XCTUnwrap(resources.gpuMaterialTexture)
      let circuitBoardTexture = try XCTUnwrap(resources.circuitBoardTexture)
      let sampler = try XCTUnwrap(resources.materialSampler)
      let cpuImage = try XCTUnwrap(resources.cpuMaterialImage)
      let gpuImage = try XCTUnwrap(resources.gpuMaterialImage)
      let circuitBoardImage = try XCTUnwrap(resources.circuitBoardImage)
      let circuitBoardImageIdentity = ObjectIdentifier(circuitBoardImage)
      let identities = [
        ObjectIdentifier(cpuTexture), ObjectIdentifier(gpuTexture),
        ObjectIdentifier(circuitBoardTexture), ObjectIdentifier(sampler),
      ]
      XCTAssertEqual(resources.materialTextureCount, 3)
      try requireReferenceMaterialPreservation(cpu: cpuImage, gpu: gpuImage)
      for (texture, dimension) in [(cpuTexture, 440), (gpuTexture, 464)] {
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(texture.width, dimension)
        XCTAssertEqual(texture.height, dimension)
        XCTAssertEqual(texture.mipmapLevelCount, 9)
      }
      XCTAssertGreaterThan(circuitBoardImage.width, 0)
      XCTAssertEqual(circuitBoardImage.width, circuitBoardImage.height)
      XCTAssertLessThanOrEqual(circuitBoardImage.width, 2_048)
      XCTAssertEqual(circuitBoardTexture.pixelFormat, .rgba8Unorm_srgb)
      XCTAssertEqual(circuitBoardTexture.width, circuitBoardImage.width)
      XCTAssertEqual(circuitBoardTexture.height, circuitBoardImage.height)
      XCTAssertEqual(circuitBoardTexture.mipmapLevelCount,
                     1 + Int(floor(log2(Double(circuitBoardImage.width)))))
      try requireCircuitBoardBackgroundDarkening(circuitBoardImage)
      let fixture = try await mount(
        snapshot: snapshot(cpu: Array(repeating: 85, count: 10), gpu: 12))
      let layout = try XCTUnwrap(fixture.metalViews.only?.renderer?.layout)
      let regions = layout.instances.filter {
        Int($0.properties.x) == 4 && Int($0.properties.y) >= 256
      }
      XCTAssertEqual(regions.count, ComputeChipSnapshot.gpuRegionCount)
      XCTAssertEqual(regions.map { Int($0.properties.y) }, Array(256..<272))
      var receipts: [String] = []
      var means: [(red: Double, green: Double, blue: Double, luminance: Double)] = []
      var unchangedCPU: [Data]?
      var perBankMeans: [[(red: Double, green: Double, blue: Double, luminance: Double)]] = []
      for value in [12.0, 50.0, 82.0] {
        fixture.model.snapshot = snapshot(cpu: Array(repeating: 85, count: 10), gpu: value)
        try await requireState(
          value >= 75 ? "High activity" : "Active",
          id: "compute-gpu-activity-state", in: fixture)
        let pixels = try await readback(
          from: fixture, name: "compute-native-material-gpu-\(Int(value))")
        if value == 12 {
          try requireCircuitBoardMaterialPixels(
            layout: layout, resources: resources, classification: "genuine production Metal drawable"
          ) { point in
            let x = Int((point.x * CGFloat(pixels.width) / pixels.pointSize.width).rounded(.down))
            let y = Int((point.y * CGFloat(pixels.height) / pixels.pointSize.height).rounded(.down))
            guard x >= 0, y >= 0, x < pixels.width, y < pixels.height else {
              throw ComputePresentationFailure("A circuit-board sample must be inside its drawable")
            }
            let offset = y * pixels.bytesPerRow + x * 4
            return NSColor(srgbRed: CGFloat(pixels.bytes[offset + 2]) / 255,
                           green: CGFloat(pixels.bytes[offset + 1]) / 255,
                           blue: CGFloat(pixels.bytes[offset]) / 255, alpha: 1)
          }
        }
        let cpu = try layout.cpuRegions.map { try interiorPixels(in: $0, from: pixels).rgb }
        if let unchangedCPU { XCTAssertEqual(cpu, unchangedCPU) } else { unchangedCPU = cpu }
        var rgb = Data()
        var bankMeans: [(red: Double, green: Double, blue: Double, luminance: Double)] = []
        for region in regions {
          let rect = CGRect(
            x: CGFloat(region.rect.x - region.rect.z / 2),
            y: CGFloat(region.rect.y - region.rect.w / 2),
            width: CGFloat(region.rect.z), height: CGFloat(region.rect.w))
          let sample = try interiorPixels(in: rect, from: pixels)
          rgb.append(sample.rgb)
          let mean = actualPixelMean(sample.rgb)
          bankMeans.append(mean)
          if value == 82 {
            let levels = stride(from: 0, to: sample.rgb.count, by: 3).map { offset in
              (0.2126 * Double(sample.rgb[offset]) + 0.7152 * Double(sample.rgb[offset + 1])
                + 0.0722 * Double(sample.rgb[offset + 2])) / 255
            }.sorted()
            XCTAssertGreaterThan(
              try XCTUnwrap(levels.last), mean.luminance + 0.10,
              "Every actual bank must have a localized bright core above its darker tile field")
            XCTAssertLessThan(try XCTUnwrap(levels.first), mean.luminance - 0.03)
          }
          receipts.append(
            "aggregate=\(value); region=\(Int(region.properties.y)); luminance=\(sample.luminance); samples=\(sample.rgb.count / 3)"
          )
        }
        perBankMeans.append(bankMeans)
        guard !rgb.isEmpty, rgb.count % 3 == 0 else {
          throw ComputePresentationFailure(
            "Actual mapped GPU pixels must contain complete RGB samples")
        }
        var sums = [Double](repeating: 0, count: 3)
        for offset in stride(from: 0, to: rgb.count, by: 3) {
          for channel in 0..<3 { sums[channel] += Double(rgb[offset + channel]) / 255 }
        }
        let count = Double(rgb.count / 3)
        let red = sums[0] / count
        let green = sums[1] / count
        let blue = sums[2] / count
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        means.append((red, green, blue, luminance))
        receipts.append(
          "aggregate=\(value); mean_red=\(red); mean_green=\(green); mean_blue=\(blue); mean_luminance=\(luminance)"
        )
        XCTAssertEqual(
          [
            ObjectIdentifier(try XCTUnwrap(resources.cpuMaterialTexture)),
            ObjectIdentifier(try XCTUnwrap(resources.gpuMaterialTexture)),
            ObjectIdentifier(try XCTUnwrap(resources.circuitBoardTexture)),
            ObjectIdentifier(try XCTUnwrap(resources.materialSampler)),
          ], identities)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(resources.circuitBoardImage)),
                       circuitBoardImageIdentity)
        try requireCompletedMetal(in: fixture)
      }
      retainText(
        receipts.joined(separator: "\n"),
        name: "compute-native-material-actual-pixel-hue-progression")
      XCTAssertEqual(means.count, 3)
      // The owner reference requires simultaneous spatial hues, replacing the
      // earlier uniform whole-chip mean-hue contract. Per-bank brightness still rises.
      XCTAssertEqual(perBankMeans.count, 3)
      for index in 0..<ComputeChipSnapshot.gpuRegionCount {
        XCTAssertGreaterThan(perBankMeans[1][index].luminance, perBankMeans[0][index].luminance)
        XCTAssertGreaterThan(perBankMeans[2][index].luminance, perBankMeans[1][index].luminance)
        let high = perBankMeans[2][index]
        if index == 1 || index == 5 {
          XCTAssertGreaterThan(high.blue, high.green)
          XCTAssertGreaterThan(high.green, high.red)
          XCTAssertGreaterThan(
            high.green - high.blue,
            perBankMeans[0][index].green - perBankMeans[0][index].blue)
        } else if index == 2 || index >= 8 {
          XCTAssertGreaterThan(high.blue, high.red)
          XCTAssertGreaterThan(high.red, high.green)
          XCTAssertGreaterThan(
            high.red - high.green,
            perBankMeans[0][index].red - perBankMeans[0][index].green)
        } else {
          XCTAssertGreaterThan(high.blue, high.green)
          XCTAssertGreaterThan(high.green, high.red)
        }
      }
      XCTAssertGreaterThan(means[1].luminance, means[0].luminance)
      XCTAssertGreaterThan(means[2].luminance, means[1].luminance)
      let cpuReference = try XCTUnwrap(unchangedCPU)
      XCTAssertEqual(cpuReference.count, 10)
      for (index, bytes) in cpuReference.enumerated() {
        let mean = actualPixelMean(bytes)
        if index < 4 {
          XCTAssertGreaterThan(mean.blue, mean.green)
          XCTAssertGreaterThan(mean.green, mean.red)
        } else {
          XCTAssertGreaterThan(mean.green, mean.blue)
          XCTAssertGreaterThan(mean.blue, mean.red)
        }
      }
      let geometryBefore = fixture.diagnostics.snapshot().geometryRebuilds
      fixture.window.setContentSize(NSSize(width: 1_100, height: 780))
      let resized = await waitUntil { abs(fixture.hostingView.bounds.width - 1_100) <= 0.5 }
      XCTAssertTrue(resized)
      guard resized else {
        throw ComputePresentationFailure("The actual native material fixture must resize")
      }
      fixture.model.snapshot = snapshot(cpu: Array(repeating: 85, count: 10), gpu: 82)
      _ = try await readback(from: fixture, name: "compute-native-material-resized")
      XCTAssertGreaterThan(fixture.diagnostics.snapshot().geometryRebuilds, geometryBefore)
      XCTAssertEqual(resources.materialTextureCount, 3)
      XCTAssertEqual(
        [
          ObjectIdentifier(try XCTUnwrap(resources.cpuMaterialTexture)),
          ObjectIdentifier(try XCTUnwrap(resources.gpuMaterialTexture)),
          ObjectIdentifier(try XCTUnwrap(resources.circuitBoardTexture)),
          ObjectIdentifier(try XCTUnwrap(resources.materialSampler)),
        ], identities)
      XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(resources.circuitBoardImage)),
                     circuitBoardImageIdentity)
      fixture.close()
      let detached = await waitUntil {
        let observation = fixture.diagnostics.snapshot()
        return observation.activeSurfaces == 0 && observation.ownedBuffers == 0
      }
      XCTAssertTrue(detached)
      guard detached else {
        throw ComputePresentationFailure(
          "Closing the native material fixture must detach its surface")
      }
      XCTAssertEqual(fixture.diagnostics.snapshot().ownedBuffers, 0)
      let reopened = try await mount(
        snapshot: snapshot(cpu: Array(repeating: 85, count: 10), gpu: 82))
      _ = try await readback(from: reopened, name: "compute-native-material-reopened")
      XCTAssertEqual(
        [
          ObjectIdentifier(try XCTUnwrap(resources.cpuMaterialTexture)),
          ObjectIdentifier(try XCTUnwrap(resources.gpuMaterialTexture)),
          ObjectIdentifier(try XCTUnwrap(resources.circuitBoardTexture)),
          ObjectIdentifier(try XCTUnwrap(resources.materialSampler)),
        ], identities)
      XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(resources.circuitBoardImage)),
                     circuitBoardImageIdentity)
      try requireCompletedMetal(in: reopened)
      retainText(
        "cpu_texture=\(identities[0]); gpu_texture=\(identities[1]); circuit_board_texture=\(identities[2]); sampler=\(identities[3]); immutable_material_count=3; immutable_sampler_count=1; uploaded_chip_mip_levels=9; uploaded_board_mip_levels=\(circuitBoardTexture.mipmapLevelCount); material_gpu_allocation_bytes=\(cpuTexture.allocatedSize + gpuTexture.allocatedSize + circuitBoardTexture.allocatedSize); decoded_material_raster_bytes=\(cpuImage.bytesPerRow * cpuImage.height + gpuImage.bytesPerRow * gpuImage.height + circuitBoardImage.bytesPerRow * circuitBoardImage.height); resource_identities_unchanged_after_values_resize_and_reopen=true",
        name: "compute-native-material-shared-resource-ownership")
    }

    func testWholeComponentNativeFixtureStatesPreserveNamesQualityAndIndependentFreshness()
      async throws
    {
      let fixture = try await mount(snapshot: snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: 0))
      let cases:
        [(
          name: String, quality: CPUSampleQuality, values: [Double], gpu: Double?, gpuAge: Double,
          cpuName: String, gpuName: String, cpuState: String, gpuState: String, provenance: String,
          expectedCPUName: String?, expectedGPUName: String?
        )] = [
          (
            "idle", .perLogicalProcessor, [0, 0, 0, 0, 0, 0], 0, 0, "Synthetic CPU",
            "Synthetic GPU", "Idle", "Idle",
            "CPU: logical-processor activity", nil, nil
          ),
          (
            "equal-measured", .perLogicalProcessor, [22, 22, 22, 22, 22, 22], 12, 0,
            "Synthetic CPU", "Synthetic GPU", "Active",
            "Active", "CPU: logical-processor activity", nil, nil
          ),
          (
            "aggregate-fallback", .hostAggregateFallback, [22, 22, 22, 22, 22, 22], 12, 0,
            "Synthetic CPU", "Synthetic GPU",
            "Aggregate · Active", "Active", "host aggregate fallback; regions illustrative", nil,
            nil
          ),
          (
            "warming", .warmingUp, [0, 0, 0, 0, 0, 0], 0, 0, "Synthetic CPU", "Synthetic GPU",
            "Warming up", "Idle",
            "measurement warming up", nil, nil
          ),
          (
            "gpu-missing", .perLogicalProcessor, [22, 0, 0, 0, 0, 0], nil, 0, "Synthetic CPU",
            "Synthetic GPU", "Active",
            "Activity unavailable", "CPU: logical-processor activity", nil, nil
          ),
          (
            "gpu-stale-cpu-fresh", .perLogicalProcessor, [22, 0, 0, 0, 0, 0], 82, 20,
            "Synthetic CPU", "Synthetic GPU", "Active",
            "Stale activity", "CPU: logical-processor activity", nil, nil
          ),
          (
            "unknown-quality", .unknown, [0, 0, 0, 0, 0, 0], nil, 0, "Synthetic CPU",
            "Synthetic GPU", "Provenance unavailable",
            "Activity unavailable", "CPU: provenance unavailable", nil, nil
          ),
          (
            "long-names", .perLogicalProcessor, [22, 0, 0, 0, 0, 0], 12, 0,
            "Apple M99 Ultra — Synthetic Engineering Sample, extended local CPU variant",
            "External Graphics Test Device — Synthetic extended GPU variant",
            "Active", "Active", "CPU: logical-processor activity", nil, nil
          ),
          (
            "raw-model-identity", .perLogicalProcessor, [22, 0, 0, 0, 0, 0], 12, 0,
            "Mac16,13", "Synthetic GPU", "Active", "Active", "CPU: logical-processor activity", nil,
            nil
          ),
          (
            "empty-identities", .perLogicalProcessor, [22, 0, 0, 0, 0, 0], 12, 0,
            "", "", "Active", "Active", "CPU: logical-processor activity",
            "CPU identity unavailable", "GPU identity unavailable"
          ),
          (
            "whitespace-identities", .perLogicalProcessor, [22, 0, 0, 0, 0, 0], 12, 0,
            " \n\t ", " \n\t ", "Active", "Active", "CPU: logical-processor activity",
            "CPU identity unavailable", "GPU identity unavailable"
          ),
        ]
      for item in cases {
        fixture.model.snapshot = snapshot(
          cpu: item.values, gpu: item.gpu, quality: item.quality,
          gpuAge: item.gpuAge, cpuName: item.cpuName, gpuName: item.gpuName)
        try await requireState(item.cpuState, id: "compute-cpu-activity-state", in: fixture)
        try await requireState(item.gpuState, id: "compute-gpu-activity-state", in: fixture)
        try await requireState(
          item.expectedCPUName ?? item.cpuName, id: "compute-cpu-hardware-name", in: fixture)
        try await requireState(
          item.expectedGPUName ?? item.gpuName, id: "compute-gpu-hardware-name", in: fixture)
        let cpuName = try await semanticValue("compute-cpu-hardware-name", in: fixture)
        let gpuName = try await semanticValue("compute-gpu-hardware-name", in: fixture)
        let provenance = try await semanticValue("compute-activity-provenance", in: fixture)
        let rendererStatus = try await semanticValue("compute-renderer-status", in: fixture)
        XCTAssertEqual(cpuName, item.expectedCPUName ?? item.cpuName)
        XCTAssertEqual(gpuName, item.expectedGPUName ?? item.gpuName)
        XCTAssertTrue(provenance.contains(item.provenance))
        XCTAssertEqual(rendererStatus, "Metal · motion reduced")
        try await requireNativeLabelContainment(in: fixture)
        try await retainNativeViewAndSemantics(fixture, name: "compute-native-fixture-\(item.name)")
        _ = try await readback(from: fixture, name: "compute-native-fixture-\(item.name)-metal")
      }
      try requireCompletedMetal(in: fixture)
      XCTAssertEqual(
        fixture.diagnostics.snapshot().activeClocks, 0,
        "Reduced-motion fixtures must preserve static activity without a recurring clock")
    }

    func testWholeComponentGenuineMetalFailureRetainsStaticNativeStructureAndTruthfulStatus()
      async throws
    {
      let resources = ComputeChipResources(
        device: nil, commandQueue: nil, library: nil,
        libraryOrigin: "", devices: [])
      let circuitBoardImage = try XCTUnwrap(resources.circuitBoardImage)
      XCTAssertGreaterThan(circuitBoardImage.width, 0)
      XCTAssertEqual(circuitBoardImage.width, circuitBoardImage.height)
      XCTAssertNil(resources.circuitBoardTexture)
      XCTAssertEqual(resources.materialTextureCount, 0)
      let fixture = try await mount(
        snapshot: snapshot(cpu: [22, 0, 0, 0, 0, 0], gpu: nil),
        resources: resources, requireMetal: false)
      try await requireState(
        "Static chip view · Metal device unavailable", id: "compute-renderer-status", in: fixture)
      let cpuName = try await semanticValue("compute-cpu-hardware-name", in: fixture)
      let gpuName = try await semanticValue("compute-gpu-hardware-name", in: fixture)
      XCTAssertEqual(cpuName, "Synthetic CPU")
      XCTAssertEqual(gpuName, "Synthetic GPU")
      XCTAssertTrue(fixture.metalViews.isEmpty)
      XCTAssertEqual(fixture.diagnostics.snapshot().submissions, 0)
      XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
      try await requireNativeLabelContainment(in: fixture)
      try await requireState(
        "Activity unavailable", id: "compute-gpu-activity-state", in: fixture)
      let geometryReady = await waitUntil { fixture.model.componentFrame.width > 0 }
      XCTAssertTrue(geometryReady)
      guard geometryReady else {
        throw ComputePresentationFailure("The production component must expose its actual geometry")
      }
      let componentFrame = fixture.model.componentFrame
      let missing = try await retainNativeViewAndSemantics(
        fixture, name: "compute-native-fixture-metal-unavailable")
      fixture.model.snapshot = snapshot(cpu: [22, 0, 0, 0, 0, 0], gpu: 0)
      try await requireState("Idle", id: "compute-gpu-activity-state", in: fixture)
      let idle = try await retainNativeViewAndSemantics(
        fixture, name: "compute-native-fixture-metal-unavailable-measured-idle")
      XCTAssertEqual(fixture.model.componentFrame, componentFrame)
      let layout = ComputeChipLayout.make(
        width: componentFrame.width, cpuRegionCount: fixture.model.snapshot.cpu.activity.count)
      try requireNativeFallbackMaterialStructure(
        layout: layout, resources: resources, componentFrame: componentFrame,
        bitmap: missing, fixture: fixture)
      let scaleX = CGFloat(missing.pixelsWide) / fixture.hostingView.bounds.width
      let scaleY = CGFloat(missing.pixelsHigh) / fixture.hostingView.bounds.height
      try requireCircuitBoardMaterialPixels(
        layout: layout, resources: resources, classification: "actual native fallback Canvas cache"
      ) { point in
        let x = Int(((componentFrame.minX + point.x) * scaleX).rounded(.down))
        let y = Int(((componentFrame.minY + point.y) * scaleY).rounded(.down))
        guard x >= 0, y >= 0, x < missing.pixelsWide, y < missing.pixelsHigh else {
          throw ComputePresentationFailure("A circuit-board sample must be inside its native cache")
        }
        return try XCTUnwrap(missing.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      }
      // Canonical mapped region order is part of the current material-layout contract.
      var mappedGPURegionIDs: Set<Int> = []
      let regions = layout.instances.filter { instance in
        let id = Int(instance.properties.y)
        return Int(instance.properties.x) == 4 && id >= 256
          && id < 256 + ComputeChipSnapshot.gpuRegionCount
          && mappedGPURegionIDs.insert(id).inserted
      }
      XCTAssertEqual(regions.count, ComputeChipSnapshot.gpuRegionCount)
      XCTAssertEqual(
        regions.map { Int($0.properties.y) },
        Array(256..<(256 + ComputeChipSnapshot.gpuRegionCount)))
      retainText(
        "component_frame=\(NSStringFromRect(componentFrame)); hosting_bounds=\(NSStringFromRect(fixture.hostingView.bounds)); native_cache=\(missing.pixelsWide)x\(missing.pixelsHigh); canonical_mapped_region_rects=\(regions.map { String(describing: $0.rect) })",
        name: "compute-native-static-fallback-region-geometry")
      var measurements: [String] = []
      var comparisons: [(Data, Data)] = []
      for region in regions {
        let rect = CGRect(
          x: CGFloat(region.rect.x - region.rect.z / 2),
          y: CGFloat(region.rect.y - region.rect.w / 2),
          width: CGFloat(region.rect.z), height: CGFloat(region.rect.w))
        let unavailable = try nativeCachedInteriorPixels(
          in: rect, componentFrame: componentFrame, bitmap: missing, fixture: fixture)
        let measured = try nativeCachedInteriorPixels(
          in: rect, componentFrame: componentFrame, bitmap: idle, fixture: fixture)
        measurements.append(
          "illustrative_region=\(Int(region.properties.y) - 256); unavailable_luminance=\(unavailable.luminance); measured_idle_luminance=\(measured.luminance); samples=\(unavailable.rgb.count / 3)"
        )
        XCTAssertLessThan(
          measured.luminance, 0.16,
          "The genuine static fallback must not emit activity for measured zero")
        let idleMean = actualPixelMean(measured.rgb)
        XCTAssertLessThan(
          max(idleMean.red, max(idleMean.green, idleMean.blue))
            - min(idleMean.red, min(idleMean.green, idleMean.blue)), 0.10)
        comparisons.append((unavailable.rgb, measured.rgb))
      }
      retainText(
        "classification=actual production Canvas inside public native NSView cache; no alternate drawing\ncomponent_frame=\(NSStringFromRect(componentFrame)); GPU nil then measured zero\n"
          + measurements.joined(separator: "\n"),
        name: "compute-native-static-fallback-unavailable-idle-pixel-comparison")
      for comparison in comparisons {
        XCTAssertNotEqual(
          comparison.0, comparison.1,
          "Every actual fallback GPU region must distinguish unavailable activity from measured idle"
        )
      }
      XCTAssertTrue(fixture.metalViews.isEmpty)
      XCTAssertEqual(fixture.diagnostics.snapshot().submissions, 0)
      XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
    }

    func testMountedMetalToStaticFallbackUsesCurrentActivityAndPauseLabels() async throws {
      let fixture = try await mount(snapshot: snapshot(cpu: [22, 0, 0, 0, 0, 0], gpu: 12))
      try await requireState("Active", id: "compute-cpu-activity-state", in: fixture)
      try await requireState("Active", id: "compute-gpu-activity-state", in: fixture)
      try requireCompletedMetal(in: fixture)

      // Keep the mounted component identity and its published renderer presentation.
      fixture.model.resources = ComputeChipResources(
        device: nil, commandQueue: nil, library: nil, libraryOrigin: "", devices: [])
      try await requireState(
        "Static chip view · Metal device unavailable", id: "compute-renderer-status", in: fixture)
      let detached = await waitUntil {
        fixture.metalViews.isEmpty && fixture.diagnostics.snapshot().activeSurfaces == 0
          && fixture.diagnostics.snapshot().inFlightSlots == 0
          && fixture.diagnostics.snapshot().ownedBuffers == 0
      }
      XCTAssertTrue(detached, "Changing capability must detach the previous production renderer")
      guard detached else {
        throw ComputePresentationFailure("The previous Metal surface did not detach")
      }
      let submissions = fixture.diagnostics.snapshot().submissions

      fixture.model.snapshot = snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: 0)
      try await requireState("Idle", id: "compute-cpu-activity-state", in: fixture)
      try await requireState("Idle", id: "compute-gpu-activity-state", in: fixture)
      try await retainNativeViewAndSemantics(fixture, name: "compute-fallback-transition-idle")

      fixture.model.snapshot = snapshot(cpu: [0, 0, 0, 0, 0, 0], gpu: nil, quality: .unavailable)
      try await requireState("Activity unavailable", id: "compute-cpu-activity-state", in: fixture)
      try await requireState("Activity unavailable", id: "compute-gpu-activity-state", in: fixture)
      try await retainNativeViewAndSemantics(fixture, name: "compute-fallback-transition-unavailable")

      fixture.model.autoRefresh = false
      try await requireState("Paused", id: "compute-cpu-activity-state", in: fixture)
      try await requireState("Paused", id: "compute-gpu-activity-state", in: fixture)
      try await retainNativeViewAndSemantics(fixture, name: "compute-fallback-transition-paused")

      fixture.model.autoRefresh = true
      fixture.model.snapshot = snapshot(cpu: [22, 0, 0, 0, 0, 0], gpu: 82, gpuAge: 20)
      try await requireState("Active", id: "compute-cpu-activity-state", in: fixture)
      try await requireState("Stale activity", id: "compute-gpu-activity-state", in: fixture)
      XCTAssertTrue(fixture.metalViews.isEmpty)
      XCTAssertEqual(fixture.diagnostics.snapshot().submissions, submissions)
      XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
    }

    private func actualPixelMean(_ rgb: Data) -> (
      red: Double, green: Double, blue: Double, luminance: Double
    ) {
      XCTAssertGreaterThan(rgb.count, 0)
      XCTAssertEqual(rgb.count % 3, 0)
      var sums = [Double](repeating: 0, count: 3)
      for offset in stride(from: 0, to: rgb.count, by: 3) {
        for channel in 0..<3 { sums[channel] += Double(rgb[offset + channel]) / 255 }
      }
      let count = Double(max(rgb.count / 3, 1))
      let r = sums[0] / count
      let g = sums[1] / count
      let b = sums[2] / count
      return (r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }

    private func requireCircuitBoardBackgroundDarkening(_ processed: CGImage) throws {
      let url = try XCTUnwrap(ComputeChipResources.assetBundle.url(
        forResource: "ComputeCircuitBoard", withExtension: "png"))
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
      let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(processed.width, original.width)
      XCTAssertEqual(processed.height, original.height)
      let originalBitmap = NSBitmapImageRep(cgImage: original)
      let processedBitmap = NSBitmapImageRep(cgImage: processed)
      var originalLuminance = 0.0
      var processedLuminance = 0.0
      func luminance(_ color: NSColor) -> Double {
        0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent)
          + 0.0722 * Double(color.blueComponent)
      }
      for row in 0..<32 {
        for column in 0..<32 {
          let x = min(original.width - 1, Int((Double(column) + 0.5) / 32 * Double(original.width)))
          let y = min(original.height - 1, Int((Double(row) + 0.5) / 32 * Double(original.height)))
          originalLuminance += luminance(try XCTUnwrap(
            originalBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))) / 1_024
          processedLuminance += luminance(try XCTUnwrap(
            processedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))) / 1_024
        }
      }
      XCTAssertGreaterThan(originalLuminance, 0)
      XCTAssertLessThan(processedLuminance, originalLuminance * 0.40,
                        "The shared PCB raster must be distinctly darker than the bundled source")
      XCTAssertGreaterThan(processedLuminance, originalLuminance * 0.20,
                           "Darkening must preserve circuit-board detail")
      XCTAssertEqual(processedLuminance, originalLuminance * 0.32, accuracy: 1.0 / 255 + 0.001)
      retainText("bounded_samples=1024; source_mean_srgb_luminance=\(originalLuminance); shared_processed_mean_srgb_luminance=\(processedLuminance); black_overlay_alpha=0.68; same_processed_image_used_by_metal_and_static_fallback=true",
                 name: "compute-native-circuit-board-background-contrast")
    }

    private func requireReferenceMaterialPreservation(cpu: CGImage, gpu: CGImage) throws {
      let url = try XCTUnwrap(
        ComputeChipResources.assetBundle.url(
          forResource: "ComputeChipReference", withExtension: "png"))
      let bytes = try Data(contentsOf: url)
      XCTAssertEqual(
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        "7184bbb39a6b014b32283869557edb6166acecd1bc8f201401ceda02169975f1")
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(image.width, 1_448)
      XCTAssertEqual(image.height, 1_086)
      let reference = NSBitmapImageRep(cgImage: image)
      var receipts: [String] = []
      // The exact source's GPU banks 1 and 5 are blue/cyan. Its green mint
      // regions belong to the CPU, so GPU activity must preserve B > G > R.
      for (bank, rect, expected) in [
        (1, CGRect(x: 1002, y: 410, width: 49, height: 73), [0.1528, 0.3281, 0.5573]),
        (5, CGRect(x: 1002, y: 497, width: 49, height: 82), [0.0227, 0.3352, 0.6412]),
      ] {
        var sums = [Double](repeating: 0, count: 3)
        for y in Int(rect.minY)..<Int(rect.maxY) {
          for x in Int(rect.minX)..<Int(rect.maxX) {
            var pixel = [UInt](repeating: 0, count: reference.samplesPerPixel)
            reference.getPixel(&pixel, atX: x, y: y)
            for channel in 0..<3 { sums[channel] += Double(pixel[channel]) / 255 }
          }
        }
        let mean = sums.map { $0 / Double(rect.width * rect.height) }
        XCTAssertGreaterThan(mean[2], mean[1])
        XCTAssertGreaterThan(mean[1], mean[0])
        for channel in 0..<3 { XCTAssertEqual(mean[channel], expected[channel], accuracy: 0.01) }
        receipts.append(
          "original_reference_gpu_bank=\(bank); source_roi=\(NSStringFromRect(rect)); mean_raw_rgb=\(mean); family=blue_cyan"
        )
      }
      for (isCPU, prepared, dimension) in [(true, cpu, 440), (false, gpu, 464)] {
        XCTAssertEqual(prepared.width, dimension)
        XCTAssertEqual(prepared.height, dimension)
        let crop =
          isCPU ? ComputeChipReferenceGeometry.cpuCrop : ComputeChipReferenceGeometry.gpuCrop
        let banks =
          isCPU ? ComputeChipReferenceGeometry.cpuBanks : ComputeChipReferenceGeometry.gpuBanks
        let plate =
          isCPU
          ? ComputeChipReferenceGeometry.cpuPlateInterior
          : ComputeChipReferenceGeometry.gpuPlateInterior
        let auxiliary = isCPU ? [] : ComputeChipReferenceGeometry.gpuAuxiliaryLightMasks
        let lines =
          isCPU
          ? ComputeChipReferenceGeometry.cpuLeaderLines
          : ComputeChipReferenceGeometry.gpuLeaderLines
        let bitmap = NSBitmapImageRep(cgImage: prepared)
        var preserved = 0
        for y in stride(from: 0, to: dimension, by: 5) {
          for x in stride(from: 0, to: dimension, by: 5) {
            let point = CGPoint(x: crop.minX + CGFloat(x) + 0.5, y: crop.minY + CGFloat(y) + 0.5)
            guard !plate.contains(point),
              !(banks + auxiliary).contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) })
            else { continue }
            let repaired = lines.contains { line in
              zip(line, line.dropFirst()).contains { start, end in
                let dx = end.x - start.x
                let dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                let t = min(
                  max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
                return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= 2
              }
            }
            guard !repaired else { continue }
            let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            guard actual.alphaComponent > 0.99 else { continue }
            let expected = try XCTUnwrap(
              reference.colorAt(
                x: Int(crop.minX) + x,
                y: Int(crop.minY) + y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
            var rawActual = [UInt](repeating: 0, count: bitmap.samplesPerPixel)
            var rawExpected = [UInt](repeating: 0, count: reference.samplesPerPixel)
            bitmap.getPixel(&rawActual, atX: x, y: y)
            reference.getPixel(&rawExpected, atX: Int(crop.minX) + x, y: Int(crop.minY) + y)
            for channel in 0..<3 {
              XCTAssertEqual(Double(rawActual[channel]), Double(rawExpected[channel]), accuracy: 1)
            }
            preserved += 1
          }
        }
        XCTAssertGreaterThan(preserved, 1_000)
        let sentinels: [CGPoint] =
          isCPU
          ? [.init(x: 247, y: 350), .init(x: 236, y: 686), .init(x: 593, y: 640)]
          : [.init(x: 890, y: 340), .init(x: 1254, y: 744), .init(x: 1279, y: 707)]
        for point in sentinels {
          let actual = try XCTUnwrap(
            bitmap.colorAt(x: Int(point.x - crop.minX), y: Int(point.y - crop.minY))?
              .usingColorSpace(.sRGB))
          let expected = try XCTUnwrap(
            reference.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
          XCTAssertGreaterThan(actual.alphaComponent, 0.99)
          XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
          XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
          XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
        }
        let exteriorContacts: [CGPoint] =
          isCPU
          ? [.init(x: 593, y: 475)]
          : [.init(x: 1279, y: 443), .init(x: 1279, y: 420)]
        for point in exteriorContacts {
          XCTAssertEqual(
            try XCTUnwrap(
              bitmap.colorAt(
                x: Int(point.x - crop.minX),
                y: Int(point.y - crop.minY))
            ).alphaComponent, 0,
            "Asymmetric reference contacts must not be reflected onto exterior package pixels")
        }
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
        if !isCPU {
          for point in [CGPoint(x: 1057, y: 355), CGPoint(x: 1057, y: 768)] {
            XCTAssertGreaterThan(
              try XCTUnwrap(
                bitmap.colorAt(x: Int(point.x - crop.minX), y: Int(point.y - crop.minY))
              ).alphaComponent, 0.99,
              "The reference GPU must keep its continuous top and bottom center bridges")
          }
        }
        receipts.append(
          "channel=\(isCPU ? "CPU" : "GPU"); original_crop=\(NSStringFromRect(crop)); prepared=\(dimension)x\(dimension); unedited_opaque_rgb_samples=\(preserved); source_orientation_and_contact_sentinels_preserved=true"
        )
      }
      XCTAssertEqual(cpu.bytesPerRow * cpu.height + gpu.bytesPerRow * gpu.height, 1_635_584)
      retainText(
        receipts.joined(separator: "\n"),
        name: "compute-native-exact-reference-material-preservation")
    }

    private func requireCircuitBoardMaterialPixels(
      layout: ComputeChipLayout, resources: ComputeChipResources, classification: String,
      colorAt: (CGPoint) throws -> NSColor
    ) throws {
      let image = try XCTUnwrap(resources.circuitBoardImage)
      let reference = NSBitmapImageRep(cgImage: image)
      let excluded = layout.instances.filter { [Float(5), 6, 10, 11].contains($0.properties.x) }
        .map { instance -> CGRect in
          let cosine = abs(cos(CGFloat(instance.properties.w)))
          let sine = abs(sin(CGFloat(instance.properties.w)))
          let width = CGFloat(instance.rect.z) * cosine + CGFloat(instance.rect.w) * sine
          let height = CGFloat(instance.rect.z) * sine + CGFloat(instance.rect.w) * cosine
          return CGRect(x: CGFloat(instance.rect.x) - width / 2,
                        y: CGFloat(instance.rect.y) - height / 2,
                        width: width, height: height).insetBy(dx: -3, dy: -3)
        }
      func luminance(_ color: NSColor) -> Double {
        0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent)
          + 0.0722 * Double(color.blueComponent)
      }
      var receipts: [String] = []
      for (channel, board) in [("CPU", layout.cpuBoard), ("GPU", layout.gpuBoard)] {
        var errors: [Double] = []
        var visible = 0
        for row in 0..<32 {
          for column in 0..<32 {
            let u = (CGFloat(column) + 0.5) / 32
            let v = (CGFloat(row) + 0.5) / 32
            let point = CGPoint(x: board.minX + u * board.width, y: board.minY + v * board.height)
            guard board.insetBy(dx: 12, dy: 12).contains(point),
              !excluded.contains(where: { $0.contains(point) }) else { continue }
            // Average the source footprint instead of selecting one bright source pixel
            // that can disappear when the immutable mipmapped material is minified.
            var expected = 0.0
            for y in -2...2 {
              for x in -2...2 {
                let sourceX = min(image.width - 1, max(0, Int(
                  (u + CGFloat(x) * 0.25 / board.width) * CGFloat(image.width))))
                let sourceY = min(image.height - 1, max(0, Int(
                  (v + CGFloat(y) * 0.25 / board.height) * CGFloat(image.height))))
                expected += luminance(try XCTUnwrap(
                  reference.colorAt(x: sourceX, y: sourceY)?.usingColorSpace(.sRGB))) / 25
              }
            }
            guard expected > 0.08 else { continue }
            let actual = luminance(try colorAt(point))
            errors.append(abs(actual - expected))
            if actual > 0.04 { visible += 1 }
          }
        }
        let visibleFraction = Double(visible) / Double(max(errors.count, 1))
        let meanError = errors.reduce(0, +) / Double(max(errors.count, 1))
        XCTAssertGreaterThanOrEqual(errors.count, 8, "Each board must expose sampled source detail outside its chip and live traces")
        XCTAssertGreaterThanOrEqual(visibleFraction, 0.60, "Bundled circuit-board detail must appear in actual native pixels")
        XCTAssertLessThan(meanError, 0.12, "Rendered board samples must follow the shared source material")
        receipts.append("channel=\(channel); board=\(NSStringFromRect(board)); source_selected_samples=\(errors.count); visible_fraction=\(visibleFraction); mean_srgb_luminance_error=\(meanError)")
      }
      retainText("classification=\(classification); bounded source-correlated samples exclude chip, shadow, decorative trace segments, endpoints and border\n" + receipts.joined(separator: "\n"),
                 name: "compute-native-circuit-board-material-pixels")
    }

    private func requireNativeFallbackMaterialStructure(
      layout: ComputeChipLayout, resources: ComputeChipResources, componentFrame: CGRect,
      bitmap: NSBitmapImageRep, fixture: ComputePresentationWindow
    ) throws {
      let scaleX = CGFloat(bitmap.pixelsWide) / fixture.hostingView.bounds.width
      let scaleY = CGFloat(bitmap.pixelsHigh) / fixture.hostingView.bounds.height
      XCTAssertEqual(scaleX, scaleY, accuracy: 0.02)
      let materials = [
        ("CPU", try XCTUnwrap(resources.cpuMaterialImage), layout.cpuPackage, layout.cpuNameplate),
        ("GPU", try XCTUnwrap(resources.gpuMaterialImage), layout.gpuPackage, layout.gpuNameplate),
      ]
      let activity = layout.instances.filter { Int($0.properties.x) == 4 }.map { instance in
        CGRect(
          x: CGFloat(instance.rect.x - instance.rect.z / 2),
          y: CGFloat(instance.rect.y - instance.rect.w / 2),
          width: CGFloat(instance.rect.z), height: CGFloat(instance.rect.w))
      }
      var receipts: [String] = []
      for (name, image, package, nameplate) in materials {
        let reference = NSBitmapImageRep(cgImage: image)
        var steelLuminance: [Double] = []
        var pinWarmth: [Double] = []
        // Bounded reference-asset sampling excludes every activity region and label. This
        // checks the actual native Canvas contains the detailed material, not just its FX.
        for row in 0..<64 {
          for column in 0..<64 {
            let u = (CGFloat(column) + 0.5) / 64
            let v = (CGFloat(row) + 0.5) / 64
            let point = CGPoint(
              x: package.minX + u * package.width,
              y: package.minY + v * package.height)
            guard !nameplate.insetBy(dx: -2, dy: -2).contains(point),
              !activity.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) })
            else { continue }
            let source = try XCTUnwrap(
              reference.colorAt(
                x: min(image.width - 1, Int(u * CGFloat(image.width))),
                y: min(image.height - 1, Int(v * CGFloat(image.height))))?.usingColorSpace(.sRGB))
            guard source.alphaComponent > 0.98 else { continue }
            let r = Double(source.redComponent)
            let g = Double(source.greenComponent)
            let b = Double(source.blueComponent)
            let referenceLuminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let steel =
              referenceLuminance >= 0.18
              && max(r, max(g, b)) - min(r, min(g, b)) <= 0.12
            let pin = referenceLuminance >= 0.18 && r > b + 0.10 && g > b + 0.08
            guard steel || pin else { continue }
            let x = Int(((componentFrame.minX + point.x) * scaleX).rounded(.down))
            let y = Int(((componentFrame.minY + point.y) * scaleY).rounded(.down))
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else {
              throw ComputePresentationFailure(
                "Every actual fallback material sample must be inside its native cache")
            }
            let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let actualLuminance =
              0.2126 * Double(actual.redComponent)
              + 0.7152 * Double(actual.greenComponent) + 0.0722 * Double(actual.blueComponent)
            if steel { steelLuminance.append(actualLuminance) }
            if pin { pinWarmth.append(Double(actual.redComponent - actual.blueComponent)) }
          }
        }
        receipts.append(
          "channel=\(name); reference_image=\(image.width)x\(image.height); package=\(NSStringFromRect(package)); steel_samples=\(steelLuminance.count); steel_mean_luminance=\(steelLuminance.reduce(0, +) / Double(max(steelLuminance.count, 1))); steel_visible_fraction=\(Double(steelLuminance.filter { $0 > 0.12 }.count) / Double(max(steelLuminance.count, 1))); pin_samples=\(pinWarmth.count); pin_mean_red_minus_blue=\(pinWarmth.reduce(0, +) / Double(max(pinWarmth.count, 1)))"
        )
        XCTAssertGreaterThanOrEqual(steelLuminance.count, 20)
        XCTAssertGreaterThanOrEqual(pinWarmth.count, 4)
        XCTAssertGreaterThan(
          steelLuminance.reduce(0, +) / Double(max(steelLuminance.count, 1)), 0.10)
        XCTAssertGreaterThanOrEqual(
          Double(steelLuminance.filter { $0 > 0.12 }.count) / Double(max(steelLuminance.count, 1)),
          0.60,
          "Steel material must remain visible outside the activity rectangles")
        XCTAssertGreaterThan(
          pinWarmth.reduce(0, +) / Double(max(pinWarmth.count, 1)), 0.03,
          "Gold package pins must appear in the genuine native fallback cache")
      }
      retainText(
        "classification=actual native fallback Canvas material pixels; reference assets select bounded opaque steel/pin locations outside all activity/label rectangles\n"
          + receipts.joined(separator: "\n"),
        name: "compute-native-static-fallback-steel-and-pins")
    }

    func testControlledNativeAccessibilityCapabilitiesPreserveInputsActionsAndMetalOutput()
      async throws
    {
      let preferences = actualAccessibilityPreferences()
      let fixture = try await mount(snapshot: snapshot(cpu: [22, 0, 0, 0, 0, 0], gpu: 12))
      fixture.model.showsInteractionFixtures = true
      let modes: [(String, GraphiteAccessibilityCapabilities)] = [
        ("normal", .init()),
        ("contrast", .init(increaseContrast: true)),
        ("transparency", .init(reduceTransparency: true)),
        ("combined", .init(increaseContrast: true, reduceTransparency: true)),
      ]
      var normalGPU: (rgb: Data, luminance: Double)?
      var normalExecution: ComputeChipRendererObservation?
      for (index, mode) in modes.enumerated() {
        fixture.model.capabilities = mode.1
        fixture.model.snapshot = snapshot(cpu: [22, 0, 0, 0, 0, 0], gpu: 12)
        await allowNativeEvents(for: 0.02)
        try await requireState("Active", id: "compute-cpu-activity-state", in: fixture)
        try await requireState("Active", id: "compute-gpu-activity-state", in: fixture)
        try await requireState("Metal · motion reduced", id: "compute-renderer-status", in: fixture)
        let controlIDs = [
          "compute-fixture-field", "compute-fixture-primary", "compute-fixture-destructive",
          "compute-fixture-disabled",
        ]
        let rowReady = await waitForNativeControls(controlIDs, in: fixture)
        retainText(
          try semanticsJSON(fixture), name: "compute-native-capability-\(mode.0)-controls-ready")
        XCTAssertTrue(rowReady, "Every actual native interaction control must finish mounting")
        guard rowReady else {
          throw ComputePresentationFailure("The native capability interaction row did not mount")
        }
        let controls = await semanticObservations(in: fixture)
        try requireCompleteAccessibilityReport(fixture.lastAccessibilityReport)
        let field = try XCTUnwrap(controls.filter { $0.id == "compute-fixture-field" }.only)
        XCTAssertEqual(field.role, kAXTextFieldRole)
        XCTAssertEqual(field.value, "Native fixture field")
        XCTAssertEqual(field.enabled, true)
        let primary = try XCTUnwrap(controls.filter { $0.id == "compute-fixture-primary" }.only)
        let destructive = try XCTUnwrap(
          controls.filter { $0.id == "compute-fixture-destructive" }.only)
        let disabled = try XCTUnwrap(controls.filter { $0.id == "compute-fixture-disabled" }.only)
        for control in [primary, destructive, disabled] {
          XCTAssertEqual(control.role, kAXButtonRole)
        }
        XCTAssertEqual(primary.enabled, true)
        XCTAssertEqual(destructive.enabled, true)
        XCTAssertEqual(disabled.enabled, false)
        let panel = try XCTUnwrap(controls.filter { $0.id == "rig-compute-cores-panel" }.only)
        let window = try XCTUnwrap(controls.filter { $0.role == kAXWindowRole }.only)
        XCTAssertTrue(window.frame.insetBy(dx: -2, dy: -2).contains(panel.frame))
        for control in [field, primary, destructive, disabled] {
          XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(control.frame))
          XCTAssertGreaterThan(control.frame.width, 0)
          XCTAssertGreaterThan(control.frame.height, 0)
        }
        try accessibilityProbe.focus(id: field.id)
        let focused = await waitForNativeFocus(id: field.id, in: fixture)
        XCTAssertTrue(focused)
        guard focused else {
          throw ComputePresentationFailure("The actual native fixture field did not receive focus")
        }
        try accessibilityProbe.press(id: primary.id)
        try accessibilityProbe.press(id: destructive.id)
        let dispatched = await waitUntil {
          fixture.model.primaryInvocations == index + 1
            && fixture.model.destructiveInvocations == index + 1
        }
        XCTAssertTrue(dispatched, "Capability flags must preserve native action dispatch")
        guard dispatched else {
          throw ComputePresentationFailure("The native capability fixture actions did not dispatch")
        }
        XCTAssertEqual(fixture.model.disabledInvocations, 0)
        try await requireNativeLabelContainment(in: fixture)
        try accessibilityProbe.focus(id: field.id)
        let focusBeforeCapture = await waitForNativeFocus(id: field.id, in: fixture)
        XCTAssertTrue(focusBeforeCapture)
        guard focusBeforeCapture else {
          throw ComputePresentationFailure("The native field must retain focus for its capture")
        }
        let nativeView = try await retainNativeViewAndSemantics(
          fixture, name: "compute-native-capability-\(mode.0)")
        let samples = try nativeSurfaceSamples(
          nativeView, controls: [field, primary, destructive, disabled], fixture: fixture)
        let pixels = try await readback(
          from: fixture, name: "compute-native-capability-\(mode.0)-metal")
        let layout = try XCTUnwrap(fixture.metalViews.only?.renderer?.layout)
        let firstGPU = try XCTUnwrap(
          layout.instances.first { Int($0.properties.x) == 4 && Int($0.properties.y) == 256 })
        let region = CGRect(
          x: CGFloat(firstGPU.rect.x - firstGPU.rect.z / 2),
          y: CGFloat(firstGPU.rect.y - firstGPU.rect.w / 2),
          width: CGFloat(firstGPU.rect.z), height: CGFloat(firstGPU.rect.w))
        let gpu = try interiorPixels(in: region, from: pixels)
        let execution = fixture.diagnostics.snapshot()
        if let normalExecution {
          XCTAssertEqual(execution.geometryRebuilds, normalExecution.geometryRebuilds)
          XCTAssertEqual(execution.ownedBuffers, normalExecution.ownedBuffers)
          XCTAssertEqual(execution.activeSurfaces, 1)
        } else {
          normalExecution = execution
        }
        if let normalGPU {
          if mode.1.increaseContrast {
            XCTAssertGreaterThanOrEqual(gpu.luminance, normalGPU.luminance)
            if preferences["increase_contrast"] == false {
              XCTAssertGreaterThan(gpu.luminance, normalGPU.luminance + 0.01)
            }
          } else {
            XCTAssertEqual(gpu.rgb, normalGPU.rgb)
          }
        } else {
          normalGPU = gpu
        }
        XCTAssertEqual(execution.activeClocks, 0)
        let appearance = fixture.window.effectiveAppearance.bestMatch(from: [
          .darkAqua, .accessibilityHighContrastDarkAqua,
        ])
        XCTAssertTrue(appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua)
        retainText(
          "classification=controlled native capability fixture; no OS preference writes\nmode=\(mode.0); increase_contrast_override=\(mode.1.increaseContrast); reduce_transparency_override=\(mode.1.reduceTransparency); local_suppress_motion=true; actual_workspace_preferences=\(preferences); native_appearance=\(fixture.window.effectiveAppearance.name.rawValue); gpu_region_luminance=\(gpu.luminance)\n\(samples)",
          name: "compute-native-capability-\(mode.0)-receipt")
        try requireCompletedMetal(in: fixture)
        XCTAssertEqual(actualAccessibilityPreferences(), preferences)
      }
    }

    private func actualAccessibilityPreferences() -> [String: Bool] {
      [
        "increase_contrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
        "reduce_transparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "reduce_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      ]
    }

    private func waitForNativeFocus(id: String, in fixture: ComputePresentationWindow) async -> Bool
    {
      let deadline = Date().addingTimeInterval(3)
      repeat {
        let observations = await semanticObservations(in: fixture)
        if fixture.lastAccessibilityReport.errors.isEmpty,
          observations.filter({ $0.id == id }).only?.focused == true
        {
          return true
        }
        await allowNativeEvents(for: 0.02)
      } while Date() < deadline
      return false
    }

    private func waitForNativeControls(_ ids: [String], in fixture: ComputePresentationWindow) async
      -> Bool
    {
      let deadline = Date().addingTimeInterval(5)
      repeat {
        let observations = await semanticObservations(in: fixture)
        if fixture.lastAccessibilityReport.errors.isEmpty,
          !fixture.lastAccessibilityReport.budgetExceeded,
          ids.allSatisfy({ id in
            let matches = observations.filter { $0.id == id }
            guard let control = matches.only else { return false }
            return control.frame.width > 0 && control.frame.height > 0
          })
        {
          return true
        }
        await allowNativeEvents(for: 0.02)
      } while Date() < deadline
      return false
    }

    private func nativeSurfaceSamples(
      _ bitmap: NSBitmapImageRep, controls: [ComputeSemanticObservation],
      fixture: ComputePresentationWindow
    ) throws -> String {
      try requireCompleteAccessibilityReport(fixture.lastAccessibilityReport)
      let window = try XCTUnwrap(
        fixture.lastAccessibilityReport.elements.filter { $0.role == kAXWindowRole }.only)
      let contentSize = fixture.hostingView.bounds.size
      let content = CGRect(
        x: window.frame.minX, y: window.frame.maxY - contentSize.height,
        width: contentSize.width, height: contentSize.height)
      let scaleX = CGFloat(bitmap.pixelsWide) / contentSize.width
      let scaleY = CGFloat(bitmap.pixelsHigh) / contentSize.height
      XCTAssertEqual(scaleX, scaleY, accuracy: 0.02)
      var rows: [String] = []
      for control in controls {
        let x = Int(((control.frame.maxX - 8 - content.minX) * scaleX).rounded())
        let y = Int(((control.frame.midY - content.minY) * scaleY).rounded())
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else {
          throw ComputePresentationFailure(
            "Native control samples must lie inside the actual hosting-view cache")
        }
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        rows.append(
          "\(control.id): frame=\(NSStringFromRect(control.frame)); sample=\(x),\(y); sRGB=\(color.redComponent),\(color.greenComponent),\(color.blueComponent); alpha=\(color.alphaComponent)"
        )
      }
      return
        "native_view_cache_pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh); AX_content=\(NSStringFromRect(content)); scale=\(scaleX),\(scaleY)\n"
        + rows.joined(separator: "\n")
    }

    private func nativeCachedInteriorPixels(
      in region: CGRect, componentFrame: CGRect, bitmap: NSBitmapImageRep,
      fixture: ComputePresentationWindow
    ) throws -> (rgb: Data, luminance: Double) {
      let scaleX = CGFloat(bitmap.pixelsWide) / fixture.hostingView.bounds.width
      let scaleY = CGFloat(bitmap.pixelsHigh) / fixture.hostingView.bounds.height
      XCTAssertEqual(scaleX, scaleY, accuracy: 0.02)
      let interior = region.insetBy(
        dx: max(2, region.width * 0.12), dy: max(2, region.height * 0.12)
      )
      .offsetBy(dx: componentFrame.minX, dy: componentFrame.minY)
      let minX = Int((interior.minX * scaleX).rounded(.up))
      let maxX = Int((interior.maxX * scaleX).rounded(.down))
      let minY = Int((interior.minY * scaleY).rounded(.up))
      let maxY = Int((interior.maxY * scaleY).rounded(.down))
      guard minX >= 0, minY >= 0, maxX <= bitmap.pixelsWide, maxY <= bitmap.pixelsHigh,
        maxX > minX, maxY > minY
      else {
        throw ComputePresentationFailure("The actual Canvas region must be inside its native cache")
      }
      var rgb = Data()
      rgb.reserveCapacity((maxX - minX) * (maxY - minY) * 3)
      var total = 0.0
      for y in minY..<maxY {
        for x in minX..<maxX {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          let red = UInt8((max(0, min(1, color.redComponent)) * 255).rounded())
          let green = UInt8((max(0, min(1, color.greenComponent)) * 255).rounded())
          let blue = UInt8((max(0, min(1, color.blueComponent)) * 255).rounded())
          rgb.append(red)
          rgb.append(green)
          rgb.append(blue)
          total += (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
        }
      }
      return (rgb, total / Double((maxX - minX) * (maxY - minY)))
    }

    private func snapshot(
      cpu values: [Double], gpu: Double?, quality: CPUSampleQuality = .perLogicalProcessor,
      gpuAge: Double = 0, cpuName: String = "Synthetic CPU", gpuName: String = "Synthetic GPU"
    ) -> ComputeChipSnapshot {
      let now = Date().timeIntervalSince1970
      let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
      let cpu = CPUMetrics(
        percent: average, perCPU: values, countLogical: values.count,
        countPhysical: values.count, freqMHz: nil, freqPerCoreMHz: nil,
        loadAvg: (0, 0, 0), brand: cpuName, user: average, system: 0, idle: 100 - average,
        sampleQuality: quality, observedAt: now)
      let graphics = GPUMetrics(
        vendor: "Synthetic", name: "Transport name is not device identity", utilGPU: gpu,
        utilRenderer: gpu, utilTiler: gpu, memUsedMiB: nil, memTotalMiB: 0,
        cores: nil, metal: true, registryID: 777, observedAt: now - gpuAge)
      return .project(
        cpu: cpu, gpu: [graphics], devices: [.init(name: gpuName, registryID: 777)], now: now)
    }

    private func mount(
      snapshot: ComputeChipSnapshot, resources: ComputeChipResources = .shared,
      requireMetal: Bool = true
    ) async throws -> ComputePresentationWindow {
      if requireMetal, resources.pipeline() == nil {
        throw ComputePresentationFailure(
          resources.failureReason ?? "The compiled chip Metal pipeline is unavailable")
      }
      let fixture = ComputePresentationWindow(snapshot: snapshot, resources: resources)
      fixtures.append(fixture)
      NSApp.activate(ignoringOtherApps: true)
      fixture.window.makeKeyAndOrderFront(nil)
      fixture.window.orderFrontRegardless()
      let exposed = await waitUntil {
        NSApp.isActive && fixture.window.isKeyWindow
          && fixture.window.occlusionState.contains(.visible)
      }
      let frontmost = NSWorkspace.shared.frontmostApplication
      let ownedWindows = NSApp.windows.map { window in
        "number=\(window.windowNumber),title=\(window.title),visible=\(window.isVisible),key=\(window.isKeyWindow),main=\(window.isMainWindow),occlusion=\(window.occlusionState.rawValue),frame=\(NSStringFromRect(window.frame))"
      }.joined(separator: "\n")
      retainText(
        "active=\(NSApp.isActive); hidden=\(NSApp.isHidden); activation_policy=\(NSApp.activationPolicy().rawValue); application_occlusion=\(NSApp.occlusionState.rawValue)\nfixture_window_number=\(fixture.window.windowNumber); visible=\(fixture.window.isVisible); key=\(fixture.window.isKeyWindow); main=\(fixture.window.isMainWindow); occlusion=\(fixture.window.occlusionState.rawValue)\nkey_window_number=\(NSApp.keyWindow?.windowNumber ?? -1); main_window_number=\(NSApp.mainWindow?.windowNumber ?? -1); modal_window_number=\(NSApp.modalWindow?.windowNumber ?? -1)\nfrontmost_pid=\(frontmost?.processIdentifier ?? -1); frontmost_bundle=\(frontmost?.bundleURL?.path ?? "unavailable")\nowned_windows:\n\(ownedWindows)",
        name: "compute-native-fixture-public-activation")
      XCTAssertTrue(exposed)
      guard exposed else {
        throw ComputePresentationFailure(
          "The native fixture did not become active, key, and exposed")
      }
      if requireMetal {
        let mounted = await waitUntil {
          fixture.metalViews.count == 1 && fixture.diagnostics.snapshot().completedCommands > 0
        }
        XCTAssertTrue(mounted)
        guard mounted else {
          throw ComputePresentationFailure(
            "Exactly one production Metal surface must complete a command before the fixture proceeds"
          )
        }
      }
      retainText(
        "window=\(NSStringFromRect(fixture.window.frame)); content_bounds=\(NSStringFromRect(fixture.hostingView.bounds)); content_minimum=\(NSStringFromSize(fixture.window.contentMinSize)); content_maximum=\(NSStringFromSize(fixture.window.contentMaxSize)); hosting_sizing_options=\(fixture.hostingView.sizingOptions.rawValue); metal_bounds=\(fixture.metalViews.map { NSStringFromRect($0.bounds) })",
        name: "compute-native-fixture-viewport")
      XCTAssertEqual(fixture.hostingView.bounds.width, 1_000, accuracy: 0.5)
      XCTAssertEqual(fixture.hostingView.bounds.height, 780, accuracy: 0.5)
      guard abs(fixture.hostingView.bounds.width - 1_000) <= 0.5,
        abs(fixture.hostingView.bounds.height - 780) <= 0.5
      else {
        throw ComputePresentationFailure(
          "The native fixture must retain its explicit 1,000×780 content viewport")
      }
      return fixture
    }

    private func readback(from fixture: ComputePresentationWindow, name: String) async throws
      -> ComputeChipPixels
    {
      let view = try XCTUnwrap(fixture.metalViews.only)
      let renderer = try XCTUnwrap(view.renderer)
      var pixels: ComputeChipPixels?
      renderer.requestReadback { pixels = $0 }
      let completed = await waitUntil { pixels != nil }
      XCTAssertTrue(
        completed, "The exact production drawable pass must complete its diagnostic blit")
      guard completed else {
        throw ComputePresentationFailure(
          "The exact production drawable readback did not complete within its deadline")
      }
      let result = try XCTUnwrap(pixels)
      XCTAssertGreaterThan(result.width, 0)
      XCTAssertGreaterThan(result.height, 0)
      XCTAssertGreaterThanOrEqual(result.bytesPerRow, result.width * 4)
      XCTAssertEqual(result.bytes.count, result.bytesPerRow * result.height)
      XCTAssertEqual(result.pointSize.width, view.bounds.width, accuracy: 0.5)
      XCTAssertEqual(result.pointSize.height, view.bounds.height, accuracy: 0.5)
      let provider = try XCTUnwrap(CGDataProvider(data: result.bytes as CFData))
      let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
      let image = try XCTUnwrap(
        CGImage(
          width: result.width, height: result.height, bitsPerComponent: 8,
          bitsPerPixel: 32, bytesPerRow: result.bytesPerRow, space: colorSpace,
          bitmapInfo: [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
          ],
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      let bitmap = NSBitmapImageRep(cgImage: image)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try directEvidence.save(png, name: name, extension: "png")
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = name
      attachment.lifetime = .keepAlways
      if !directEvidence.isEnabled { add(attachment) }
      retainText(
        "window=\(NSStringFromRect(fixture.window.frame)); metal_bounds=\(NSStringFromRect(view.bounds)); point_size=\(NSStringFromSize(result.pointSize)); pixels=\(result.width)x\(result.height); stride=\(result.bytesPerRow); format=BGRA8_sRGB\n"
          + (try diagnosticJSON(fixture.diagnostics.snapshot())), name: "\(name)-readback-receipt")
      return result
    }

    private func interiorPixels(in region: CGRect, from pixels: ComputeChipPixels) throws -> (
      rgb: Data, luminance: Double
    ) {
      let rect = region.insetBy(dx: max(2, region.width * 0.12), dy: max(2, region.height * 0.12))
      let scaleX = Double(pixels.width) / pixels.pointSize.width
      let scaleY = Double(pixels.height) / pixels.pointSize.height
      XCTAssertEqual(scaleX, scaleY, accuracy: 0.02)
      let minX = Int((rect.minX * scaleX).rounded(.up))
      let maxX = Int((rect.maxX * scaleX).rounded(.down))
      let minY = Int((rect.minY * scaleY).rounded(.up))
      let maxY = Int((rect.maxY * scaleY).rounded(.down))
      guard minX >= 0, minY >= 0, maxX <= pixels.width, maxY <= pixels.height,
        maxX > minX, maxY > minY
      else {
        throw ComputePresentationFailure(
          "A sampled region must be entirely inside the genuine drawable")
      }
      var rgb = Data()
      rgb.reserveCapacity((maxX - minX) * (maxY - minY) * 3)
      var total = 0.0
      for y in minY..<maxY {
        for x in minX..<maxX {
          let offset = y * pixels.bytesPerRow + x * 4
          let blue = pixels.bytes[offset]
          let green = pixels.bytes[offset + 1]
          let red = pixels.bytes[offset + 2]
          rgb.append(red)
          rgb.append(green)
          rgb.append(blue)
          total += (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
        }
      }
      return (rgb, total / Double((maxX - minX) * (maxY - minY)))
    }

    private func requireCompletedMetal(in fixture: ComputePresentationWindow) throws {
      let observation = fixture.diagnostics.snapshot()
      retainText(try diagnosticJSON(observation), name: "compute-whole-component-metal-execution")
      XCTAssertEqual(fixture.metalViews.count, 1)
      XCTAssertEqual(observation.activeSurfaces, 1)
      XCTAssertGreaterThan(observation.completedCommands, 0)
      XCTAssertEqual(observation.failedCommands, 0)
      XCTAssertEqual(observation.vertexFunction, "compute_chip_vertex")
      XCTAssertEqual(observation.fragmentFunction, "compute_chip_fragment")
      XCTAssertTrue(observation.libraryOrigin.hasSuffix(".metallib"))
      let gpuDuration = try XCTUnwrap(observation.lastGPUDuration)
      XCTAssertTrue(gpuDuration.isFinite)
      XCTAssertGreaterThan(gpuDuration, 0)
      XCTAssertLessThanOrEqual(observation.maximumInFlightSlots, 3)
      XCTAssertLessThanOrEqual(observation.ownedBuffers, 7)
      XCTAssertEqual(observation.sharedMaterialTextures, 3)
      XCTAssertEqual(observation.sharedMaterialSamplers, 1)
      XCTAssertEqual(observation.materialTextureLoads, 3)
      let view = try XCTUnwrap(fixture.metalViews.only)
      XCTAssertNil(
        view.hitTest(NSPoint(x: view.frame.midX, y: view.frame.midY)),
        "The decorative canvas must pass pointer events to the owning native view")
      XCTAssertFalse(view.acceptsFirstResponder)
    }

    private func requireState(_ expected: String, id: String, in fixture: ComputePresentationWindow)
      async throws
    {
      let deadline = Date().addingTimeInterval(5)
      var present = false
      repeat {
        let matches = await semanticObservations(in: fixture).filter { $0.id == id }
        present =
          fixture.lastAccessibilityReport.errors.isEmpty
          && !fixture.lastAccessibilityReport.budgetExceeded
          && matches.count == 1 && matches.only?.value == expected
        if present { break }
        await allowNativeEvents(for: 0.02)
      } while Date() < deadline
      retainText(try semanticsJSON(fixture), name: "compute-native-state-\(id)-\(expected)")
      XCTAssertTrue(present, "The native semantic element \(id) must expose exactly '\(expected)'")
      guard present else {
        throw ComputePresentationFailure(
          "The unique native semantic element \(id) did not expose '\(expected)' within its deadline"
        )
      }
    }

    private func semanticValue(_ id: String, in fixture: ComputePresentationWindow) async throws
      -> String
    {
      let matches = await semanticObservations(in: fixture).filter { $0.id == id }
      try requireCompleteAccessibilityReport(fixture.lastAccessibilityReport)
      XCTAssertEqual(matches.count, 1, "Every semantic ID must have one actual native owner")
      return try XCTUnwrap(matches.only).value
    }

    private func requireNativeLabelContainment(in fixture: ComputePresentationWindow) async throws {
      let observations = await semanticObservations(in: fixture)
      try requireCompleteAccessibilityReport(fixture.lastAccessibilityReport)
      let nativeWindow = try XCTUnwrap(observations.filter { $0.role == kAXWindowRole }.only)
      for channel in ["cpu", "gpu"] {
        let panel = try XCTUnwrap(
          observations.filter { $0.id == "rig-\(channel)-cores-panel" }.only)
        let name = try XCTUnwrap(
          observations.filter { $0.id == "compute-\(channel)-hardware-name" }.only)
        let status = try XCTUnwrap(
          observations.filter { $0.id == "compute-\(channel)-activity-state" }.only)
        XCTAssertTrue(nativeWindow.frame.insetBy(dx: -2, dy: -2).contains(panel.frame))
        XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(name.frame))
        XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(status.frame))
        XCTAssertGreaterThan(name.frame.width, 0)
        XCTAssertGreaterThan(name.frame.height, 0)
      }
    }

    private func semanticObservations(in fixture: ComputePresentationWindow) async
      -> [ComputeSemanticObservation]
    {
      let report = accessibilityProbe.observe(
        pid: getpid(), windowTitle: fixture.window.title,
        contentSize: fixture.hostingView.bounds.size)
      fixture.lastAccessibilityReport = report
      return report.elements
    }

    private func requireCompleteAccessibilityReport(_ report: ComputePresentationAXReport) throws {
      XCTAssertTrue(report.errors.isEmpty, "Public AX reads must complete: \(report.errors)")
      XCTAssertFalse(
        report.budgetExceeded, "The entire scoped native AX tree must fit the observation budget")
      guard report.errors.isEmpty && !report.budgetExceeded else {
        throw ComputePresentationFailure("The scoped public AX observation did not complete")
      }
    }

    @discardableResult
    private func retainNativeViewAndSemantics(_ fixture: ComputePresentationWindow, name: String)
      async throws -> NSBitmapImageRep
    {
      let view = fixture.hostingView
      view.displayIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try directEvidence.save(data, name: "\(name)-native-view-cache", extension: "png")
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
      attachment.name = "\(name)-native-view-cache"
      attachment.lifetime = .keepAlways
      if !directEvidence.isEnabled { add(attachment) }
      _ = await semanticObservations(in: fixture)
      try requireCompleteAccessibilityReport(fixture.lastAccessibilityReport)
      retainText(try semanticsJSON(fixture), name: "\(name)-native-semantics")
      retainText(
        "classification=public NSView cache of actual mounted native structure and controls; this is not a screen capture and does not prove Metal visibility\nhosting_bounds=\(NSStringFromRect(view.bounds)); cache_pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh); actual Metal output is retained separately from the production drawable blit",
        name: "\(name)-native-view-cache-receipt")
      return bitmap
    }

    private func semanticsJSON(_ fixture: ComputePresentationWindow) throws -> String {
      let report = fixture.lastAccessibilityReport
      let rows = report.elements.map { row -> [String: Any] in
        [
          "id": row.id, "value": row.value, "role": row.role, "frame": NSStringFromRect(row.frame),
          "enabled": row.enabled.map { $0 as Any } ?? NSNull(),
          "focused": row.focused.map { $0 as Any } ?? NSNull(),
        ]
      }
      let data = try JSONSerialization.data(
        withJSONObject: [
          "window": NSStringFromRect(fixture.window.frame), "elements": rows,
          "ax_errors": report.errors, "observer_elapsed_seconds": report.elapsed,
          "observer_budget_exceeded": report.budgetExceeded,
          "observer_scope": report.scope,
        ],
        options: [.prettyPrinted, .sortedKeys])
      return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func diagnosticJSON(_ observation: ComputeChipRendererObservation) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return try XCTUnwrap(String(data: encoder.encode(observation), encoding: .utf8))
    }

    private func retainText(_ text: String, name: String) {
      do {
        try directEvidence.save(Data(text.utf8), name: name, extension: "txt")
      } catch {
        XCTFail("Direct fixture evidence could not preserve \(name): \(error)")
      }
      let attachment = XCTAttachment(string: text)
      attachment.name = name
      attachment.lifetime = .keepAlways
      if !directEvidence.isEnabled { add(attachment) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      repeat {
        if condition() { return true }
        await allowNativeEvents(for: 0.02)
      } while Date() < deadline
      return condition()
    }

    private func allowNativeEvents(for duration: TimeInterval) async {
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
  }

  /// Direct public XCTest runs have no Xcode activity transport; only attachment delivery changes.
  @MainActor
  final class DirectNativeFixtureEvidenceWriter {
    private var directEvidenceDirectory: URL?
    private var directEvidenceBytes = 0
    private var directEvidenceEntries: [[String: Any]] = []
    private var testName = ""
    var isEnabled: Bool { directEvidenceDirectory != nil }

    func configure(testName: String) throws {
      self.testName = testName
      directEvidenceDirectory = nil
      directEvidenceBytes = 0
      directEvidenceEntries.removeAll()
      guard let path = ProcessInfo.processInfo.environment["FORGE_DIRECT_XCTEST_EVIDENCE_DIRECTORY"]
      else { return }
      guard path.hasPrefix("/") else {
        throw ComputePresentationFailure(
          "Direct fixture evidence requires an absolute private directory.")
      }
      let root = URL(fileURLWithPath: path, isDirectory: true)
      let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
        ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700
      else {
        throw ComputePresentationFailure(
          "Direct fixture evidence must be an owner-only regular directory.")
      }
      let safeName = testName.unicodeScalars.map { scalar -> Character in
        let value = scalar.value
        let allowed =
          (65...90).contains(value) || (97...122).contains(value)
          || (48...57).contains(value) || value == 45
        return allowed ? Character(String(scalar)) : "_"
      }
      let directory = root.appendingPathComponent(String(safeName.prefix(180)), isDirectory: true)
      guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw ComputePresentationFailure(
          "Direct fixture evidence refuses to replace an earlier case receipt.")
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      directEvidenceDirectory = directory
    }

    func save(_ data: Data, name: String, extension suffix: String)
      throws
    {
      guard let directory = directEvidenceDirectory else { return }
      guard directEvidenceEntries.count < 128, data.count <= 16 * 1024 * 1024,
        directEvidenceBytes + data.count <= 64 * 1024 * 1024
      else {
        throw ComputePresentationFailure(
          "Direct fixture evidence exceeded its bounded attachment budget.")
      }
      let safeName = name.unicodeScalars.map { scalar -> Character in
        let value = scalar.value
        let allowed =
          (65...90).contains(value) || (97...122).contains(value)
          || (48...57).contains(value) || value == 45
        return allowed ? Character(String(scalar)) : "_"
      }
      let fileName =
        String(format: "%03d-", directEvidenceEntries.count + 1)
        + String(safeName.prefix(160)) + "." + suffix
      let target = directory.appendingPathComponent(fileName)
      try data.write(to: target, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      directEvidenceBytes += data.count
      directEvidenceEntries.append([
        "name": name, "file": fileName, "bytes": data.count,
        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      ])
      let manifest = try JSONSerialization.data(
        withJSONObject: [
          "classification":
            "Exact existing fixture attachment bytes; Metal drawable blits and native-view caches retain their separate source classifications",
          "test": testName,
          "transport":
            "Validated private filesystem; normal XCTest attachment delivery is unchanged when this opt-in is absent",
          "attachments": directEvidenceEntries,
          "attachment_count": directEvidenceEntries.count, "total_bytes": directEvidenceBytes,
          "limit_count": 128, "limit_bytes": 64 * 1024 * 1024,
        ], options: [.prettyPrinted, .sortedKeys])
      let manifestURL = directory.appendingPathComponent("manifest.json")
      try manifest.write(to: manifestURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

  }

  private struct ComputeSemanticObservation: Sendable {
    var id: String
    var value: String
    var role: String
    var frame: CGRect
    var enabled: Bool?
    var focused: Bool?
  }

  private struct ComputePresentationAXReport: Sendable {
    var elements: [ComputeSemanticObservation] = []
    var errors: [String] = []
    var elapsed: TimeInterval = 0
    var budgetExceeded = false
    var scope = ""
  }

  /// Own-process public AX queries can enter the native view implementation synchronously.
  @MainActor
  private final class ComputePresentationAXProbe {
    private var elementsByIdentifier: [String: [AXUIElement]] = [:]

    func clear() { elementsByIdentifier.removeAll() }

    func focus(id: String) throws {
      let element = try XCTUnwrap(elementsByIdentifier[id]?.only)
      AXUIElementSetMessagingTimeout(element, 0.1)
      let status = AXUIElementSetAttributeValue(
        element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      XCTAssertEqual(status, .success)
      guard status == .success else {
        throw ComputePresentationFailure("Native field focus failed: AXError \(status.rawValue)")
      }
    }

    func press(id: String) throws {
      let element = try XCTUnwrap(elementsByIdentifier[id]?.only)
      AXUIElementSetMessagingTimeout(element, 0.1)
      let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
      XCTAssertEqual(status, .success)
      guard status == .success else {
        throw ComputePresentationFailure("Native button action failed: AXError \(status.rawValue)")
      }
    }

    func observe(pid: pid_t, windowTitle: String, contentSize: CGSize)
      -> ComputePresentationAXReport
    {
      let started = ProcessInfo.processInfo.systemUptime
      clear()
      let deadline = started + 2
      var report = ComputePresentationAXReport()
      let application = AXUIElementCreateApplication(pid)
      let windows = elements(
        application, attribute: kAXWindowsAttribute, limit: 32, errors: &report.errors)
      let matches = windows.filter {
        string($0, attribute: kAXTitleAttribute, errors: &report.errors) == windowTitle
      }
      guard let window = matches.only else {
        report.errors.append(
          "Expected one AX window titled '\(windowTitle)'; observed \(matches.count)")
        report.elapsed = ProcessInfo.processInfo.systemUptime - started
        return report
      }
      let windowObservation = observation(window, errors: &report.errors)
      report.elements.append(windowObservation)
      let expectedContent = CGRect(
        x: windowObservation.frame.minX,
        y: windowObservation.frame.maxY - contentSize.height,
        width: contentSize.width, height: contentSize.height)
      var content = elements(
        window, attribute: kAXContentsAttribute, limit: 32, errors: &report.errors)
      report.scope = "AXContents; expected_native_content=\(NSStringFromRect(expectedContent))"
      if content.isEmpty && report.errors.isEmpty {
        content = elements(
          window, attribute: kAXChildrenAttribute, limit: 32, errors: &report.errors)
        report.scope =
          "direct AXChildren; expected_native_content=\(NSStringFromRect(expectedContent))"
      }
      let roots = content.filter { element in
        let role = string(element, attribute: kAXRoleAttribute, errors: &report.errors)
        let candidate = frame(element, errors: &report.errors)
        return role == kAXGroupRole && abs(candidate.minX - expectedContent.minX) <= 0.5
          && abs(candidate.minY - expectedContent.minY) <= 0.5
          && abs(candidate.width - expectedContent.width) <= 0.5
          && abs(candidate.height - expectedContent.height) <= 0.5
      }
      guard let root = roots.only, report.errors.isEmpty else {
        report.errors.append(
          "Expected one native content AXGroup matching the actual hosted viewport; observed \(roots.count)"
        )
        report.elapsed = ProcessInfo.processInfo.systemUptime - started
        return report
      }
      var queue = [root]
      var seen: [AXUIElement] = []
      while !queue.isEmpty && seen.count < 2_048 && ProcessInfo.processInfo.systemUptime < deadline
      {
        let element = queue.removeFirst()
        guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
        seen.append(element)
        let observed = observation(element, errors: &report.errors)
        report.elements.append(observed)
        if !observed.id.isEmpty { elementsByIdentifier[observed.id, default: []].append(element) }
        queue.append(
          contentsOf: elements(
            element, attribute: kAXChildrenAttribute,
            limit: 2_048 - seen.count - queue.count, errors: &report.errors))
      }
      report.budgetExceeded = !queue.isEmpty
      report.elapsed = ProcessInfo.processInfo.systemUptime - started
      return report
    }

    private func observation(_ element: AXUIElement, errors: inout [String])
      -> ComputeSemanticObservation
    {
      let id = string(element, attribute: kAXIdentifierAttribute, errors: &errors)
      let value = string(element, attribute: kAXValueAttribute, errors: &errors)
      let description =
        value.isEmpty ? string(element, attribute: kAXDescriptionAttribute, errors: &errors) : ""
      let title =
        value.isEmpty && description.isEmpty
        ? string(element, attribute: kAXTitleAttribute, errors: &errors) : ""
      return .init(
        id: id, value: value.isEmpty ? (description.isEmpty ? title : description) : value,
        role: string(element, attribute: kAXRoleAttribute, errors: &errors),
        frame: frame(element, errors: &errors),
        enabled: attribute(element, kAXEnabledAttribute, errors: &errors) as? Bool,
        focused: attribute(element, kAXFocusedAttribute, errors: &errors) as? Bool)
    }

    private func frame(_ element: AXUIElement, errors: inout [String]) -> CGRect {
      var origin = CGPoint.zero
      var size = CGSize.zero
      if let position = attribute(element, kAXPositionAttribute, errors: &errors),
        CFGetTypeID(position) == AXValueGetTypeID()
      {
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
      }
      if let dimensions = attribute(element, kAXSizeAttribute, errors: &errors),
        CFGetTypeID(dimensions) == AXValueGetTypeID()
      {
        AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
      }
      return CGRect(origin: origin, size: size)
    }

    private func attribute(_ element: AXUIElement, _ name: String, errors: inout [String])
      -> CFTypeRef?
    {
      AXUIElementSetMessagingTimeout(element, 0.1)
      var result: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
      record(status, attribute: name, errors: &errors)
      return status == .success ? result : nil
    }

    private func string(_ element: AXUIElement, attribute name: String, errors: inout [String])
      -> String
    {
      attribute(element, name, errors: &errors) as? String ?? ""
    }

    private func elements(
      _ element: AXUIElement, attribute name: String, limit: Int, errors: inout [String]
    ) -> [AXUIElement] {
      AXUIElementSetMessagingTimeout(element, 0.1)
      var count = 0
      let countStatus = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
      record(countStatus, attribute: "\(name) count", errors: &errors)
      guard countStatus == .success, count > 0 else { return [] }
      if count > limit {
        errors.append("\(name) exceeds the bounded observation count: \(count) > \(limit)")
      }
      guard limit > 0 else { return [] }
      var result: CFArray?
      let status = AXUIElementCopyAttributeValues(
        element, name as CFString, 0, min(limit, count), &result)
      record(status, attribute: name, errors: &errors)
      return status == .success ? result as? [AXUIElement] ?? [] : []
    }

    private func record(_ status: AXError, attribute: String, errors: inout [String]) {
      if status != .success && status != .attributeUnsupported && status != .noValue {
        errors.append("\(attribute): AXError \(status.rawValue)")
      }
    }
  }

  private struct ComputePresentationFailure: Error {
    var description: String
    init(_ description: String) { self.description = description }
  }

  extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
  }

  @MainActor
  private final class ComputePresentationModel: ObservableObject {
    @Published var snapshot: ComputeChipSnapshot
    @Published var resources: ComputeChipResources
    @Published var autoRefresh = true
    @Published var showsComponent = true
    @Published var motionEnabled = false
    @Published var showsInteractionFixtures = false
    @Published var capabilities = GraphiteAccessibilityCapabilities()
    @Published var fieldValue = "Native fixture field"
    var componentFrame = CGRect.zero
    var primaryInvocations = 0
    var destructiveInvocations = 0
    var disabledInvocations = 0
    init(snapshot: ComputeChipSnapshot, resources: ComputeChipResources) {
      self.snapshot = snapshot
      self.resources = resources
    }
  }

  @MainActor
  private struct ComputePresentationRoot: View {
    @ObservedObject var model: ComputePresentationModel
    let diagnostics: ComputeChipDiagnostics
    var body: some View {
      VStack(alignment: .leading) {
        if model.showsComponent {
          GraphitePanel(title: "COMPUTE CORES",
                        surface: GraphitePanelSurface(topColor: GraphitePalette.computePanelTop, bottomColor: GraphitePalette.computePanelBottom)) {
            ComputeCoresContentView(
              snapshot: model.snapshot, autoRefresh: model.autoRefresh, suppressMotion: !model.motionEnabled,
              resources: model.resources, diagnostics: diagnostics
            )
            .onGeometryChange(for: CGRect.self) { geometry in
              geometry.frame(in: .named("compute-native-fixture"))
            } action: { frame in
              model.componentFrame = frame
            }
            if model.showsInteractionFixtures {
              HStack(spacing: 12) {
                TextField("Fixture field", text: $model.fieldValue)
                  .textFieldStyle(GraphiteFieldStyle())
                  .frame(width: 180)
                  .accessibilityIdentifier("compute-fixture-field")
                Button("Primary action") { model.primaryInvocations += 1 }
                  .buttonStyle(GraphiteButtonStyle(kind: .primary))
                  .accessibilityIdentifier("compute-fixture-primary")
                Button("Delete sample", role: .destructive) { model.destructiveInvocations += 1 }
                  .buttonStyle(GraphiteButtonStyle(kind: .destructive))
                  .accessibilityIdentifier("compute-fixture-destructive")
                Button("Disabled action") { model.disabledInvocations += 1 }
                  .buttonStyle(GraphiteButtonStyle())
                  .disabled(true)
                  .accessibilityIdentifier("compute-fixture-disabled")
              }
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("rig-compute-cores-panel")
        }
        Spacer(minLength: 0)
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(GraphitePalette.canvas)
      .coordinateSpace(name: "compute-native-fixture")
      .preferredColorScheme(.dark)
      .environment(\.graphiteAccessibilityCapabilities, model.capabilities)
    }
  }

  @MainActor
  private final class ComputePresentationWindow {
    let model: ComputePresentationModel
    let diagnostics = ComputeChipDiagnostics()
    let window: NSWindow
    let hostingView: NSHostingView<ComputePresentationRoot>
    var lastAccessibilityReport = ComputePresentationAXReport()

    init(snapshot: ComputeChipSnapshot, resources: ComputeChipResources) {
      model = ComputePresentationModel(snapshot: snapshot, resources: resources)
      hostingView = NSHostingView(
        rootView: ComputePresentationRoot(
          model: model, diagnostics: diagnostics))
      hostingView.sizingOptions = []
      hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 780)
      hostingView.autoresizingMask = [.width, .height]
      window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1_000, height: 780),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = "Compute Cores — synthetic native fixture"
      window.appearance = NSAppearance(named: .darkAqua)
      window.isReleasedWhenClosed = false
      window.contentView = hostingView
      window.setContentSize(NSSize(width: 1_000, height: 780))
      window.center()
    }

    var metalViews: [ComputeChipMetalView] {
      func descendants(_ view: NSView) -> [ComputeChipMetalView] {
        (view as? ComputeChipMetalView).map { [$0] } ?? view.subviews.flatMap(descendants)
      }
      return descendants(hostingView)
    }

    func close() {
      model.showsComponent = false
      window.orderOut(nil)
      window.close()
    }
  }
#endif
