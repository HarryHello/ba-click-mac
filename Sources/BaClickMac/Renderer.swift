import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

struct TexturedVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD3<Float>
    var particleAlpha: Float
    var coverageFactor: Float
}

struct RingVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD3<Float>
    var dissolveThreshold: Float
    var coverageOpacity: Float
}

final class Renderer: NSObject, MTKViewDelegate {
    let particleSystem = ParticleSystem()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let sampler: MTLSamplerState

    private let diskPipeline: MTLRenderPipelineState
    private let ringPipeline: MTLRenderPipelineState
    private let trianglePipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState

    private let circleTexture: MTLTexture
    private let ringTexture: MTLTexture
    private let triangleTexture: MTLTexture
    private let trailTexture: MTLTexture

    private var viewportSize = SIMD2<Float>(1, 1)
    private var scale: Float = 1

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.source, options: nil),
              let texturedVertex = library.makeFunction(name: "textured_vertex"),
              let ringVertex = library.makeFunction(name: "ring_vertex"),
              let diskFragment = library.makeFunction(name: "disk_fragment"),
              let ringFragment = library.makeFunction(name: "ring_fragment"),
              let triangleFragment = library.makeFunction(name: "triangle_fragment"),
              let trailFragment = library.makeFunction(name: "trail_fragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.sampler = sampler

        // Load the original game-derived textures from the web project.
        guard let circle = Renderer.loadTexture(device: device, name: "circle", ext: "rgba", width: 512, height: 512, pixelFormat: .rgba8Unorm_srgb),
              let ring = Renderer.loadTexture(device: device, name: "ring", ext: "raw", width: 256, height: 128, pixelFormat: .r8Unorm),
              let triangle = Renderer.loadTexture(device: device, name: "triangle", ext: "rgba", width: 128, height: 128, pixelFormat: .rgba8Unorm_srgb),
              let trail = Renderer.loadTexture(device: device, name: "trail", ext: "rgba", width: 512, height: 512, pixelFormat: .rgba8Unorm_srgb) else {
            return nil
        }
        self.circleTexture = circle
        self.ringTexture = ring
        self.triangleTexture = triangle
        self.trailTexture = trail

        do {
            self.diskPipeline = try Renderer.makePipeline(
                device: device,
                view: view,
                vertexFunction: texturedVertex,
                fragmentFunction: diskFragment
            )
            self.ringPipeline = try Renderer.makePipeline(
                device: device,
                view: view,
                vertexFunction: ringVertex,
                fragmentFunction: ringFragment
            )
            self.trianglePipeline = try Renderer.makePipeline(
                device: device,
                view: view,
                vertexFunction: texturedVertex,
                fragmentFunction: triangleFragment
            )
            self.trailPipeline = try Renderer.makePipeline(
                device: device,
                view: view,
                vertexFunction: texturedVertex,
                fragmentFunction: trailFragment
            )
        } catch {
            return nil
        }

        super.init()

        view.device = device
        view.delegate = self
        updateProjection(view: view)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateProjection(view: view)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        particleSystem.update(now: now)

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        var diskVertices: [TexturedVertex] = []
        var ringVertices: [RingVertex] = []
        var triangleVertices: [TexturedVertex] = []
        var trailVertices: [TexturedVertex] = []

        appendDisks(to: &diskVertices)
        appendRings(to: &ringVertices)
        appendShards(to: &triangleVertices)
        appendTrail(to: &trailVertices)

        encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        var diskEmission = BAEffect.disk.emission
        encoder.setFragmentBytes(&diskEmission, length: MemoryLayout<Float>.size, index: 2)
        drawTextured(vertices: diskVertices, texture: circleTexture, pipeline: diskPipeline, encoder: encoder)

        var ringEmission = BAEffect.rings.hdrIntensity
        encoder.setFragmentBytes(&ringEmission, length: MemoryLayout<Float>.size, index: 2)
        drawRing(vertices: ringVertices, texture: ringTexture, pipeline: ringPipeline, encoder: encoder)

        drawTextured(vertices: triangleVertices, texture: triangleTexture, pipeline: trianglePipeline, encoder: encoder)
        drawTextured(vertices: trailVertices, texture: trailTexture, pipeline: trailPipeline, encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Geometry building

    private func appendDisks(to vertices: inout [TexturedVertex]) {
        for burst in particleSystem.bursts {
            let progress = Float(burst.ageMs / Double(BAEffect.disk.lifetimeMs))
            guard progress >= 0, progress < 1 else { continue }

            let alpha = BAEval.number(BAEffect.disk.alphaKeys, progress)
            guard alpha > 0.01 else { continue }

            let size = BAEffect.disk.radius * BAEval.hermite(BAEffect.disk.sizeKeys, progress) * scale
            let color = BAEval.color(BAEffect.disk.colorKeys, progress)
            let material = Renderer.linearEnergy(color, intensity: BAEffect.disk.emission)
            appendTexturedSprite(
                center: burst.position,
                size: size,
                angle: burst.diskRotation,
                uvMin: SIMD2(0, 0),
                uvMax: SIMD2(1, 1),
                color: material,
                particleAlpha: alpha,
                coverageFactor: 1,
                to: &vertices
            )
        }
    }

    private func appendRings(to vertices: inout [RingVertex]) {
        for burst in particleSystem.bursts {
            let progress = Float(burst.ageMs / Double(BAEffect.rings.lifetimeMs))
            guard progress >= 0, progress < 1 else { continue }

            let sizeFactor = BAEval.hermite(BAEffect.rings.sizeKeys, progress)
            let dissolve = BAEval.hermite(BAEffect.rings.dissolveKeys, progress)
            let color = BAEval.color(BAEffect.rings.colorKeys, progress)
            let material = Renderer.linearEnergy(color, intensity: BAEffect.rings.hdrIntensity)

            for ring in burst.rings {
                let radius = ring.radius * sizeFactor
                appendRingSprite(
                    center: burst.position,
                    radius: radius,
                    angle: ring.rotation,
                    color: material,
                    dissolveThreshold: dissolve,
                    coverageOpacity: 1,
                    to: &vertices
                )
            }
        }
    }

    private func appendShards(to vertices: inout [TexturedVertex]) {
        for shard in particleSystem.shards {
            let progress = Float(shard.ageMs / shard.lifetimeMs)
            guard progress >= 0, progress < 1 else { continue }

            let alpha = BAEval.number(BAEffect.shards.alphaKeys, progress)
            guard alpha > 0.01 else { continue }

            let size = shard.size * BAEval.hermite(BAEffect.shards.sizeKeys, progress)
            let color = BAEval.color(BAEffect.shards.colorKeys, progress)
            let material = Renderer.linearEnergy(color, intensity: BAEffect.shards.hdrIntensity) * BAEffect.shards.startColor
            let flipV = shard.textureFrame % 2 == 1
            let uvMin = SIMD2<Float>(0, flipV ? 1 : 0)
            let uvMax = SIMD2<Float>(1, flipV ? 0 : 1)
            appendTexturedSprite(
                center: shard.position,
                size: size,
                angle: 0,
                uvMin: uvMin,
                uvMax: uvMax,
                color: material,
                particleAlpha: alpha,
                coverageFactor: 1,
                to: &vertices
            )
        }
    }

    private func appendTrail(to vertices: inout [TexturedVertex]) {
        let points = particleSystem.trail
        guard points.count >= 2 else { return }

        let totalLength = zip(points, points.dropFirst()).reduce(Float(0)) { acc, pair in
            acc + simd_distance(pair.0.position, pair.1.position)
        }
        guard totalLength > 0 else { return }

        var distances: [Float] = [0]
        for i in 1..<points.count {
            distances.append(distances[i - 1] + simd_distance(points[i - 1].position, points[i].position))
        }

        let halfWidth = BAEffect.trail.width * scale * 0.5
        let materialIntensity: Float = 23.968628

        for i in 1..<points.count {
            let from = points[i - 1]
            let to = points[i]
            let delta = to.position - from.position
            let length = simd_length(delta)
            guard length > 0.0001 else { continue }

            let tangent = delta / length
            let normal = SIMD2(-tangent.y, tangent.x)
            let offset = normal * halfWidth

            let fromProgress = distances[i - 1] / totalLength
            let toProgress = distances[i] / totalLength
            let fromColor = Renderer.linearEnergy(
                BAEval.color(BAEffect.trail.gradient, fromProgress),
                intensity: materialIntensity
            )
            let toColor = Renderer.linearEnergy(
                BAEval.color(BAEffect.trail.gradient, toProgress),
                intensity: materialIntensity
            )
            let fromCoverage = BAEval.number(BAEffect.trail.coverageLongitudinalKeys, fromProgress)
            let toCoverage = BAEval.number(BAEffect.trail.coverageLongitudinalKeys, toProgress)

            let fromLeft = from.position + offset
            let fromRight = from.position - offset
            let toLeft = to.position + offset
            let toRight = to.position - offset

            let uFrom = 1 - fromProgress
            let uTo = 1 - toProgress

            let v0 = TexturedVertex(position: fromLeft, uv: SIMD2(uFrom, 1), color: fromColor, particleAlpha: BAEffect.trail.trailOpacity, coverageFactor: fromCoverage)
            let v1 = TexturedVertex(position: toLeft, uv: SIMD2(uTo, 1), color: toColor, particleAlpha: BAEffect.trail.trailOpacity, coverageFactor: toCoverage)
            let v2 = TexturedVertex(position: toRight, uv: SIMD2(uTo, 0), color: toColor, particleAlpha: BAEffect.trail.trailOpacity, coverageFactor: toCoverage)
            let v3 = TexturedVertex(position: fromRight, uv: SIMD2(uFrom, 0), color: fromColor, particleAlpha: BAEffect.trail.trailOpacity, coverageFactor: fromCoverage)

            vertices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
        }
    }

    // MARK: - Vertex builders

    private func appendTexturedSprite(
        center: SIMD2<Float>,
        size: Float,
        angle: Float,
        uvMin: SIMD2<Float>,
        uvMax: SIMD2<Float>,
        color: SIMD3<Float>,
        particleAlpha: Float,
        coverageFactor: Float,
        to vertices: inout [TexturedVertex]
    ) {
        let half = size * 0.5
        let c = cos(angle)
        let s = sin(angle)
        let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(-half, -half), SIMD2(uvMin.x, uvMin.y)),
            (SIMD2(half, -half), SIMD2(uvMax.x, uvMin.y)),
            (SIMD2(half, half), SIMD2(uvMax.x, uvMax.y)),
            (SIMD2(-half, half), SIMD2(uvMin.x, uvMax.y))
        ]
        var tri: [TexturedVertex] = []
        tri.reserveCapacity(4)
        for (corner, uv) in corners {
            let rotated = SIMD2(
                corner.x * c - corner.y * s,
                corner.x * s + corner.y * c
            )
            tri.append(TexturedVertex(position: center + rotated, uv: uv, color: color, particleAlpha: particleAlpha, coverageFactor: coverageFactor))
        }
        vertices.append(contentsOf: [tri[0], tri[1], tri[2], tri[0], tri[2], tri[3]])
    }

    private func appendRingSprite(
        center: SIMD2<Float>,
        radius: Float,
        angle: Float,
        color: SIMD3<Float>,
        dissolveThreshold: Float,
        coverageOpacity: Float,
        to vertices: inout [RingVertex]
    ) {
        let half = radius
        let c = cos(angle)
        let s = sin(angle)
        let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(-half, -half), SIMD2(0, 0)),
            (SIMD2(half, -half), SIMD2(1, 0)),
            (SIMD2(half, half), SIMD2(1, 1)),
            (SIMD2(-half, half), SIMD2(0, 1))
        ]
        var tri: [RingVertex] = []
        tri.reserveCapacity(4)
        for (corner, uv) in corners {
            let rotated = SIMD2(
                corner.x * c - corner.y * s,
                corner.x * s + corner.y * c
            )
            tri.append(RingVertex(position: center + rotated, uv: uv, color: color, dissolveThreshold: dissolveThreshold, coverageOpacity: coverageOpacity))
        }
        vertices.append(contentsOf: [tri[0], tri[1], tri[2], tri[0], tri[2], tri[3]])
    }

    private func drawTextured(
        vertices: [TexturedVertex],
        texture: MTLTexture,
        pipeline: MTLRenderPipelineState,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        vertices.withUnsafeBytes { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private func drawRing(
        vertices: [RingVertex],
        texture: MTLTexture,
        pipeline: MTLRenderPipelineState,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        vertices.withUnsafeBytes { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private func updateProjection(view: MTKView) {
        let bounds = view.bounds
        viewportSize = SIMD2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1)))
        scale = Float(max(bounds.height, 1) / 1080.0)
        particleSystem.setViewportHeight(bounds.height)
    }

    // MARK: - Helpers

    private static func makePipeline(
        device: MTLDevice,
        view: MTKView,
        vertexFunction: MTLFunction,
        fragmentFunction: MTLFunction
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func loadTexture(
        device: MTLDevice,
        name: String,
        ext: String,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture? {
        guard let url = resourceURL(name: name, ext: ext),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        data.withUnsafeBytes { raw in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * (pixelFormat == .r8Unorm ? 1 : 4)
            )
        }
        return texture
    }

    private static func resourceURL(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates = [
            exeURL.deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)"),
            exeURL.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func srgbToLinear(_ value: Float) -> Float {
        let c = min(max(value / 255.0, 0), 1)
        if c <= 0.04045 {
            return c / 12.92
        }
        return pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearEnergy(_ color: SIMD3<Float>, intensity: Float) -> SIMD3<Float> {
        SIMD3(
            srgbToLinear(color.x),
            srgbToLinear(color.y),
            srgbToLinear(color.z)
        ) * intensity
    }
}