import Foundation
import simd

/// Keyframe helpers matching the web project's Unity curve evaluation.
enum BAEval {
    static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    /// Linear keyframes: [time, value]
    static func number(_ keys: [[Float]], _ progress: Float) -> Float {
        let t = clamp01(progress)
        if t <= keys[0][0] { return keys[0][1] }
        for i in 1..<keys.count {
            if t <= keys[i][0] {
                let prev = keys[i - 1]
                let curr = keys[i]
                let span = curr[0] - prev[0]
                let local = span > 0 ? (t - prev[0]) / span : 1
                return lerp(prev[1], curr[1], local)
            }
        }
        return keys[keys.count - 1][1]
    }

    /// Unity smooth curve: [time, value], smoothstep interpolation between values
    static func smoothNumber(_ keys: [[Float]], _ progress: Float) -> Float {
        let t = clamp01(progress)
        if t <= keys[0][0] { return keys[0][1] }
        for i in 1..<keys.count {
            if t <= keys[i][0] {
                let prev = keys[i - 1]
                let curr = keys[i]
                let span = curr[0] - prev[0]
                let local = span > 0 ? (t - prev[0]) / span : 1
                let eased = local * local * (3 - 2 * local)
                return lerp(prev[1], curr[1], eased)
            }
        }
        return keys[keys.count - 1][1]
    }

    /// Unity Hermite keyframes: [time, value, inSlope, outSlope]
    static func hermite(_ keys: [[Float]], _ progress: Float) -> Float {
        let t = clamp01(progress)
        if t <= keys[0][0] { return keys[0][1] }
        for i in 1..<keys.count {
            if t <= keys[i][0] {
                let prev = keys[i - 1]
                let curr = keys[i]
                let span = curr[0] - prev[0]
                let local = span > 0 ? (t - prev[0]) / span : 1
                let s = local * local
                let c = s * local
                let prevOut = prev.count > 3 ? prev[3] : 0
                let currIn = curr.count > 2 ? curr[2] : 0
                let h00 = 2 * c - 3 * s + 1
                let h10 = c - 2 * s + local
                let h01 = -2 * c + 3 * s
                let h11 = c - s
                return h00 * prev[1] + h10 * prevOut * span +
                    h01 * curr[1] + h11 * currIn * span
            }
        }
        return keys[keys.count - 1][1]
    }

    /// Color keyframes: [time, r, g, b] (0...255)
    static func color(_ keys: [[Float]], _ progress: Float) -> SIMD3<Float> {
        let t = clamp01(progress)
        if t <= keys[0][0] {
            return SIMD3(keys[0][1], keys[0][2], keys[0][3])
        }
        for i in 1..<keys.count {
            if t <= keys[i][0] {
                let prev = keys[i - 1]
                let curr = keys[i]
                let span = curr[0] - prev[0]
                let local = span > 0 ? (t - prev[0]) / span : 1
                return SIMD3(
                    lerp(prev[1], curr[1], local),
                    lerp(prev[2], curr[2], local),
                    lerp(prev[3], curr[3], local)
                )
            }
        }
        let last = keys[keys.count - 1]
        return SIMD3(last[1], last[2], last[3])
    }
}

enum BAEffect {
    static let worldToReferencePixels: Float = 540
    static let shardLocalScale: Float = 0.3078824
    static let shardUnit = worldToReferencePixels * shardLocalScale
    static let ringMeshOuterRadius: Float = 1.0636684

    enum disk {
        static let lifetimeMs: Float = 200
        static let radius: Float = 0.12 * 2 * 0.5 * worldToReferencePixels
        static let colorKeys: [[Float]] = [
            [0, 255, 255, 255],
            [0.1205921, 61.344, 99.607, 255]
        ]
        static let alphaKeys: [[Float]] = [
            [0, 1],
            [0.1088273, 1],
            [1, 0]
        ]
        static let sizeKeys: [[Float]] = [
            [0, 0.32583582, 2.4004734, 2.4004734],
            [0.21392822, 0.7159773, 0.9115745, 0.9115745],
            [1, 1, 0, 0]
        ]
        static let emission: Float = 2.0
    }

