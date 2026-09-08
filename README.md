# Live For Shader

**Live For Shader** is a complete ground-up rewrite of the car shader (`Car1.vsh` / `Car1.psh`) for an older version of a racing simulation. Newer versions are using different shading and post processing methods which is not compatible with this project. For several reasons, I prefer to improve older versions.

While maintaining the original visual balance, I'm trying to achieve better realism by adjusting small details such as paint types, perspective corrections, and mapping techniques, as well as making some adjustments and changes to the materials. It upgrades the legacy vertex-based lighting pipeline into a per-pixel shading architecture featuring physically inspired material types, dynamic procedural flakes, luma-preserving hue-shifting pearlescence, dedicated glass Fresnel rendering, and smart dark plastic bumper masking.

## History
To briefly summarize, the project began as a result of my attempts to increase performance on low-end c2-era integrated graphics processors that fallback into vertex-shader software emulation (without modded drivers) for legacy hardware due to insufficient support on modern operating systems. Also it provided to display given hexadecimal colors on vehicle surface with accurate values without any shading effects that helps to create real world vehicle paint codes. After many years, it turned to a different goal and I am making it public now.

---

## Table of Contents
- [Comparison with Legacy Shaders](#comparison-with-legacy-shaders)
- [Paint Material Modes](#paint-material-modes)
- [Shader Configuration & Tuning](#shader-configuration--tuning)
- [Debug Visualization](#debug-visualization)
- [Technical Architecture](#technical-architecture)
- [Installation](#installation)
- [License & Credits](#license--credits)

---

## Comparison with Legacy Shaders

| Feature | Legacy Shaders (0.6H) | Live For Shader 1.0.0 |
| :--- | :--- | :--- |
| **Lighting Model** | Per-vertex lighting ($N \cdot L$ in VS) | **Per-pixel diffuse lighting** ($N \cdot L$ in PS) |
| **Materials** | Basic uniform gloss & env map | **5 Selectable Paint Types** (Solid, Matte, Metallic, Pearl, Chrome) |
| **Metallic Flakes** | Micro-normal vertex jitter | **Procedural Hash-Based Flakes** in UV space |
| **Pearlescent Shift** | Not supported | **YIQ-Based Luma-Preserving Hue Rotation** |
| **Trim/Bumper Protection** | Reflection applied universally | **Luminance-Based Dark Plastic Masking** |
| **Glass Reflections** | Shared body Fresnel parameters | **Independent Glass Fresnel & Reflection Strength** |
| **Environment Mapping** | Perspective division hack (`r4.z`) | **Direct View-Space Reflection Vectors** |

---

## Paint Material Modes

Change the active paint mode directly in `Car1.psh` by editing `#define ACTIVE_PAINT`:

```hlsl
#define ACTIVE_PAINT 2   // 0 = Solid, 1 = Matte, 2 = Metallic, 3 = Pearlescent, 4 = Chrome

```

### 1. Solid Paint (`PAINT_SOLID = 0`)

Pure paint finish with clean base diffuse and standard Fresnel clearcoat specular highlights.

### 2. Matte Paint (`PAINT_MATTE = 1`)

Low-gloss finish with suppressed specular reflections and disabled clearcoat.

### 3. Metallic Paint (`PAINT_METALLIC = 2`)

Procedural flake highlights calculated using a high-frequency hash function on reflection UVs. Default mode.

```hlsl
// Metallic Parameters
static const float FlakeIntensityGlobal = 0.48f;  // Flake brightness multiplier
static const float FlakeDensity         = 0.80f;  // Flake coverage (0.0 - 1.0)
static const float FlakeSize            = 512.0f; // Scale (256=large, 512=default, 1024=fine)

```

### 4. Pearlescent Paint (`PAINT_PEARLESCENT = 3`)

Angle-dependent color shifting. Uses a luma-preserving RGB rotation matrix derived from YIQ color space to shift hues without blowing out saturation or luminance.

```hlsl
// Pearlescent Parameters
static const int   UseAutoPearlColor        = 1;     // 1 = Auto shift, 0 = Manual
static const float PearlHueShift            = 0.05f; // Hue rotation angle
static const float PearlIridescentStrength  = 1.0f;  // Intensity at grazing angles
static const float PearlEnvScale            = 0.55f; // Env reflection blend factor

```

### 5. Chrome Paint (`PAINT_CHROME = 4`)

Mirror-like reflection dominated by the environment map with subtle base color bleeding and contrast boosting.

```hlsl
// Chrome Parameters
static const float  ChromeEnvStrength   = 1.00f;                  // Mirror factor
static const float  ChromeFresnelPower  = 2.0f;                   // Falloff sharpness
static const float3 ChromeBaseTint      = float3(0.90,0.92,0.95); // Tint (Cool Silver)
static const float  ChromeGlossContrast = 1.75f;                  // Highlight contrast

```

---

## Shader Configuration & Tuning

> [!TIP]
> All parameters are declared as `static const` at the top of `Car1.psh`, meaning compiler optimization will resolve conditional logic at compile-time with **zero runtime performance penalty**.

### Diffuse Falloff Controls

Adjust diffuse brightness and light spread in `ps_main()`:

```hlsl
float exponent  = 1.25f; // Falloff width (1.0 = natural, <1.0 = wider, >1.0 = tighter)
float intensity = 1.75f; // Brightness multiplier (1.75 = 75% brighter painted surfaces)

```

### Dark Plastic Masking

Automatically detects dark areas on the livery texture (bumpers, grilles, side skirts, also including interior texture) and strips metallic/pearl/clearcoat effects to keep trim matte.

```hlsl
static const float DarkPlasticThreshold  = 0.85f; // Luminance threshold
static const float DarkPlasticSoftness   = 0.10f; // Soft transition width
static const int   EnableDarkPlasticMask = 1;     // 1 = Enabled, 0 = Disabled

```

### Dedicated Glass Settings

```hlsl
static const float GlassReflectionStrength = 2.4f; // Peak reflectivity at grazing angle
static const float GlassFresnelPower       = 2.0f; // Reflection sharpness curve

```

---

## Debug Visualization

Built-in real-time mask rendering to verify livery alpha channels and dark plastic detection. Set `DebugMask` in `Car1.psh`:

```hlsl
static const int DebugMask = 0; // 0 = Off (Normal Render)
                                // 1 = Paint Effect Mask
                                // 2 = Body Mask (Alpha > 0.8)
                                // 3 = Glass Mask (Alpha < 0.8)
                                // 4 = Dark Plastic Mask

```

---

## Technical Architecture

### Vertex Shader (`Car1.vsh`)

* **Interpolated Vectors**: Passes normalized `Normal` (`TEXCOORD4`), `LightDir` (`TEXCOORD5`), and `EyeVec` (`TEXCOORD6`) to PS.
* **Unweighted Direct Light**: `oD0` passes raw $SunColor \times VertexColor \times 2$ without pre-multiplying $N \cdot L$.
* **Clean Reflection Vectors**: Direct view-space transformation via `local_to_view` matrix without perspective division artifacts.
* **Unscaled Fresnel Pass-through**: `EnvA.x` passes raw Schlick Fresnel while `EnvA.y` passes `envmaplevel.a`.

### Pixel Shader (`Car1.psh`)

* **Per-Pixel $N \cdot L$**: Evaluates surface normal vs. light direction per pixel for crisp body highlights.
* **Single-Pass Reflection Scaling**: Fixes the legacy double-scaling bug by applying envmap intensity exactly once.
* **Shader Model 2.0 Compatible**: Complex instructions doesn't work due to limitations. I haven't figured out how to improve the flake effects with fewer commands yet. I tried to keep them as short as possible.
 
---

## Installation

> [!IMPORTANT]
> Make sure to create a backup copy of your original shader files before overwriting them.

1. Navigate to your installation directory.
2. Backup the default `Car1.vsh` and `Car1.psh` files.
3. Replace them with the updated files:
```text
path/to/game/data/shaders/Car1.vsh
path/to/game/data/shaders/Car1.psh

```


4. Restart the game to reload shaders.

---

## License & Credits

* **Author**: obdegirmenci
* **Date**: Sep 9, 2026
* **Version**: 1.0.0
* **License**: [MIT License](https://www.google.com/search?q=LICENSE)

