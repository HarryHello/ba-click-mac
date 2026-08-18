import Foundation
import CoreGraphics
import QuartzCore
import simd

struct RingParticle {
    var radius: Float
    var rotation: Float
    var angularBlend: Float
    var angularVelocity: Float
}

struct ClickBurst {
    var position: SIMD2<Float>
    var ageMs: Double
    var diskRotation: Float
    var rings: [RingParticle]
}

struct ShardParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var ageMs: Double
    var lifetimeMs: Double
    var size: Float
    var textureFrame: Int
}

struct TrailPoint {
    var position: SIMD2<Float>
    var time: Double
}

/// Ports the web project's FX_Touch particle state more faithfully:
/// click bursts contain rotating dissolve rings + disk; shards fly outward;
/// a separate trail keeps the most recent cursor path.
final class ParticleSystem {
    var bursts: [ClickBurst] = []
    var shards: [ShardParticle] = []
    var trail: [TrailPoint] = []

    private(set) var pendingClicks: [SIMD2<Float>] = []
    private var scale: Float = 1
    var ringScale: Float = 1
    var shardScale: Float = 1
    private var lastTime: Double = 0
    private var lastTrailPoint: SIMD2<Float> = .zero
    private var lastPointerPosition: SIMD2<Float>?
    private var trailDistanceSinceShard: Float = 0

    func setViewportHeight(_ height: CGFloat) {
        scale = Float(max(height, 1) / 1080.0)
    }

    func addClick(at position: SIMD2<Float>) {
        pendingClicks.append(position)
    }

    func addTrailPoint(at position: SIMD2<Float>) {
        let now = CACurrentMediaTime()

        if let previous = lastPointerPosition {
            let delta = position - previous
            let length = simd_length(delta)
            if length > 0 {
                spawnTrailShards(from: previous, to: position, distance: length)
            }
        }
        lastPointerPosition = position

        let minDistance = BAEffect.trail.minVertexDistance * scale
        if trail.isEmpty || simd_distance(lastTrailPoint, position) >= minDistance {
            trail.append(TrailPoint(position: position, time: now))
            lastTrailPoint = position
        }
    }

    func update(now: Double) {
        if lastTime == 0 {
            lastTime = now
        }

        for position in pendingClicks {
            spawnClick(at: position)
        }
        pendingClicks.removeAll()

        let deltaMs = (now - lastTime) * 1000
        if deltaMs > 0 && deltaMs < 100 {
            updateBursts(deltaMs: deltaMs)
            updateShards(deltaMs: deltaMs)
        }

        bursts.removeAll { $0.ageMs >= Double(BAEffect.rings.lifetimeMs) }
        shards.removeAll { $0.ageMs >= $0.lifetimeMs }
        trail.removeAll { now - $0.time >= 0.3 }

        lastTime = now
    }

    func hasActiveParticles() -> Bool {
        !bursts.isEmpty || !shards.isEmpty || !trail.isEmpty
    }

    // MARK: - Spawning

    private func spawnClick(at position: SIMD2<Float>) {
        var rings: [RingParticle] = []
        for _ in 0..<BAEffect.rings.count {
            let angularBlend = Float.random(in: 0...1)
            rings.append(
                RingParticle(
                    radius: Float.random(in: BAEffect.rings.radiusMin...BAEffect.rings.radiusMax) * ringScale * scale,
                    rotation: Float.random(in: 0..<(2 * .pi)),
                    angularBlend: angularBlend,
                    angularVelocity: ringAngularVelocity(angularBlend: angularBlend, progress: 0)
                )
            )
        }

        bursts.append(
            ClickBurst(
                position: position,
                ageMs: 0,
                diskRotation: Float.random(in: 0..<(2 * .pi)),
                rings: rings
            )
        )

        let speedRange = BAEffect.shards.clickSpeedMin...BAEffect.shards.clickSpeedMax
        let sizeRange = BAEffect.shards.sizeMin...BAEffect.shards.sizeMax
        let lifetimeRange = BAEffect.shards.clickLifetimeMinMs...BAEffect.shards.clickLifetimeMaxMs

        for _ in 0..<BAEffect.shards.clickCount {
            let angle = Float.random(in: 0..<(2 * .pi))
            let speed = Float.random(in: speedRange) * scale * shardScale
            let radius = BAEffect.shards.clickRadius * scale * shardScale
            let velocity = SIMD2<Float>(cos(angle), sin(angle)) * speed
            shards.append(
                ShardParticle(
                    position: position + SIMD2<Float>(cos(angle), sin(angle)) * radius,
                    velocity: velocity,
                    ageMs: 0,
                    lifetimeMs: Double(Float.random(in: lifetimeRange)),
                    size: Float.random(in: sizeRange) * scale * shardScale,
                    textureFrame: Int.random(in: 0...1)
                )
            )
        }
    }

