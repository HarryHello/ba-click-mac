import Foundation

/// Metal shader source compiled at runtime so the Swift Package Manager build
/// does not depend on Xcode's Metal library packaging.
enum ShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct TexturedVertex {
        float2 position;
        float2 uv;
        float3 color;
        float particleAlpha;
        float coverageFactor;
    };

    struct RingVertex {
        float2 position;
        float2 uv;
        float3 color;
        float dissolveThreshold;
        float coverageOpacity;
    };

    struct TexturedVertexOut {
        float4 position [[position]];
        float2 uv;
        float3 color;
        float particleAlpha;
        float coverageFactor;
    };

    struct RingVertexOut {
        float4 position [[position]];
        float2 uv;
        float3 color;
        float dissolveThreshold;
        float coverageOpacity;
    };

    float linearToSrgb(float value) {
        float c = clamp(value, 0.0, 1.0);
        if (c <= 0.0031308) {
            return c * 12.92;
        }
        return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }

    vertex TexturedVertexOut textured_vertex(
        const device TexturedVertex *vertices [[buffer(0)]],
        constant float2 &viewportSize [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        TexturedVertex v = vertices[vid];
        TexturedVertexOut out;
        float2 ndc = v.position / viewportSize * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = v.uv;
        out.color = v.color;
        out.particleAlpha = v.particleAlpha;
        out.coverageFactor = v.coverageFactor;
        return out;
    }

    vertex RingVertexOut ring_vertex(
        const device RingVertex *vertices [[buffer(0)]],
        constant float2 &viewportSize [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        RingVertex v = vertices[vid];
        RingVertexOut out;
        float2 ndc = v.position / viewportSize * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = v.uv;
        out.color = v.color;
        out.dissolveThreshold = v.dissolveThreshold;
        out.coverageOpacity = v.coverageOpacity;
        return out;
    }

    // Disk: Circle_01. The red channel is the texture alpha/coverage.
    fragment float4 disk_fragment(
        TexturedVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float &emissionScale [[buffer(2)]]
    ) {
        float4 s = tex.sample(samp, in.uv);
        float textureAlpha = s.r;
        float3 emission = s.rgb * max(in.color, float3(0.0)) * textureAlpha * max(emissionScale, 0.0);
        float alpha = textureAlpha * clamp(in.particleAlpha, 0.0, 1.0);
        float3 srgb = float3(linearToSrgb(emission.r), linearToSrgb(emission.g), linearToSrgb(emission.b));
        return float4(srgb * alpha, alpha);
    }

    // Dissolve ring: Ring3 alpha texture is R8.
    fragment float4 ring_fragment(
        RingVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float &emissionScale [[buffer(2)]]
    ) {
        float textureAlpha = tex.sample(samp, in.uv).r;
        if (textureAlpha < in.dissolveThreshold) {
            discard_fragment();
        }
        textureAlpha = clamp(textureAlpha, 0.0, 1.0);
        float3 emission = max(in.color, float3(0.0)) * max(emissionScale, 0.0) * textureAlpha;
        float alpha = textureAlpha * clamp(in.coverageOpacity, 0.0, 1.0);
        float3 srgb = float3(linearToSrgb(emission.r), linearToSrgb(emission.g), linearToSrgb(emission.b));
        return float4(srgb * alpha, alpha);
    }

    // Shards: Triangle_02_1. Alpha modulates emission.
    fragment float4 triangle_fragment(
        TexturedVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 s = tex.sample(samp, in.uv);
        float particleAlpha = clamp(in.particleAlpha, 0.0, 1.0);
        float coverage = s.a * particleAlpha * clamp(in.coverageFactor, 0.0, 1.0);
        float3 emission = s.rgb * max(in.color, float3(0.0)) * coverage;
        float3 srgb = float3(linearToSrgb(emission.r), linearToSrgb(emission.g), linearToSrgb(emission.b));
        return float4(srgb * coverage, coverage);
    }

    // Trail: Trail_03. Emission does not get modulated by alpha.
    fragment float4 trail_fragment(
        TexturedVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 s = tex.sample(samp, in.uv);
        float particleAlpha = clamp(in.particleAlpha, 0.0, 1.0);
        float coverage = s.a * particleAlpha * clamp(in.coverageFactor, 0.0, 1.0);
        float3 emission = s.rgb * max(in.color, float3(0.0)) * particleAlpha;
        float3 srgb = float3(linearToSrgb(emission.r), linearToSrgb(emission.g), linearToSrgb(emission.b));
        return float4(srgb * coverage, coverage);
    }

    struct FullscreenOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2(3.0, -1.0),
            float2(-1.0, 3.0)
        };
        FullscreenOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = positions[vid] * 0.5 + 0.5;
        return out;
    }

    // Composite pass: scene + blurred bloom, additive-ish glow on a
    // transparent overlay.
    fragment float4 composite_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> scene [[texture(0)]],
        texture2d<float> bloom [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant float &bloomStrength [[buffer(0)]]
    ) {
        float4 s = scene.sample(samp, in.uv);
        float4 b = bloom.sample(samp, in.uv);
        float3 color = clamp(s.rgb + b.rgb * max(bloomStrength, 0.0), 0.0, 1.0);
        float maxColor = max(max(color.r, color.g), color.b);
        float alpha = clamp(max(s.a, maxColor), 0.0, 1.0);
        return float4(color * alpha, alpha);
    }
    """
}