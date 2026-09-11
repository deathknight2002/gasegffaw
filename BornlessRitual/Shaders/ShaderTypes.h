//
//  ShaderTypes.h
//  Bornless Ritual — layouts shared by Swift (via the bridging header) and Metal.
//
//  Rules: only simd types, uint/int/float, fixed-size C arrays and enums. No bool
//  (use uint flags). Every struct is 16-byte aligned by construction; keep the field
//  order. Swift sees these as C structs (e.g. `FrameUniforms`), MSL includes this file.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#include <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

// MARK: - Binding indices

typedef NS_ENUM(EnumBackingType, BufferIndex) {
    BufferIndexFrameUniforms   = 0,   // FrameUniforms
    BufferIndexVertices        = 1,   // Vertex[]  (all static+dynamic meshes in one buffer)
    BufferIndexIndices         = 2,   // uint32[]  (all meshes; per-geometry base offsets in GeometryRange)
    BufferIndexInstances       = 3,   // InstanceData[]
    BufferIndexLights          = 4,   // LightData[lightCount]
    BufferIndexMaterials       = 5,   // MaterialData[]
    BufferIndexGeometryRanges  = 6,   // GeometryRange[] indexed by geometryIndex
    BufferIndexRingHistory     = 7,   // RingHistoryEntry[RING_COUNT * RING_HISTORY_TICKS]
    BufferIndexSigilParams     = 8,   // SigilParams
    BufferIndexDaemonParams    = 9,   // DaemonParams
    BufferIndexAccel           = 10,  // instance_acceleration_structure (RT path)
    BufferIndexSDFScene        = 11,  // SDFScene (fallback path)
    BufferIndexFroxelParams    = 12,  // FroxelParams
    BufferIndexEmbers          = 13,  // EmberInstance[] (written by the ember compute kernel)
    BufferIndexEmberCount      = 14,  // uint (atomic live count) / indirect args
    BufferIndexPostParams      = 15,  // PostParams
    BufferIndexFlames          = 16,  // FlameData[flameCount]
    BufferIndexSigilVertices   = 17,  // SigilFilamentVertex[]
    BufferIndexTextureGenParams= 18,  // TextureGenParams
    BufferIndexDrawArgs        = 19,  // MTLDrawPrimitivesIndirectArguments
};

typedef NS_ENUM(EnumBackingType, TextureIndex) {
    TextureIndexGBufferAlbedo    = 0,   // rgba8Unorm_srgb? NO: rgba8Unorm (linear albedo) .a = material id / 255
    TextureIndexGBufferNormal    = 1,   // rgba16Float: xyz world normal, w roughness
    TextureIndexGBufferMotion    = 2,   // rg16Float: motion in pixels (current − previous), MetalFX convention
    TextureIndexGBufferEmissive  = 3,   // rgba16Float: rgb emissive radiance, a metallic
    TextureIndexDepth            = 4,   // depth32Float, reversed-Z
    TextureIndexDirectDiffuse    = 5,   // rgba16Float (noisy → denoised)
    TextureIndexDirectSpecular   = 6,   // rgba16Float
    TextureIndexReflection       = 7,   // rgba16Float rgb radiance, a hit distance
    TextureIndexHistoryDiffuse   = 8,
    TextureIndexHistorySpecular  = 9,
    TextureIndexHistoryReflection= 10,
    TextureIndexPrevDepth        = 11,
    TextureIndexPrevNormal       = 12,
    TextureIndexMoments          = 13,  // rg16Float (SVGF moments) + history length in b (rgba16Float)
    TextureIndexFroxelScatter    = 14,  // 3D rgba16Float: rgb in-scatter, a transmittance (integrated)
    TextureIndexFroxelLighting   = 15,  // 3D rgba16Float per-froxel lighting (pre-integration)
    TextureIndexFroxelHistory    = 16,
    TextureIndexHDRColor         = 17,  // rgba16Float composite target (internal res)
    TextureIndexHeat             = 18,  // r16Float heat/shimmer strength (internal res)
    TextureIndexUpscaled         = 19,  // rgba16Float native res
    TextureIndexBloom0           = 20,  // bloom chain base (5 mips)
    TextureIndexOutput           = 21,  // final bgra8Unorm (drawable-sized offscreen, copied to drawable)
    TextureIndexAlbedoAtlas      = 22,  // 2D array: procedural material albedo (see MaterialTextureLayer)
    TextureIndexNormalAtlas      = 23,  // 2D array: normal (xy) + roughness (z) + height (w)
    TextureIndexBlueNoise        = 24,  // 128×128 rgba8 generated at startup (void-and-cluster approx.)
    TextureIndexSSSDiffuse       = 25,  // rgba16Float
    TextureIndexPrevHDR          = 26,  // for the TAA fallback when MetalFX is unavailable
    TextureIndexChalkMask        = 27,  // r8Unorm 2048² chalk decal (circle + name letters) for the floor
};