    enum rings {
        static let count = 2
        static let lifetimeMs: Float = 600
        // Raw Unity radii; runtime scale applied via settings.ringScale.
        static let radiusMin: Float = 0.12 * worldToReferencePixels * ringMeshOuterRadius
        static let radiusMax: Float = 0.14 * worldToReferencePixels * ringMeshOuterRadius
        static let angularVelocityMinKeys: [[Float]] = [
            [0.14903903, 1],
            [1, 0.45561826]
        ]
        static let angularVelocityMaxKeys: [[Float]] = [
            [0.15865384, 0.79881656],
            [1, -0.06509134]
        ]
        static let angularVelocityMultiplier: Float = 11.170107
        static let rotationDirection: Float = -1
        static let bandToOuterRadius: Float = 0.0598573766034603
        static let widthStart: Float = 1
        static let widthEnd: Float = 1
        static let dissolveDirection: Float = 1
        static let radialSamples = 8
        static let arcSamples = 96
        static let textureUvMin: Float = 0.0005
        static let textureUvMax: Float = 0.9995
        static let hdrIntensity: Float = 5.992157
        static let colorKeys: [[Float]] = [
            [0.1117723, 255, 255, 255],
            [0.5000076, 75.778, 166.588, 255],
            [1, 75.778, 166.588, 255]
        ]
        static let sizeKeys: [[Float]] = [
            [0.007209778, 0.42050898, 2.4004734, 2.4004734],
            [0.21392822, 0.7159773, 0.9115745, 0.9115745],
            [1, 1, 0, 0]
        ]
        static let dissolveKeys: [[Float]] = [
            [0, 1, 0, 0],
            [0.2, 0, 0, 2.4249368],
            [1, 1, 0.27735636, 0.27735636]
        ]
    }

    enum shards {
        static let hdrIntensity: Float = 5.992157
        static let startColor = SIMD3<Float>(0.5377358, 0.5377358, 0.5377358)
        static let clickCount = 4
        static let clickLifetimeMinMs: Float = 600
        static let clickLifetimeMaxMs: Float = 700
        static let clickRadius: Float = 0.3 * shardUnit
        static let clickSpeedMin: Float = 0.3 * shardUnit
        static let clickSpeedMax: Float = 0.4 * shardUnit
        static let trailRadius: Float = 0.15 * shardUnit
        static let trailSpeedMin: Float = 0.2 * shardUnit
        static let trailSpeedMax: Float = 0.3 * shardUnit
        static let trailLifetimeMinMs: Float = 200
        static let trailLifetimeMaxMs: Float = 400
        static let trailSpacing: Float = worldToReferencePixels / 5
        static let maxCount = 200
        static let sizeMin: Float = 0.1 * shardUnit
        static let sizeMax: Float = 0.2 * shardUnit
        static let sizeKeys: [[Float]] = [
            [0, 0, 0, 0],
            [0.15445095, 1, 0, 0],
            [1, 0, -2.1621501, -2.1621501]
        ]
        static let colorKeys: [[Float]] = [
            [0, 255, 255, 255],
            [0.1823606, 255, 255, 255],
            [0.282353, 94.92, 197.16, 255],
            [0.4617685, 94.99, 196.99, 255],
            [0.6617685, 89.99, 185.99, 240.99],
            [0.8264744, 94.99, 196.99, 255],
            [1, 94.99, 196.99, 255]
        ]
        static let alphaKeys: [[Float]] = [
            [0, 1],
            [0.2882429, 1],
            [0.3647059, 0],
            [0.4705882, 1],
            [0.5735256, 0],
            [0.6676432, 1],
            [0.7558862, 0],
            [0.8529488, 1],
            [1, 1]
        ]
    }

    enum trail {
        static let lifetimeMs: Float = 300
        static let geometryWidth: Float = 0.005 * worldToReferencePixels
        static let width: Float = 0.005 * worldToReferencePixels
        static let minVertexDistance: Float = 0.01 * worldToReferencePixels
        static let trailOpacity: Float = 1.0
        static let gradient: [[Float]] = [
            [0, 0, 0, 0],
            [0.5794156, 0, 50, 130],
            [0.97941558, 0, 160, 255],
            [1, 0, 175, 255]
        ]
        static let coverageLongitudinalKeys: [[Float]] = [
            [0, 0.15],
            [0.248532, 0.15],
            [0.97941558, 1],
            [1, 1]
        ]
    }
}
