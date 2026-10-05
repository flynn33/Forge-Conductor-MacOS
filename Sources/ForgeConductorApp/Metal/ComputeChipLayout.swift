import Foundation
import CoreGraphics
import simd

/// Three float4s give Swift and the offline Metal shader an identical 48-byte instance stride.
struct ComputeChipInstance: Equatable, Sendable {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var properties: SIMD4<Float>
}

// Source-pixel coordinates in the bundled owner reference. Masks replace photographed
// activity, labels and annotation leaders while preserving package geometry and detail.
enum ComputeChipReferenceGeometry {
    static let referenceSize = CGSize(width: 1448, height: 1086)
    static let cpuCrop = CGRect(x: 174, y: 338, width: 440, height: 440)
    static let gpuCrop = CGRect(x: 824, y: 330, width: 464, height: 464)

    static let cpuOutline: [CGPoint] = [
        .init(x: 212, y: 349), .init(x: 576, y: 349),
        .init(x: 587, y: 360), .init(x: 587, y: 758),
        .init(x: 576, y: 770), .init(x: 212, y: 770),
        .init(x: 201, y: 758), .init(x: 201, y: 360),
    ]
    // One continuous outer silhouette: do not cut transparent central top/bottom
    // notches out of the GPU. Internal trim in the sampled image remains visible.
    static let gpuOutline: [CGPoint] = [
        .init(x: 853, y: 349), .init(x: 1262, y: 349),
        .init(x: 1274, y: 361), .init(x: 1274, y: 763),
        .init(x: 1262, y: 775), .init(x: 853, y: 775),
        .init(x: 841, y: 763), .init(x: 841, y: 361),
    ]
    static let cpuContactGroups: [CGRect] = [
        .init(x: 241, y: 344, width: 40, height: 16),
        .init(x: 365, y: 344, width: 40, height: 16),
        .init(x: 441, y: 344, width: 8, height: 16),
        .init(x: 508, y: 344, width: 40, height: 16),
        .init(x: 244, y: 758, width: 48, height: 16),
        .init(x: 339, y: 758, width: 27, height: 16),
        .init(x: 380, y: 758, width: 75, height: 16),
        .init(x: 508, y: 758, width: 40, height: 16),
        .init(x: 190, y: 402, width: 14, height: 56),
        .init(x: 582, y: 402, width: 14, height: 56),
        .init(x: 190, y: 625, width: 14, height: 97),
        .init(x: 582, y: 625, width: 14, height: 97),
    ]
    static let gpuContactGroups: [CGRect] = [
        .init(x: 884, y: 333, width: 39, height: 18),
        .init(x: 1189, y: 333, width: 43, height: 18),
        .init(x: 884, y: 773, width: 39, height: 16),
        .init(x: 1189, y: 773, width: 43, height: 16),
        .init(x: 828, y: 419, width: 15, height: 39),
        .init(x: 828, y: 687, width: 15, height: 34),
        .init(x: 1272, y: 686, width: 14, height: 35),
    ]