typedef NS_ENUM(EnumBackingType, MaterialTextureLayer) {
    MaterialTextureLayerFloorStone = 0, MaterialTextureLayerWallStone = 1, MaterialTextureLayerCloth = 2,
    MaterialTextureLayerWax = 3, MaterialTextureLayerSkin = 4, MaterialTextureLayerAltarStone = 5,
    MaterialTextureLayerIron = 6, MaterialTextureLayerCount = 7,
};

// MARK: - Constants

#define RING_COUNT              5
#define RING_HISTORY_TICKS      304     // 2.5 s lifetime × 120 Hz + slack; ring buffer indexed by tick % RING_HISTORY_TICKS
#define MAX_LIGHTS              12
#define MAX_EMBERS              16384
#define MAX_SDF_PRIMITIVES      48
#define FROXEL_X                160
#define FROXEL_Y                90
#define FROXEL_Z                64
#define SIM_TICK_RATE           120
#define WARMUP_FRAMES           16
#define EMBER_LIFETIME_TICKS    300
#define EMBERS_PER_TICK_MAX     48      // ember compute grid = RING_HISTORY_TICKS × EMBERS_PER_TICK_MAX; live if hash-selected by rate

// Material flags
#define MATERIAL_FLAG_SSS        (1u << 0)   // screen-space subsurface (skin)
#define MATERIAL_FLAG_WAX        (1u << 1)   // wax translucency (candle-lit from inside)
#define MATERIAL_FLAG_CHALK      (1u << 2)   // floor: apply chalk decal mask
#define MATERIAL_FLAG_GLOSSY     (1u << 3)   // traced reflections
#define MATERIAL_FLAG_EMISSIVE   (1u << 4)
#define MATERIAL_FLAG_NO_SHADOW  (1u << 5)   // does not cast shadow rays (flame proxies)

// Light types
#define LIGHT_TYPE_SPHERE        0     // candle flame (soft, radius)
#define LIGHT_TYPE_RING          1     // sigil ring (emissive torus, sampled on the ring)
#define LIGHT_TYPE_DAEMON        2     // daemon body glow (sphere)
#define LIGHT_TYPE_AMBIENT       3     // uniform ambient term (not shadowed)

// Render path
#define RENDER_PATH_RT           0
#define RENDER_PATH_FALLBACK     1

// SDF primitive types (fallback path)
#define SDF_BOX                  0
#define SDF_SPHERE               1
#define SDF_CAPSULE              2
#define SDF_CYLINDER             3
#define SDF_PLANE                4
#define SDF_ROOM                 5     // inverted box (chamber interior)

// MARK: - Structs

