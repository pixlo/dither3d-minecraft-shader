#version 330 compatibility

// --- Uniforms ---
uniform sampler2D colortex0;    // scene color
uniform sampler2D depthtex0;    // depth buffer
uniform sampler2D colortex4;    // dither atlas (custom texture)
uniform sampler2D colortex5;    // dither ramp (custom texture)
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float viewWidth;
uniform float viewHeight;

// --- Dither3D tunable parameters ---
#define dither_Scale 6.5             // [4.0 5.0 5.5 6.0 6.5 7.0 8.0 9.0 10.0]
#define dither_SizeVariability 0.0   // [0.0 0.25 0.5 0.75 1.0]
#define dither_Contrast 0.5          // [0.1 0.25 0.5 0.75 1.0 1.5 2.0]
#define dither_StretchSmoothness 1.0 // [0.0 0.25 0.5 1.0 1.5 2.0]
#define dither_InputExposure 1.0     // [0.5 0.75 1.0 1.25 1.5 2.0]
#define dither_InputOffset 0.0       // [-0.2 -0.1 0.0 0.1 0.2]

// --- Dither3D library ---
#include "lib/dither3d.glsl"

// --- Varying input from vertex shader ---
in vec2 texCoord;

// Reconstruct absolute world-space position from screen UV and depth.
// Uses absoluteWorldPos (camera-relative + cameraPosition) so that
// dithering is anchored to the world grid, not the player.
vec3 getWorldPos(vec2 uv, float depth) {
    vec2 ndc        = uv * 2.0 - 1.0;
    vec4 clipPos    = vec4(ndc, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos    = gbufferProjectionInverse * clipPos;
    viewPos        /= viewPos.w;
    vec3 worldPos   = (gbufferModelViewInverse * viewPos).xyz;
    // CRITICAL: offset by camera position for surface-stable coordinates
    vec3 absoluteWorldPos = worldPos + cameraPosition;
    return absoluteWorldPos;
}

void main() {
    /* DRAWBUFFERS:0 */

    // 1. Sample depth and scene color
    float depth      = texture(depthtex0, texCoord).r;
    vec4  sceneColor = texture(colortex0, texCoord);

    // 2. Sky check -- pass through unchanged
    if (depth >= 1.0) {
        gl_FragData[0] = sceneColor;
        return;
    }

    vec3 absoluteWorldPos = getWorldPos(texCoord, depth);

    // Reconstruct surface normal from world-position screen derivatives.
    vec3 dWdx = dFdx(absoluteWorldPos);
    vec3 dWdy = dFdy(absoluteWorldPos);
    vec3 normal = normalize(cross(dWdx, dWdy));
    vec3 absN = abs(normal);

    // Triplanar UV: pick projection plane based on dominant normal axis.
    // Minecraft blocks are axis-aligned so this gives clean results.
    vec2 ditherUV;
    vec2 dx, dy;
    if (absN.y >= absN.x && absN.y >= absN.z) {
        // Horizontal surface (floor/ceiling) -> XZ
        ditherUV = absoluteWorldPos.xz;
        dx = dFdx(absoluteWorldPos.xz);
        dy = dFdy(absoluteWorldPos.xz);
    } else if (absN.x >= absN.z) {
        // East/West wall -> YZ
        ditherUV = absoluteWorldPos.yz;
        dx = dFdx(absoluteWorldPos.yz);
        dy = dFdy(absoluteWorldPos.yz);
    } else {
        // North/South wall -> XY
        ditherUV = absoluteWorldPos.xy;
        dx = dFdx(absoluteWorldPos.xy);
        dy = dFdy(absoluteWorldPos.xy);
    }

    // Gamma correction on full color (linear -> perceptual).
    vec4 adjustedColor = sceneColor;
    adjustedColor.rgb = pow(max(adjustedColor.rgb, vec3(0.0)), vec3(1.0 / 2.0));

    // Color dithering (respects DITHER_COLOR_MODE: 0=Grayscale, 1=RGB, 2=CMYK)
    vec4 dithered = getDither3DColor(colortex4, colortex5,
                                      ditherUV, texCoord,
                                      dx, dy, adjustedColor);
    gl_FragData[0] = vec4(dithered.rgb, 1.0);
}
