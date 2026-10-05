import Foundation
import simd

struct ComputeTraceRoute: Equatable, Sendable {
    let points: [SIMD2<Float>]
    let channel: Int
    let seed: Int
    let cumulativeLengths: [Float]

    init(points: [SIMD2<Float>], channel: Int, seed: Int) {
        self.points = Array(points.prefix(16)); self.channel = channel; self.seed = seed
        var lengths: [Float] = [0]
        for (a, b) in zip(self.points, self.points.dropFirst()) {
            lengths.append((lengths.last ?? 0) + simd_distance(a, b))
        }
        cumulativeLengths = lengths
    }
    var length: Float { cumulativeLengths.last ?? 0 }

    func point(at distance: Float) -> (position: SIMD2<Float>, angle: Float) {
        guard let first = points.first else { return (.zero, 0) }
        let distance = min(max(distance, 0), length)
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let vector = b - a
            let segment = cumulativeLengths[index] - cumulativeLengths[index - 1]
            if segment > 0, distance <= cumulativeLengths[index] {
                return (a + vector * ((distance - cumulativeLengths[index - 1]) / segment), atan2(vector.y, vector.x))
            }
        }
        let a = points.dropLast().last ?? first
        let b = points.last ?? first
        return (b, atan2(b.y - a.y, b.x - a.x))
    }
}

/// Renderer-local envelopes and distance phases; no model publication or source sampling.
struct ComputeChipAnimation {
    static let maximumRoutes = 64
    static let maximumPulses = 192
    private(set) var values = Array(repeating: Float(0), count: 272)
    private var hasObservedValue = Array(repeating: false, count: 272)
    private(set) var active = [false, false]
    private(set) var phase: [Float] = [0, 0]
    private var hold: [Double] = [0, 0]
    private var lastTime: TimeInterval?
    private var pulseStorage: [ComputeChipInstance] = []

    mutating func resetClock() { lastTime = nil }

    mutating func advance(snapshot: ComputeChipSnapshot, monotonic: TimeInterval, wallTime: TimeInterval,
                          motionAllowed: Bool, paused: Bool) -> Bool {
        let dt = Float(min(max(lastTime.map { monotonic - $0 } ?? 0, 0), 0.1))
        lastTime = monotonic
        func targets(_ channel: ComputeChipChannel) -> [Float?] {
            if paused && (channel.quality == .measured || channel.quality == .aggregateFallback) {
                return channel.activity
            }
            return channel.validActivity(at: wallTime)
        }
        let sources = [targets(snapshot.cpu), targets(snapshot.gpu)]
        var needsMotion = false
        for channel in 0..<2 {
            let offset = channel == 0 ? 0 : 256
            let source = sources[channel]
            let maximum = source.reduce(Float(0)) { max($0, $1 ?? 0) }
            if !source.contains(where: { $0 != nil }) {
                active[channel] = false; hold[channel] = 0
            } else if maximum >= 0.02 { active[channel] = true; hold[channel] = 0.35 }
            else if maximum < 0.01 {
                hold[channel] = max(0, hold[channel] - Double(dt))
                if hold[channel] == 0 { active[channel] = false }
            }
            let fresh = channel == 0 ? snapshot.cpu.isFresh(at: wallTime) : snapshot.gpu.isFresh(at: wallTime)
            let input = channel == 0 ? snapshot.cpu : snapshot.gpu
            let staleMeasured = !paused && !fresh && (input.quality == .measured || input.quality == .aggregateFallback)
            for index in 0..<(channel == 0 ? 256 : 16) {
                let valueIndex = offset + index
                if staleMeasured {
                    if !hasObservedValue[valueIndex] {
                        if index < input.activity.count, let previous = input.activity[index] {
                            values[valueIndex] = previous; hasObservedValue[valueIndex] = true
                        } else { values[valueIndex] = -1 }
                    }
                    continue
                }
                guard index < source.count, let target = source[index] else {
                    values[valueIndex] = -1; hasObservedValue[valueIndex] = false; continue
                }
                hasObservedValue[valueIndex] = true
                if values[valueIndex] < 0 { values[valueIndex] = 0 }
                if !motionAllowed || paused {
                    values[valueIndex] = target
                } else {
                    let tau: Float = target > values[valueIndex] ? 0.18 : 0.5
                    values[valueIndex] += (target - values[valueIndex]) * (1 - exp(-dt / tau))
                    if abs(target - values[valueIndex]) < 0.001 { values[valueIndex] = target }
                }
                if fresh && abs(target - values[valueIndex]) >= 0.001 { needsMotion = true }
            }
            if motionAllowed && !paused && fresh && active[channel] {
                phase[channel] += dt * (60 + 100 * min(max(maximum, 0), 1))
                // Keep simulation arithmetic bounded across arbitrarily long sessions.
                if phase[channel] > 100_000 { phase[channel].formTruncatingRemainder(dividingBy: 100_000) }
                needsMotion = true
            }
        }
        return motionAllowed && !paused && needsMotion
    }

    mutating func pulseInstances(routes: [ComputeTraceRoute], snapshot: ComputeChipSnapshot,
                        wallTime: TimeInterval, motionAllowed: Bool, paused: Bool) -> [ComputeChipInstance] {
        pulseStorage.removeAll(keepingCapacity: true)
        guard motionAllowed && !paused else { return pulseStorage }
        pulseStorage.reserveCapacity(min(routes.count, Self.maximumRoutes) * 3)
        let cpuMaximum = snapshot.cpu.activity.reduce(Float(0)) { max($0, $1 ?? 0) }
        let gpuMaximum = snapshot.gpu.activity.reduce(Float(0)) { max($0, $1 ?? 0) }
        for route in routes.prefix(Self.maximumRoutes) {
            let channel = route.channel
            let source = channel == 0 ? snapshot.cpu : snapshot.gpu
            guard source.isFresh(at: wallTime), active[channel], route.length > 1 else { continue }
            let distance = (phase[channel] + Float(route.seed * 17)).truncatingRemainder(dividingBy: route.length)
            let maximum = channel == 0 ? cpuMaximum : gpuMaximum
            for tail in 0..<3 {
                let sample = max(0, distance - Float(tail) * 10)
                let position = route.point(at: sample)
                let color = GraphitePalette.linearRGBA(0x25DBF4,
                    alpha: (1 - Float(tail) * 0.27) * (0.35 + maximum * 0.65))
                pulseStorage.append(.init(rect: SIMD4(position.position.x, position.position.y,
                                               tail == 0 ? 9 : 15, tail == 0 ? 9 : 6),
                                    color: color, properties: SIMD4(7, -1, Float(route.seed), position.angle)))
            }
        }
        return pulseStorage
    }
}
