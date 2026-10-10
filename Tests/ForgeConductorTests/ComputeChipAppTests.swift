import AppKit
import CoreGraphics
import MetalKit
import SwiftUI
import XCTest
import ForgeConductorCore
import Darwin
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class ComputeChipAppTests: XCTestCase {
    func testProjectionClampsFiniteValuesAndNeverTurnsMissingIntoIdle() {
        let projection = project(cpu: cpu(values: [-10, 50, 110, .nan], quality: .perLogicalProcessor))
        XCTAssertEqual(projection.cpu.activity[0], 0)
        XCTAssertEqual(projection.cpu.activity[1], 0.5)
        XCTAssertEqual(projection.cpu.activity[2], 1)
        XCTAssertNil(projection.cpu.activity[3])
        XCTAssertNil(ComputeChipSnapshot.fraction(.infinity))
        XCTAssertNil(ComputeChipSnapshot.fraction(nil))
        XCTAssertEqual(projection.cpu.name, "Apple M5 Max")
        let missing = project(cpu: nil)
        XCTAssertTrue(missing.cpu.activity.isEmpty)
        XCTAssertEqual(missing.cpu.label(at: 100, paused: false), "Activity unavailable")
    }

    func testBlankHardwareNamesStayVisibleWithoutDiscardingRegistryMatchedActivity() {
        for blank in ["", " \n\t "] {
            var processor = cpu(values: [20, 0], quality: .perLogicalProcessor)
            processor.brand = blank
            let snapshot = ComputeChipSnapshot.project(
                cpu: processor, gpu: [gpu()],
                devices: [.init(name: blank, registryID: 42)], now: 100)
            XCTAssertEqual(snapshot.cpu.name, "CPU identity unavailable")
            XCTAssertEqual(snapshot.gpu.name, "GPU identity unavailable")
            XCTAssertEqual(snapshot.cpu.activity, [0.2, 0])
            XCTAssertEqual(snapshot.gpu.quality, .measured)
            XCTAssertEqual(snapshot.gpu.observedAt, 100)
            XCTAssertTrue(snapshot.gpu.activity.allSatisfy { $0 == 0.6 })
            XCTAssertEqual(snapshot.gpu.engineReadings, "Device 60% · Renderer 20% · Tiler 12%")
        }
        let unidentified = ComputeChipSnapshot.project(cpu: nil, gpu: [gpu()], devices: [], now: 100)
        XCTAssertEqual(unidentified.cpu.name, "CPU identity unavailable")
        XCTAssertEqual(unidentified.gpu.name, "GPU identity unavailable")
        XCTAssertEqual(unidentified.gpu.quality, .unavailable)
        XCTAssertTrue(unidentified.gpu.activity.allSatisfy { $0 == nil })
    }

    func testRawCPUModelIdentifierAndNonemptyGPUVariantArePreserved() {
        var processor = cpu(values: [20, 0], quality: .perLogicalProcessor)
        processor.brand = "  Mac16,13  "
        let variant = "AMD Radeon RX 7900 XTX — External Engineering Variant"
        let snapshot = ComputeChipSnapshot.project(
            cpu: processor, gpu: [gpu()],
            devices: [.init(name: " \n" + variant + "\t ", registryID: 42)], now: 100)
        XCTAssertEqual(snapshot.cpu.name, "Mac16,13")
        XCTAssertEqual(snapshot.gpu.name, variant)
        XCTAssertEqual(snapshot.gpu.quality, .measured)
        XCTAssertTrue(snapshot.gpu.activity.allSatisfy { $0 == 0.6 })
    }

    func testEqualMeasuredCPUValuesRemainMeasuredAndFallbackIsExplicit() {
        let measured = project(cpu: cpu(values: [18, 18, 18, 18], quality: .perLogicalProcessor))
        XCTAssertEqual(measured.cpu.quality, .measured)
        XCTAssertEqual(measured.cpu.activity.compactMap { $0 }, [0.18, 0.18, 0.18, 0.18])
        XCTAssertTrue(measured.provenance.contains("logical-processor activity"))
        let fallback = project(cpu: cpu(values: [18, 18, 18, 18], quality: .hostAggregateFallback))
        XCTAssertEqual(fallback.cpu.quality, .aggregateFallback)
        XCTAssertTrue(fallback.provenance.contains("host aggregate fallback; regions illustrative"))
        let warming = project(cpu: cpu(values: [0, 0, 0, 0], quality: .warmingUp))
        XCTAssertTrue(warming.cpu.activity.allSatisfy { $0 == nil })
        XCTAssertEqual(warming.cpu.label(at: 100, paused: false), "Warming up")
        let unknown = project(cpu: cpu(values: [0, 0, 0, 0], quality: .unknown))
        XCTAssertEqual(unknown.cpu.label(at: 100, paused: false), "Provenance unavailable")
    }

    func testGPUAssociationRequiresExactRegistryIdentityAndKeepsIndependentTime() {
        let devices = [ComputeGPUIdentity(name: "Unmatched local device", registryID: 9),
                       ComputeGPUIdentity(name: "Apple M5 Max", registryID: 42)]
        let sample = gpu(registryID: 42, observedAt: 96, percent: 65)
        let snapshot = ComputeChipSnapshot.project(cpu: cpu(values: [20, 0], quality: .perLogicalProcessor),
                                                   gpu: [sample], devices: devices, now: 100)
        XCTAssertEqual(snapshot.gpu.name, "Apple M5 Max")
        XCTAssertEqual(snapshot.gpu.observedAt, 96)
        XCTAssertEqual(snapshot.gpu.label(at: 100, paused: false), "Stale activity")
        XCTAssertEqual(snapshot.cpu.label(at: 100, paused: false), "Active")
        XCTAssertTrue(snapshot.gpu.validActivity(at: 100).allSatisfy { $0 == nil })
        let unmatched = ComputeChipSnapshot.project(cpu: nil, gpu: [gpu(registryID: 77)], devices: devices, now: 100)
        XCTAssertEqual(unmatched.gpu.name, "Unmatched local device")
        XCTAssertEqual(unmatched.gpu.quality, .unavailable)
        XCTAssertTrue(unmatched.gpu.activity.allSatisfy { $0 == nil })
        XCTAssertTrue(unmatched.gpu.engineReadings.isEmpty)
    }

    func testOversizedLogicalTopologyGroupsTruthfullyAndIncludesEveryProcessor() {
        let projected = project(cpu: cpu(values: Array(repeating: 40, count: 300), quality: .perLogicalProcessor))
        XCTAssertEqual(projected.cpu.logicalCount, 300)
        XCTAssertEqual(projected.cpu.activity.count, 256)
        XCTAssertTrue(projected.cpu.activity.allSatisfy { abs(($0 ?? -1) - 0.4) < 0.00001 })
        XCTAssertTrue(projected.provenance.contains("grouped logical-processor activity"))
        var incomplete = cpu(values: Array(repeating: 40, count: 299), quality: .perLogicalProcessor)
        incomplete.countLogical = 300
        XCTAssertNil(project(cpu: incomplete).cpu.activity.last!)
    }

    func testChipLayoutIsBoundedStableAndStacksOnlyInsideNarrowFrame() {
        for count in [0, 1, 24, 256, 4_096] {
            let normal = ComputeChipLayout.make(width: 1_060, cpuRegionCount: count)
            let repeated = ComputeChipLayout.make(width: 1_060, cpuRegionCount: count)
            let narrow = ComputeChipLayout.make(width: 580, cpuRegionCount: count)
            XCTAssertFalse(normal.stacked)
            XCTAssertTrue(narrow.stacked)
            XCTAssertEqual(normal.cpuPackage.width, normal.cpuPackage.height)
            XCTAssertEqual(narrow.gpuPackage.width, narrow.gpuPackage.height)
            XCTAssertEqual(normal.instances, repeated.instances)
            XCTAssertLessThanOrEqual(normal.instances.count, ComputeChipLayout.maximumInstances)
            XCTAssertLessThanOrEqual(normal.routes.count, ComputeChipAnimation.maximumRoutes)
            XCTAssertEqual(normal.cpuRegions.count, min(max(count, 1), 256))
            XCTAssertTrue(normal.cpuRegions.allSatisfy { normal.cpuPackage.contains($0) })
            XCTAssertTrue(normal.cpuRegions.allSatisfy { $0.width > 0 && $0.height > 0 })
            XCTAssertEqual(normal.size.height, ComputeChipLayout.height(for: 1_060))
            XCTAssertGreaterThan(narrow.gpuPanel.minY, narrow.cpuPanel.maxY)
        }
    }

    func testChipsUseCompactReferenceFootprintAndFourSidedBoundedFanout() {
        for width: CGFloat in [1_060, 760, 580, 280] {
            let layout = ComputeChipLayout.make(width: width, cpuRegionCount: 256)
            let panelWidth = width < 760 ? width : (width - 20) / 2
            let priorPackageWidth = min(390, max(220, panelWidth - 70))
            for package in [layout.cpuPackage, layout.gpuPackage] {
                XCTAssertEqual(package.width, priorPackageWidth * 0.46, accuracy: 0.0001)
                XCTAssertEqual(package.height, priorPackageWidth * 0.46, accuracy: 0.0001)
            }
            XCTAssertEqual(layout.routes.count, 64)
            XCTAssertTrue(layout.cpuRegions.allSatisfy { $0.width > 0 && $0.height > 0 })
            let gpuRegions = layout.instances.filter { $0.properties.x == 4 && $0.properties.y >= 256 }
            XCTAssertEqual(gpuRegions.map { Int($0.properties.y) }, Array(256...271))
            XCTAssertTrue(gpuRegions.allSatisfy { $0.rect.z > 0 && $0.rect.w > 0 })
            for channel in 0..<2 {
                let package = channel == 0 ? layout.cpuPackage : layout.gpuPackage
                let crop = channel == 0 ? ComputeChipReferenceGeometry.cpuCrop : ComputeChipReferenceGeometry.gpuCrop
                let groups = channel == 0 ? ComputeChipReferenceGeometry.cpuContactGroups : ComputeChipReferenceGeometry.gpuContactGroups
                let contacts = layout.routes.filter { $0.channel == channel }.compactMap { $0.points.first }.map { point in
                    CGPoint(x: crop.minX + (CGFloat(point.x) - package.minX) / package.width * crop.width,
                            y: crop.minY + (CGFloat(point.y) - package.minY) / package.height * crop.height)
                }
                XCTAssertEqual(contacts.count, 32)
                XCTAssertTrue(contacts.allSatisfy { point in groups.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) } },
                              "Every animated trace starts at a photographed gold contact")
                let upperY: CGFloat = channel == 0 ? 346 : 335
                let lowerY: CGFloat = channel == 0 ? 772 : 787
                let leftX: CGFloat = channel == 0 ? 192 : 830
                let rightX: CGFloat = channel == 0 ? 594 : 1284
                XCTAssertEqual(contacts.filter { abs($0.y - upperY) < 0.01 }.count, 8)
                XCTAssertEqual(contacts.filter { abs($0.y - lowerY) < 0.01 }.count, 8)
                XCTAssertEqual(contacts.filter { abs($0.x - leftX) < 0.01 }.count, 8)
                XCTAssertEqual(contacts.filter { abs($0.x - rightX) < 0.01 }.count, 8)
            }
        }
    }

    func testSingleLogicalProcessorOnlyChangesItsOwnEnvelope() {
        let snapshot = project(cpu: cpu(values: [0, 0, 88, 0], quality: .perLogicalProcessor))
        var animation = ComputeChipAnimation()
        _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100, motionAllowed: true, paused: false)
        XCTAssertTrue(animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100, motionAllowed: true, paused: false))
        XCTAssertGreaterThan(animation.values[2], 0)
        XCTAssertEqual(animation.values[0], 0)
        XCTAssertEqual(animation.values[1], 0)
        XCTAssertEqual(animation.values[3], 0)
        XCTAssertEqual(animation.values[2], 0.88 * (1 - exp(-0.1 / 0.18)), accuracy: 0.00001)
        var hugeDelta = ComputeChipAnimation()
        _ = hugeDelta.advance(snapshot: snapshot, monotonic: 0, wallTime: 100, motionAllowed: true, paused: false)
        _ = hugeDelta.advance(snapshot: snapshot, monotonic: 10_000, wallTime: 100, motionAllowed: true, paused: false)
        XCTAssertEqual(hugeDelta.values[2], animation.values[2], accuracy: 0.00001)
    }

    func testDecorativeTraceBedAndPulseHaloClearNativeHeaderAndStatusSlots() {
        for width: CGFloat in [1_560, 1_060, 928, 820, 800, 760, 759, 580, 400, 360, 320, 280] {
            let layout = ComputeChipLayout.make(width: width, cpuRegionCount: 24)
            for route in layout.routes {
                let panel = route.channel == 0 ? layout.cpuPanel : layout.gpuPanel
                let board = route.channel == 0 ? layout.cpuBoard : layout.gpuBoard
                let header = CGRect(x: panel.minX, y: panel.minY, width: panel.width,
                                    height: ComputeChipLayout.panelHeaderHeight)
                let status = CGRect(x: panel.minX, y: panel.maxY - ComputeChipLayout.panelFooterHeight,
                                    width: panel.width, height: ComputeChipLayout.panelFooterHeight)
                let xs = route.points.map { CGFloat($0.x) }
                let ys = route.points.map { CGFloat($0.y) }
                let traceBounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!,
                                         height: ys.max()! - ys.min()!).insetBy(dx: -8, dy: -8)
                XCTAssertFalse(header.intersects(traceBounds), "Width \(width), route \(route.seed)")
                XCTAssertFalse(status.intersects(traceBounds), "Width \(width), route \(route.seed)")
                XCTAssertTrue(panel.contains(traceBounds), "Trace halos remain inside their component panel")
                XCTAssertTrue(board.insetBy(dx: -0.01, dy: -0.01).contains(traceBounds),
                              "Every pulse halo remains on its circuit board")
            }
            for instance in layout.instances where instance.properties.x == 5 || instance.properties.x == 6 {
                let cosine = abs(cos(CGFloat(instance.properties.w)))
                let sine = abs(sin(CGFloat(instance.properties.w)))
                let width = CGFloat(instance.rect.z) * cosine + CGFloat(instance.rect.w) * sine
                let height = CGFloat(instance.rect.z) * sine + CGFloat(instance.rect.w) * cosine
                let bounds = CGRect(x: CGFloat(instance.rect.x) - width / 2,
                                    y: CGFloat(instance.rect.y) - height / 2,
                                    width: width, height: height)
                XCTAssertTrue(layout.cpuPanel.contains(bounds) || layout.gpuPanel.contains(bounds),
                              "Every decorative segment and endpoint stays inside the narrowed frames")
            }
        }
    }

    func testCircuitBoardsFitActualTraceEndsAndKeepNativeLabelsOutsideTheirFrames() {
        for width: CGFloat in [1_560, 1_060, 928, 820, 800, 760, 759, 580, 400, 360, 320, 280] {
            let layout = ComputeChipLayout.make(width: width, cpuRegionCount: 24)
            let backgrounds = layout.instances.indices.filter { layout.instances[$0].properties.x == 9 }
            XCTAssertEqual(backgrounds.count, 2)
            guard backgrounds.count == 2 else { continue }
            for (channel, panel, board, package) in [
                (0, layout.cpuPanel, layout.cpuBoard, layout.cpuPackage),
                (1, layout.gpuPanel, layout.gpuBoard, layout.gpuPackage),
            ] {
                let header = CGRect(x: panel.minX, y: panel.minY, width: panel.width,
                                    height: ComputeChipLayout.panelHeaderHeight)
                let footer = CGRect(x: panel.minX, y: panel.maxY - ComputeChipLayout.panelFooterHeight,
                                    width: panel.width, height: ComputeChipLayout.panelFooterHeight)
                XCTAssertTrue(panel.contains(board), "Width \(width), channel \(channel)")
                XCTAssertFalse(header.intersects(board), "Native headings stay outside the board")
                XCTAssertFalse(footer.intersects(board), "Native status and engine readings stay outside the board")
                XCTAssertLessThan(board.width, panel.width)
                XCTAssertLessThan(board.height, panel.height)
                XCTAssertTrue(board.contains(package))

                let start = backgrounds[channel]
                let end = channel == 0 ? backgrounds[1] : layout.instances.endIndex
                let artwork = layout.instances[(start + 1)..<end].filter {
                    [Float(5), 6, 10, 11].contains($0.properties.x)
                }
                XCTAssertTrue(artwork.contains { $0.properties.x == 10 })
                XCTAssertTrue(artwork.contains { $0.properties.x == 11 })
                XCTAssertTrue(artwork.contains { $0.properties.x == 5 })
                XCTAssertTrue(artwork.contains { $0.properties.x == 6 })
                let bounds = artwork.map { instance -> CGRect in
                    let cosine = abs(cos(CGFloat(instance.properties.w)))
                    let sine = abs(sin(CGFloat(instance.properties.w)))
                    let extentX = CGFloat(instance.rect.z) * cosine + CGFloat(instance.rect.w) * sine
                    let extentY = CGFloat(instance.rect.z) * sine + CGFloat(instance.rect.w) * cosine
                    return CGRect(x: CGFloat(instance.rect.x) - extentX / 2,
                                  y: CGFloat(instance.rect.y) - extentY / 2,
                                  width: extentX, height: extentY)
                }
                let visibleArtwork = bounds.reduce(CGRect.null) { $0.union($1) }
                XCTAssertTrue(bounds.allSatisfy { board.contains($0) })
                XCTAssertEqual(visibleArtwork.minX - board.minX, 8, accuracy: 0.01)
                XCTAssertEqual(visibleArtwork.minY - board.minY, 8, accuracy: 0.01)
                XCTAssertEqual(board.maxX - visibleArtwork.maxX, 8, accuracy: 0.01)
                XCTAssertEqual(board.maxY - visibleArtwork.maxY, 8, accuracy: 0.01)
                let background = layout.instances[start]
                XCTAssertEqual(CGFloat(background.rect.x), board.midX, accuracy: 0.01)
                XCTAssertEqual(CGFloat(background.rect.y), board.midY, accuracy: 0.01)
                XCTAssertEqual(CGFloat(background.rect.z), board.width, accuracy: 1.01)
                XCTAssertEqual(CGFloat(background.rect.w), board.height, accuracy: 1.01)
            }
        }
    }

    func testCompactPanelsPreserveApprovedArtworkFootprintAndRecordedRouteLengths() {
        let layout = ComputeChipLayout.make(width: 928, cpuRegionCount: 10)
        XCTAssertEqual(layout.size.height, 458)
        XCTAssertEqual(layout.cpuPanel, CGRect(x: 36, y: 0, width: 382, height: 458))
        XCTAssertEqual(layout.gpuPanel, CGRect(x: 510, y: 0, width: 382, height: 458))
        XCTAssertEqual(layout.cpuPackage.minX, 138.68, accuracy: 0.0001)
        XCTAssertEqual(layout.cpuPackage.minY, 168.68, accuracy: 0.0001)
        XCTAssertEqual(layout.cpuPackage.width, 176.64, accuracy: 0.0001)
        XCTAssertEqual(layout.gpuPackage.minX, 612.68, accuracy: 0.0001)
        XCTAssertEqual(layout.gpuPackage.minY, 168.68, accuracy: 0.0001)
        XCTAssertEqual(layout.gpuPackage.size, layout.cpuPackage.size)
        let backgrounds = layout.instances.filter { $0.properties.x == 9 }
        XCTAssertEqual(backgrounds.count, 2)
        XCTAssertTrue(backgrounds.allSatisfy { $0.color == GraphitePalette.linearRGBA(0x020817) })

        // Lengths recorded by the approved 928-point production Metal motion fixture.
        // Translation may change final Float rounding, but never the path's shape or scale.
        let approvedLengths: [(index: Int, length: Float)] = [
            (3, 78.8698501586914), (10, 58.3492431640625),
            (21, 50.78894805908203), (30, 71.56834411621094),
            (38, 71.56831359863281), (43, 62.76820373535156),
            (51, 78.86984252929688), (62, 71.56832885742188),
        ]
        for item in approvedLengths {
            XCTAssertEqual(layout.routes[item.index].length, item.length, accuracy: 0.0002)
        }
        let stacked = ComputeChipLayout.make(width: 280, cpuRegionCount: 10)
        XCTAssertEqual(stacked.size.height, 608)
        XCTAssertEqual(stacked.cpuPanel.height, 294)
        XCTAssertEqual(stacked.gpuPanel.minY, 314)
        XCTAssertEqual(stacked.gpuPackage.minY - stacked.cpuPackage.minY, 314, accuracy: 0.0001)
    }

    func testPauseRetainsShadingAcrossLaterWallTimeAndReduceMotionHasNoPulses() {
        let snapshot = project(cpu: cpu(values: [25, 70], quality: .perLogicalProcessor),
                               samples: [gpu(percent: 60)])
        var animation = ComputeChipAnimation()
        XCTAssertFalse(animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100,
                                         motionAllowed: true, paused: true))
        let frozen = animation.values
        XCTAssertFalse(animation.advance(snapshot: snapshot, monotonic: 20, wallTime: 120,
                                         motionAllowed: true, paused: true))
        XCTAssertEqual(animation.values, frozen)
        XCTAssertEqual(animation.values[0], 0.25)
        XCTAssertEqual(animation.values[256], 0.6)
        XCTAssertEqual(snapshot.cpu.label(at: 120, paused: true), "Paused")
        XCTAssertFalse(animation.advance(snapshot: snapshot, monotonic: 21, wallTime: 100,
                                         motionAllowed: false, paused: false))
        let routes = ComputeChipLayout.make(width: 1_060, cpuRegionCount: 2).routes
        XCTAssertTrue(animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                               motionAllowed: false, paused: false).isEmpty)
    }

    func testTraceFollowsPolylineCornersAndPulseSlotsAreBoundedDeterministic() {
        let route = ComputeTraceRoute(points: [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 20)], channel: 0, seed: 1)
        XCTAssertEqual(route.length, 40)
        XCTAssertEqual(route.point(at: 10).position, SIMD2(10, 0))
        XCTAssertEqual(route.point(at: 30).position, SIMD2(20, 10))
        XCTAssertEqual(route.point(at: 30).angle, .pi / 2, accuracy: 0.00001)
        let snapshot = project(cpu: cpu(values: [80], quality: .perLogicalProcessor))
        var animation = ComputeChipAnimation()
        _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100, motionAllowed: true, paused: false)
        _ = animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100, motionAllowed: true, paused: false)
        let routes = Array(repeating: route, count: 400)
        let pulses = animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100, motionAllowed: true, paused: false)
        XCTAssertEqual(pulses.count, 192)
        XCTAssertEqual(pulses, animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100, motionAllowed: true, paused: false))
        XCTAssertTrue(animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 105, motionAllowed: true, paused: false).isEmpty)
    }

    func testStaleGPUStopsWhileFreshCPUStillMovesAndInvalidChannelsRemainDark() {
        let snapshot = project(cpu: cpu(values: [80], quality: .perLogicalProcessor),
                               samples: [gpu(observedAt: 96, percent: 80)])
        var animation = ComputeChipAnimation()
        _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100, motionAllowed: true, paused: false)
        XCTAssertTrue(animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100, motionAllowed: true, paused: false))
        XCTAssertGreaterThan(animation.phase[0], 0)
        XCTAssertEqual(animation.phase[1], 0)
        XCTAssertEqual(animation.values[256], 0.8, accuracy: 0.00001)
    }

    func testTracePulseIlluminationUsesSmoothedActivityAndPreservesChannelTintFamilies() {
        let routes = [
            ComputeTraceRoute(points: [SIMD2(0, 0), SIMD2(100, 0)], channel: 0, seed: 2),
            ComputeTraceRoute(points: [SIMD2(0, 10), SIMD2(100, 10)], channel: 0, seed: 6),
            ComputeTraceRoute(points: [SIMD2(0, 20), SIMD2(100, 20)], channel: 1, seed: 130),
            ComputeTraceRoute(points: [SIMD2(0, 30), SIMD2(100, 30)], channel: 1, seed: 134),
        ]
        var snapshot = project(cpu: cpu(values: [80, 20], quality: .perLogicalProcessor),
                               samples: [gpu(percent: 60)])
        var animation = ComputeChipAnimation()
        _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100,
                              motionAllowed: true, paused: false)
        _ = animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100,
                              motionAllowed: true, paused: false)
        let pulses = animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                             motionAllowed: true, paused: false)
        XCTAssertEqual(pulses.count, 12)
        let tints: [UInt32] = [0x33ACFF, 0x37DCC0, 0x33ACFF, 0xA275FF]
        for (index, route) in routes.enumerated() {
            let maximum = animation.values[route.channel == 0 ? 0 : 256]
            XCTAssertGreaterThan(maximum, 0)
            XCTAssertLessThan(maximum, route.channel == 0 ? 0.8 : 0.6)
            let tint = GraphitePalette.linearRGBA(tints[index])
            for tail in 0..<3 {
                let pulse = pulses[index * 3 + tail]
                XCTAssertEqual(pulse.properties.y, maximum)
                XCTAssertEqual(pulse.properties.z, Float(route.seed))
                XCTAssertEqual(pulse.color.x, tint.x)
                XCTAssertEqual(pulse.color.y, tint.y)
                XCTAssertEqual(pulse.color.z, tint.z)
                XCTAssertEqual(pulse.color.w,
                               (1 - Float(tail) * 0.27) * (0.35 + pow(maximum, 0.65) * 0.65),
                               accuracy: 0.00001)
            }
        }
        snapshot.cpu.activity = [0.05, 0.01]
        snapshot.gpu.activity = Array(repeating: 0.95, count: 16)
        XCTAssertEqual(animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                               motionAllowed: true, paused: false), pulses,
                       "Raw target changes cannot bypass the renderer's activity envelope")
        _ = animation.advance(snapshot: snapshot, monotonic: 0.2, wallTime: 100,
                              motionAllowed: true, paused: false)
        let next = animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                           motionAllowed: true, paused: false)
        XCTAssertEqual(next.count, 12)
        XCTAssertGreaterThan(next[0].properties.y, 0.05)
        XCTAssertLessThan(next[0].properties.y, pulses[0].properties.y)
        XCTAssertLessThan(next[0].color.w, pulses[0].color.w)
        XCTAssertGreaterThan(next[6].properties.y, pulses[6].properties.y)
        XCTAssertLessThan(next[6].properties.y, 0.95)
        XCTAssertGreaterThan(next[6].color.w, pulses[6].color.w)
        XCTAssertTrue(animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                              motionAllowed: true, paused: true).isEmpty)
        XCTAssertTrue(animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                              motionAllowed: false, paused: false).isEmpty)
        snapshot.gpu.observedAt = 90
        _ = animation.advance(snapshot: snapshot, monotonic: 0.3, wallTime: 100,
                              motionAllowed: true, paused: false)
        let freshOnly = animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100,
                                                motionAllowed: true, paused: false)
        XCTAssertEqual(freshOnly.count, 6)
        XCTAssertTrue(freshOnly.allSatisfy { $0.properties.z == 2 || $0.properties.z == 6 })
    }

    func testLuminousTraceStreaksRemainInsideTheExistingEightPointBoardHalo() {
        let snapshot = project(cpu: cpu(values: [80], quality: .perLogicalProcessor),
                               samples: [gpu(percent: 80)])
        for width: CGFloat in [1_560, 1_060, 928, 820, 800, 760, 759, 580, 400, 360, 320, 280] {
            let layout = ComputeChipLayout.make(width: width, cpuRegionCount: 1)
            var animation = ComputeChipAnimation()
            _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100,
                                  motionAllowed: true, paused: false)
            _ = animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100,
                                  motionAllowed: true, paused: false)
            let pulses = animation.pulseInstances(routes: layout.routes, snapshot: snapshot, wallTime: 100,
                                                 motionAllowed: true, paused: false)
            XCTAssertEqual(layout.routes.count, 64)
            XCTAssertEqual(pulses.count, 192)
            for pulse in pulses {
                XCTAssertEqual(pulse.rect.z, 15)
                XCTAssertEqual(pulse.rect.w, 5.5)
                let cosine = abs(cos(CGFloat(pulse.properties.w)))
                let sine = abs(sin(CGFloat(pulse.properties.w)))
                let extentX = CGFloat(pulse.rect.z) * cosine + CGFloat(pulse.rect.w) * sine
                let extentY = CGFloat(pulse.rect.z) * sine + CGFloat(pulse.rect.w) * cosine
                XCTAssertLessThanOrEqual(extentX / 2, 8)
                XCTAssertLessThanOrEqual(extentY / 2, 8)
                let bounds = CGRect(x: CGFloat(pulse.rect.x) - extentX / 2,
                                    y: CGFloat(pulse.rect.y) - extentY / 2,
                                    width: extentX, height: extentY)
                let board = pulse.properties.z < 128 ? layout.cpuBoard : layout.gpuBoard
                XCTAssertTrue(board.insetBy(dx: -0.01, dy: -0.01).contains(bounds),
                              "Width \(width), route \(pulse.properties.z)")
            }
        }
    }

    func testFreshInvalidChannelImmediatelyStopsOnlyItsPreviouslyActiveTrace() {
        let routes = [
            ComputeTraceRoute(points: [SIMD2(0, 0), SIMD2(100, 0)], channel: 0, seed: 0),
            ComputeTraceRoute(points: [SIMD2(0, 10), SIMD2(100, 10)], channel: 1, seed: 1),
        ]
        let qualities: [ComputeActivityQuality] = [.unavailable, .warmingUp, .unknown, .measured, .aggregateFallback]
        for channel in 0..<2 {
            for quality in qualities {
                var snapshot = project(cpu: cpu(values: [80], quality: .perLogicalProcessor),
                                       samples: [gpu(percent: 60)])
                var animation = ComputeChipAnimation()
                _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100, motionAllowed: true, paused: false)
                _ = animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100, motionAllowed: true, paused: false)
                XCTAssertEqual(animation.active, [true, true])
                let priorPhase = animation.phase[channel]
                var invalid = channel == 0 ? snapshot.cpu : snapshot.gpu
                invalid.quality = quality
                invalid.observedAt = 100.1
                invalid.activity = Array(repeating: nil, count: invalid.activity.count)
                if channel == 0 { snapshot.cpu = invalid } else { snapshot.gpu = invalid }

                XCTAssertTrue(animation.advance(snapshot: snapshot, monotonic: 0.2, wallTime: 100.1,
                                                 motionAllowed: true, paused: false))
                XCTAssertFalse(animation.active[channel], "\(quality), channel \(channel)")
                XCTAssertTrue(animation.active[1 - channel])
                XCTAssertEqual(animation.phase[channel], priorPhase)
                XCTAssertEqual(animation.values[channel == 0 ? 0 : 256], -1)
                let pulses = animation.pulseInstances(routes: routes, snapshot: snapshot, wallTime: 100.1,
                                                      motionAllowed: true, paused: false)
                XCTAssertEqual(pulses.count, 3)
                XCTAssertTrue(pulses.allSatisfy { Int($0.properties.z) == 1 - channel })

                invalid.quality = .measured
                invalid.activity = Array(repeating: 0.015, count: invalid.activity.count)
                if channel == 0 { snapshot.cpu = invalid } else { snapshot.gpu = invalid }
                _ = animation.advance(snapshot: snapshot, monotonic: 0.3, wallTime: 100.1,
                                      motionAllowed: true, paused: false)
                XCTAssertFalse(animation.active[channel], "An invalid sample must also clear the previous hold")
            }
        }
    }

    func testMeasuredIdleRetainsBoundedTraceHysteresisAfterActivity() {
        var snapshot = project(cpu: cpu(values: [80], quality: .perLogicalProcessor), samples: [gpu(percent: 0)])
        var animation = ComputeChipAnimation()
        _ = animation.advance(snapshot: snapshot, monotonic: 0, wallTime: 100, motionAllowed: true, paused: false)
        _ = animation.advance(snapshot: snapshot, monotonic: 0.1, wallTime: 100, motionAllowed: true, paused: false)
        snapshot.cpu.activity = [0]
        _ = animation.advance(snapshot: snapshot, monotonic: 0.2, wallTime: 100, motionAllowed: true, paused: false)
        XCTAssertTrue(animation.active[0], "Measured idle keeps its short visual hold")
        for time in [0.3, 0.4, 0.5] {
            _ = animation.advance(snapshot: snapshot, monotonic: time, wallTime: 100, motionAllowed: true, paused: false)
        }
        XCTAssertFalse(animation.active[0], "Measured idle releases the hold after 350ms")
    }

    private func project(cpu: CPUMetrics?, samples: [GPUMetrics] = []) -> ComputeChipSnapshot {
        ComputeChipSnapshot.project(cpu: cpu, gpu: samples,
                                    devices: [.init(name: "Apple M5 Max", registryID: 42)], now: 100)
    }
    private func cpu(values: [Double], quality: CPUSampleQuality) -> CPUMetrics {
        CPUMetrics(percent: 18, perCPU: values, countLogical: values.count, countPhysical: values.count,
                   freqMHz: nil, freqPerCoreMHz: nil, loadAvg: (0, 0, 0), brand: "Apple M5 Max",
                   user: 0, system: 0, idle: 0, sampleQuality: quality, observedAt: 100)
    }
    private func gpu(registryID: UInt64? = 42, observedAt: Double = 100, percent: Double = 60) -> GPUMetrics {
        GPUMetrics(vendor: "Apple", name: "Observed registry name", utilGPU: percent, utilRenderer: 20, utilTiler: 12,
                   memUsedMiB: nil, memTotalMiB: 0, cores: nil, metal: true, registryID: registryID, observedAt: observedAt)
    }
}

