import SwiftUI
import AppKit
import MetalKit
import ForgeConductorCore

@MainActor
private final class ComputeChipPresentationState: ObservableObject {
    @Published var presentation: ComputeChipPresentation?
    func apply(_ next: ComputeChipPresentation) {
        if presentation != next { presentation = next }
    }
}

/// Native labels surround one detailed Metal canvas; the canvas owns all animated FX.
struct ComputeCoresContentView: View {
    let snapshot: ComputeChipSnapshot
    var autoRefresh: Bool
    var suppressMotion = false
    var resources: ComputeChipResources = .shared
    var diagnostics: ComputeChipDiagnostics? = nil
    var surfaceDiagnostics: RuntimeDiagnostics? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.graphiteAccessibilityCapabilities) private var capabilities
    @StateObject private var state = ComputeChipPresentationState()
    @State private var cachedLayout: ComputeChipLayout?

    var body: some View {
        let layout = cachedLayout ?? ComputeChipLayout.make(width: 900, cpuRegionCount: snapshot.cpu.activity.count)
        let reducedMotion = reduceMotion || suppressMotion
        let unavailable = state.presentation?.rendererFailure ?? resources.failureReason
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if unavailable != nil {
                    ComputeChipStaticFallback(layout: layout, snapshot: snapshot, resources: resources, paused: !autoRefresh)
                        .accessibilityHidden(true)
                } else {
                    ComputeChipSurface(snapshot: snapshot, autoRefresh: autoRefresh, reduceMotion: reducedMotion,
                                       increasedContrast: contrast == .increased || capabilities.increaseContrast, resources: resources,
                                       diagnostics: diagnostics, surfaceDiagnostics: surfaceDiagnostics,
                                       presentationChanged: state.apply)
                        .allowsHitTesting(false)
                        .accessibilityLabel("CPU and GPU chip activity illustration")
                        .accessibilityIdentifier("compute-render-surface")
                }
                chipLabels(channel: snapshot.cpu, panel: layout.cpuPanel, plate: layout.cpuNameplate,
                           title: "CPU", state: unavailable == nil ? state.presentation?.cpuState : nil, id: "cpu")
                chipLabels(channel: snapshot.gpu, panel: layout.gpuPanel, plate: layout.gpuNameplate,
                           title: "GPU", state: unavailable == nil ? state.presentation?.gpuState : nil, id: "gpu")
            }
            .frame(maxWidth: .infinity)
            .frame(height: layout.size.height)
            .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.width } action: { width in
                if width > 0 && abs(width - (cachedLayout?.size.width ?? 0)) > 0.5 {
                    cachedLayout = ComputeChipLayout.make(width: width, cpuRegionCount: snapshot.cpu.activity.count)
                }
            }
            .onAppear { updateTopology() }
            .onChange(of: snapshot.cpu.activity.count) { _, _ in updateTopology() }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(spacing: 10) {
                    legend("Idle", color: GraphitePalette.textMuted, shape: .circle)
                    legend("Active", color: GraphitePalette.chartCPU, shape: .circle)
                    legend("High activity", color: GraphitePalette.chartGPU, shape: .diamond)
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(snapshot.provenance)
                .font(.system(size: 12))
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(snapshot.provenance)
                .accessibilityIdentifier("compute-activity-provenance")
            if let unavailable {
                Text("Static chip view · \(unavailable)")
                    .font(.system(size: 12))
                    .foregroundStyle(GraphitePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("Static chip view · \(unavailable)")
                    .accessibilityIdentifier("compute-renderer-status")
            } else {
                Text(reducedMotion ? "Metal · motion reduced" : autoRefresh ? "Metal · simulated trace flow" : "Metal · paused")
                    .font(.system(size: 11))
                    .foregroundStyle(GraphitePalette.textMuted)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(reducedMotion ? "Metal · motion reduced" : autoRefresh ? "Metal · simulated trace flow" : "Metal · paused")
                    .accessibilityIdentifier("compute-renderer-status")
            }
        }
        .background((reduceTransparency || capabilities.reduceTransparency) ? GraphitePalette.computePanelBottom : Color.clear)
    }

    private func updateTopology() {
        if cachedLayout?.cpuRegions.count != max(snapshot.cpu.activity.count, 1) {
            cachedLayout = ComputeChipLayout.make(width: cachedLayout?.size.width ?? 900, cpuRegionCount: snapshot.cpu.activity.count)
        }
    }

    private enum LegendShape { case circle, diamond }
    private func legend(_ title: String, color: Color, shape: LegendShape) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: shape == .circle ? 4 : 1)
                .fill(color).frame(width: 7, height: 7).rotationEffect(.degrees(shape == .diamond ? 45 : 0))
            Text(title).foregroundStyle(GraphitePalette.textSecondary)
        }
    }

    private func chipLabels(channel: ComputeChipChannel, panel: CGRect, plate: CGRect,
                            title: String, state: String?, id: String) -> some View {
        let status = state ?? channel.label(at: Date().timeIntervalSince1970, paused: !autoRefresh)
        let appleIdentity = channel.name.hasPrefix("Apple ")
        let plateName = appleIdentity ? String(channel.name.dropFirst(6)) : channel.name
        let plateFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let nameFitsPlate = plateName.rangeOfCharacter(from: .newlines) == nil
            && (plateName as NSString).size(withAttributes: [.font: plateFont]).width
                + (appleIdentity ? 14 : 0) <= plate.width - 6
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(GraphitePalette.textPrimary)
                Text(id == "cpu" ? (channel.logicalCount > 0 ? "\(channel.logicalCount) logical processors"
                      : "Logical count unavailable") : (channel.hardwareCoreCount.map { "\($0) reported GPU cores · aggregate activity" }
                                                        ?? "Aggregate activity · illustrative regions"))
                    .font(.system(size: 12)).foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .frame(width: panel.width, height: 60, alignment: .topLeading)
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    if appleIdentity && nameFitsPlate {
                        Image(systemName: "apple.logo").font(.system(size: 11))
                    }
                    Text(nameFitsPlate ? plateName : title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                if id == "gpu" && nameFitsPlate {
                    Text("GPU").font(.system(size: 8, weight: .medium))
                }
            }
                .foregroundStyle(Color(red: 0.77, green: 0.87, blue: 0.97))
                .frame(width: plate.width - 6, height: plate.height)
                .position(x: plate.midX - panel.minX, y: plate.midY - panel.minY)
                .help(channel.name)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(channel.name)
                .accessibilityIdentifier("compute-\(id)-hardware-name")
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(.clear)
                .frame(width: panel.width - 32, height: 16)
                .position(x: panel.width / 2, y: panel.height - 37)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(status)
                .accessibilityIdentifier("compute-\(id)-activity-state")
            VStack(spacing: 3) {
                if !channel.engineReadings.isEmpty {
                    Text(channel.engineReadings).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(channel.engineReadings)
                        .accessibilityIdentifier("compute-gpu-engine-readings")
                }
            }
            .frame(width: panel.width - 32, height: 30)
            .position(x: panel.width / 2, y: panel.height - 19)
        }
        .frame(width: panel.width, height: panel.height)
        .offset(x: panel.minX, y: panel.minY)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-\(id)-cores-panel")
        .allowsHitTesting(false)
    }
}