typedef struct {
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;        // jittered, reversed-Z
    simd_float4x4 viewProjection;
    simd_float4x4 invViewProjection;
    simd_float4x4 prevViewProjection;      // un-jittered previous frame (for motion vectors)
    simd_float4x4 unjitteredViewProjection;
    simd_float3   cameraPosition;
    float         time;                    // ritual seconds = tick / 120
    simd_float3   prevCameraPosition;
    float         deltaTime;               // seconds since previous rendered frame (0 in warm-up)
    simd_float2   jitter;                  // in NDC units (already applied to projectionMatrix)
    simd_float2   renderSize;              // internal resolution in pixels
    simd_float2   outputSize;              // native resolution in pixels
    simd_float2   invRenderSize;
    unsigned int  frameIndex;              // see ARCHITECTURE §6
    unsigned int  tick;
    unsigned int  seedLo;
    unsigned int  seedHi;
    unsigned int  lightCount;
    unsigned int  renderPath;              // RENDER_PATH_*
    unsigned int  historyValid;            // 0 after reset
    unsigned int  stage;                   // 1..8
    float         exposureEV;
    float         ambient;                 // 0..1 slider
    float         flameIntensity;          // slider
    float         smokeDensity;            // slider
    float         candleWarmthK;           // 1500..2400 K
    float         emberScale;
    float         nearPlane;
    float         farPlane;
    float         ringKindle;              // 0..1 chalk-ring ember glow
    float         sigilErupt;              // 0..1 sigil visibility/energy
    float         manifestT;               // 0..1 daemon condensation
    float         stageProgress;
    float         heatShimmer;             // 0..1 post strength
    float         renderScale;
    float         padding0;
    float         padding1;
} FrameUniforms;

typedef struct {
    simd_float3 position;                  // 12 bytes used, 16 stride — acceleration structures read xyz at offset 0
    simd_float3 normal;
    simd_float4 tangent;                   // xyz + handedness
    simd_float2 uv;
    simd_float2 padding;
} Vertex;

typedef struct {
    simd_float4x4 model;
    simd_float4x4 prevModel;
    simd_float4x4 normalMatrix;            // inverse-transpose of model (upper 3×3 used)
    unsigned int  materialIndex;
    unsigned int  geometryIndex;           // into GeometryRange[]
    unsigned int  flags;                   // reserved
    unsigned int  padding;
} InstanceData;

typedef struct {
    unsigned int firstIndex;               // into the shared index buffer
    unsigned int indexCount;
    unsigned int baseVertex;               // added to every index
    unsigned int padding;
} GeometryRange;

typedef struct {
    simd_float3  albedo;                   // linear
    float        roughness;
    simd_float3  emissive;                 // linear radiance
    float        metallic;
    simd_float3  sssColor;                 // subsurface tint (skin: (0.9,0.3,0.2))
    float        sssRadiusMm;              // skin 2.5, wax 6.0
    unsigned int flags;                    // MATERIAL_FLAG_*
    unsigned int textureLayer;             // MaterialTextureLayer or 0xFFFFFFFF for none
    float        uvScale;
    float        normalStrength;
} MaterialData;

typedef struct {
    simd_float3  position;
    float        radius;                   // sphere/daemon radius or ring tube radius
    simd_float3  radiance;                 // linear RGB radiant intensity scale (W·sr⁻¹ analogue)
    float        intensity;                // scalar multiplier (flicker applied on CPU)
    unsigned int type;                     // LIGHT_TYPE_*
    float        ringRadius;               // LIGHT_TYPE_RING major radius
    float        temperatureK;             // 0 = use radiance colour as-is
    unsigned int flags;
} LightData;

typedef struct {
    simd_float3  position;                 // flame base (wick top)
    float        height;                   // metres (candle ≈ 0.035)
    simd_float3  color;                    // linear tint (elemental)
    float        intensity;                // 0..1 ignition ramp × flicker
    float        temperatureK;             // 0 → colour-only
    float        flicker;                  // 0..1 instantaneous
    float        width;
    unsigned int flags;
} FlameData;

typedef struct {
    float angle;                           // rad
    float omega;                           // rad/s
    float radius;                          // m
    float energy;                          // ½ I ω² for this ring
} RingHistoryEntry;                        // index = tick % RING_HISTORY_TICKS, then ring

