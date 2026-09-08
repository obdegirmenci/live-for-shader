// Vertex Shader : CAR1
/*
 ================================================================================
 Mod Name   :    Live For Shader
 Version    :    1.0.0
 Date       :    2026-09-08
 Author     :    obdegirmenci
 Description:    Fully rewritten pixel & vertex shader overhaul.
 - Improved lighting and reflections
 - Better reflection rendering
 ================================================================================
 */

// Environment mapping method from "alternative" version.
// Outputs Normal, LightDir, EyeVec for per-pixel diffuse.

// ==============================================================================
// Changes from 0.6H default pixel shader
// ==============================================================================
/*
 refactor(vertex-shader): prepare per-pixel lighting and fix envmap fresnel

 Major rewrite of vertex shader to support per-pixel lighting in pixel shader.
 Outputs normalized vectors (Normal, LightDir, EyeVec) instead of pre-computed
 NdotL. Environment mapping now passes raw Fresnel and separate env intensity.

 BREAKING CHANGES:
 - VS_OUTPUT structure changed:
     * Added float3 Normal : TEXCOORD4
     * Added float3 LightDir : TEXCOORD5
     * Added float3 EyeVec : TEXCOORD6
 - oD0 (COLOR0) now contains raw sun_col * vertex color (no NdotL multiplication)
 - oD0 no longer has ld_dot_n applied (moved to pixel shader)
 - oT2 (envmap UV) now uses direct r4.xy (no perspective division)
 - EnvA (TEXCOORD3) changed:
     * EnvA.x = raw Fresnel (Schlick) instead of envmaplevel.a * fresnel
     * EnvA.y = envmaplevel.a (global env intensity) instead of fresnel

 NEW FEATURES:
 - Per-pixel vector outputs for diffuse and specular:
     * Normal (interpolated, pixel shader re-normalizes)
     * LightDir (constant directional light direction)
     * EyeVec (vertex-to-eye in local space)
 - Raw Fresnel computed in vertex shader (Schlick approximation)
 - Micro-normal variation (nvar) removed for cleaner per-pixel normals
   (previously used to break mirror reflections, now handled in pixel shader)

 FIXES:
 - Envmap double-scaling bug fixed:
     * Old: VSH applied envmaplevel.a * fresnel to EnvA.x, PSH multiplied again
     * New: VSH passes raw fresnel (EnvA.x) and envLevel (EnvA.y) separately
 - Perspective division removed from envmap UV (oT2):
     * Old: r4.xy / max(0.5, r4.z + 0.5) (incorrect for cube/2D env maps)
     * New: r4.xy (direct reflection vector in view space)
 - Fresnel calculation now uses pixel shader's NdotV instead of r4.z proxy
   (more accurate for Schlick approximation)

 PERFORMANCE:
 - Reduced ALU in vertex shader (removed perspective division, micro-normals)
 - Moved NdotL and pow() to pixel shader (better for quality, same cost)
 - Cleaner instruction count for VS 2.0/3.0 compatibility

 CODE CLARITY:
 - Renamed outputs to match their actual content
 - Added comments explaining raw fresnel vs scaled fresnel separation
 - Removed obsolete SHINY-specific perspective hack
*/

#define SHINY

//=============================================================================
// Vertex Shader Input Structure
//=============================================================================
struct VS_INPUT
{
    float4 v0 : POSITION;   // Vertex position
    float3 v3 : NORMAL;     // Vertex normal
    float4 v5 : COLOR;      // Vertex color (per-vertex base color)
    float2 v8 : TEXCOORD0;  // Base texture coordinates
};

//=============================================================================
// Vertex Shader Output Structure
//=============================================================================
struct VS_OUTPUT
{
    float4 oPos  : POSITION;   // Clip space position
    float4 oD0   : COLOR0;     // Raw sun * vertex color (without NdotL)
    float4 oD1   : COLOR1;     // Ambient (hemisphere) color
    float2 oT0   : TEXCOORD0;  // Lightmap texture coordinates
    float2 oT1   : TEXCOORD1;  // Base texture coordinates

    #ifdef SHINY
    float2 oT2   : TEXCOORD2;  // Environment map reflection coordinates
    float2 EnvA  : TEXCOORD3;  // x = fresnel factor, y = envmap intensity multiplier
    #endif

    float3 Normal   : TEXCOORD4;   // Vertex normal (interpolated per-pixel)
    float3 LightDir : TEXCOORD5;   // Light direction (interpolated per-pixel)
    float3 EyeVec   : TEXCOORD6;   // Eye vector (interpolated per-pixel)
    float oFog      : FOG;         // Fog factor
};

//=============================================================================
// Global Constants (Register Bindings)
//=============================================================================

// Matrix to transform vertices to clip space (world-view-projection)
float4x4 lightinfo_mat : register(c0);

// Sun light color (direct light)
float4 sun_col : register(c6);

