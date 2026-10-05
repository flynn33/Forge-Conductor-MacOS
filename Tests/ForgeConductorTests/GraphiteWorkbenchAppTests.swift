import AppKit
import SwiftUI
import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class GraphiteWorkbenchAppTests: XCTestCase {
    func testWorkbenchControlsDefaultHiddenAndPersistOnlyExplicitChoices() throws {
        let suite = "forge.workbench.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untouched-manager-draft", forKey: "manager.fixture")
        let preferences = WorkbenchPreferences(defaults: defaults)
        XCTAssertTrue(preferences.enabledControls.isEmpty)
        for control in WorkbenchPreferences.Control.allCases {
            XCTAssertFalse(preferences.shows(control))
            XCTAssertNil(defaults.object(forKey: control.preferenceKey))
        }
        preferences.setShown(true, for: .guidedSetup)
        preferences.setShown(true, for: .refresh)
        let reopened = WorkbenchPreferences(defaults: defaults)
        XCTAssertEqual(reopened.enabledControls, [.guidedSetup, .refresh])
        reopened.setShown(false, for: .refresh)
        XCTAssertEqual(WorkbenchPreferences(defaults: defaults).enabledControls, [.guidedSetup])
        XCTAssertEqual(defaults.string(forKey: "manager.fixture"), "untouched-manager-draft")
        for control in WorkbenchPreferences.Control.allCases where control != .guidedSetup && control != .refresh {
            XCTAssertNil(defaults.object(forKey: control.preferenceKey))
        }
    }

    func testWorkbenchPreferencesRemainIsolatedBetweenDefaultsSuites() throws {
        let firstSuite = "forge.workbench.tests.\(UUID().uuidString)"
        let secondSuite = "forge.workbench.tests.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }
        WorkbenchPreferences(defaults: first).setShown(true, for: .navigation)
        XCTAssertTrue(WorkbenchPreferences(defaults: first).shows(.navigation))
        XCTAssertTrue(WorkbenchPreferences(defaults: second).enabledControls.isEmpty)
    }

    func testSetupPresentationActivatesOwningWindowWithoutEnablingControls() throws {
        let suite = "forge.workbench.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkbenchPreferences(defaults: defaults)
        var activations = 0
        preferences.activateMainWindow = { activations += 1 }
        preferences.presentGuidedSetup()
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(preferences.isGuidedSetupPresented)
        XCTAssertTrue(preferences.enabledControls.isEmpty)
        preferences.isGuidedSetupPresented = false
        preferences.presentGuidedSetup()
        XCTAssertEqual(activations, 2)
        XCTAssertTrue(preferences.isGuidedSetupPresented)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("forge.workbench.control.")
        }.isEmpty)
    }

    func testReadableForegroundsAndInteractiveBoundariesMeetContrastTargets() throws {
        let pairs: [(Color, Color, Double, String)] = [
            (GraphitePalette.textPrimary, GraphitePalette.canvas, 4.5, "body"),
            (GraphitePalette.textSecondary, GraphitePalette.panelTop, 4.5, "secondary"),
            (GraphitePalette.textMuted, GraphitePalette.field, 4.5, "metadata"),
            (GraphitePalette.textPrimary, GraphitePalette.selectionTop, 4.5, "selected navigation"),
            (GraphitePalette.primaryInk, GraphitePalette.primaryFill, 4.5, "primary action"),
            (GraphitePalette.primaryInk, GraphitePalette.primaryHovered, 4.5, "hovered primary action"),
            (GraphitePalette.primaryInk, GraphitePalette.primaryPressed, 4.5, "pressed action"),
            (GraphitePalette.failure, GraphitePalette.destructiveSurface, 4.5, "destructive action"),
            (GraphitePalette.success, GraphitePalette.panelTop, 4.5, "success"),
            (GraphitePalette.warning, GraphitePalette.panelTop, 4.5, "warning"),
            (GraphitePalette.controlBorder, GraphitePalette.field, 3, "field boundary"),
            (GraphitePalette.focus, GraphitePalette.field, 3, "keyboard focus"),
        ]
        for (foreground, background, minimum, name) in pairs {
            let a = try luminance(foreground)
            let b = try luminance(background)
            XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), minimum, name)
        }
    }

    func testMetalUsesSameOpaqueGraphiteCanvasAndDistinctSeries() throws {
        let canvas = try XCTUnwrap(NSColor(GraphitePalette.canvas).usingColorSpace(.sRGB))
        XCTAssertEqual(GraphitePalette.metalClear.red, canvas.redComponent, accuracy: 0.00001)
        XCTAssertEqual(GraphitePalette.metalClear.green, canvas.greenComponent, accuracy: 0.00001)
        XCTAssertEqual(GraphitePalette.metalClear.blue, canvas.blueComponent, accuracy: 0.00001)
        XCTAssertEqual(GraphitePalette.metalClear.alpha, 1)
        let pairs: [(Color, SIMD4<Float>)] = [
            (GraphitePalette.chartCPU, GraphitePalette.metalCPU),
            (GraphitePalette.chartRAM, GraphitePalette.metalRAM),
            (GraphitePalette.chartGPU, GraphitePalette.metalGPU),
        ]
        for (color, encoded) in pairs {
            let uiColor = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            XCTAssertEqual(encoded.x, Float(uiColor.redComponent), accuracy: 0.00001)
            XCTAssertEqual(encoded.y, Float(uiColor.greenComponent), accuracy: 0.00001)
            XCTAssertEqual(encoded.z, Float(uiColor.blueComponent), accuracy: 0.00001)
        }
        XCTAssertNotEqual(GraphitePalette.metalCPU, GraphitePalette.metalRAM)
        XCTAssertNotEqual(GraphitePalette.metalCPU, GraphitePalette.metalGPU)
    }

    func testChipSRGBBoundaryConvertsOnceAndPreservesAlpha() {
        XCTAssertEqual(GraphitePalette.linearRGBA(0x000000), SIMD4(0, 0, 0, 1))
        XCTAssertEqual(GraphitePalette.linearRGBA(0xFFFFFF, alpha: 0.25), SIMD4(1, 1, 1, 0.25))
        let converted = GraphitePalette.linearRGBA(0x808080)
        XCTAssertEqual(converted.x, 0.21586, accuracy: 0.00001)
        XCTAssertEqual(converted.y, converted.x)
        XCTAssertEqual(converted.z, converted.x)
    }

    func testTraceGeometryClampsFiniteValuesAndRejectsInvalidScale() {
        let groups = GraphiteTraceGeometry.segments(samples: [-20, 50, 140, nil, .nan, .infinity, 0])
        XCTAssertEqual(groups.map(\.count), [3, 1])
        XCTAssertEqual(groups[0][0].y, -0.85, accuracy: 0.00001)
        XCTAssertEqual(groups[0][1].y, 0, accuracy: 0.00001)
        XCTAssertEqual(groups[0][2].y, 0.85, accuracy: 0.00001)
        XCTAssertEqual(groups[1][0].y, -0.85, accuracy: 0.00001)
        XCTAssertTrue(groups.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertTrue(GraphiteTraceGeometry.segments(samples: [30, 50], maximumValue: 0).isEmpty)
        XCTAssertTrue(GraphiteTraceGeometry.segments(samples: [30, 50], maximumValue: .nan).isEmpty)
        let disk = GraphiteTraceGeometry.segments(samples: [0, 100, 200], maximumValue: 200)
        XCTAssertEqual(disk[0][1].y, 0, accuracy: 0.00001)
    }

    func testTraceFillAndEveryStrokeLayerSplitAtMissingSamples() {
        let parts = GraphiteTraceGeometry.parts(samples: [10, 20, nil, 70, 80],
                                               color: GraphitePalette.rgba(0xC69BF1),
                                               viewport: CGSize(width: 200, height: 80))
        XCTAssertEqual(parts.fill.count, 12)
        XCTAssertEqual(parts.core.count, 12)
        XCTAssertEqual(parts.halo.count, 24)
        for triangle in stride(from: 0, to: parts.fill.count, by: 3) {
            let positions = parts.fill[triangle..<(triangle + 3)].map { $0.pos.x }
            XCTAssertTrue(positions.allSatisfy { $0 <= -0.5 } || positions.allSatisfy { $0 >= 0.5 },
                          "No fill triangle may cross the missing sample at x=0")
        }
        for layer in [parts.core, parts.halo] {
            for triangle in stride(from: 0, to: layer.count, by: 3) {
                let positions = layer[triangle..<(triangle + 3)].map { $0.pos.x }
                XCTAssertTrue(positions.allSatisfy { $0 < -0.4 } || positions.allSatisfy { $0 > 0.4 },
                              "Neither the bright core nor its halo may bridge a gap")
            }
        }
    }

    func testEmptyAndUnavailableTraceDoNotInventZeroAndSingleSampleRemainsIsolated() {
        let viewport = CGSize(width: 140, height: 36)
        for samples: [Float?] in [[], [nil, .nan, .infinity]] {
            let parts = GraphiteTraceGeometry.parts(samples: samples, color: GraphitePalette.rgba(0x52DCD3), viewport: viewport)
            XCTAssertEqual(parts.vertexCount, 0)
            XCTAssertTrue(GraphiteTraceGeometry.segments(samples: samples).isEmpty)
        }
        let single = GraphiteTraceGeometry.parts(samples: [50], color: GraphitePalette.rgba(0x52DCD3), viewport: viewport)
        XCTAssertTrue(single.fill.isEmpty)
        XCTAssertEqual(single.core.count, 6)
        let zeros = GraphiteTraceGeometry.parts(samples: [0, 0], color: GraphitePalette.rgba(0x52DCD3), viewport: viewport)
        XCTAssertEqual(zeros.core.count, 6)
        XCTAssertEqual(zeros.fill.count, 6)
        XCTAssertTrue(zeros.fill.allSatisfy { abs($0.pos.y + 0.85) < 0.00001 })
    }

    func testTraceStrokeWidthRemainsInPointsAcrossViewportSizesAndSlopes() {
        for viewport in [CGSize(width: 200, height: 80), CGSize(width: 400, height: 160)] {
            for end in [SIMD2<Float>(0.5, 0), SIMD2<Float>(0.5, 0.5)] {
                let vertices = GraphiteTraceGeometry.stroke(SIMD2(-0.5, 0), end, viewport: viewport,
                                                           color: GraphitePalette.rgba(0x52DCD3), width: 1.35)
                XCTAssertEqual(vertices.count, 6)
                let delta = vertices[1].pos - vertices[0].pos
                let widthInPoints = hypot(Double(delta.x) * viewport.width / 2, Double(delta.y) * viewport.height / 2)
                XCTAssertEqual(widthInPoints, 1.35, accuracy: 0.00001)
            }
        }
    }

    func testTraceGeometryUsesOnlyLatest300SamplesAndBoundedVertices() {
        let samples = Array<Float?>(repeating: 25, count: 2_000)
        let normalized = GraphiteTraceGeometry.normalizedSamples(samples)
        XCTAssertEqual(normalized.count, 300)
        let viewport = CGSize(width: 180, height: 36)
        let parts = GraphiteTraceGeometry.parts(samples: samples, color: GraphitePalette.rgba(0xF1CA70),
                                               viewport: viewport, fraction: 0.5)
        XCTAssertEqual(parts.fill.count, 6 * 299)
        XCTAssertEqual(parts.halo.count, 12 * 299)
        XCTAssertEqual(parts.core.count, 6 * 299)
        XCTAssertEqual(parts.meter.count, 12)
        XCTAssertLessThanOrEqual(parts.vertexCount, 24 * 300 + 12)
        XCTAssertTrue((parts.fill + parts.halo + parts.core + parts.meter).allSatisfy {
            $0.pos.x.isFinite && $0.pos.y.isFinite && $0.color.w.isFinite
        })
        XCTAssertEqual(GraphiteTraceGeometry.parts(samples: [1, 2], color: GraphitePalette.rgba(0x52DCD3),
                                                  viewport: .zero).vertexCount, 0)
        XCTAssertTrue(GraphiteTraceGeometry.normalizedSamples([.nan, .infinity, nil]).allSatisfy { $0 == nil })
        let suffix = GraphiteTraceGeometry.normalizedSamples(Array<Float?>(repeating: 99, count: 300) + [7])
        XCTAssertEqual(suffix.first, 99)
        XCTAssertEqual(suffix.last, 7)
    }

    private func luminance(_ color: Color) throws -> Double {
        let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
