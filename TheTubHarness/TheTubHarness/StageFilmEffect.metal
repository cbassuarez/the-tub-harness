#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// --- Film grain (hash-based animated noise) ---

float grainHash(float2 p, float seed) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33 + seed);
    return fract((p3.x + p3.y) * p3.z);
}

// --- Tone curve: slight S-curve for contrast + shadow lift ---

half toneCurve(half x) {
    // Lift shadows slightly, add gentle mid contrast
    half lifted = x + 0.012h * (1.0h - x);
    // Mild S-curve: more contrast in mids, preserve extremes
    return lifted + 0.08h * lifted * (1.0h - lifted) * (2.0h * lifted - 1.0h);
}

// --- Main film grade: grain + vignette + color grade ---
// Applied as .colorEffect() on the entire stage view.

[[ stitchable ]] half4 filmGrade(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float grainAmount,
    float vignetteRadius,
    float vignetteSoftness
) {
    // Skip fully transparent pixels
    if (color.a < 0.001h) return color;

    float2 uv = position / size;

    // --- Film grain ---
    float grain = grainHash(floor(position * 1.2), fract(time * 7.13)) * 2.0 - 1.0;
    // Grain is stronger in midtones, weaker in deep shadows and highlights
    float luma = dot(float3(color.rgb), float3(0.299, 0.587, 0.114));
    float grainMask = 4.0 * luma * (1.0 - luma); // peaks at luma=0.5
    color.rgb += half3(grain * half(grainAmount * grainMask));

    // --- Vignette ---
    float2 centeredUV = uv - 0.5;
    float dist = length(centeredUV * float2(1.0, size.y / size.x)); // aspect-corrected
    float vig = smoothstep(vignetteRadius, vignetteRadius - vignetteSoftness, dist);
    color.rgb *= half3(vig);

    // --- Color grade: cool shadows, neutral mids ---
    // Push shadows toward teal (industrial cold)
    float shadowWeight = 1.0 - smoothstep(0.0, 0.25, luma);
    color.r -= half(shadowWeight * 0.010);
    color.g += half(shadowWeight * 0.006);
    color.b += half(shadowWeight * 0.018);

    // Subtle warmth in upper mids (just enough to separate from shadows)
    float midWeight = smoothstep(0.2, 0.5, luma) * (1.0 - smoothstep(0.5, 0.8, luma));
    color.r += half(midWeight * 0.008);
    color.g += half(midWeight * 0.003);

    // Tone curve on each channel
    color.r = toneCurve(color.r);
    color.g = toneCurve(color.g);
    color.b = toneCurve(color.b);

    color.rgb = clamp(color.rgb, half3(0), half3(1));
    return color;
}

// --- Chromatic aberration: subtle RGB split radiating from center ---
// Audio-reactive: base strength + transient pulse + low-frequency sway.
// Applied as .layerEffect() on the entire stage view.

[[ stitchable ]] half4 chromaticAberration(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float baseStrength,
    float rms,
    float transientFlux,
    float lowBand,
    float time
) {
    float2 uv = position / size;
    float2 center = uv - 0.5;

    // Audio-reactive strength: base + gentle RMS breathing + transient spike
    float breath = rms * 0.6;
    float spike = transientFlux > 0.35 ? (transientFlux - 0.35) * 2.0 : 0.0;
    // Low-frequency sway: subtle directional drift from bass
    float sway = sin(time * 1.7) * lowBand * 0.3;

    float strength = baseStrength + breath + spike * 1.5;

    // Aberration increases quadratically toward edges (like a real lens)
    float dist2 = dot(center, center);
    float2 dir = center * dist2 * strength;
    // Add slight directional bias from bass sway
    dir += float2(sway * 0.02, sway * 0.01);
    float2 offsetPx = dir * size;

    // Sample each channel at slightly different positions
    half4 rSample = layer.sample(position + offsetPx);
    half4 gSample = layer.sample(position);
    half4 bSample = layer.sample(position - offsetPx);

    // Preserve alpha from center sample — don't clip transparent regions
    return half4(rSample.r, gSample.g, bSample.b, max(max(rSample.a, gSample.a), bSample.a));
}

// --- Soft bloom: brightens areas near bright pixels ---
// Applied as .layerEffect() for subtle light bleed.

[[ stitchable ]] half4 softBloom(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float intensity,
    float threshold
) {
    half4 center = layer.sample(position);

    // 8-tap box sample for a cheap bloom kernel
    float radius = 3.0;
    half3 bloom = half3(0);
    float count = 0.0;
    for (float dy = -1.0; dy <= 1.0; dy += 1.0) {
        for (float dx = -1.0; dx <= 1.0; dx += 1.0) {
            if (dx == 0.0 && dy == 0.0) continue;
            half4 s = layer.sample(position + float2(dx, dy) * radius);
            float sLuma = dot(float3(s.rgb), float3(0.299, 0.587, 0.114));
            // Only bloom from pixels brighter than threshold
            float weight = max(0.0, sLuma - threshold);
            bloom += s.rgb * half(weight);
            count += weight;
        }
    }

    if (count > 0.001) {
        bloom /= half(count);
        center.rgb += bloom * half(intensity);
    }

    // Never exceed source alpha, never clip color channels
    center.rgb = min(center.rgb, half3(center.a));
    return center;
}
