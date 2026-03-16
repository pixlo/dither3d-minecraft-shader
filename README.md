# Dither3D Minecraft Shader

Surface-stable fractal dithering shader pack for Minecraft (Iris/OptiFine). Converts the scene to a black-and-white halftone pattern where dots are anchored to world-space surfaces, stay stable when the camera moves, and scale fractally with distance.

Ported from [Dither3D](https://github.com/runevision/Dither3D) by **Rune Skovbo Johansen** (Unity, HLSL) to GLSL as a Minecraft composite post-process.

## Screenshots

![Dither3D in Minecraft](https://github.com/pixlo/dither3d-minecraft-shader/raw/main/screenshots/preview.png)

## Features

- **Surface-stable** — dither dots are anchored to block positions, not the screen
- **Fractal scaling** — dots smoothly transition between sizes based on distance
- **Triplanar projection** — correct dithering on floors, walls, and ceilings
- **Radial compensation** — stable dot size across the entire field of view
- **SVD-based anisotropy** — dots compress instead of stretching on angled surfaces

## Installation

1. Install [Iris Shaders](https://irisshaders.dev/) (Fabric/Quilt) or OptiFine
2. Download the [latest release](https://github.com/pixlo/dither3d-minecraft-shader/releases) or clone this repo
3. Place the folder (or zip) into `.minecraft/shaderpacks/`
4. In-game: **Options > Video Settings > Shader Packs** > select **Dither3D-Minecraft**

## Configuration

Edit `shaders/lib/dither3d.glsl` to tweak parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `dither_Scale` | 6.5 | Dot size. Higher = larger dots |
| `dither_Contrast` | 0.5 | Sharpness of dot edges |
| `dither_SizeVariability` | 0.0 | 0 = uniform dots, 1 = size varies with brightness |
| `RADIAL_COMPENSATION` | 1 | Compensate for perspective distortion |
| `INVERSE_DOTS` | 0 | Invert black/white |
| `FLIP_ATLAS_LAYERS` | 1 | Flip atlas layer order (needed for Iris) |

## Credits

- **Original algorithm and textures**: [Rune Skovbo Johansen](https://github.com/runevision) — [Dither3D](https://github.com/runevision/Dither3D)
- **Minecraft port**: [pixlo](https://github.com/pixlo)

## License

This project is licensed under the [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/), same as the original Dither3D.
