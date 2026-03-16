/*
 * Dither3D for Minecraft Iris/OptiFine shader packs.
 * Ported from Unity HLSL (Dither3DInclude.cginc) to GLSL.
 *
 * Original algorithm and textures by Rune Skovbo Johansen
 * https://github.com/runevision/Dither3D
 *
 * Copyright (c) 2025 Rune Skovbo Johansen
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#ifndef DITHER3D_GLSL
#define DITHER3D_GLSL

// gbufferProjection is declared in the including file (composite.fsh).
// Iris does not allow redundant uniform declarations.

// ---------------------------------------------------------------------------
// Constants -- hardcoded for the 4x4 Bayer atlas (recursion = 2)
//   dotsPerSide = pow(2, recursion) = 4
//   layers (zRes) = dotsPerSide^2 = 16
//   size (xRes)   = 16 * dotsPerSide = 64
// ---------------------------------------------------------------------------
const float DITHER_XRES       = 64.0;
const float DITHER_INV_XRES   = 1.0 / 64.0;
const float DITHER_DOTS_PER_SIDE = 4.0;
const float DITHER_DOTS_TOTAL = 16.0;           // dotsPerSide^2
const float DITHER_INV_ZRES   = 1.0 / 16.0;
const float DITHER_LAYER_COUNT = 16.0;

// ---------------------------------------------------------------------------
// Tunable parameters -- defaults matching the Unity material inspector
// ---------------------------------------------------------------------------
const float dither_Scale            = 6.5;
const float dither_SizeVariability  = 0.0;
const float dither_Contrast         = 0.5;
const float dither_StretchSmoothness = 1.0;
const float dither_InputExposure    = 1.0;
const float dither_InputOffset      = 0.0;

// ---------------------------------------------------------------------------
// Feature toggles
// ---------------------------------------------------------------------------
#define RADIAL_COMPENSATION 1
#define INVERSE_DOTS 0
#define QUANTIZE_LAYERS 0

// Minecraft/Iris may not flip PNGs on load (unlike standard OpenGL).
// If the dither pattern looks inverted (fine detail where coarse should be),
// set this to 1 to reverse layer indexing in the atlas.
#define FLIP_ATLAS_LAYERS 1

// ---------------------------------------------------------------------------
// sampleDitherAtlas
//
// Emulates a 3D texture lookup via a 2D atlas PNG.
// The atlas has DITHER_XRES columns and (DITHER_XRES * DITHER_LAYER_COUNT) rows.
// Layers are stacked vertically.  Layer 0 occupies the BOTTOM rows of the PNG
// (lowest v in OpenGL, because Unity's Texture2D.SetPixels writes layer 0
// first, and PNG row 0 is the top, but OpenGL flips Y on load so layer 0
// ends up at v ~ 0).
//
// z_normalized is in [0,1], mapping to layers 0..15.
// We perform manual bilinear interpolation between the two nearest layers.
// ---------------------------------------------------------------------------
float sampleDitherAtlas(sampler2D tex, vec2 uv, float z_normalized) {
    // z_normalized is already in [0,1] range corresponding to the full Z axis.
    // Convert to a continuous layer index in [0, LAYER_COUNT).
    // The original code sets subLayer = (subLayer - 0.5) * invZres, so
    // z_normalized already accounts for the half-texel offset.  We reverse
    // that to recover the continuous layer index.
    float layerFloat = z_normalized * DITHER_LAYER_COUNT;

    // Two nearest layers (clamped to valid range).
    float layer0 = floor(layerFloat);
    float layer1 = layer0 + 1.0;
    float frac_z = layerFloat - layer0;

    layer0 = clamp(layer0, 0.0, DITHER_LAYER_COUNT - 1.0);
    layer1 = clamp(layer1, 0.0, DITHER_LAYER_COUNT - 1.0);

    #if (FLIP_ATLAS_LAYERS)
        layer0 = DITHER_LAYER_COUNT - 1.0 - layer0;
        layer1 = DITHER_LAYER_COUNT - 1.0 - layer1;
    #endif

    // Each layer occupies a vertical band of height (1 / LAYER_COUNT) in the atlas.
    // Layer 0 is at the bottom (v near 0).
    float invLayerCount = 1.0 / DITHER_LAYER_COUNT;

    // The UV.x wraps normally (the atlas columns match the 3D texture X).
    // The UV.y must be remapped into the correct layer band.
    // fract(uv) keeps the coordinates tiling within [0,1).
    vec2 uvTiled = fract(uv);

    // Sample layer0.
    float v0 = (layer0 + uvTiled.y) * invLayerCount;
    float s0 = texture(tex, vec2(uvTiled.x, v0)).r;

    // Sample layer1.
    float v1 = (layer1 + uvTiled.y) * invLayerCount;
    float s1 = texture(tex, vec2(uvTiled.x, v1)).r;

    // Linearly interpolate between the two layers.
    return mix(s0, s1, frac_z);
}

// ---------------------------------------------------------------------------
// sampleRamp
//
// Port of the brightness ramp lookup (lines 42-43 of original).
// The ramp texture is a 1-row, XRES-wide texture.  We perform manual
// bilinear interpolation between the two nearest texels to guarantee
// correctness regardless of GPU texture filtering state.
// ---------------------------------------------------------------------------
float sampleRamp(sampler2D tex, float brightness) {
    // Try to sample the ramp texture.
    float u = 0.5 * DITHER_INV_XRES + (1.0 - DITHER_INV_XRES) * brightness;
    float texelPos = u * DITHER_XRES - 0.5;
    float t0 = floor(texelPos);
    float t1 = t0 + 1.0;
    float frac_t = texelPos - t0;
    float u0 = clamp((t0 + 0.5) * DITHER_INV_XRES, 0.0, 1.0);
    float u1 = clamp((t1 + 0.5) * DITHER_INV_XRES, 0.0, 1.0);
    float s0 = texture(tex, vec2(u0, 0.5)).r;
    float s1 = texture(tex, vec2(u1, 0.5)).r;
    float rampVal = mix(s0, s1, frac_t);

    // Fallback: if ramp texture isn't loading (returns 0), use linear brightness.
    // A valid ramp at brightness=0.5 should return ~0.5, not 0.
    return max(rampVal, brightness);
}

// ---------------------------------------------------------------------------
// getDither3D
//
// Line-by-line port of GetDither3D_() from the original HLSL.
//
// Parameters:
//   ditherAtlas  -- the 2D atlas texture that encodes the 3D dither volume
//   rampTex      -- the 1D brightness ramp texture
//   ditherUV     -- object-space UV coordinates for the dither pattern
//   texCoord     -- screen-space coordinates in [0,1] (gl_FragCoord.xy / resolution)
//   dx, dy       -- screen-space derivatives of ditherUV (dFdx / dFdy)
//   brightness   -- input brightness in [0,1]
//
// Returns: vec4(bw, fract(uv.x), fract(uv.y), subLayer)
//   bw is the final dithered value in [0,1].
// ---------------------------------------------------------------------------
vec4 getDither3D(
    sampler2D ditherAtlas,
    sampler2D rampTex,
    vec2 ditherUV,
    vec2 texCoord,
    vec2 dx,
    vec2 dy,
    float brightness
) {
    // -----------------------------------------------------------------------
    // Inverse dots (line 23-25)
    // -----------------------------------------------------------------------
    #if (INVERSE_DOTS)
        brightness = 1.0 - brightness;
    #endif

    // -----------------------------------------------------------------------
    // Texture dimensions -- hardcoded constants (lines 29-38)
    // -----------------------------------------------------------------------
    float xRes     = DITHER_XRES;        // 64
    float invXres  = DITHER_INV_XRES;    // 1/64
    float dotsPerSide = DITHER_DOTS_PER_SIDE;  // 4
    float dotsTotal   = DITHER_DOTS_TOTAL;     // 16
    float invZres     = DITHER_INV_ZRES;       // 1/16

    // -----------------------------------------------------------------------
    // Brightness ramp lookup (lines 42-43)
    // -----------------------------------------------------------------------
    float brightnessCurve = sampleRamp(rampTex, brightness);

    // -----------------------------------------------------------------------
    // Radial compensation (lines 45-58)
    // -----------------------------------------------------------------------
    #if (RADIAL_COMPENSATION)
        // texCoord is in [0,1]; convert to NDC [-1,1].
        vec2 screenP = texCoord * 2.0 - 1.0;

        // Project screen position into view-space direction on the camera plane.
        // OpenGL does not negate Y (Unity does because of its flipped clip space).
        vec2 viewDirProj = screenP / vec2(
            gbufferProjection[0][0],
            gbufferProjection[1][1]
        );

        // Radial compensation factor: keeps dots stable under camera rotation.
        float radialCompensation = dot(viewDirProj, viewDirProj) + 1.0;
        dx *= radialCompensation;
        dy *= radialCompensation;
    #endif

    // -----------------------------------------------------------------------
    // Singular value decomposition for frequency (lines 60-84)
    //
    // matr = mat2(dx, dy)  -- GLSL mat2 is column-major, so columns are dx, dy.
    // determinant is invariant to transpose so column vs row order doesn't matter.
    // -----------------------------------------------------------------------
    mat2 matr = mat2(dx, dy);                       // columns: dx, dy
    vec4 vectorized = vec4(dx, dy);
    float Q = dot(vectorized, vectorized);           // sum of squares
    float R = determinant(matr);                     // ad - bc
    float discriminantSqr = max(0.0, Q * Q - 4.0 * R * R);
    float discriminant = sqrt(discriminantSqr);

    // freq = (max-frequency, min-frequency)
    // max(0.0) guards against NaN from float imprecision making the argument negative.
    vec2 freq = sqrt(max(vec2(0.0), vec2(Q + discriminant, Q - discriminant) / 2.0));

    // -----------------------------------------------------------------------
    // Spacing (lines 86-127)
    // -----------------------------------------------------------------------

    // Use the smaller frequency (larger stretching direction) for spacing.
    float spacing = freq.y;

    // Scale by user-specified power-of-two scale.
    float scaleExp = exp2(dither_Scale);
    spacing *= scaleExp;

    // Normalize for the number of dots in the pattern.
    spacing *= dotsPerSide * 0.125;

    // Brightness-dependent spacing multiplier.
    // SizeVariability=0 -> divide by brightness (constant dot size).
    // SizeVariability=1 -> leave spacing alone (variable dot size).
    float brightnessSpacingMultiplier =
        pow(brightnessCurve * 2.0 + 0.001, -(1.0 - dither_SizeVariability));
    spacing *= brightnessSpacingMultiplier;

    // -----------------------------------------------------------------------
    // Fractal level (lines 129-160)
    // -----------------------------------------------------------------------

    // Protect against log2(0).
    float spacingLog = log2(max(spacing, 0.0001));
    float patternScaleLevel_f = floor(spacingLog);   // fractal level (float)
    int   patternScaleLevel   = int(patternScaleLevel_f);
    float f = spacingLog - patternScaleLevel_f;       // fractional part in [0,1)

    // UV coordinates at the current fractal level.
    vec2 uv = ditherUV / exp2(patternScaleLevel_f);

    // Third coordinate for the 3D texture: maps fractional part to a sub-layer.
    // First used layer has 1/4 of the dots; last has all dots.
    float subLayer = mix(0.25 * dotsTotal, dotsTotal, 1.0 - f);

    // Optional: quantize layers.
    #if (QUANTIZE_LAYERS)
        float origSubLayer = subLayer;
        subLayer = floor(subLayer + 0.5);
        // Compensate threshold for quantized layer to keep dot size constant.
        float thresholdTweak = sqrt(subLayer / origSubLayer);
    #endif

    // Convert to normalised z coordinate (half-texel offset + normalize).
    subLayer = (subLayer - 0.5) * invZres;

    // -----------------------------------------------------------------------
    // Sample the dither atlas (line 160)
    // -----------------------------------------------------------------------
    float pattern = sampleDitherAtlas(ditherAtlas, uv, subLayer);

    // -----------------------------------------------------------------------
    // Contrast & threshold (lines 162-202)
    // -----------------------------------------------------------------------

    // Base contrast from user setting, scaled by resolution and brightness.
    float contrast = dither_Contrast * scaleExp * brightnessSpacingMultiplier * 0.1;

    // Adjust contrast for surface stretching (anisotropy).
    // Protect against division by zero when freq.x is tiny.
    contrast *= pow(freq.y / max(freq.x, 0.0001), dither_StretchSmoothness);

    // Base value: lerp towards original brightness when contrast is low,
    // to avoid everything collapsing to 0.5.
    float baseVal = mix(0.5, brightness, clamp(1.05 / (1.0 + contrast), 0.0, 1.0));

    // Threshold: brighter output -> lower threshold -> larger dots.
    #if (QUANTIZE_LAYERS)
        float threshold = 1.0 - brightnessCurve * thresholdTweak;
    #else
        float threshold = 1.0 - brightnessCurve;
    #endif

    // Final dithered value.
    float bw = clamp((pattern - threshold) * contrast + baseVal, 0.0, 1.0);

    #if (INVERSE_DOTS)
        bw = 1.0 - bw;
    #endif

    return vec4(bw, fract(uv.x), fract(uv.y), subLayer);
}

// ---------------------------------------------------------------------------
// Convenience wrapper: computes dx/dy automatically from ditherUV.
// Port of GetDither3D() (lines 205-211).
// ---------------------------------------------------------------------------
vec4 getDither3DAuto(
    sampler2D ditherAtlas,
    sampler2D rampTex,
    vec2 ditherUV,
    vec2 texCoord,
    float brightness
) {
    vec2 dx = dFdx(ditherUV);
    vec2 dy = dFdy(ditherUV);
    return getDither3D(ditherAtlas, rampTex, ditherUV, texCoord, dx, dy, brightness);
}

// ---------------------------------------------------------------------------
// Convenience wrapper with alternative UVs to hide seams.
// Port of GetDither3DAltUV() (lines 213-225).
// ---------------------------------------------------------------------------
vec4 getDither3DAltUV(
    sampler2D ditherAtlas,
    sampler2D rampTex,
    vec2 ditherUV,
    vec2 ditherUVAlt,
    vec2 texCoord,
    float brightness
) {
    vec2 dxA = dFdx(ditherUV);
    vec2 dyA = dFdy(ditherUV);
    vec2 dxB = dFdx(ditherUVAlt);
    vec2 dyB = dFdy(ditherUVAlt);
    vec2 dx = (dot(dxA, dxA) < dot(dxB, dxB)) ? dxA : dxB;
    vec2 dy = (dot(dyA, dyA) < dot(dyB, dyB)) ? dyA : dyB;
    return getDither3D(ditherAtlas, rampTex, ditherUV, texCoord, dx, dy, brightness);
}

// ---------------------------------------------------------------------------
// getGrayscale -- port of GetGrayscale (lines 229-232)
// Standard luminance coefficients (ITU BT.601).
// ---------------------------------------------------------------------------
float getGrayscale(vec3 color) {
    return clamp(0.299 * color.r + 0.587 * color.g + 0.114 * color.b, 0.0, 1.0);
}

float getGrayscale(vec4 color) {
    return getGrayscale(color.rgb);
}

// ===========================================================================
// Stubs for future colour modes (RGB / CMYK)
// These are wrapped in #ifdef so they compile away when not needed.
// ===========================================================================

#ifdef DITHER_COLOR_SUPPORT

// ---------------------------------------------------------------------------
// RotateUV -- port of RotateUV (lines 262-265)
// ---------------------------------------------------------------------------
vec2 rotateUV(vec2 uv, vec2 xUnitDir) {
    return uv.x * xUnitDir + uv.y * vec2(-xUnitDir.y, xUnitDir.x);
}

// ---------------------------------------------------------------------------
// RGBtoCMYK -- port of lines 247-260
// ---------------------------------------------------------------------------
vec4 rgbToCMYK(vec3 rgb) {
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;
    float k = min(1.0 - r, min(1.0 - g, 1.0 - b));
    vec3 cmy = vec3(0.0);
    float invK = 1.0 - k;
    if (invK != 0.0) {
        cmy.x = (1.0 - r - k) / invK;
        cmy.y = (1.0 - g - k) / invK;
        cmy.z = (1.0 - b - k) / invK;
    }
    return clamp(vec4(cmy, k), 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// CMYKtoRGB -- port of lines 234-245
// ---------------------------------------------------------------------------
vec3 cmykToRGB(vec4 cmyk) {
    float c = cmyk.x;
    float m = cmyk.y;
    float y = cmyk.z;
    float k = cmyk.w;

    float invK = 1.0 - k;
    float r = 1.0 - min(1.0, c * invK + k);
    float g = 1.0 - min(1.0, m * invK + k);
    float b = 1.0 - min(1.0, y * invK + k);
    return clamp(vec3(r, g, b), 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// getDither3DColor -- port of GetDither3DColor_ (lines 267-294)
// ---------------------------------------------------------------------------
vec4 getDither3DColor(
    sampler2D ditherAtlas,
    sampler2D rampTex,
    vec2 ditherUV,
    vec2 texCoord,
    vec2 dx,
    vec2 dy,
    vec4 color
) {
    // Adjust brightness by exposure and offset.
    color.rgb = clamp(color.rgb * dither_InputExposure + dither_InputOffset, 0.0, 1.0);

    #ifdef DITHERCOL_GRAYSCALE
        vec4 dither = getDither3D(ditherAtlas, rampTex, ditherUV, texCoord, dx, dy, getGrayscale(color));
        color.rgb = vec3(dither.x);
    #elif defined(DITHERCOL_RGB)
        color.r = getDither3D(ditherAtlas, rampTex, ditherUV, texCoord, dx, dy, color.r).x;
        color.g = getDither3D(ditherAtlas, rampTex, ditherUV, texCoord, dx, dy, color.g).x;
        color.b = getDither3D(ditherAtlas, rampTex, ditherUV, texCoord, dx, dy, color.b).x;
    #elif defined(DITHERCOL_CMYK)
        vec4 cmyk = rgbToCMYK(color.rgb);
        // C, M, Y, K at angles 15, 75, 0, 45 degrees.
        cmyk.x = getDither3D(ditherAtlas, rampTex, rotateUV(ditherUV, vec2(0.966, 0.259)), texCoord, dx, dy, cmyk.x).x;
        cmyk.y = getDither3D(ditherAtlas, rampTex, rotateUV(ditherUV, vec2(0.259, 0.966)), texCoord, dx, dy, cmyk.y).x;
        cmyk.z = getDither3D(ditherAtlas, rampTex, rotateUV(ditherUV, vec2(1.000, 0.000)), texCoord, dx, dy, cmyk.z).x;
        cmyk.w = getDither3D(ditherAtlas, rampTex, rotateUV(ditherUV, vec2(0.707, 0.707)), texCoord, dx, dy, cmyk.w).x;
        color.rgb = cmykToRGB(cmyk);
    #endif

    return color;
}

#endif // DITHER_COLOR_SUPPORT

#endif // DITHER3D_GLSL