    private func spawnTrailShards(from: SIMD2<Float>, to: SIMD2<Float>, distance: Float) {
        let spacing = max(1, BAEffect.shards.trailSpacing * scale)
        let combined = trailDistanceSinceShard + distance
        let strides = Int(combined / spacing)
        guard strides > 0, shards.count < BAEffect.shards.maxCount else {
            trailDistanceSinceShard = combined.truncatingRemainder(dividingBy: spacing)
            return
        }

        for stride in 0..<strides {
            let travelled = spacing - trailDistanceSinceShard + Float(stride) * spacing
            let progress = min(1, travelled / distance)
            let position = from + (to - from) * progress
            spawnTrailShard(at: position)
            if shards.count >= BAEffect.shards.maxCount {
                break
            }
        }
        trailDistanceSinceShard = combined.truncatingRemainder(dividingBy: spacing)
    }

    private func spawnTrailShard(at position: SIMD2<Float>) {
        let angle = Float.random(in: 0..<(2 * .pi))
        let speed = Float.random(in: BAEffect.shards.trailSpeedMin...BAEffect.shards.trailSpeedMax) * scale * shardScale
        let radius = BAEffect.shards.trailRadius * scale * shardScale
        let direction = SIMD2<Float>(cos(angle), sin(angle))
        let lifetime = Float.random(in: BAEffect.shards.trailLifetimeMinMs...BAEffect.shards.trailLifetimeMaxMs)

        shards.append(
            ShardParticle(
                position: position + direction * radius,
                velocity: direction * speed,
                ageMs: 0,
                lifetimeMs: Double(lifetime),
                size: Float.random(in: BAEffect.shards.sizeMin...BAEffect.shards.sizeMax) * scale * shardScale,
                textureFrame: Int.random(in: 0...1)
            )
        )
    }

    private func ringAngularVelocity(angularBlend: Float, progress: Float) -> Float {
        let minV = BAEval.smoothNumber(BAEffect.rings.angularVelocityMinKeys, progress)
        let maxV = BAEval.smoothNumber(BAEffect.rings.angularVelocityMaxKeys, progress)
        let velocity = minV + (maxV - minV) * angularBlend
        return velocity * BAEffect.rings.angularVelocityMultiplier * BAEffect.rings.rotationDirection
    }

    private func updateBursts(deltaMs: Double) {
        for index in bursts.indices {
            let previousAge = bursts[index].ageMs
            bursts[index].ageMs += deltaMs

            for ringIndex in bursts[index].rings.indices {
                let sampleAgeMs = (previousAge + bursts[index].ageMs) * 0.5
                let progress = Float(sampleAgeMs / Double(BAEffect.rings.lifetimeMs))
                bursts[index].rings[ringIndex].angularVelocity = ringAngularVelocity(
                    angularBlend: bursts[index].rings[ringIndex].angularBlend,
                    progress: progress
                )
                bursts[index].rings[ringIndex].rotation +=
                    bursts[index].rings[ringIndex].angularVelocity * Float(deltaMs / 1000)
            }
        }
    }

    private func updateShards(deltaMs: Double) {
        let seconds = Float(deltaMs / 1000)
        for index in shards.indices {
            shards[index].ageMs += deltaMs
            shards[index].position += shards[index].velocity * seconds
        }
    }
}