private struct ComputeChipSurface: NSViewRepresentable {
    var snapshot: ComputeChipSnapshot
    var autoRefresh: Bool
    var reduceMotion: Bool
    var increasedContrast: Bool
    var resources: ComputeChipResources
    var diagnostics: ComputeChipDiagnostics?
    var surfaceDiagnostics: RuntimeDiagnostics?
    var presentationChanged: (ComputeChipPresentation) -> Void

    func makeCoordinator() -> ComputeChipRenderer {
        ComputeChipRenderer(resources: resources, diagnostics: diagnostics ?? ComputeChipDiagnostics(), surfaceDiagnostics: surfaceDiagnostics,
                            presentationChanged: presentationChanged)
    }

    func makeNSView(context: Context) -> ComputeChipMetalView {
        let view = ComputeChipMetalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("CPU and GPU chip activity illustration")
        view.setAccessibilityIdentifier("compute-render-surface")
        context.coordinator.attach(view)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ComputeChipMetalView, context: Context) {
        context.coordinator.update(snapshot: snapshot, autoRefresh: autoRefresh, reduceMotion: reduceMotion,
                                   increasedContrast: increasedContrast)
    }

    static func dismantleNSView(_ view: ComputeChipMetalView, coordinator: ComputeChipRenderer) {
        coordinator.detach(from: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComputeChipMetalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 900, height: proposal.height ?? 500)
    }
}