    // These encompass the framed luminous banks. Inset by 3 native pixels for
    // the actual tile field; a 2-3 pixel soft outer ring can remove baked bloom.
    static let cpuBanks: [CGRect] = [
        .init(x: 251, y: 436, width: 56, height: 83),
        .init(x: 313, y: 436, width: 56, height: 83),
        .init(x: 251, y: 530, width: 56, height: 85),
        .init(x: 313, y: 530, width: 56, height: 85),
        .init(x: 403, y: 436, width: 40, height: 83),
        .init(x: 450, y: 436, width: 40, height: 83),
        .init(x: 498, y: 436, width: 40, height: 83),
        .init(x: 403, y: 530, width: 40, height: 85),
        .init(x: 450, y: 530, width: 40, height: 85),
        .init(x: 498, y: 530, width: 40, height: 85),
    ]
    static let gpuBanks: [CGRect] = [
        .init(x: 940, y: 407, width: 55, height: 79),
        .init(x: 999, y: 407, width: 55, height: 79),
        .init(x: 1058, y: 407, width: 55, height: 79),
        .init(x: 1117, y: 407, width: 55, height: 79),
        .init(x: 940, y: 494, width: 55, height: 88),
        .init(x: 999, y: 494, width: 55, height: 88),
        .init(x: 1058, y: 494, width: 55, height: 88),
        .init(x: 1117, y: 494, width: 55, height: 88),
        .init(x: 885, y: 412, width: 32, height: 84),
        .init(x: 885, y: 505, width: 32, height: 79),
        .init(x: 885, y: 594, width: 32, height: 64),
        .init(x: 885, y: 666, width: 32, height: 50),
        .init(x: 1196, y: 412, width: 33, height: 66),
        .init(x: 1196, y: 486, width: 33, height: 62),
        .init(x: 1196, y: 556, width: 33, height: 59),
        .init(x: 1196, y: 623, width: 33, height: 93),
    ]
    // A single coarse 12 x 11 grid changes target topology. Native source tile
    // pitches are approximately 6 x 7.6px in main fields and 6.6 x 7.4px at sides.
    static let cpuGridColumns = [8, 8, 8, 8, 6, 6, 6, 6, 6, 6]
    static let cpuGridRows = [10, 10, 11, 11, 10, 10, 11, 11, 11, 11]
    static let gpuGridColumns = [8, 8, 8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 4, 4, 4, 4]
    static let gpuGridRows = [10, 10, 10, 10, 12, 12, 12, 12, 11, 10, 8, 6, 8, 8, 8, 12]

    // Replace only plate interiors, preserving all photographed border/pins.
    static let cpuPlateInterior = CGRect(x: 302, y: 658, width: 187, height: 58)
    static let gpuPlateInterior = CGRect(x: 974, y: 625, width: 170, height: 82)
    static let cpuNameplate = CGRect(x: 307, y: 667, width: 176, height: 39)
    static let gpuNameplate = CGRect(x: 980, y: 640, width: 158, height: 60)
    static let gpuAuxiliaryLightMasks: [CGRect] = [
        .init(x: 958, y: 589, width: 17, height: 49),
        .init(x: 1139, y: 589, width: 16, height: 49),
    ]
    // Visible annotation lines cross real chip pixels in the reference. Repair
    // a thin stroked mask by sampling on either normal side, before unlighting.
    static let cpuLeaderLines: [[CGPoint]] = [
        [.init(x: 201, y: 517), .init(x: 248, y: 517)],
        [.init(x: 543, y: 517), .init(x: 588, y: 517)],
    ]
    static let gpuLeaderLines: [[CGPoint]] = [
        [.init(x: 824, y: 512), .init(x: 832, y: 512), .init(x: 841, y: 502),
         .init(x: 854, y: 480), .init(x: 863, y: 471), .init(x: 884, y: 471)],
        [.init(x: 1230, y: 497), .init(x: 1251, y: 499), .init(x: 1274, y: 519)],
    ]
    static func normalized(_ source: CGRect, cpu: Bool) -> CGRect {
        let crop = cpu ? cpuCrop : gpuCrop
        return CGRect(x: (source.minX - crop.minX) / crop.width,
                      y: (source.minY - crop.minY) / crop.height,
                      width: source.width / crop.width, height: source.height / crop.height)
    }
}

struct ComputeChipLayout {
    static let maximumInstances = 4096
    static let packageScale: CGFloat = 0.46
    let size: CGSize
    let stacked: Bool
    let cpuPanel: CGRect
    let gpuPanel: CGRect
    let cpuPackage: CGRect
    let gpuPackage: CGRect
    let cpuNameplate: CGRect
    let gpuNameplate: CGRect
    let cpuRegions: [CGRect]
    let instances: [ComputeChipInstance]
    let routes: [ComputeTraceRoute]

