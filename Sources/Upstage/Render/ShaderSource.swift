import Foundation

/// Metal shaders compiled at runtime (SwiftPM's `swift build` does not compile
/// .metal files, so the source lives here as a string).
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadUniforms {
        float4x4 mvp;
        float4 uvRect;        // u0 v0 u1 v1 in displayed (pre-rotated) space
        float opacity;
        float flipH;
        float flipV;
        float quarterTurns;   // 0..3, clockwise, applied after crop/flip
    };

    struct FilterUniforms {
        float4 p0;
        float4 p1;
        float4 p2;
        float2 texelSize;
        float2 pad;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
        float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
        float2 c = corners[vid];
        VOut o;
        o.position = u.mvp * float4(c, 0.0, 1.0);
        float2 uv = float2(mix(u.uvRect.x, u.uvRect.z, c.x), mix(u.uvRect.y, u.uvRect.w, c.y));
        if (u.flipH > 0.5) uv.x = 1.0 - uv.x;
        if (u.flipV > 0.5) uv.y = 1.0 - uv.y;
        int q = int(u.quarterTurns + 0.5) & 3;
        if (q == 1) uv = float2(uv.y, 1.0 - uv.x);
        else if (q == 2) uv = float2(1.0 - uv.x, 1.0 - uv.y);
        else if (q == 3) uv = float2(1.0 - uv.y, uv.x);
        o.uv = uv;
        return o;
    }

    fragment float4 textured_fragment(VOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler s [[sampler(0)]],
                                      constant QuadUniforms &u [[buffer(0)]]) {
        float4 c = tex.sample(s, in.uv);
        return c * u.opacity;
    }

    fragment float4 solid_fragment(VOut in [[stage_in]], constant FilterUniforms &f [[buffer(0)]]) {
        float4 c = f.p0;
        return float4(c.rgb * c.a, c.a);
    }

    // ---- filters ---------------------------------------------------------

    float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
        float4 q = c.r < p.x ? float4(p.xyw, c.r) : float4(c.r, p.yzx);
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, float3(0.0), float3(1.0)), c.y);
    }

    // p0 = brightness, contrast, saturation, gamma ; p1.x = hue shift (turns), p1.y = opacity
    fragment float4 color_correction_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float4 c = tex.sample(s, in.uv);
        float a = max(c.a, 1e-5);
        float3 rgb = c.rgb / a;
        rgb = pow(max(rgb, float3(0.0)), float3(1.0 / max(f.p0.w, 0.01)));
        rgb = (rgb - 0.5) * f.p0.y + 0.5 + f.p0.x;
        float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(l), rgb, f.p0.z);
        if (abs(f.p1.x) > 1e-5) {
            float3 hsv = rgb2hsv(clamp(rgb, float3(0.0), float3(1.0)));
            hsv.x = fract(hsv.x + f.p1.x);
            rgb = hsv2rgb(hsv);
        }
        rgb = clamp(rgb, float3(0.0), float3(1.0));
        float oa = c.a * f.p1.y;
        return float4(rgb * oa, oa);
    }

    // p0 = key colour rgb ; p1 = similarity, smoothness, spill
    fragment float4 chroma_key_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float4 c = tex.sample(s, in.uv);
        float a = max(c.a, 1e-5);
        float3 rgb = c.rgb / a;
        float3 key = f.p0.rgb;
        // compare in CbCr so lighting changes do not break the key
        float2 cc = float2(-0.1687 * rgb.r - 0.3313 * rgb.g + 0.5 * rgb.b, 0.5 * rgb.r - 0.4187 * rgb.g - 0.0813 * rgb.b);
        float2 kc = float2(-0.1687 * key.r - 0.3313 * key.g + 0.5 * key.b, 0.5 * key.r - 0.4187 * key.g - 0.0813 * key.b);
        float dist = distance(cc, kc) * 2.0;
        float similarity = f.p1.x;
        float smoothness = max(f.p1.y, 1e-4);
        float alpha = smoothstep(similarity, similarity + smoothness, dist);
        // spill suppression: pull the key hue out of edge pixels
        float spill = f.p1.z;
        float keyDom = max(key.g - max(key.r, key.b), 0.0) > 0.0 ? 1.0 : 0.0;
        if (spill > 0.0) {
            float3 desat = float3(dot(rgb, float3(0.2126, 0.7152, 0.0722)));
            float amount = (1.0 - alpha) * spill;
            if (keyDom > 0.5) {
                float g = min(rgb.g, (rgb.r + rgb.b) * 0.5 + (rgb.g - (rgb.r + rgb.b) * 0.5) * (1.0 - spill));
                rgb = mix(rgb, float3(rgb.r, g, rgb.b), 1.0);
            }
            rgb = mix(rgb, desat, amount * 0.5);
        }
        float oa = c.a * alpha;
        return float4(rgb * oa, oa);
    }

    // p0 = lumaMin, lumaMax, smooth
    fragment float4 luma_key_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float4 c = tex.sample(s, in.uv);
        float a = max(c.a, 1e-5);
        float3 rgb = c.rgb / a;
        float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float sm = max(f.p0.z, 1e-4);
        float alpha = smoothstep(f.p0.x - sm, f.p0.x, l) * (1.0 - smoothstep(f.p0.y, f.p0.y + sm, l));
        float oa = c.a * alpha;
        return float4(rgb * oa, oa);
    }

    // p0.x = amount
    fragment float4 sharpen_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float2 t = f.texelSize;
        float4 c = tex.sample(s, in.uv);
        float4 n = tex.sample(s, in.uv + float2(0.0, -t.y));
        float4 so = tex.sample(s, in.uv + float2(0.0, t.y));
        float4 e = tex.sample(s, in.uv + float2(t.x, 0.0));
        float4 w = tex.sample(s, in.uv + float2(-t.x, 0.0));
        float4 blur = (n + so + e + w + c) / 5.0;
        float4 r = c + (c - blur) * f.p0.x * 4.0;
        return float4(clamp(r.rgb, float3(0.0), float3(1.0)), c.a);
    }

    // p0.x = radius (px), p0.y = direction (0 = horizontal, 1 = vertical)
    fragment float4 blur_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float2 dir = f.p0.y > 0.5 ? float2(0.0, f.texelSize.y) : float2(f.texelSize.x, 0.0);
        float radius = max(f.p0.x, 0.001);
        const int taps = 8;
        float stepSize = radius / float(taps);
        float sigma = radius / 2.0;
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int i = -taps; i <= taps; i++) {
            float d = float(i) * stepSize;
            float w = exp(-(d * d) / (2.0 * sigma * sigma));
            acc += tex.sample(s, in.uv + dir * d) * w;
            wsum += w;
        }
        return acc / wsum;
    }

    // Lanczos-3 resampling into a differently sized target. texelSize = 1/input size.
    float lanczos(float x) {
        const float a = 3.0;
        if (x == 0.0) return 1.0;
        if (abs(x) >= a) return 0.0;
        float px = 3.14159265 * x;
        return (a * sin(px) * sin(px / a)) / (px * px);
    }

    fragment float4 lanczos_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float2 inSize = 1.0 / f.texelSize;
        float2 pos = in.uv * inSize - 0.5;
        float2 base = floor(pos);
        float2 fracPart = pos - base;
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int j = -2; j <= 3; j++) {
            float wy = lanczos(float(j) - fracPart.y);
            for (int i = -2; i <= 3; i++) {
                float wx = lanczos(float(i) - fracPart.x);
                float w = wx * wy;
                float2 uv = (base + float2(float(i), float(j)) + 0.5) * f.texelSize;
                acc += tex.sample(s, uv) * w;
                wsum += w;
            }
        }
        float4 r = acc / max(wsum, 1e-5);
        return float4(clamp(r.rgb, float3(0.0), float3(1.0)), clamp(r.a, 0.0, 1.0));
    }

    // ---- transitions -------------------------------------------------------
    // p0.x = progress 0..1, p0.y = kind (0 fade, 1 fadeToBlack, 2 slideLeft, 3 slideRight, 4 slideUp, 5 slideDown)
    fragment float4 transition_fragment(VOut in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]], sampler s [[sampler(0)]], constant FilterUniforms &f [[buffer(0)]]) {
        float t = clamp(f.p0.x, 0.0, 1.0);
        int kind = int(f.p0.y + 0.5);
        if (kind == 0) {
            return mix(a.sample(s, in.uv), b.sample(s, in.uv), t);
        } else if (kind == 1) {
            float k = t < 0.5 ? (1.0 - t * 2.0) : ((t - 0.5) * 2.0);
            float4 c = t < 0.5 ? a.sample(s, in.uv) : b.sample(s, in.uv);
            return float4(c.rgb * k, 1.0);
        } else {
            float2 d = float2(0.0);
            if (kind == 2) d = float2(-1.0, 0.0);
            else if (kind == 3) d = float2(1.0, 0.0);
            else if (kind == 4) d = float2(0.0, -1.0);
            else d = float2(0.0, 1.0);
            float2 uvA = in.uv - d * t;
            float2 uvB = in.uv - d * t + d;
            bool inA = uvA.x >= 0.0 && uvA.x <= 1.0 && uvA.y >= 0.0 && uvA.y <= 1.0;
            if (inA) return a.sample(s, uvA);
            return b.sample(s, clamp(uvB, float2(0.0), float2(1.0)));
        }
    }
    """
}