#if !SWIFT_PACKAGE
@MainActor
final class ComputeChipNativeLifecycleTests: XCTestCase, @unchecked Sendable {
    private let directEvidence = DirectNativeFixtureEvidenceWriter()
    private var hiddenWindows: [NSWindow] = []
    private var fixture: ComputeNativeFixture?

    nonisolated override func setUp() async throws { try await isolateHost() }
    private func isolateHost() throws {
        continueAfterFailure = true
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw XCTSkip("Native Compute evidence requires an application host and display")
        }
        guard ComputeChipResources.shared.pipeline() != nil else {
            XCTFail(ComputeChipResources.shared.failureReason ?? "Compiled Metal chip pipeline unavailable")
            throw NSError(domain: "ComputeNative", code: 1)
        }
        try directEvidence.configure(testName: name)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        hiddenWindows = NSApp.windows.filter(\.isVisible)
        hiddenWindows.forEach { $0.orderOut(nil) }
    }
    nonisolated override func tearDown() async throws { await restoreHost() }
    private func restoreHost() async {
        fixture?.close(); fixture = nil
        hiddenWindows.forEach { $0.orderFront(nil) }; hiddenWindows.removeAll()
    }

    func testCompiledChipCommandsCompleteAndReuseBuffersAcrossSamplesAndResize() async throws {
        let fixture = mount(paused: true)
        await require { fixture.diagnostics.snapshot().completedCommands > 0 }
        let baseline = fixture.diagnostics.snapshot()
        XCTAssertEqual(baseline.failedCommands, 0)
        XCTAssertEqual(baseline.activeSurfaces, 1)
        XCTAssertEqual(baseline.ownedBuffers, 7)
        XCTAssertEqual(baseline.activeClocks, 0)
        XCTAssertEqual(baseline.vertexFunction, "compute_chip_vertex")
        XCTAssertEqual(baseline.fragmentFunction, "compute_chip_fragment")
        XCTAssertFalse(baseline.libraryOrigin.isEmpty)
        fixture.update(percent: 70, paused: true)
        await require { fixture.diagnostics.snapshot().completedCommands > baseline.completedCommands }
        XCTAssertEqual(fixture.diagnostics.snapshot().geometryRebuilds, baseline.geometryRebuilds)
        let prior = fixture.diagnostics.snapshot().completedCommands
        fixture.resize(width: 580)
        await require { fixture.diagnostics.snapshot().completedCommands > prior }
        XCTAssertTrue(fixture.renderer.layout?.stacked == true)
        XCTAssertEqual(fixture.diagnostics.snapshot().ownedBuffers, 7)
        XCTAssertLessThanOrEqual(fixture.diagnostics.snapshot().maximumInFlightSlots, 3)
        retain("compiled-demand-resize", fixture.diagnostics.snapshot())
        fixture.close()
        await require { fixture.diagnostics.snapshot().ownedBuffers == 0 && fixture.diagnostics.snapshot().inFlightSlots == 0 }
        XCTAssertEqual(fixture.diagnostics.snapshot().activeSurfaces, 0)
    }

    func testClockStopsWhenScrolledOffscreenAndOrderedOutThenResumesOnce() async throws {
        let fixture = mount(paused: true)
        await require { fixture.diagnostics.snapshot().completedCommands > 0 }
        try await measurePhase("paused-baseline", fixture: fixture)
        fixture.update(percent: 35, paused: false)
        await require { fixture.diagnostics.snapshot().animationFrames >= 3 }
        XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 1)
        XCTAssertLessThanOrEqual(fixture.surface.preferredFramesPerSecond, 30)
        try await measurePhase("visible-active", fixture: fixture)
        fixture.scrollAway()
        await require { fixture.diagnostics.snapshot().activeClocks == 0 && fixture.diagnostics.snapshot().inFlightSlots == 0 }
        let hidden = fixture.diagnostics.snapshot().submissions
        try await measurePhase("scrolled-hidden", fixture: fixture)
        XCTAssertEqual(fixture.diagnostics.snapshot().submissions, hidden)
        fixture.update(percent: 70, paused: false)
        fixture.scrollBack()
        await require { fixture.diagnostics.snapshot().submissions > hidden && fixture.diagnostics.snapshot().activeClocks == 1 }
        fixture.window.orderOut(nil)
        await require { fixture.diagnostics.snapshot().activeClocks == 0 && fixture.diagnostics.snapshot().inFlightSlots == 0 }
        let orderedOut = fixture.diagnostics.snapshot().submissions
        await events(0.35)
        XCTAssertEqual(fixture.diagnostics.snapshot().submissions, orderedOut)
        retain("viewport-and-window-quiescence", fixture.diagnostics.snapshot())
    }

    func testDrawableReadbackRetainsOneInFlightCommandAndOnlyLatestPendingRequest() async throws {
        let fixture = mount(paused: true)
        await require { fixture.diagnostics.snapshot().completedCommands > 0
            && fixture.diagnostics.snapshot().inFlightSlots == 0 }
        var delivered: [Int] = []
        fixture.renderer.requestReadback { _ in delivered.append(1) }
        fixture.surface.draw()
        fixture.renderer.requestReadback { _ in delivered.append(2) }
        fixture.surface.draw()
        fixture.renderer.requestReadback { _ in delivered.append(3) }
        fixture.surface.draw()
        await require { delivered == [1, 3] && fixture.diagnostics.snapshot().inFlightReadbacks == 0
            && fixture.surface.framebufferOnly }
        let observation = fixture.diagnostics.snapshot()
        XCTAssertEqual(delivered, [1, 3], "The intermediate pending callback must be replaced, not queued")
        XCTAssertEqual(observation.maximumInFlightReadbacks, 1)
        XCTAssertEqual(observation.inFlightReadbacks, 0)
        XCTAssertEqual(observation.failedCommands, 0)
        XCTAssertEqual(observation.ownedBuffers, 7)
        retain("one-in-flight-readback-and-latest-pending", observation)
        fixture.close()
        await require { fixture.diagnostics.snapshot().ownedBuffers == 0
            && fixture.diagnostics.snapshot().inFlightSlots == 0
            && fixture.diagnostics.snapshot().inFlightReadbacks == 0 }
    }

    func testPausedAndReducedMotionDrawStaticFramesWithoutRecurringClock() async throws {
        let fixture = mount(paused: true)
        await require { fixture.diagnostics.snapshot().completedCommands > 0 }
        await events(0.15)
        let paused = fixture.diagnostics.snapshot().submissions
        await events(0.35)
        XCTAssertEqual(fixture.diagnostics.snapshot().submissions, paused)
        XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
        fixture.update(percent: 80, paused: false, reduceMotion: true)
        await require { fixture.diagnostics.snapshot().submissions > paused }
        await events(0.15)
        let reduced = fixture.diagnostics.snapshot().submissions
        await events(0.35)
        XCTAssertEqual(fixture.diagnostics.snapshot().submissions, reduced)
        XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
        XCTAssertTrue(fixture.surface.isPaused)
        retain("paused-and-reduced-motion", fixture.diagnostics.snapshot())
    }

    func testMinimizedOccludedAndRepeatedlyReopenedNativeChipsReleaseAndResumeOneClock() async throws {
        let initial = mount(paused: false)
        await require { initial.diagnostics.snapshot().animationFrames >= 3 }
        initial.window.miniaturize(nil)
        await require { initial.window.isMiniaturized && initial.diagnostics.snapshot().activeClocks == 0
            && initial.diagnostics.snapshot().inFlightSlots == 0 }
        let minimized = initial.diagnostics.snapshot().submissions
        await events(0.3)
        XCTAssertEqual(initial.diagnostics.snapshot().submissions, minimized)
        initial.update(percent: 45, paused: false)
        initial.window.deminiaturize(nil)
        initial.window.makeKeyAndOrderFront(nil)
        await require { !initial.window.isMiniaturized && initial.diagnostics.snapshot().submissions > minimized
            && initial.diagnostics.snapshot().activeClocks == 1 }

        let cover = NSWindow(contentRect: initial.window.frame.insetBy(dx: -24, dy: -24),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.isOpaque = true; cover.backgroundColor = .black
        defer { cover.orderOut(nil); cover.close() }
        cover.orderFrontRegardless()
        await require(failureDescription:
            "Stage full occlusion; application_active=\(NSApp.isActive); " +
            "initial_visible=\(initial.window.isVisible); initial_on_active_space=\(initial.window.isOnActiveSpace); " +
            "initial_occlusion=\(initial.window.occlusionState.rawValue); initial_frame=\(NSStringFromRect(initial.window.frame)); " +
            "initial_level=\(initial.window.level.rawValue); cover_visible=\(cover.isVisible); " +
            "cover_on_active_space=\(cover.isOnActiveSpace); cover_occlusion=\(cover.occlusionState.rawValue); " +
            "cover_frame=\(NSStringFromRect(cover.frame)); cover_level=\(cover.level.rawValue); " +
            "rendering_eligible=\(initial.surface.isRenderingEligible); " +
            "active_clocks=\(initial.diagnostics.snapshot().activeClocks); in_flight_slots=\(initial.diagnostics.snapshot().inFlightSlots)"
        ) { !initial.window.occlusionState.contains(.visible)
            && initial.diagnostics.snapshot().activeClocks == 0 && initial.diagnostics.snapshot().inFlightSlots == 0 }
        XCTAssertTrue(initial.window.isVisible, "This assertion distinguishes native occlusion from orderOut")
        let occluded = initial.diagnostics.snapshot().submissions
        await events(0.3)
        XCTAssertEqual(initial.diagnostics.snapshot().submissions, occluded)
        initial.update(percent: 45, paused: false)
        cover.orderOut(nil)
        initial.window.makeKeyAndOrderFront(nil)
        await require { initial.window.occlusionState.contains(.visible)
            && initial.diagnostics.snapshot().submissions > occluded && initial.diagnostics.snapshot().activeClocks == 1 }
        retain("minimized-fully-occluded-and-resumed", initial.diagnostics.snapshot())
        initial.close()
        await require { initial.diagnostics.snapshot().ownedBuffers == 0 && initial.diagnostics.snapshot().inFlightSlots == 0 }

        for cycle in 1...12 {
            let reopened = mount(paused: false)
            await require { reopened.diagnostics.snapshot().completedCommands > 0
                && reopened.diagnostics.snapshot().activeClocks == 1 }
            let mounted = reopened.diagnostics.snapshot()
            XCTAssertEqual(mounted.activeSurfaces, 1, "Cycle \(cycle)")
            XCTAssertEqual(mounted.ownedBuffers, 7, "Cycle \(cycle)")
            reopened.close()
            await require { reopened.diagnostics.snapshot().ownedBuffers == 0 && reopened.diagnostics.snapshot().inFlightSlots == 0 }
            let released = reopened.diagnostics.snapshot()
            XCTAssertEqual(released.activeSurfaces, 0, "Cycle \(cycle)")
            XCTAssertEqual(released.activeClocks, 0, "Cycle \(cycle)")
            XCTAssertEqual(released.failedCommands, 0, "Cycle \(cycle)")
            retain("reopen-cycle-\(cycle)-released", released)
        }
    }

    func testNativeCoverOrderingComparisonCapturesOwnedWindowServerEvidence() async throws {
        let initial = mount(paused: true)
        NSApp.activate(ignoringOtherApps: true)
        initial.window.makeKeyAndOrderFront(nil)
        initial.window.orderFrontRegardless()
        var snapshots: [[String: Any]] = []
        var outcomes: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        func exposed() -> Bool {
            NSApp.isActive && initial.window.isKeyWindow && initial.window.isVisible
                && initial.window.occlusionState.contains(.visible)
        }
        let ready = await wait(timeout: 4, predicate: exposed)
        snapshots.append(coverOrderingSnapshot("startup", initial: initial, cover: nil))
        guard ready else {
            try retainCoverOrderingEvidence(snapshots: snapshots, outcomes: outcomes, elapsed: ProcessInfo.processInfo.systemUptime - started)
            XCTFail("The actual native XCTest host must be active, key and exposed before comparing cover order")
            throw NSError(domain: "ComputeNativeCoverOrdering", code: 1)
        }
        await require { initial.diagnostics.snapshot().completedCommands > 0 }

        for variant in ["original-order-front", "explicit-above-initial", "floating-order-front"] {
            let cover = NSWindow(contentRect: initial.window.frame.insetBy(dx: -24, dy: -24),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.isOpaque = true; cover.backgroundColor = .black
            defer { cover.orderOut(nil); cover.close() }
            switch variant {
            case "explicit-above-initial": cover.order(.above, relativeTo: initial.window.windowNumber)
            case "floating-order-front": cover.level = .floating; cover.orderFrontRegardless()
            default: cover.orderFrontRegardless()
            }
            snapshots.append(coverOrderingSnapshot(variant + "-start", initial: initial, cover: cover))
            let phaseStart = ProcessInfo.processInfo.systemUptime
            let deadline = phaseStart + 4
            var visibleSamples: [Bool] = []
            while ProcessInfo.processInfo.systemUptime < deadline && visibleSamples.count < 48 {
                visibleSamples.append(initial.window.occlusionState.contains(.visible))
                await events(0.1)
            }
            let terminalOccluded = !initial.window.occlusionState.contains(.visible)
            let stayedVisible = initial.window.isVisible
            outcomes.append([
                "variant": variant, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - phaseStart,
                "occlusion_visible_samples": visibleSamples, "any_occluded_sample": visibleSamples.contains(false),
                "terminal_fully_occluded": terminalOccluded, "initial_window_still_visible": stayedVisible,
            ])
            snapshots.append(coverOrderingSnapshot(variant + "-terminal", initial: initial, cover: cover))
            XCTAssertTrue(stayedVisible, "Native occlusion must remain distinct from orderOut: \(variant)")
            cover.orderOut(nil)
            initial.window.makeKeyAndOrderFront(nil)
            let recovered = await wait(timeout: 4, predicate: exposed)
            snapshots.append(coverOrderingSnapshot(variant + "-recovery", initial: initial, cover: cover))
            guard recovered else {
                try retainCoverOrderingEvidence(snapshots: snapshots, outcomes: outcomes, elapsed: ProcessInfo.processInfo.systemUptime - started)
                XCTFail("The native window must recover active/key/exposed state after \(variant)")
                throw NSError(domain: "ComputeNativeCoverOrdering", code: 2)
            }
        }
        try retainCoverOrderingEvidence(snapshots: snapshots, outcomes: outcomes, elapsed: ProcessInfo.processInfo.systemUptime - started)
        XCTAssertTrue(outcomes.dropFirst().contains { ($0["terminal_fully_occluded"] as? Bool) == true
            && ($0["initial_window_still_visible"] as? Bool) == true },
                      "At least one explicit-order or floating native control must demonstrate full occlusion")
        XCTAssertTrue(exposed(), "The fixture must finish exposed and recoverable")
    }

    private func coverOrderingSnapshot(_ phase: String, initial: ComputeNativeFixture, cover: NSWindow?) -> [String: Any] {
        let capturedRows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let rows = capturedRows ?? []
        var ownRows: [[String: Any]] = []
        for (index, row) in rows.prefix(512).enumerated() {
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() else { continue }
            let bounds = row[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let numericBounds = Dictionary(uniqueKeysWithValues: ["X", "Y", "Width", "Height"].compactMap { key -> (String, Double)? in
                guard let value = bounds[key] as? NSNumber, value.doubleValue.isFinite else { return nil }
                return (key, value.doubleValue)
            })
            ownRows.append([
                "global_front_to_back_index": index,
                "window_number": (row[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
                "layer": (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                "alpha": (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1,
                "bounds": numericBounds,
            ])
        }
        func window(_ value: NSWindow) -> [String: Any] {
            ["window_number": value.windowNumber, "is_visible": value.isVisible, "is_key": value.isKeyWindow,
             "on_active_space": value.isOnActiveSpace, "occlusion_state": value.occlusionState.rawValue,
             "level": value.level.rawValue, "frame": NSStringFromRect(value.frame)]
        }
        let observation = initial.diagnostics.snapshot()
        return [
            "phase": phase, "uptime": ProcessInfo.processInfo.systemUptime, "app_active": NSApp.isActive,
            "app_activation_policy": NSApp.activationPolicy().rawValue,
            "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "initial": window(initial.window), "cover": cover.map { window($0) as Any } ?? NSNull(),
            "own_pid": getpid(), "own_windowserver_rows": ownRows, "windowserver_total_row_count": rows.count,
            "windowserver_snapshot_available": capturedRows != nil,
            "windowserver_scanned_row_count": min(512, rows.count), "windowserver_scan_truncated": rows.count > 512,
            "active_clocks_context_only": observation.activeClocks, "in_flight_slots_context_only": observation.inFlightSlots,
        ]
    }

    private func retainCoverOrderingEvidence(snapshots: [[String: Any]], outcomes: [[String: Any]], elapsed: Double) throws {
        let json: [String: Any] = [
            "schema_version": 1, "scope": "Actual app-hosted paused Compute fixture; owned PID window metadata only",
            "phase_deadline_seconds": 4, "elapsed_seconds": elapsed, "snapshots": snapshots, "outcomes": outcomes,
            "coordinate_systems": "CGWindow bounds use desktop upper-left coordinates; AppKit frames use lower-left coordinates",
            "occlusion_predicate": "Initial window remains isVisible and its native occlusionState lacks visible",
            "clock_evidence": "Paused and stale data can stop clocks independently; clocks are not occlusion proof",
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw NSError(domain: "ComputeNativeCoverOrdering", code: 3, userInfo: [NSLocalizedDescriptionKey: "Owned window evidence exceeds 2 MiB"])
        }
        try directEvidence.save(data, name: "compute-native-cover-ordering", extension: "json")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "compute-native-cover-ordering"; attachment.lifetime = .keepAlways
        if !directEvidence.isEnabled { add(attachment) }
        XCTAssertTrue(snapshots.allSatisfy { ($0["windowserver_snapshot_available"] as? Bool) == true },
                      "The native comparison requires actual WindowServer metadata")
    }

    func testPowerStateNotificationFromBackgroundDeliversOnMainActorAndDetaches() async throws {
        let fixture = mount(paused: true)
        await require { fixture.diagnostics.snapshot().completedCommands > 0
            && fixture.diagnostics.snapshot().inFlightSlots == 0 }
        await events(0.15)
        XCTAssertTrue(fixture.surface.hasPowerStateObservation)
        let before = fixture.diagnostics.snapshot()
        let deliveredBefore = fixture.surface.powerStateNotificationCount
        let postedOnMain = await Task.detached {
            let postedOnMain = Thread.isMainThread
            NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange,
                                             object: ProcessInfo.processInfo)
            return postedOnMain
        }.value
        XCTAssertFalse(postedOnMain, "The test must exercise Foundation's documented background delivery origin")
        await require { fixture.surface.powerStateNotificationCount == deliveredBefore + 1
            && fixture.diagnostics.snapshot().completedCommands > before.completedCommands }
        XCTAssertEqual(fixture.surface.preferredFramesPerSecond,
                       ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30)
        XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
        XCTAssertEqual(fixture.diagnostics.snapshot().failedCommands, 0)
        fixture.close()
        await require { fixture.diagnostics.snapshot().ownedBuffers == 0
            && fixture.diagnostics.snapshot().inFlightSlots == 0 }
        XCTAssertFalse(fixture.surface.hasPowerStateObservation)
        let detached = fixture.diagnostics.snapshot()
        let deliveredAtDetach = fixture.surface.powerStateNotificationCount
        await Task.detached {
            NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange,
                                             object: ProcessInfo.processInfo)
        }.value
        await events(0.15)
        XCTAssertEqual(fixture.surface.powerStateNotificationCount, deliveredAtDetach)
        XCTAssertEqual(fixture.diagnostics.snapshot().submissions, detached.submissions)
        XCTAssertEqual(fixture.diagnostics.snapshot().activeSurfaces, 0)
        XCTAssertEqual(fixture.diagnostics.snapshot().activeClocks, 0)
        XCTAssertEqual(fixture.diagnostics.snapshot().ownedBuffers, 0)
        retain("background-power-state-delivery-and-detach", fixture.diagnostics.snapshot())
    }

    func testSharedNestedClipBoundsLeasesSurviveDetachAndReparentAndRestoreOriginalFlags() async throws {
        let baselineEntries = ComputeChipMetalView.clipBoundsObservationEntryCount
        let baselineGeometryEntries = ComputeChipMetalView.geometryObservationEntryCount
        var records: [[String: Any]] = []
        for originalFlag in [false, true] {
            let fixture = ComputeSharedClipFixture(originalFlag: originalFlag)
            defer { fixture.close() }
            fixture.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            fixture.window.displayIfNeeded()
            await require { fixture.firstDiagnostics.snapshot().completedCommands > 0
                && fixture.secondDiagnostics.snapshot().completedCommands > 0
                && fixture.secondDiagnostics.snapshot().inFlightSlots == 0 }
            XCTAssertEqual(ComputeChipMetalView.clipBoundsObservationEntryCount, baselineEntries + 2)
            XCTAssertEqual(ComputeChipMetalView.geometryObservationEntryCount, baselineGeometryEntries + fixture.geometryAncestors.count)
            XCTAssertTrue(fixture.geometryAncestors.allSatisfy { $0.postsFrameChangedNotifications })
            XCTAssertTrue(fixture.outer.contentView.postsBoundsChangedNotifications)
            XCTAssertTrue(fixture.inner.contentView.postsBoundsChangedNotifications)
            weak var first = fixture.first
            fixture.releaseFirst()
            // A duplicate shutdown must neither release the surviving owner's lease nor restore its flags.
            first?.removeLifecycleObservations()
            first?.removeLifecycleObservations()
            XCTAssertTrue(fixture.outer.contentView.postsBoundsChangedNotifications)
            XCTAssertTrue(fixture.inner.contentView.postsBoundsChangedNotifications)
            XCTAssertEqual(ComputeChipMetalView.clipBoundsObservationEntryCount, baselineEntries + 2)
            XCTAssertEqual(ComputeChipMetalView.geometryObservationEntryCount, baselineGeometryEntries + fixture.geometryAncestors.count)
            XCTAssertTrue(fixture.geometryAncestors.allSatisfy { $0.postsFrameChangedNotifications })
            await require { first == nil && fixture.firstDiagnostics.snapshot().activeSurfaces == 0
                && fixture.firstDiagnostics.snapshot().inFlightSlots == 0
                && fixture.firstDiagnostics.snapshot().ownedBuffers == 0 }

            weak var second = fixture.second
            var rounds: [[String: Any]] = []
            do {
                let survivingSurface = try XCTUnwrap(fixture.second)
                let renderer = try XCTUnwrap(survivingSurface.renderer)
                for phase in ["post-first-detach", "after-reparent"] {
                    if phase == "after-reparent" {
                        survivingSurface.removeFromSuperview()
                        XCTAssertEqual(ComputeChipMetalView.clipBoundsObservationEntryCount, baselineEntries)
                        XCTAssertEqual(ComputeChipMetalView.geometryObservationEntryCount, baselineGeometryEntries)
                        XCTAssertTrue(fixture.geometryAncestors.allSatisfy { $0.postsFrameChangedNotifications == originalFlag })
                        XCTAssertEqual(fixture.outer.contentView.postsBoundsChangedNotifications, originalFlag)
                        XCTAssertEqual(fixture.inner.contentView.postsBoundsChangedNotifications, originalFlag)
                        fixture.innerDocument.addSubview(survivingSurface)
                    }
                    XCTAssertEqual(ComputeChipMetalView.clipBoundsObservationEntryCount, baselineEntries + 2)
                    XCTAssertEqual(ComputeChipMetalView.geometryObservationEntryCount, baselineGeometryEntries + fixture.geometryAncestors.count)
                    XCTAssertTrue(fixture.geometryAncestors.allSatisfy { $0.postsFrameChangedNotifications })
                    XCTAssertTrue(fixture.outer.contentView.postsBoundsChangedNotifications)
                    XCTAssertTrue(fixture.inner.contentView.postsBoundsChangedNotifications)
                    let sameSurvivingRenderer = survivingSurface.renderer === renderer
                    XCTAssertTrue(sameSurvivingRenderer)
                    fixture.outer.contentView.scroll(to: NSPoint(x: 0, y: 1_200))
                    fixture.outer.reflectScrolledClipView(fixture.outer.contentView)
                    await require { !survivingSurface.isRenderingEligible
                        && fixture.secondDiagnostics.snapshot().inFlightSlots == 0 }
                    let off = fixture.secondDiagnostics.snapshot()
                    await events(0.15)
                    XCTAssertEqual(fixture.secondDiagnostics.snapshot().submissions, off.submissions)
                    fixture.outer.contentView.scroll(to: .zero)
                    fixture.outer.reflectScrolledClipView(fixture.outer.contentView)
                    await require { survivingSurface.isRenderingEligible
                        && fixture.secondDiagnostics.snapshot().completedCommands > off.completedCommands }
                    let resumed = fixture.secondDiagnostics.snapshot()
                    XCTAssertEqual(resumed.activeSurfaces, 1)
                    XCTAssertEqual(resumed.activeClocks, 0, "Paused typed input must remain paused while native bounds events redraw it.")
                    XCTAssertEqual(resumed.failedCommands, 0)
                    rounds.append(["phase": phase, "off_submissions": off.submissions,
                        "resumed_commands": resumed.completedCommands,
                        "surviving_renderer_retained": sameSurvivingRenderer])
                }
            }
            fixture.releaseSecond()
            XCTAssertEqual(ComputeChipMetalView.clipBoundsObservationEntryCount, baselineEntries)
            XCTAssertEqual(ComputeChipMetalView.geometryObservationEntryCount, baselineGeometryEntries)
            XCTAssertTrue(fixture.geometryAncestors.allSatisfy { $0.postsFrameChangedNotifications == originalFlag })
            XCTAssertEqual(fixture.outer.contentView.postsBoundsChangedNotifications, originalFlag)
            XCTAssertEqual(fixture.inner.contentView.postsBoundsChangedNotifications, originalFlag)
            await require { second == nil && fixture.secondDiagnostics.snapshot().activeSurfaces == 0
                && fixture.secondDiagnostics.snapshot().inFlightSlots == 0
                && fixture.secondDiagnostics.snapshot().ownedBuffers == 0 }
            XCTAssertEqual(rounds.count, 2)
            records.append(["original_flag": originalFlag, "registry_baseline": baselineEntries,
                "registry_after_last_detach": ComputeChipMetalView.clipBoundsObservationEntryCount,
                "geometry_registry_baseline": baselineGeometryEntries, "geometry_ancestor_count": fixture.geometryAncestors.count,
                "geometry_registry_after_last_detach": ComputeChipMetalView.geometryObservationEntryCount,
                "all_original_frame_flags_restored": fixture.geometryAncestors.allSatisfy { $0.postsFrameChangedNotifications == originalFlag },
                "outer_flag_after_last_detach": fixture.outer.contentView.postsBoundsChangedNotifications,
                "inner_flag_after_last_detach": fixture.inner.contentView.postsBoundsChangedNotifications,
                "first_surface_released": first == nil, "second_surface_released": second == nil,
                "scroll_rounds": rounds])
        }
        XCTAssertEqual(ComputeChipMetalView.clipBoundsObservationEntryCount, baselineEntries)
        XCTAssertEqual(ComputeChipMetalView.geometryObservationEntryCount, baselineGeometryEntries)
        let data = try JSONSerialization.data(withJSONObject: ["scope": "Two real paused Compute surfaces, two shared native clips and bounded shared frame ancestors, false/true initial flags, no input update during scroll", "records": records],
                                             options: [.prettyPrinted, .sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 64 * 1_024)
        try directEvidence.save(data, name: "compute-shared-clip-bounds-leases", extension: "json")
        if !directEvidence.isEnabled {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "compute-shared-clip-bounds-leases"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func mount(paused: Bool) -> ComputeNativeFixture {
        let fixture = ComputeNativeFixture(paused: paused)
        self.fixture = fixture
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.displayIfNeeded()
        return fixture
    }
    private func wait(timeout: Double = 4, predicate: @escaping () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
    private func require(failureDescription: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line,
                         predicate: @escaping () -> Bool) async {
        let succeeded = await wait(predicate: predicate)
        let detail = succeeded ? "" : failureDescription()
        XCTAssertTrue(succeeded, "Expected bounded native Compute transition" + (detail.isEmpty ? "" : ": \(detail)"),
                      file: file, line: line)
    }
    private func events(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    private func retain(_ name: String, _ snapshot: ComputeChipRendererObservation) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do { try directEvidence.save(data, name: "compute-\(name)", extension: "json") }
        catch { XCTFail("Could not preserve the exact native Compute observation: \(error)") }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "compute-\(name)"; attachment.lifetime = .keepAlways
        if !directEvidence.isEnabled { add(attachment) }
    }
    private struct ProcessMeasurement {
        let uptime: Double
        let userSeconds: Double
        let systemSeconds: Double
    }
    private func processMeasurement() throws -> ProcessMeasurement {
        var usage = rusage()
        guard getrusage(Int32(RUSAGE_SELF), &usage) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        return ProcessMeasurement(uptime: ProcessInfo.processInfo.systemUptime,
                                  userSeconds: seconds(usage.ru_utime), systemSeconds: seconds(usage.ru_stime))
    }
    private func measurePhase(_ name: String, fixture: ComputeNativeFixture) async throws {
        await events(0.2)
        let before = try processMeasurement()
        let resourcesBefore = fixture.diagnostics.snapshot()
        await events(1.5)
        let after = try processMeasurement()
        let elapsed = after.uptime - before.uptime
        let user = after.userSeconds - before.userSeconds
        let system = after.systemSeconds - before.systemSeconds
        let resourcesAfter = fixture.diagnostics.snapshot()
        let json: [String: Any] = [
            "phase": name, "wall_seconds": elapsed, "process_user_cpu_seconds": user,
            "process_system_cpu_seconds": system, "process_cpu_percent_one_core": (user + system) / elapsed * 100,
            "submissions": resourcesAfter.submissions - resourcesBefore.submissions,
            "completed_commands": resourcesAfter.completedCommands - resourcesBefore.completedCommands,
            "last_gpu_duration_seconds": resourcesAfter.lastGPUDuration.map { $0 as Any } ?? NSNull(),
            "owned_buffers": resourcesAfter.ownedBuffers, "in_flight_slots": resourcesAfter.inFlightSlots,
            "active_clocks": resourcesAfter.activeClocks,
            "scope": "Same app-hosted fixture; process CPU includes other application-host work."
        ]
        XCTAssertGreaterThan(elapsed, 0)
        XCTAssertGreaterThanOrEqual(user + system, 0)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try directEvidence.save(data, name: "compute-process-phase-\(name)", extension: "json")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "compute-process-phase-\(name)"; attachment.lifetime = .keepAlways
        if !directEvidence.isEnabled { add(attachment) }
    }
}

@MainActor
private final class ComputeNativeFixture {
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView
    let surface: ComputeChipMetalView
    let renderer: ComputeChipRenderer
    let diagnostics = ComputeChipDiagnostics()
    init(paused: Bool) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
        document = ComputeFlippedDocument(frame: NSRect(x: 0, y: 0, width: 900, height: 1_900))
        surface = ComputeChipMetalView(frame: NSRect(x: 0, y: 0, width: 900, height: ComputeChipLayout.height(for: 900)))
        renderer = ComputeChipRenderer(diagnostics: diagnostics)
        document.addSubview(surface); scroll.documentView = document; window.contentView = scroll
        renderer.attach(surface); update(percent: 35, paused: paused)
    }
    func update(percent: Float, paused: Bool, reduceMotion: Bool = false) {
        let now = Date().timeIntervalSince1970
        let snapshot = ComputeChipSnapshot(cpu: .init(name: "Native fixture CPU", quality: .measured, observedAt: now,
                                                       activity: [percent / 100, 0, 0.2, 0], logicalCount: 4),
                                           gpu: .init(name: "Native fixture GPU", quality: .measured, observedAt: now,
                                                       activity: Array(repeating: percent / 100, count: 16), logicalCount: 0))
        renderer.update(snapshot: snapshot, autoRefresh: !paused, reduceMotion: reduceMotion, increasedContrast: false)
    }
    func resize(width: CGFloat) {
        window.setContentSize(CGSize(width: width, height: 600))
        document.setFrameSize(CGSize(width: width, height: 1_900))
        surface.setFrameSize(CGSize(width: width, height: ComputeChipLayout.height(for: width)))
        scrollBack(); window.displayIfNeeded()
    }
    func scrollAway() {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_200)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func scrollBack() {
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func close() {
        renderer.detach(from: surface); window.orderOut(nil); window.close()
    }
}
@MainActor
private final class ComputeSharedClipFixture {
    let window: NSWindow
    let outer: NSScrollView
    let inner: NSScrollView
    let outerDocument: NSView
    let innerDocument: NSView
    let firstDiagnostics = ComputeChipDiagnostics(), secondDiagnostics = ComputeChipDiagnostics()
    let firstRenderer: ComputeChipRenderer
    let secondRenderer: ComputeChipRenderer
    var first: ComputeChipMetalView?
    var second: ComputeChipMetalView?
    private(set) var geometryAncestors: [NSView] = []

    init(originalFlag: Bool) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        inner = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        outer.hasVerticalScroller = true; inner.hasVerticalScroller = true
        outerDocument = ComputeFlippedDocument(frame: NSRect(x: 0, y: 0, width: 900, height: 2_200))
        innerDocument = ComputeFlippedDocument(frame: NSRect(x: 0, y: 0, width: 900, height: 1_900))
        inner.documentView = innerDocument; outerDocument.addSubview(inner); outer.documentView = outerDocument
        outer.contentView.postsBoundsChangedNotifications = originalFlag
        inner.contentView.postsBoundsChangedNotifications = originalFlag
        firstRenderer = ComputeChipRenderer(diagnostics: firstDiagnostics)
        secondRenderer = ComputeChipRenderer(diagnostics: secondDiagnostics)
        first = ComputeChipMetalView(frame: NSRect(x: 0, y: 0, width: 430, height: 500))
        second = ComputeChipMetalView(frame: NSRect(x: 450, y: 0, width: 430, height: 500))
        window.contentView = outer
        var ancestor: NSView? = innerDocument
        while let candidate = ancestor, geometryAncestors.count < 64 {
            candidate.postsFrameChangedNotifications = originalFlag
            geometryAncestors.append(candidate)
            ancestor = candidate.superview
        }
        XCTAssertNil(ancestor, "The real shared fixture ancestry must fit the production 64-ancestor bound.")
        if let first { innerDocument.addSubview(first) }
        if let second { innerDocument.addSubview(second) }
        let now = Date().timeIntervalSince1970
        let snapshot = ComputeChipSnapshot(cpu: .init(name: "Shared clip CPU", quality: .measured, observedAt: now,
            activity: [0.35, 0, 0.2, 0], logicalCount: 4),
            gpu: .init(name: "Shared clip GPU", quality: .measured, observedAt: now,
            activity: Array(repeating: 0.35, count: 16), logicalCount: 0))
        if let first {
            firstRenderer.attach(first)
            firstRenderer.update(snapshot: snapshot, autoRefresh: false, reduceMotion: false, increasedContrast: false)
        }
        if let second {
            secondRenderer.attach(second)
            secondRenderer.update(snapshot: snapshot, autoRefresh: false, reduceMotion: false, increasedContrast: false)
        }
    }

    func releaseFirst() {
        guard let surface = first else { return }
        firstRenderer.detach(from: surface)
        surface.removeLifecycleObservations(); surface.removeLifecycleObservations()
        surface.removeFromSuperview(); first = nil
    }

    func releaseSecond() {
        guard let surface = second else { return }
        secondRenderer.detach(from: surface)
        surface.removeLifecycleObservations(); surface.removeLifecycleObservations()
        surface.removeFromSuperview(); second = nil
    }

    func close() {
        releaseFirst(); releaseSecond(); window.orderOut(nil)
        window.contentView = nil; window.close()
    }
}

@MainActor private final class ComputeFlippedDocument: NSView { override var isFlipped: Bool { true } }
#endif