    static func height(for width: CGFloat) -> CGFloat {
        let stacked = width < 760
        let panelWidth = stacked ? width : (width - 20) / 2
        let package = min(390, max(220, panelWidth - 70))
        return (package + 160) * (stacked ? 2 : 1) + (stacked ? 20 : 0)
    }

    static func make(width: CGFloat, cpuRegionCount: Int) -> Self {
        let width = max(width, 280)
        let stacked = width < 760
        let panelWidth = stacked ? width : (width - 20) / 2
        let previousPackageSize = min(390, max(220, panelWidth - 70))
        let packageSize = previousPackageSize * packageScale
        let panelHeight = previousPackageSize + 160
        let cpuPanel = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        let gpuPanel = CGRect(x: stacked ? 0 : panelWidth + 20,
                              y: stacked ? panelHeight + 20 : 0, width: panelWidth, height: panelHeight)
        func package(in panel: CGRect) -> CGRect {
            CGRect(x: panel.midX - packageSize / 2,
                   y: panel.minY + 83 + (previousPackageSize - packageSize) / 2,
                   width: packageSize, height: packageSize)
        }
        let cpuPackage = package(in: cpuPanel)
        let gpuPackage = package(in: gpuPanel)
        func plate(in package: CGRect, channel: Int) -> CGRect {
            let reference = channel == 0 ? ComputeChipReferenceGeometry.cpuNameplate : ComputeChipReferenceGeometry.gpuNameplate
            let normalized = ComputeChipReferenceGeometry.normalized(reference, cpu: channel == 0)
            return CGRect(x: package.minX + normalized.minX * package.width,
                          y: package.minY + normalized.minY * package.height,
                          width: normalized.width * package.width, height: normalized.height * package.height)
        }
        var instances: [ComputeChipInstance] = []
        var routes: [ComputeTraceRoute] = []
        var cpuRegions: [CGRect] = []
        func append(_ rect: CGRect, kind: Float, color: SIMD4<Float>, region: Int = -1, seed: Int = 0,
                    angle: Float = 0) {
            instances.append(.init(rect: SIMD4(Float(rect.midX), Float(rect.midY), Float(rect.width), Float(rect.height)),
                                   color: color, properties: SIMD4(kind, Float(region), Float(seed), angle)))
        }
        let blue = GraphitePalette.linearRGBA(0x33ACFF)
        let mint = GraphitePalette.linearRGBA(0x37DCC0)
        let violet = GraphitePalette.linearRGBA(0xA275FF)
        let cpuBanks = ComputeChipReferenceGeometry.cpuBanks.map {
            ComputeChipReferenceGeometry.normalized($0.insetBy(dx: 3, dy: 3), cpu: true)
        }
        let gpuBanks = ComputeChipReferenceGeometry.gpuBanks.map {
            ComputeChipReferenceGeometry.normalized($0.insetBy(dx: 3, dy: 3), cpu: false)
        }
        func mapped(_ normalized: CGRect, in body: CGRect) -> CGRect {
            CGRect(x: body.minX + normalized.minX * body.width,
                   y: body.minY + normalized.minY * body.height,
                   width: normalized.width * body.width, height: normalized.height * body.height)
        }
        for (channel, body) in [cpuPackage, gpuPackage].enumerated() {
            let s = body.width
            let panel = channel == 0 ? cpuPanel : gpuPanel
            append(panel.insetBy(dx: 0.5, dy: 0.5), kind: 9,
                   color: GraphitePalette.linearRGBA(0x0B1822), seed: channel + 101)
            append(body.insetBy(dx: -5, dy: -5).offsetBy(dx: 0, dy: 2), kind: 10,
                   color: SIMD4(0, 0, 0, 0.65), seed: channel)
            append(body, kind: 11, color: SIMD4(repeating: 1), seed: channel)
            let count = channel == 0 ? min(max(cpuRegionCount, 1), 256) : 16
            for region in 0..<count {
                let rect: CGRect
                let tint: SIMD4<Float>
                let bankIndex: Int
                let gridColumns: Int
                let gridRows: Int
                if channel == 0 {
                    bankIndex = region % cpuBanks.count
                    let bank = mapped(cpuBanks[bankIndex], in: body)
                    let population = (count + cpuBanks.count - 1 - bankIndex) / cpuBanks.count
                    let columns = max(1, Int(ceil(sqrt(Double(population) * Double(bank.width / bank.height)))))
                    let rows = Int(ceil(Double(population) / Double(columns)))
                    let cellWidth = bank.width / CGFloat(columns)
                    let cellHeight = bank.height / CGFloat(rows)
                    let position = region / cpuBanks.count
                    let gap = min(0.3, min(cellWidth, cellHeight) * 0.06)
                    rect = CGRect(x: bank.minX + CGFloat(position % columns) * cellWidth + gap,
                                  y: bank.minY + CGFloat(position / columns) * cellHeight + gap,
                                  width: cellWidth - gap * 2, height: cellHeight - gap * 2)
                    cpuRegions.append(rect)
                    gridColumns = max(1, Int((Double(ComputeChipReferenceGeometry.cpuGridColumns[bankIndex]) / Double(columns)).rounded()))
                    gridRows = max(1, Int((Double(ComputeChipReferenceGeometry.cpuGridRows[bankIndex]) / Double(rows)).rounded()))
                    tint = bankIndex < 4 ? blue : mint
                } else {
                    bankIndex = region
                    gridColumns = ComputeChipReferenceGeometry.gpuGridColumns[bankIndex]
                    gridRows = ComputeChipReferenceGeometry.gpuGridRows[bankIndex]
                    rect = mapped(gpuBanks[region], in: body)
                    tint = region >= 8 || region == 2 ? violet : blue
                }
                append(rect, kind: 4, color: tint, region: channel == 0 ? region : 256 + region,
                       seed: gridColumns + gridRows * 32 + bankIndex * 1024)
            }
            if channel == 1 {
                for (index, source) in ComputeChipReferenceGeometry.gpuAuxiliaryLightMasks.enumerated() {
                    let normalized = ComputeChipReferenceGeometry.normalized(source.insetBy(dx: 2, dy: 2), cpu: false)
                    append(mapped(normalized, in: body), kind: 12,
                           color: GraphitePalette.linearRGBA(0x25DBF4), region: 256,
                           seed: 2 + 8 * 32 + (16 + index) * 1024)
                }
            }
            let field = CGRect(x: panel.minX + 16, y: panel.minY + 92,
                               width: panel.width - 32, height: panel.height - 214)
            func clamped(_ point: SIMD2<Float>) -> SIMD2<Float> {
                SIMD2(min(max(point.x, Float(field.minX)), Float(field.maxX)),
                      min(max(point.y, Float(field.minY)), Float(field.maxY)))
            }
            // Route anchors use photographed contact groups in the same source coordinate system.
            let crop = channel == 0 ? ComputeChipReferenceGeometry.cpuCrop : ComputeChipReferenceGeometry.gpuCrop
            let outline = channel == 0 ? ComputeChipReferenceGeometry.cpuOutline : ComputeChipReferenceGeometry.gpuOutline
            let groups = channel == 0 ? ComputeChipReferenceGeometry.cpuContactGroups : ComputeChipReferenceGeometry.gpuContactGroups
            let outlineMinX = outline.map(\.x).min()!
            let outlineMaxX = outline.map(\.x).max()!
            let outlineMinY = outline.map(\.y).min()!
            let outlineMaxY = outline.map(\.y).max()!
            func anchors(side: Int) -> [CGPoint] {
                let selected = groups.filter { group in
                    switch side {
                    case 0: return group.maxY <= outlineMinY + 12
                    case 1: return group.minY >= outlineMaxY - 12
                    case 2: return group.maxX <= outlineMinX + 3
                    default: return group.minX >= outlineMaxX - 5
                    }
                }
                return selected.flatMap { group -> [CGPoint] in
                    let count = max(1, Int((side < 2 ? group.width : group.height) / 8))
                    return (0..<count).map { index in
                        let offset = (CGFloat(index) + 0.5) / CGFloat(count)
                        let point = side < 2
                            ? CGPoint(x: group.minX + group.width * offset, y: side == 0 ? group.minY + 2 : group.maxY - 2)
                            : CGPoint(x: side == 2 ? group.minX + 2 : group.maxX - 2, y: group.minY + group.height * offset)
                        return CGPoint(x: body.minX + (point.x - crop.minX) / crop.width * s,
                                       y: body.minY + (point.y - crop.minY) / crop.height * s)
                    }
                }
            }
            let sideAnchors = (0..<4).map { anchors(side: $0) }
            for routeIndex in 0..<128 {
                let side = routeIndex / 32
                let contact = routeIndex % 32
                let animated = contact % 4 == 2
                let contacts = sideAnchors[side]
                guard !contacts.isEmpty else { continue }
                let anchor = contacts[min(contacts.count - 1, contact * contacts.count / 32)]
                let origin = SIMD2<Float>(Float(anchor.x), Float(anchor.y))
                let direction: Float = side == 0 || side == 2 ? -1 : 1
                let outward = side < 2 ? SIMD2<Float>(0, direction) : SIMD2<Float>(direction, 0)
                let tangent = side < 2 ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
                let stub = 10 + Float(contact % 5) * 2
                let spread = Float(contact - 15) * 2.1
                let bend = abs(spread) * 0.55
                let extent = max(stub + abs(spread) + 16, 38 + Float((contact * 7 + channel * 11) % 11) * 4)
                let points: [SIMD2<Float>] = [origin,
                    clamped(origin + outward * stub),
                    clamped(origin + outward * (stub + bend) + tangent * (spread * 0.55)),
                    clamped(origin + outward * (extent - abs(spread) * 0.45 - 6) + tangent * (spread * 0.55)),
                    clamped(origin + outward * (extent - 6) + tangent * spread),
                    clamped(origin + outward * extent + tangent * spread)]
                if animated {
                    routes.append(ComputeTraceRoute(points: points, channel: channel,
                                                    seed: routeIndex + channel * 128))
                }
                for (a, b) in zip(points, points.dropFirst()) {
                    let vector = b - a
                    let length = simd_length(vector)
                    guard length > 0 else { continue }
                    append(CGRect(x: CGFloat((a.x + b.x) / 2 - length / 2),
                                  y: CGFloat((a.y + b.y) / 2 - 0.3), width: CGFloat(length), height: 0.6),
                           kind: 6, color: GraphitePalette.linearRGBA(0x1B6384, alpha: animated ? 0.80 : 0.44),
                           angle: atan2(vector.y, vector.x))
                }
                let endpoint = points[points.count - 1]
                append(CGRect(x: CGFloat(endpoint.x) - 0.65, y: CGFloat(endpoint.y) - 0.65,
                              width: 1.3, height: 1.3),
                       kind: 5, color: GraphitePalette.linearRGBA(0x38B6D7, alpha: animated ? 1 : 0.5), seed: routeIndex)
            }
        }
        return Self(size: CGSize(width: width, height: height(for: width)), stacked: stacked,
                    cpuPanel: cpuPanel, gpuPanel: gpuPanel, cpuPackage: cpuPackage, gpuPackage: gpuPackage,
                    cpuNameplate: plate(in: cpuPackage, channel: 0), gpuNameplate: plate(in: gpuPackage, channel: 1), cpuRegions: cpuRegions,
                    instances: instances, routes: routes)
    }
}
