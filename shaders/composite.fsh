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

// --- Dither3D library (getDither3D, getGrayscale) ---
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

    // DEBUG: change mode to isolate issues
    // 0 = passthrough (normal scene), 1 = depth viz, 2 = world pos, 3 = dither
    #define DEBUG_MODE 3

    #if DEBUG_MODE == 0
        gl_FragData[0] = sceneColor;
    #elif DEBUG_MODE == 1
        gl_FragData[0] = vec4(vec3(depth), 1.0);
    #elif DEBUG_MODE == 2
        vec3 wp = getWorldPos(texCoord, depth);
        gl_FragData[0] = vec4(fract(wp.x), fract(wp.z), 0.0, 1.0);
    #else
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

        // Gamma correction: Minecraft stores colors in linear space.
        float brightness = getGrayscale(sceneColor.rgb);
        brightness = pow(max(brightness, 0.0), 1.0 / 2.0);  // sqrt — gentler than 1/2.2

        vec4 ditherResult = getDither3D(colortex4, colortex5,
                                        ditherUV, texCoord,
                                        dx, dy, brightness);
        gl_FragData[0] = vec4(vec3(ditherResult.x), 1.0);
    #endif
}
