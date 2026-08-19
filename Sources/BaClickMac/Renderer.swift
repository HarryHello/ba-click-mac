import AppKit
import Metal
import MetalKit
import MetalPerformanceShaders
import QuartzCore
import simd

/// Vertex payloads are built from float4 lanes only, so the Swift layout is
/// guaranteed to match the MSL struct byte-for-byte (no packed/alignment doubt).
struct TexturedVertex {
    var a: SIMD4<Float> // position.xy
    var b: SIMD4<Float> // uv.xy
    var c: SIMD4<Float> // color.rgb + particleAlpha
    var d: SIMD4<Float> // coverageFactor

    init(position: SIMD2<Float>, uv: SIMD2<Float>, color: SIMD3<Float>, particleAlpha: Float, coverageFactor: Float) {
        self.a = SIMD4(position.x, position.y, 0, 0)
        self.b = SIMD4(uv.x, uv.y, 0, 0)
        self.c = SIMD4(color.x, color.y, color.z, particleAlpha)
        self.d = SIMD4(coverageFactor, 0, 0, 0)
    }
}

struct RingVertex {
    var a: SIMD4<Float> // position.xy
    var b: SIMD4<Float> // uv.xy
    var c: SIMD4<Float> // color.rgb + dissolveThreshold
    var d: SIMD4<Float> // coverageOpacity