// Up direction vector in world space (used for hemisphere ambient)
float4 up_dir : register(c7);

// Ambient color base (constant part)
float4 basecolamb : register(c8);

// Ambient color variation with normal dot up (hemisphere intensity)
float4 diffcolamb : register(c9);

// Main light direction vector (normalized)
float4 light_dir : register(c10);

// Matrix to map vertex positions to lightmap texel space
float4x4 local_to_texel : register(c12);

// Fog parameters: x = scale, y = offset (z and w unused)
float4 fog_info : register(c90);

// Clamping values for lightmap texture coordinates (min and max)
float4 clampmin : register(c16);
float4 clampmax : register(c17);

#ifdef SHINY
// Eye position in local/model space
float4 eye_local : register(c30);

// Matrix to transform from local space to view space
float4x4 local_to_view : register(c31);

// Environment map parameters:
//   .a = overall environment map intensity multiplier (used in EnvA.y)
float4 envmaplevel : register(c36);
#endif

//=============================================================================
// Main Vertex Shader Function
//=============================================================================
VS_OUTPUT vs_main(in VS_INPUT In)
{
    VS_OUTPUT Out;

    //---------------------------------------------------------------------
    // Position and Fog Calculation
    //---------------------------------------------------------------------
    Out.oPos = mul(In.v0, lightinfo_mat);

    // Compute fog factor based on vertex depth (z in clip space)
    // Formula: fog = z * fog_info.x + fog_info.y
    Out.oFog = Out.oPos.z * fog_info.x + fog_info.y;

    //---------------------------------------------------------------------
    // Lightmap Texture Coordinate Generation
    //---------------------------------------------------------------------
    // Transform vertex position to lightmap texel space and clamp to valid range
    Out.oT0 = clamp(mul(In.v0, local_to_texel), clampmin, clampmax).xy;

    //---------------------------------------------------------------------
    // Direct (Diffuse) Lighting: Raw Color Contribution
    //---------------------------------------------------------------------
    // Note: NdotL is NOT applied here – it will be computed per-pixel in the pixel shader.
    // Multiply sun color by vertex color and boost intensity (mul2x)
    Out.oD0.rgb = sun_col.rgb * In.v5.rgb;
    Out.oD0.rgb *= 2.0f;
    Out.oD0.a = 1.0f;   // Fully opaque

    //---------------------------------------------------------------------
    // Base Texture Coordinates
    //---------------------------------------------------------------------
    Out.oT1 = In.v8;

    //---------------------------------------------------------------------
    // Ambient Lighting Contribution (Hemisphere)
    //---------------------------------------------------------------------
    // Compute dot product between normal and up direction (world Y-axis)
    float up_dot_n = dot(In.v3, up_dir.xyz);

    // Blend between base ambient and directional ambient based on up_dot_n
    float4 ambient_light_col = basecolamb + up_dot_n * diffcolamb;

    Out.oD1.rgb = ambient_light_col.rgb * In.v5.rgb;
    Out.oD1.rgb *= 2.0f;   // Boost intensity (mul2x)
    Out.oD1.a = 1.0f;

    //---------------------------------------------------------------------
    // Per-Pixel Vector Setup (for Pixel Shader)
    //---------------------------------------------------------------------
    // Normalized vertex normal (interpolated, then re-normalized per pixel)
    Out.Normal = normalize(In.v3.xyz);

    // Light direction (constant across vertices)
    Out.LightDir = normalize(light_dir.xyz);

    // Eye vector (from vertex to camera) in local space
    Out.EyeVec = normalize(eye_local.xyz - In.v0.xyz);

    #ifdef SHINY
    //---------------------------------------------------------------------
    // Environment Mapping (Specular Reflection) – Alternative Method
    //---------------------------------------------------------------------
    // Compute view direction again (redundant but kept for clarity)
    float3 E = normalize(eye_local.xyz - In.v0.xyz);
    float3 N = normalize(In.v3.xyz);

    // Reflection vector: R = E - 2 * (E·N) * N
    float3 r3 = E - 2.0f * dot(E, N) * N;

    // Transform reflection vector from local space to view space
    float4 r4 = mul(float4(r3, 1.0f), local_to_view);

    // Direct 2D coordinates for environment map lookup (no perspective division)
    Out.oT2 = r4.xy;

    // Fresnel effect (Schlick approximation) for environment map blending
    float NdotV = saturate(dot(N, E));
    float f0 = 0.24f;                       // Fresnel reflectance at normal incidence
    float fresnel = f0 + (1.0f - f0) * pow(1.0f - NdotV, 2.0f);
    fresnel = saturate(fresnel * 1.20f);    // Slight boost for stronger effect

    // Pack fresnel and environment intensity:
    //   EnvA.x = fresnel factor (blend amount for environment map)
    //   EnvA.y = environment map overall intensity multiplier (from envmaplevel.a)
    Out.EnvA = float2(fresnel, envmaplevel.a);
    #endif

    return Out;
}
