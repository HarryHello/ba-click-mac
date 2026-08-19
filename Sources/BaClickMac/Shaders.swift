import Foundation

/// Metal shader source compiled at runtime so the Swift Package Manager build
/// does not depend on Xcode's Metal library packaging.
enum ShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct TexturedVertex {
        float4 a; // position.xy
        float4 b; // uv.xy
        float4 c; // color.rgb + particleAlpha
        float4 d; // coverageFactor
    };

    struct RingVertex {
        float4 a; // position.xy
        float4 b; // uv.xy
        float4 c; // color.rgb + dissolveThreshold
        float4 d; // coverageOpacity
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
        float2 ndc = v.a.xy / viewportSize * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = v.b.xy;
        out.color = v.c.rgb;
        out.particleAlpha = v.c.w;
        out.coverageFactor = v.d.x;
        return out;
    }

    vertex RingVertexOut ring_vertex(
        const device RingVertex *vertices [[buffer(0)]],
        constant float2 &viewportSize [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        RingVertex v = vertices[vid];
        RingVertexOut out;
        float2 ndc = v.a.xy / viewportSize * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = v.b.xy;
        out.color = v.c.rgb;
        out.dissolveThreshold = v.c.w;
        out.coverageOpacity = v.d.x;
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

    // HDR scene disk: unclamped linear emission for MXFinalBloom.
    fragment float4 disk_scene_fragment(
        TexturedVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float &emissionScale [[buffer(2)]]
    ) {
        float4 s = tex.sample(samp, in.uv);
        float textureAlpha = s.r;
        float3 emission = s.rgb * max(in.color, float3(0.0)) * textureAlpha * max(emissionScale, 0.0);
        float alpha = textureAlpha * clamp(in.particleAlpha, 0.0, 1.0);
        return float4(emission, alpha);
    }

    // HDR scene ring: unclamped linear emission for MXFinalBloom.
    fragment float4 ring_scene_fragment(
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
        return float4(emission, alpha);
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
    // Window (SDR) trail: tone-mapped. The Trail_03 texture itself carries the
    // longitudinal fade and transverse falloff (the "stretched teardrop"), so
    // we sample it directly — no synthetic curve overrides.
    fragment float4 trail_fragment(
        TexturedVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 s = tex.sample(samp, in.uv);
        float particleAlpha = clamp(in.particleAlpha, 0.0, 1.0);
        float coverageFactor = clamp(in.coverageFactor, 0.0, 1.0);
        // Trail_03 keeps its shape in RGB (teardrop) with a constant alpha;
        // coverage must follow the texture brightness so the fading tail
        // becomes transparent instead of an opaque black block.
        float textureShape = max(max(s.r, s.g), s.b);
        float coverage = s.a * textureShape * particleAlpha * coverageFactor;
        float3 emission = s.rgb * max(in.color, float3(0.0)) * particleAlpha;
        float3 srgb = float3(linearToSrgb(emission.r), linearToSrgb(emission.g), linearToSrgb(emission.b));
        return float4(srgb * coverage, coverage);
    }

    // Scene trail: HDR linear output (no clamp/tonemap) so the Bloom pass gets
    // true >1 energy for the glow, like MXFinalBloom. Same direct sampling of
    // the Trail_03 texture.
    fragment float4 trail_scene_fragment(
        TexturedVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float &emissionScale [[buffer(2)]]
    ) {
        float4 s = tex.sample(samp, in.uv);
        float particleAlpha = clamp(in.particleAlpha, 0.0, 1.0);
        float coverageFactor = clamp(in.coverageFactor, 0.0, 1.0);
        float textureShape = max(max(s.r, s.g), s.b);
        float coverage = s.a * textureShape * particleAlpha * coverageFactor;
        float3 emission = s.rgb * max(in.color, float3(0.0)) * particleAlpha * max(emissionScale, 0.0);
        return float4(emission, coverage);
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

    // Composite pass (original MXFinalBloom): source + 4-tap bloom * intensity.
    fragment float4 composite_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> scene [[texture(0)]],
        texture2d<float> bloom [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant float2 &bloomTexel [[buffer(0)]],
        constant float2 &sampleScaleAndIntensity [[buffer(1)]]
    ) {
        float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
        float2 offset = bloomTexel * sampleScaleAndIntensity.x * 0.5;
        float3 b =
            bloom.sample(samp, uv + offset * float2(-1.0, -1.0)).rgb +
            bloom.sample(samp, uv + offset * float2(1.0, -1.0)).rgb +
            bloom.sample(samp, uv + offset * float2(-1.0, 1.0)).rgb +
            bloom.sample(samp, uv + offset * float2(1.0, 1.0)).rgb;
        b *= 0.25 * sampleScaleAndIntensity.y;
        float4 s = scene.sample(samp, uv);
        float3 color = s.rgb + b;
        float maxColor = max(max(color.r, color.g), color.b);
        float alpha = clamp(max(s.a, maxColor), 0.0, 1.0);
        return float4(color * alpha, alpha);
    }

    float2 flipUV(float2 uv) {
        return float2(uv.x, 1.0 - uv.y);
    }

    // MXFinalBloom prefilter: 4-tap around the destination texel, HDR clamp
    // and the original hard-threshold soft-knee formula.
    fragment float4 prefilter_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float2 &texel [[buffer(0)]],
        constant float4 &threshold [[buffer(1)]],
        constant float &clampValue [[buffer(2)]]
    ) {
        float2 uv = flipUV(in.uv);
        float4 sum =
            src.sample(samp, uv + texel * float2(-1.0, -1.0)) +
            src.sample(samp, uv + texel * float2(1.0, -1.0)) +
            src.sample(samp, uv + texel * float2(-1.0, 1.0)) +
            src.sample(samp, uv + texel * float2(1.0, 1.0));
        float4 c = min(sum * 0.25, min(65504.0, clampValue));

        float brightness = max(max(c.r, c.g), c.b);
        float soft = brightness - threshold.y;
        soft = clamp(soft, 0.0, threshold.z);
        soft = soft * soft * threshold.w;
        float contribution = max(soft, brightness - threshold.x);
        contribution /= max(brightness, 0.0001);
        return c * contribution;
    }

    fragment float4 downsample_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> src [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant float2 &texel [[buffer(0)]]
    ) {
        float2 uv = flipUV(in.uv);
        float4 sum =
            src.sample(samp, uv + texel * float2(-1.0, -1.0)) +
            src.sample(samp, uv + texel * float2(1.0, -1.0)) +
            src.sample(samp, uv + texel * float2(-1.0, 1.0)) +
            src.sample(samp, uv + texel * float2(1.0, 1.0));
        return sum * 0.25;
    }

    fragment float4 upsample_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> coarse [[texture(0)]],
        texture2d<float> fine [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant float2 &coarseTexel [[buffer(0)]],
        constant float &sampleScale [[buffer(1)]]
    ) {
        float2 uv = flipUV(in.uv);
        float2 offset = coarseTexel * sampleScale * 0.5;
        float4 acc =
            coarse.sample(samp, uv + offset * float2(-1.0, -1.0)) +
            coarse.sample(samp, uv + offset * float2(1.0, -1.0)) +
            coarse.sample(samp, uv + offset * float2(-1.0, 1.0)) +
            coarse.sample(samp, uv + offset * float2(1.0, 1.0));
        return acc * 0.25 + fine.sample(samp, uv);
    }

    // Bloom overlay: original MXFinalBloom 4-tap composite added on top of the
    // already-drawn core, with intensity conversion 2^(I/10)-1.
    fragment float4 bloom_add_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> bloom [[texture(0)]],
        texture2d<float> scene [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant float2 &bloomTexel [[buffer(0)]],
        constant float2 &sampleScaleAndIntensity [[buffer(1)]],
        constant float &falloff [[buffer(2)]]
    ) {
        float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
        float2 offset = bloomTexel * sampleScaleAndIntensity.x * 0.5;
        float3 b =
            bloom.sample(samp, uv + offset * float2(-1.0, -1.0)).rgb +
            bloom.sample(samp, uv + offset * float2(1.0, -1.0)).rgb +
            bloom.sample(samp, uv + offset * float2(-1.0, 1.0)).rgb +
            bloom.sample(samp, uv + offset * float2(1.0, 1.0)).rgb;
        float3 e = b * (0.25 * sampleScaleAndIntensity.y);

        float lum = max(max(e.r, e.g), e.b);
        if (lum <= 0.001) {
            return float4(0.0);
        }
        // Near-linear falloff: bright near the source, smooth decay, no
        // far-field fog lift (game glow is additive-linear). Cap so the halo
        // stays translucent and hugs the trail instead of forming a solid blob.
        float a = min(0.8, pow(clamp(lum, 0.0, 1.0), max(falloff, 0.6)));
        // Lighten the deep-blue halo toward the game's bright cyan glow.
        float3 n = e / lum;
        float3 lightCyan = float3(0.6, 0.9, 1.0);
        n = mix(n, lightCyan, 0.45);
        // Premultiplied light color: visible contribution is n * a.
        return float4(n * a, a);
    }
    """
}