/// Genuine renderer failure remains useful and detailed, but never runs an alternate animation loop.
private struct ComputeChipStaticFallback: View {
    let layout: ComputeChipLayout
    let snapshot: ComputeChipSnapshot
    let resources: ComputeChipResources
    let paused: Bool
    var body: some View {
        Canvas { context, _ in
            let wallTime = Date().timeIntervalSince1970
            for instance in layout.instances {
                let kind = Int(instance.properties.x)
                guard kind != 7 else { continue }
                let rect = CGRect(x: CGFloat(instance.rect.x - instance.rect.z / 2),
                                  y: CGFloat(instance.rect.y - instance.rect.w / 2),
                                  width: CGFloat(instance.rect.z), height: CGFloat(instance.rect.w))
                var local = context
                local.translateBy(x: rect.midX, y: rect.midY)
                local.rotate(by: .radians(Double(instance.properties.w)))
                local.translateBy(x: -rect.midX, y: -rect.midY)
                if kind == 9, let image = resources.circuitBoardImage {
                    local.clip(to: Path(roundedRect: rect, cornerRadius: min(10, min(rect.width, rect.height) * 0.08)))
                    local.draw(Image(decorative: image, scale: 1), in: rect)
                    continue
                }
                if kind == 10 {
                    guard let image = instance.properties.z == 0
                        ? resources.cpuMaterialImage : resources.gpuMaterialImage else { continue }
                    var silhouette = local.resolve(Image(decorative: image, scale: 1))
                    silhouette.shading = .color(.black.opacity(Double(instance.color.w)))
                    local.addFilter(.blur(radius: 2.4))
                    local.draw(silhouette, in: rect.insetBy(dx: 5, dy: 5))
                    continue
                }
                if kind == 11 {
                    guard let image = instance.properties.z == 0
                        ? resources.cpuMaterialImage : resources.gpuMaterialImage else { continue }
                    local.draw(Image(decorative: image, scale: 1), in: rect)
                    continue
                }
                let color = Color(.sRGBLinear, red: Double(instance.color.x), green: Double(instance.color.y),
                                  blue: Double(instance.color.z), opacity: Double(instance.color.w))
                let path = kind == 5 ? Path(ellipseIn: rect) : Path(roundedRect: rect,
                    cornerRadius: kind == 9 ? 8 : kind == 0 || kind == 1 ? min(7, rect.width * 0.018) : 1)
                if kind != 4 && kind != 12 { local.fill(path, with: .color(color)) }
                if kind == 0 || kind == 1 || kind == 3 || kind == 8 || kind == 9 {
                    local.stroke(path, with: .color(GraphitePalette.controlBorder.opacity(0.4)), lineWidth: 0.7)
                }
                if kind == 4 || kind == 12 {
                    let region = Int(instance.properties.y)
                    let channel = region < 256 ? snapshot.cpu : snapshot.gpu
                    let index = region < 256 ? region : region - 256
                    let measured = channel.quality == .measured || channel.quality == .aggregateFallback
                    let value: Float? = measured && channel.activity.indices.contains(index) ? channel.activity[index] : nil
                    if value == 0 { continue }
                    let metadata = Int(instance.properties.z)
                    let bank = metadata / 1024
                    let regionColor = value == nil ? GraphitePalette.unavailable
                        : activityTint(instance: instance, bank: bank, value: value ?? 0)
                    let brightness = channel.quality != .measured && channel.quality != .aggregateFallback
                        ? 0.5 : paused || channel.isFresh(at: wallTime) ? 1.0 : 0.35
                    let columns = max(1, min(31, metadata % 32))
                    let rows = max(1, min(31, metadata / 32 % 32))
                    let step = rect.width / CGFloat(columns)
                    let rowStep = rect.height / CGFloat(rows)
                    let energy = value.map { pow(Double($0), 0.65) * brightness } ?? 0
                    local.fill(path, with: .color(regionColor.opacity(value == nil ? 0.04 * brightness
                        : energy * (region >= 256 ? 0.12 : 0.06))))
                    for column in 0..<columns {
                        for row in 0..<rows {
                            let tile = CGRect(x: rect.minX + (CGFloat(column) + 0.16) * step,
                                              y: rect.minY + (CGFloat(row) + 0.16) * rowStep,
                                              width: step * 0.66, height: rowStep * 0.66)
                            let density = Double((column * 17 + row * 31 + region * 13) % 101) / 100
                            let dx = (Double(column) + 0.5) / Double(columns) - 0.48
                            let dy = (Double(row) + 0.5) / Double(rows) - 0.56
                            let coloredHalo = exp(-8 * (dx * dx + dy * dy))
                            let hotspot = exp(-18 * (dx * dx + dy * dy))
                            if value != nil {
                                var glow = local
                                glow.addFilter(.blur(radius: min(step, rowStep) * 0.32))
                                glow.fill(Path(tile.insetBy(dx: -step * 0.12, dy: -rowStep * 0.12)),
                                          with: .color(regionColor.opacity(energy * (0.12 + coloredHalo * 0.24))))
                            }
                            local.fill(Path(roundedRect: tile, cornerRadius: min(step, rowStep) * 0.08),
                                       with: .color(regionColor.opacity(value == nil ? 0.10 * brightness
                                            : energy * (0.24 + density * 0.42 + coloredHalo * 0.28))))
                            if value != nil {
                                local.fill(Path(tile.insetBy(dx: step * 0.12, dy: rowStep * 0.12)),
                                           with: .color(Color(red: 0.78, green: 0.97, blue: 1)
                                                .opacity(hotspot * energy * 0.88)))
                            }
                        }
                    }
                }
            }
        }
    }

    private func activityTint(instance: ComputeChipInstance, bank: Int, value: Float) -> Color {
        var tint = SIMD3(instance.color.x, instance.color.y, instance.color.z)
        if instance.properties.y >= 256 && instance.properties.x != 12 {
            let blue = SIMD3<Float>(0.0331, 0.4125, 1.0)
            let cyan = SIMD3<Float>(0.0331, 0.7157, 1.0)
            let mint = SIMD3<Float>(0.0382, 0.7157, 0.5271)
            let violet = SIMD3<Float>(0.3613, 0.1779, 1.0)
            let target: SIMD3<Float>
            let amount: Float
            if bank == 1 || bank == 5 {
                let t = min(max((value - 0.15) / (0.62 - 0.15), 0), 1)
                tint = blue
                target = cyan
                amount = t * t * (3 - 2 * t)
            } else if bank == 2 || bank >= 8 {
                tint = blue
                target = violet
                amount = 0.20 + 0.75 * value
            } else {
                target = mint
                amount = value * 0.10
            }
            tint = tint * (1 - amount) + target * amount
        }
        return Color(.sRGBLinear, red: Double(tint.x), green: Double(tint.y), blue: Double(tint.z))
    }
}