    init(position: SIMD2<Float>, uv: SIMD2<Float>, color: SIMD3<Float>, dissolveThreshold: Float, coverageOpacity: Float) {
        self.a = SIMD4(position.x, position.y, 0, 0)
        self.b = SIMD4(uv.x, uv.y, 0, 0)
        self.c = SIMD4(color.x, color.y, color.z, dissolveThreshold)
        self.d = SIMD4(coverageOpacity, 0, 0, 0)
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let particleSystem = ParticleSystem()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let sampler: MTLSamplerState

    private let sceneDiskPipeline: MTLRenderPipelineState
    private let sceneRingPipeline: MTLRenderPipelineState
    private let sceneTrailPipeline: MTLRenderPipelineState
    private let diskPipeline: MTLRenderPipelineState
    private let ringPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
    private let trianglePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let bloomAddPipeline: MTLRenderPipelineState
    private let prefilterPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLRenderPipelineState
    let bloomEnabled: Bool
    /// BA_BLOOM_DEBUG_VIEW=1 shows only the bloom pyramid (no core), to
    /// verify the glow itself is being generated.
    let bloomDebugView: Bool
    var debugBloomLevels: Int { bloomLevelCount }
    var debugBloomSampleScale: Float { bloomSampleScale }
    var debugBloomIntensityFactor: Float {
        Float(Foundation.exp(Double(settings.bloomStrength) / 10.0 * 0.6931471805599453) - 1.0)
    }

    private let circleTexture: MTLTexture
    private let ringTexture: MTLTexture
    private let triangleTexture: MTLTexture
    private let trailTexture: MTLTexture

    private var hdrSceneTexture: MTLTexture?
    private var bloomDownTextures: [MTLTexture] = []
    private var bloomUpTextures: [MTLTexture] = []
    private var bloomLevelSizes: [CGSize] = []
    private var bloomLevelCount: Int = 4
    private var bloomSampleScale: Float = 1.0
    private var lastBloomLevels: Int = 16
    private var lastBloomDiffusion: Float = 7.0
    private var sceneSize: CGSize = .zero
    private weak var currentView: MTKView?
    private(set) var settings: FXSettings
    private var lastSettingsReload: TimeInterval = 0

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
              let trailFragment = library.makeFunction(name: "trail_fragment"),
              let trailSceneFragment = library.makeFunction(name: "trail_scene_fragment"),
              let diskSceneFragment = library.makeFunction(name: "disk_scene_fragment"),
              let ringSceneFragment = library.makeFunction(name: "ring_scene_fragment"),
              let prefilterFragment = library.makeFunction(name: "prefilter_fragment"),
              let downsampleFragment = library.makeFunction(name: "downsample_fragment"),
              let upsampleFragment = library.makeFunction(name: "upsample_fragment"),
              let fullscreenVertex = library.makeFunction(name: "fullscreen_vertex"),
              let compositeFragment = library.makeFunction(name: "composite_fragment"),
              let bloomAddFragment = library.makeFunction(name: "bloom_add_fragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        // Bloom now works, default ON; disable with BA_DISABLE_BLOOM=1.
        self.bloomEnabled = getenv("BA_DISABLE_BLOOM") == nil
        self.bloomDebugView = getenv("BA_BLOOM_DEBUG_VIEW") != nil
        self.settings = FXSettings.load()
        particleSystem.ringScale = settings.ringScale
        particleSystem.shardScale = settings.shardScale
        dlog("[renderer] bloomEnabled=\(self.bloomEnabled) settings=disk\(settings.diskScale) ring\(settings.ringScale)")

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
              let triangle = Renderer.loadTexture(device: device, name: "triangle", ext: "rgba", width: 256, height: 128, pixelFormat: .rgba8Unorm_srgb),
              let trail = Renderer.loadTexture(device: device, name: "trail", ext: "rgba", width: 512, height: 512, pixelFormat: .rgba8Unorm_srgb) else {
            return nil
        }
        self.circleTexture = circle
        self.ringTexture = ring
        self.triangleTexture = triangle
        self.trailTexture = trail

        do {
            // Scene (HDR bloom targets) are rendered with rgba16Float pipelines.
            self.sceneDiskPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: texturedVertex,
                fragmentFunction: diskSceneFragment,
                pixelFormat: .rgba16Float
            )
            self.sceneRingPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: ringVertex,
                fragmentFunction: ringSceneFragment,
                pixelFormat: .rgba16Float
            )
            self.sceneTrailPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: texturedVertex,
                fragmentFunction: trailSceneFragment,
                pixelFormat: .rgba16Float
            )
            // Fallback (no bloom targets) pipelines target the window directly.
            self.diskPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: texturedVertex,
                fragmentFunction: diskFragment,
                pixelFormat: view.colorPixelFormat
            )
            self.ringPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: ringVertex,
                fragmentFunction: ringFragment,
                pixelFormat: view.colorPixelFormat
            )
            self.trailPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: texturedVertex,
                fragmentFunction: trailFragment,
                pixelFormat: view.colorPixelFormat
            )
            // Triangle shards and the final composite target the window.
            self.trianglePipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: texturedVertex,
                fragmentFunction: triangleFragment,
                pixelFormat: view.colorPixelFormat
            )
            self.compositePipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: fullscreenVertex,
                fragmentFunction: compositeFragment,
                pixelFormat: view.colorPixelFormat
            )
            self.bloomAddPipeline = try Renderer.makeAdditivePipeline(
                device: device,
                vertexFunction: fullscreenVertex,
                fragmentFunction: bloomAddFragment,
                pixelFormat: view.colorPixelFormat
            )
            self.prefilterPipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: fullscreenVertex,
                fragmentFunction: prefilterFragment,
                pixelFormat: .rgba16Float
            )
            self.downsamplePipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: fullscreenVertex,
                fragmentFunction: downsampleFragment,
                pixelFormat: .rgba16Float
            )
            self.upsamplePipeline = try Renderer.makePipeline(
                device: device,
                vertexFunction: fullscreenVertex,
                fragmentFunction: upsampleFragment,
                pixelFormat: .rgba16Float
            )
        } catch {
            return nil
        }

        super.init()

        view.device = device
        view.delegate = self
        currentView = view
        updateProjection(view: view)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateProjection(view: view)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()

        // Reload settings.json every 0.5s so the user can tune live.
        if now - lastSettingsReload > 0.5 {
            settings = FXSettings.load()
            particleSystem.ringScale = settings.ringScale
            particleSystem.shardScale = settings.shardScale
            if settings.bloomLevels != lastBloomLevels ||
                settings.bloomDiffusion != lastBloomDiffusion {
                lastBloomLevels = settings.bloomLevels
                lastBloomDiffusion = settings.bloomDiffusion
                sceneSize = .zero
                if let view = currentView {
                    updateProjection(view: view)
                }
            }
            lastSettingsReload = now
        }

        particleSystem.update(now: now)

        var diskVertices: [TexturedVertex] = []
        var ringVertices: [RingVertex] = []
        var triangleVertices: [TexturedVertex] = []
        var trailVertices: [TexturedVertex] = []

        appendDisks(to: &diskVertices)
        appendRings(to: &ringVertices)
        appendShards(to: &triangleVertices)
        appendTrail(to: &trailVertices, now: now)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // 1) MXFinalBloom-style multi-level bloom on a single HDR scene.
        if bloomEnabled,
           let hdr = hdrSceneTexture,
           !bloomDownTextures.isEmpty,
           !bloomUpTextures.isEmpty {
            let scenePass = MTLRenderPassDescriptor()
            scenePass.colorAttachments[0].texture = hdr
            scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            scenePass.colorAttachments[0].loadAction = .clear
            scenePass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
                drawParticles(
                    disk: diskVertices,
                    ring: ringVertices,
                    triangle: [],
                    trail: trailVertices,
                    encoder: encoder,
                    sceneTarget: true
                )
                encoder.endEncoding()
            }

            // Prefilter bright energy, downsample, upsample.
            renderPrefilter(source: hdr, dest: bloomDownTextures[0], commandBuffer: commandBuffer)
            for i in 1..<bloomLevelCount {
                renderDownsample(source: bloomDownTextures[i - 1], dest: bloomDownTextures[i], commandBuffer: commandBuffer)
            }
            let last = bloomLevelCount - 1
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: bloomDownTextures[last], to: bloomUpTextures[last])
                blit.endEncoding()
            }
            if bloomLevelCount >= 2 {
                for i in stride(from: bloomLevelCount - 2, through: 0, by: -1) {
                    renderUpsample(
                        coarse: bloomUpTextures[i + 1],
                        fine: bloomDownTextures[i],
                        dest: bloomUpTextures[i],
                        commandBuffer: commandBuffer
                    )
                }
            }
        }

        // 2) Always draw the core effect directly to the window, then add the
        //    final bloom pyramid on top.
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        // Sharp core. Skipped in BA_BLOOM_DEBUG_VIEW so only the raw glow shows.
        if !bloomDebugView {
            drawParticles(
                disk: diskVertices,
                ring: ringVertices,
                triangle: triangleVertices,
                trail: trailVertices,
                encoder: encoder
            )
        }

        if bloomEnabled, let finalBloom = bloomUpTextures.first, let hdrScene = hdrSceneTexture {
            encoder.setRenderPipelineState(bloomAddPipeline)
            encoder.setFragmentTexture(finalBloom, index: 0)
            encoder.setFragmentTexture(hdrScene, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var bloomTexel = SIMD2<Float>(
                1.0 / Float(max(finalBloom.width, 1)),
                1.0 / Float(max(finalBloom.height, 1))
            )
            encoder.setFragmentBytes(&bloomTexel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            let intensityFactor = Float(Foundation.exp(Double(settings.bloomStrength) / 10.0 * 0.6931471805599453) - 1.0)
            var sampleScaleAndIntensity = SIMD2<Float>(bloomSampleScale, intensityFactor)
            encoder.setFragmentBytes(&sampleScaleAndIntensity, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            var falloff = settings.bloomFalloff
            encoder.setFragmentBytes(&falloff, length: MemoryLayout<Float>.size, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderPrefilter(source: MTLTexture, dest: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dest
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(prefilterPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var texel = SIMD2<Float>(1.0 / Float(source.width), 1.0 / Float(source.height))
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        let linearThreshold = Renderer.gammaToLinearUnit(settings.bloomThreshold)
        let knee = linearThreshold * 0.0 + 0.00001
        var thresholdVec = SIMD4<Float>(
            linearThreshold,
            linearThreshold - knee,
            knee * 2.0,
            0.25 / knee
        )
        encoder.setFragmentBytes(&thresholdVec, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        var clampValue: Float = 65504.0
        encoder.setFragmentBytes(&clampValue, length: MemoryLayout<Float>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func renderDownsample(source: MTLTexture, dest: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dest
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(downsamplePipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var texel = SIMD2<Float>(1.0 / Float(source.width), 1.0 / Float(source.height))
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func renderUpsample(coarse: MTLTexture, fine: MTLTexture, dest: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dest
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(upsamplePipeline)
        encoder.setFragmentTexture(coarse, index: 0)
        encoder.setFragmentTexture(fine, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var texel = SIMD2<Float>(1.0 / Float(coarse.width), 1.0 / Float(coarse.height))
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        var sampleScale = bloomSampleScale
        encoder.setFragmentBytes(&sampleScale, length: MemoryLayout<Float>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func drawParticles(
        disk: [TexturedVertex],
        ring: [RingVertex],
        triangle: [TexturedVertex],
        trail: [TexturedVertex],
        encoder: MTLRenderCommandEncoder,
        sceneTarget: Bool = false
    ) {
        let diskPipeline = sceneTarget ? sceneDiskPipeline : self.diskPipeline
        let ringPipeline = sceneTarget ? sceneRingPipeline : self.ringPipeline
        let trailPipeline = sceneTarget ? sceneTrailPipeline : self.trailPipeline

        encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        // Separate glow source intensity for click vs trail: the HDR scene
        // brightness controls how strongly each contributes to bloom.
        var diskEmission = BAEffect.disk.emission * (sceneTarget ? settings.clickBloomStrength : 1.0)
        encoder.setFragmentBytes(&diskEmission, length: MemoryLayout<Float>.size, index: 2)
        drawTextured(vertices: disk, texture: circleTexture, pipeline: diskPipeline, encoder: encoder)

        var ringEmission = BAEffect.rings.hdrIntensity * (sceneTarget ? settings.clickBloomStrength : 1.0)
        encoder.setFragmentBytes(&ringEmission, length: MemoryLayout<Float>.size, index: 2)
        drawRing(vertices: ring, texture: ringTexture, pipeline: ringPipeline, encoder: encoder)

        if sceneTarget {
            var trailEmission = settings.trailBloomStrength
            encoder.setFragmentBytes(&trailEmission, length: MemoryLayout<Float>.size, index: 2)
        }
        drawTextured(vertices: trail, texture: trailTexture, pipeline: trailPipeline, encoder: encoder)
        drawTextured(vertices: triangle, texture: triangleTexture, pipeline: trianglePipeline, encoder: encoder)
    }

    // MARK: - Geometry building

    private func appendDisks(to vertices: inout [TexturedVertex]) {
        for burst in particleSystem.bursts {
            let progress = Float(burst.ageMs / Double(BAEffect.disk.lifetimeMs))
            guard progress >= 0, progress < 1 else { continue }

            let alpha = BAEval.number(BAEffect.disk.alphaKeys, progress)
            guard alpha > 0.01 else { continue }

            let size = BAEffect.disk.radius * settings.diskScale * BAEval.hermite(BAEffect.disk.sizeKeys, progress) * scale
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

            let widthMultiplier = BAEval.lerp(BAEffect.rings.widthStart, BAEffect.rings.widthEnd, progress)

            for ring in burst.rings {
                let outerRadius = ring.radius * sizeFactor
                let width = outerRadius * BAEffect.rings.bandToOuterRadius * widthMultiplier
                let radius = outerRadius - width * 0.5
                appendRingGeometry(
                    center: burst.position,
                    radius: radius,
                    width: width,
                    rotation: ring.rotation,
                    color: material,
                    dissolveThreshold: dissolve,
                    coverageOpacity: 1,
                    to: &vertices
                )
            }
        }
    }

    private func computeTrailLength() -> Float {
        let points = particleSystem.trail
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(Float(0)) { acc, pair in
            acc + simd_distance(pair.0.position, pair.1.position)
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
            // Original FX_TEX_Triangle_02_1 is a 2x1 atlas: left frame is the
            // base triangle, right frame is its vertical flip.
            let frame = shard.textureFrame % 2
            let uMin = Float(frame) * 0.5
            let uMax = uMin + 0.5
            let uvMin = SIMD2<Float>(uMin, 0)
            let uvMax = SIMD2<Float>(uMax, 1)
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

    private func appendTrail(to vertices: inout [TexturedVertex], now: Double) {
        let points = particleSystem.trail
        guard points.count >= 2 else { return }
        let lifetime: Double = 0.3

        let totalLength = zip(points, points.dropFirst()).reduce(Float(0)) { acc, pair in
            acc + simd_distance(pair.0.position, pair.1.position)
        }
        guard totalLength > 0 else { return }

        var distances: [Float] = [0]
        for i in 1..<points.count {
            distances.append(distances[i - 1] + simd_distance(points[i - 1].position, points[i].position))
        }

        let halfWidth = BAEffect.trail.width * settings.trailScale * scale * 0.5
        let materialIntensity: Float = 8.0

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

            // Age-based fade so the trail and its glow ease out after the
            // cursor stops instead of popping away at the lifetime boundary.
            let fromAge = max(0, min(1, (now - from.time) / lifetime))
            let toAge = max(0, min(1, (now - to.time) / lifetime))
            let fromFade = Float(1 - fromAge)
            let toFade = Float(1 - toAge)
            let fromAlpha = BAEffect.trail.trailOpacity * fromFade
            let toAlpha = BAEffect.trail.trailOpacity * toFade
            let fromCov = fromCoverage * fromFade
            let toCov = toCoverage * toFade

            let uFrom = 1 - fromProgress
            let uTo = 1 - toProgress

            let fromLeft = from.position + offset
            let fromRight = from.position - offset
            let toLeft = to.position + offset
            let toRight = to.position - offset
            let v0 = TexturedVertex(position: fromLeft, uv: SIMD2(uFrom, 1), color: fromColor, particleAlpha: fromAlpha, coverageFactor: fromCov)
            let v1 = TexturedVertex(position: toLeft, uv: SIMD2(uTo, 1), color: toColor, particleAlpha: toAlpha, coverageFactor: toCov)
            let v2 = TexturedVertex(position: toRight, uv: SIMD2(uTo, 0), color: toColor, particleAlpha: toAlpha, coverageFactor: toCov)
            let v3 = TexturedVertex(position: fromRight, uv: SIMD2(uFrom, 0), color: fromColor, particleAlpha: fromAlpha, coverageFactor: fromCov)
            vertices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
        }

        // Pointed caps at both ends (original numCapVertices=1) so the trail
        // head is rounded/pointed instead of a flat square cut.
        appendTrailCap(points: points, distances: distances, totalLength: totalLength, halfWidth: halfWidth, now: now, atEnd: true, to: &vertices)
        appendTrailCap(points: points, distances: distances, totalLength: totalLength, halfWidth: halfWidth, now: now, atEnd: false, to: &vertices)
    }

    private func appendTrailCap(
        points: [TrailPoint],
        distances: [Float],
        totalLength: Float,
        halfWidth: Float,
        now: Double,
        atEnd: Bool,
        to vertices: inout [TexturedVertex]
    ) {
        let lifetime: Double = 0.3
        let index = atEnd ? points.count - 1 : 0
        let point = points[index]
        let neighbor = atEnd ? points[index - 1] : points[index + 1]
        let direction = simd_normalize(point.position - neighbor.position)
        let normal = SIMD2(-direction.y, direction.x)
        let offset = normal * halfWidth
        let forward: Float = atEnd ? 1 : -1
        let left = point.position + offset
        let right = point.position - offset
        let tip = point.position + direction * halfWidth * forward

        let progress = (distances[index] ) / totalLength
        let color = Renderer.linearEnergy(
            BAEval.color(BAEffect.trail.gradient, progress),
            intensity: 23.968628
        )
        let age = max(0, min(1, (now - point.time) / lifetime))
        let fade = Float(1 - age)
        let cov = BAEval.number(BAEffect.trail.coverageLongitudinalKeys, progress) * fade
        let alpha = BAEffect.trail.trailOpacity * fade
        let u = 1 - progress

        let c0 = TexturedVertex(position: left, uv: SIMD2(u, 1), color: color, particleAlpha: alpha, coverageFactor: cov)
        let c1 = TexturedVertex(position: tip, uv: SIMD2(u, 0.5), color: color, particleAlpha: alpha, coverageFactor: cov)
        let c2 = TexturedVertex(position: right, uv: SIMD2(u, 0), color: color, particleAlpha: alpha, coverageFactor: cov)
        vertices.append(contentsOf: [c0, c1, c2])
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

    private func appendRingGeometry(
        center: SIMD2<Float>,
        radius: Float,
        width: Float,
        rotation: Float,
        color: SIMD3<Float>,
        dissolveThreshold: Float,
        coverageOpacity: Float,
        to vertices: inout [RingVertex]
    ) {
        let bands = BAEffect.rings.radialSamples
        let segments = BAEffect.rings.arcSamples
        let innerEdge = radius - width * 0.5
        let bandWidth = width / Float(bands)
        let uvMin = BAEffect.rings.textureUvMin
        let uvMax = BAEffect.rings.textureUvMax
        let uvSpan = uvMax - uvMin
        let direction: Float = BAEffect.rings.dissolveDirection >= 0 ? 1 : -1

        vertices.reserveCapacity(bands * segments * 6)
        for band in 0..<bands {
            let innerRadius = innerEdge + bandWidth * Float(band)
            let outerRadius = innerEdge + bandWidth * Float(band + 1)
            let innerV = uvMin + uvSpan * Float(band) / Float(bands)
            let outerV = uvMin + uvSpan * Float(band + 1) / Float(bands)

            for segment in 0..<segments {
                let angle0 = rotation + Float(segment) / Float(segments) * 2 * .pi
                let angle1 = rotation + Float(segment + 1) / Float(segments) * 2 * .pi
                let c0 = cos(angle0), s0 = sin(angle0)
                let c1 = cos(angle1), s1 = sin(angle1)

                let innerStart = center + SIMD2(c0 * innerRadius, s0 * innerRadius)
                let innerEnd = center + SIMD2(c1 * innerRadius, s1 * innerRadius)
                let outerStart = center + SIMD2(c0 * outerRadius, s0 * outerRadius)
                let outerEnd = center + SIMD2(c1 * outerRadius, s1 * outerRadius)

                let progress0 = Float(segment) / Float(segments)
                let progress1 = Float(segment + 1) / Float(segments)
                let u0 = uvMin + uvSpan * (direction > 0 ? progress0 : 1 - progress0)
                let u1 = uvMin + uvSpan * (direction > 0 ? progress1 : 1 - progress1)

                let v00 = RingVertex(position: innerStart, uv: SIMD2(u0, innerV), color: color, dissolveThreshold: dissolveThreshold, coverageOpacity: coverageOpacity)
                let v01 = RingVertex(position: innerEnd, uv: SIMD2(u1, innerV), color: color, dissolveThreshold: dissolveThreshold, coverageOpacity: coverageOpacity)
                let v11 = RingVertex(position: outerEnd, uv: SIMD2(u1, outerV), color: color, dissolveThreshold: dissolveThreshold, coverageOpacity: coverageOpacity)
                let v10 = RingVertex(position: outerStart, uv: SIMD2(u0, outerV), color: color, dissolveThreshold: dissolveThreshold, coverageOpacity: coverageOpacity)

                vertices.append(contentsOf: [v00, v01, v11, v00, v11, v10])
            }
        }
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

        let byteCount = MemoryLayout<TexturedVertex>.stride * vertices.count
        if byteCount <= 4096 {
            vertices.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
        } else {
            guard let buffer = device.makeBuffer(length: max(byteCount, 1), options: .storageModeShared) else {
                return
            }
            vertices.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
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

        let byteCount = MemoryLayout<RingVertex>.stride * vertices.count
        if byteCount <= 4096 {
            vertices.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
        } else {
            guard let buffer = device.makeBuffer(length: max(byteCount, 1), options: .storageModeShared) else {
                return
            }
            vertices.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private func updateProjection(view: MTKView) {
        let bounds = view.bounds
        viewportSize = SIMD2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1)))
        scale = Float(max(bounds.height, 1) / 1080.0)
        particleSystem.setViewportHeight(bounds.height)

        var pixelSize = view.drawableSize
        if pixelSize.width <= 0 || pixelSize.height <= 0 {
            let backing = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            pixelSize = CGSize(width: bounds.width * backing, height: bounds.height * backing)
        }
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        // Bloom is soft, so render it at half resolution to cut memory/GPU cost.
        let bloomWidth = max(1, Int(pixelSize.width * 0.5))
        let bloomHeight = max(1, Int(pixelSize.height * 0.5))

        // Original MXFinalBloom: iterations and sampleScale come from the
        // diffusion parameter and the starting (half-res) texture size.
        let maxSize = Double(max(bloomWidth, bloomHeight))
        let logSize = log2(max(maxSize, 1.0))
        let logIterations = logSize + Double(settings.bloomDiffusion) - 10.0
        let iterationFloor = floor(logIterations)
        var iterations = Int(iterationFloor)
        iterations = max(1, min(iterations, 16))
        if settings.bloomLevels > 0 {
            iterations = min(iterations, settings.bloomLevels)
        }
        bloomLevelCount = iterations
        bloomSampleScale = Float(0.5 + logIterations - iterationFloor)

        if hdrSceneTexture != nil && !bloomDownTextures.isEmpty &&
            sceneSize.width == CGFloat(bloomWidth) && sceneSize.height == CGFloat(bloomHeight) {
            return
        }

        sceneSize = CGSize(width: bloomWidth, height: bloomHeight)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: bloomWidth,
            height: bloomHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        hdrSceneTexture = device.makeTexture(descriptor: descriptor)

        bloomDownTextures.removeAll()
        bloomUpTextures.removeAll()
        bloomLevelSizes.removeAll()
        var w = bloomWidth
        var h = bloomHeight
        for _ in 0..<bloomLevelCount {
            let levelDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: w,
                height: h,
                mipmapped: false
            )
            levelDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
            bloomDownTextures.append(device.makeTexture(descriptor: levelDesc)!)
            bloomUpTextures.append(device.makeTexture(descriptor: levelDesc)!)
            bloomLevelSizes.append(CGSize(width: w, height: h))
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
    }

    // MARK: - Helpers

    private static func makePipeline(
        device: MTLDevice,
        vertexFunction: MTLFunction,
        fragmentFunction: MTLFunction,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

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

    /// Pipeline that adds bloom light on top of the existing frame without
    /// changing the window alpha.
    private static func makeAdditivePipeline(
        device: MTLDevice,
        vertexFunction: MTLFunction,
        fragmentFunction: MTLFunction,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

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

    /// Unity's GammaToLinearSpace for a normalized [0,1] sRGB value.
    private static func gammaToLinearUnit(_ value: Float) -> Float {
        let c = min(max(value, 0), 1)
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