typedef struct {
    simd_float3  center;                   // (0, 1.55, 0)
    float        erupt;                    // 0..1
    simd_float3  coreColor;                // ember-white (1.0, 0.92, 0.75)
    float        filamentWidth;            // m (0.006)
    simd_float3  edgeColor;                // ember-orange (1.0, 0.45, 0.10)
    float        sparkRate;                // sparks/s
    unsigned int currentTick;
    unsigned int ringCount;
    unsigned int filamentVertexCount;
    float        gravity;                  // m/s² (slider-scaled)
    float        dragK;                    // 6.0
    float        emberScale;
    float        lifetime;                 // 2.5
    float        padding;
} SigilParams;

typedef struct {
    simd_float3  position;                 // world
    float        size;                     // quad half-size (m)
    simd_float3  color;                    // linear (blackbody × brightness)
    float        life;                     // 0..1 (0 = just born)
} EmberInstance;

typedef struct {
    simd_float3 position;                  // world
    float       glow;                      // 0..1 filament intensity along the rune stroke
    simd_float3 color;
    float       ring;                      // ring index as float (for per-ring rotation in the vertex shader)
} SigilFilamentVertex;                     // line-strip segments, drawn as expanded quads

typedef struct {
    simd_float3  center;                   // (0, 1.15, −0.25)
    float        manifest;                 // 0..1
    simd_float3  paletteCore;
    float        height;                   // 2.4
    simd_float3  paletteMid;
    float        breath;                   // 0..1 breathing phase
    simd_float3  paletteEdge;
    float        headYaw;                  // rad (slow turn)
    simd_float3  boundsMin;
    float        time;
    simd_float3  boundsMax;
    float        emissiveScale;
    unsigned int form;                     // DaemonForm raw value (leonine = 4)
    unsigned int motion;
    unsigned int presence;
    unsigned int padding;
} DaemonParams;

typedef struct {
    simd_float3  position;
    unsigned int type;                     // SDF_*
    simd_float3  halfExtents;              // box half extents / capsule (radius, halfLength, 0) / cylinder (radius, halfHeight, 0) / sphere (radius)
    unsigned int materialIndex;
    simd_float4  rotation;                 // quaternion (x,y,z,w)
    simd_float3  endB;                     // capsule second endpoint
    float        rounding;
} SDFPrimitive;

typedef struct {
    SDFPrimitive primitives[MAX_SDF_PRIMITIVES];
    unsigned int count;
    unsigned int padding[3];
} SDFScene;

typedef struct {
    simd_uint3   gridSize;                 // (FROXEL_X, FROXEL_Y, FROXEL_Z)
    float        nearZ;                    // 0.1 m
    float        farZ;                     // 12 m (exponential slice distribution)
    float        densityScale;             // smokeDensity slider
    float        anisotropy;               // HG g = 0.55
    float        ambientScatter;
    simd_float3  windDirection;
    float        windSpeed;
    simd_float3  censerPosition;           // (0, 0.9, −2.3)
    float        historyBlend;             // 0.92
    float        extinctionScale;          // σ_t per unit density (1/m)
    float        sigilSmoke;               // 0..1
    float        daemonSmoke;              // 0..1
    float        padding;
} FroxelParams;

typedef struct {
    float exposureEV;
    float bloomIntensity;                  // 0.06
    float bloomThreshold;                  // 1.0 (linear)
    float shimmerStrength;                 // px at native
    simd_float2 outputSize;
    float time;
    float vignette;                        // 0.25
    unsigned int frameIndex;               // dithering
    unsigned int padding[3];
} PostParams;

typedef struct {
    unsigned int layer;                    // MaterialTextureLayer
    unsigned int size;                     // 1024
    unsigned int seedLo;
    unsigned int seedHi;
} TextureGenParams;

#endif /* ShaderTypes_h */
