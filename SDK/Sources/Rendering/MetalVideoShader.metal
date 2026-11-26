//
//  MetalVideoShader.metal
//  CICD
//
//  NV12 → RGB với color enhancement cho camera an ninh.
//  Hỗ trợ BT.601 (SD) và BT.709 (HD ≥ 720p), gamma correction,
//  và điều chỉnh brightness / contrast / saturation.
//

#include <metal_stdlib>
using namespace metal;

// ─── Structs ─────────────────────────────────────────────────────────────────

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// Điều chỉnh màu sắc — truyền từ CPU qua setFragmentBytes
struct ColorParams {
    float brightness;   // -1.0 ~ 1.0, default 0.0
    float contrast;     // 0.5 ~ 2.0, default 1.0
    float saturation;   // 0.0 ~ 2.0, default 1.0
    float sharpness;    // 0.0 ~ 1.0, default 0.0 (0 = off)
    int   useHD;        // 1 = BT.709 (HD ≥720p), 0 = BT.601 (SD)
    int   applyGamma;   // 1 = linear→sRGB gamma, 0 = off
    // padding
    float _pad0;
    float _pad1;
};

// ─── Vertex ──────────────────────────────────────────────────────────────────

vertex VertexOut videoVertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Linear → sRGB gamma (giống display gamma, tránh hình bị nhạt)
static inline half3 linearToSRGB(half3 c) {
    half3 lo = c * 12.92h;
    half3 hi = 1.055h * pow(c, half3(1.0h / 2.4h)) - 0.055h;
    return select(hi, lo, c <= 0.0031308h);
}

/// Điều chỉnh độ bão hòa màu (saturation)
static inline half3 applySaturation(half3 rgb, float sat) {
    // Luminance weights (BT.709)
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    return mix(half3(luma), rgb, half(sat));
}

/// Contrast + brightness
static inline half3 applyContrastBrightness(half3 rgb, float contrast, float brightness) {
    return clamp((rgb - 0.5h) * half(contrast) + 0.5h + half(brightness), 0.0h, 1.0h);
}

// ─── YCbCr → RGB (BT.601 video-range) ───────────────────────────────────────

static inline half3 ycbcrToRGB_601_video(half y, half cb, half cr) {
    y  = (y  - half(16.0/255.0))  * half(255.0/219.0);
    cb = (cb - half(128.0/255.0)) * half(255.0/224.0);
    cr = (cr - half(128.0/255.0)) * half(255.0/224.0);
    half r = y                    + half(1.40200) * cr;
    half g = y - half(0.34414) * cb - half(0.71414) * cr;
    half b = y + half(1.77200) * cb;
    return clamp(half3(r, g, b), 0.0h, 1.0h);
}

// ─── YCbCr → RGB (BT.601 full-range) ────────────────────────────────────────

static inline half3 ycbcrToRGB_601_full(half y, half cb, half cr) {
    cb -= 0.5h; cr -= 0.5h;
    half r = y                    + half(1.40200) * cr;
    half g = y - half(0.34414) * cb - half(0.71414) * cr;
    half b = y + half(1.77200) * cb;
    return clamp(half3(r, g, b), 0.0h, 1.0h);
}

// ─── YCbCr → RGB (BT.709 video-range) — chuẩn cho HD ────────────────────────

static inline half3 ycbcrToRGB_709_video(half y, half cb, half cr) {
    y  = (y  - half(16.0/255.0))  * half(255.0/219.0);
    cb = (cb - half(128.0/255.0)) * half(255.0/224.0);
    cr = (cr - half(128.0/255.0)) * half(255.0/224.0);
    half r = y                    + half(1.57480) * cr;
    half g = y - half(0.18733) * cb - half(0.46813) * cr;
    half b = y + half(1.85563) * cb;
    return clamp(half3(r, g, b), 0.0h, 1.0h);
}

// ─── YCbCr → RGB (BT.709 full-range) ────────────────────────────────────────

static inline half3 ycbcrToRGB_709_full(half y, half cb, half cr) {
    cb -= 0.5h; cr -= 0.5h;
    half r = y                    + half(1.57480) * cr;
    half g = y - half(0.18733) * cb - half(0.46813) * cr;
    half b = y + half(1.85563) * cb;
    return clamp(half3(r, g, b), 0.0h, 1.0h);
}

// ─── Fragment: NV12 video-range (420v) ───────────────────────────────────────

fragment half4 nv12ToRGBFragment(
    VertexOut        in      [[stage_in]],
    texture2d<half>  yTex    [[texture(0)]],
    texture2d<half>  uvTex   [[texture(1)]],
    sampler          s       [[sampler(0)]],
    constant ColorParams& p  [[buffer(0)]])
{
    half y  = yTex.sample(s,  in.texCoord).r;
    half cb = uvTex.sample(s, in.texCoord).r;
    half cr = uvTex.sample(s, in.texCoord).g;

    half3 rgb = (p.useHD == 1)
        ? ycbcrToRGB_709_video(y, cb, cr)
        : ycbcrToRGB_601_video(y, cb, cr);

    rgb = applySaturation(rgb, p.saturation);
    rgb = applyContrastBrightness(rgb, p.contrast, p.brightness);
    if (p.applyGamma == 1) { rgb = linearToSRGB(rgb); }

    return half4(rgb, 1.0h);
}

// ─── Fragment: NV12 full-range (420f) ────────────────────────────────────────

fragment half4 nv12FullRangeToRGBFragment(
    VertexOut        in      [[stage_in]],
    texture2d<half>  yTex    [[texture(0)]],
    texture2d<half>  uvTex   [[texture(1)]],
    sampler          s       [[sampler(0)]],
    constant ColorParams& p  [[buffer(0)]])
{
    half y  = yTex.sample(s,  in.texCoord).r;
    half cb = uvTex.sample(s, in.texCoord).r;
    half cr = uvTex.sample(s, in.texCoord).g;

    half3 rgb = (p.useHD == 1)
        ? ycbcrToRGB_709_full(y, cb, cr)
        : ycbcrToRGB_601_full(y, cb, cr);

    rgb = applySaturation(rgb, p.saturation);
    rgb = applyContrastBrightness(rgb, p.contrast, p.brightness);
    if (p.applyGamma == 1) { rgb = linearToSRGB(rgb); }

    return half4(rgb, 1.0h);
}
