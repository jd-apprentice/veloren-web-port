#version 440 core
#define isinf(x) (abs(x) > 3.4e38)

/* NOTE: When included, this file will contain values for the automatically defined settings specified below. */

/* TODO: Add the ability to control the tendency to do stuff in the vertex vs. fragment shader.
 * Currently this flag is ignored and always set to prefer fragment, but this tradeoff is not correct on all
 * machines in all cases (mine, for instance). */
#define VOXYGEN_COMPUTATION_PREFERENCE_FRAGMENT 0
#define VOXYGEN_COMPUTATION_PREFERENCE_VERTEX 1

#define FLUID_MODE_LOW 0
#define FLUID_MODE_MEDIUM 1
#define FLUID_MODE_HIGH 2

#define REFLECTION_MODE_LOW 0
#define REFLECTION_MODE_MEDIUM 1
#define REFLECTION_MODE_HIGH 2

#define CLOUD_MODE_FLAT 0
#define CLOUD_MODE_MINIMAL 1
#define CLOUD_MODE_LOW 2
#define CLOUD_MODE_MEDIUM 3
#define CLOUD_MODE_HIGH 4
#define CLOUD_MODE_ULTRA 5

#define LIGHTING_ALGORITHM_LAMBERTIAN 0
#define LIGHTING_ALGORITHM_BLINN_PHONG 1
#define LIGHTING_ALGORITHM_ASHIKHMIN 2

#define SHADOW_MODE_NONE 0
#define SHADOW_MODE_CHEAP 1
#define SHADOW_MODE_MAP 2

/* Unlike the other flags (for now anyway), these are bitmask values */
#define LIGHTING_TYPE_REFLECTION 0x01
#define LIGHTING_TYPE_TRANSMISSION 0x02

/* Currently ignored, but ideally shoud be helpful for determining light transport properties. */
#define LIGHTING_REFLECTION_KIND_DIFFUSE 0
#define LIGHTING_REFLECTION_KIND_GLOSSY 1
#define LIGHTING_REFLECTION_KIND_SPECULAR 2

#define LIGHTING_TRANSPORT_MODE_IMPORTANCE 0
/* Radiance mode is currently used as a proxy for "attenuation and medium materials
 * matter," but we may make it more granular. */
#define LIGHTING_TRANSPORT_MODE_RADIANCE 1

#define LIGHTING_DISTRIBUTION_SCHEME_MICROFACET 0
#define LIGHTING_DISTRIBUTION_SCHEME_VOXEL 1

#define LIGHTING_DISTRIBUTION_BECKMANN 0
#define LIGHTING_DISTRIBUTION_TROWBRIDGE 1

#define MEDIUM_AIR 0
#define MEDIUM_WATER 1

#define MAT_SKY 0
#define MAT_BLOCK 1
#define MAT_WATER 2
#define MAT_FIGURE 3
#define MAT_LOD 4
#define MAT_PUDDLE 5

#define BLOCK_SNOW 0x21
#define BLOCK_ART_SNOW 0x22
#define BLOCK_ICE 0x43

// An arbitrary value that represents a very far distance (at least as far as the player should be able to see) without
// being too far that we end up with precision issues (used in clouds and elsewhere).
#define DIST_CAP 500000

/* Constants expected to be defined automatically by configuration: */

/*
#define VOXYGEN_COMPUTATION_PREFERENCE <preference>
#define FLUID_MODE <mode>
#define CLOUD_MODE <mode>
#define LIGHTING_ALGORITHM <algorithm>
#define SHADOW_MODE <mode>
*/

/* Constants possibly defined automatically by configuration: */

/*
#define POINT_GLOW_FACTOR <0.0..1.0>
*/

/* Constants expected to be defined by any shader that needs to perform lighting calculations
 * (but whose values may take automatically defined constants into account): */

/*
// At least one of LIGHTING_TYPE_REFLECTION or LIGHTING_TYPE_TRANSMISSION should be set.
#define LIGHTING_TYPE <type bitmask>
#define LIGHTING_REFLECTION_KIND <kind>
#define LIGHTING_TRANSPORT_MODE <mode>
#define LIGHTING_DISTRIBUTION_SCHEME <scheme>
#define LIGHTING_DISTRIBUTION <distribution>
*/

/* Constants that *may* be defined by any shader.
 * (and whose values may take automatically defined constants into account): */

/*
// When sets, shadow maps are used to cast shadows.
#define HAS_SHADOW_MAPS
// When set, "full" LOD terrain informatino is available (e.g. terrain colors).
#define HAS_LOD_FULL_INFO
*/


#define LIGHTING_TYPE LIGHTING_TYPE_REFLECTION

#define LIGHTING_REFLECTION_KIND LIGHTING_REFLECTION_KIND_GLOSSY

#define LIGHTING_TRANSPORT_MODE LIGHTING_TRANSPORT_MODE_IMPORTANCE

#define LIGHTING_DISTRIBUTION_SCHEME LIGHTING_DISTRIBUTION_SCHEME_MICROFACET

#define LIGHTING_DISTRIBUTION LIGHTING_DISTRIBUTION_BECKMANN

#ifndef GLOBALS_GLSL
#define GLOBALS_GLSL

layout(std140, set = 0, binding = 0) uniform u_globals {
    mat4 view_mat;
    mat4 proj_mat;
    mat4 all_mat;
    vec4 cam_pos;
    vec4 focus_off;
    vec4 focus_pos;
    vec4 view_distance;
    // .x = time of day, repeats every day.
    // .y = a continuous value for what day it is. Repeats every `tick_overflow` for precisions sake.
    vec4 time_of_day;
    vec4 sun_dir;
    vec4 moon_dir;
    // .x = The `Time` resource, repeated every `tick_overflow`
    // .y = a floored (`Time` / `tick_overflow`)
    // .z = Time local to client, not synced between clients.
    vec4 tick;
    vec4 screen_res;
    uvec4 light_shadow_count;
    vec4 shadow_proj_factors;
    uvec4 medium;
    ivec4 select_pos;
    vec4 gamma_exposure;
    vec4 last_lightning;
    vec2 wind_vel;
    vec2 internal_res;
    float ambiance;
    // 0 - FirstPerson
    // 1 - ThirdPerson
    uint cam_mode;
    float sprite_render_distance;
    float u_rotation;
    float screen_fade;
};

float distance_divider = 2.0;
float shadow_dithering = 0.5;

float tick_overflow = 300000.0;

// Get a scaled time with an offset that loops at a period.
float tick_loop(float period, float scale, float offset) {
    float loop = tick_overflow * scale;
    float rem = mod(loop, period);
    float rest = rem * tick.y;

    return mod(rest + tick.x * scale + offset, period);
}

float tick_loop(float period) {
    return tick_loop(period, 1.0, 0.0);
}

vec3 tick_loop(float period, vec3 scale, vec3 offset) {
    vec3 loop = tick_overflow * scale;
    vec3 rem = mod(loop, period);
    vec3 rest = rem * tick.y;

    return mod(rest + tick.x * scale + offset, period);
}

// Only works if t happened within tick_overflow
float time_since(float t) {
    return tick.x < t ? (tick_overflow - t + tick.x) : (tick.x - t);
}

#endif

#ifndef SRGB_GLSL
#define SRGB_GLSL

#extension GL_EXT_samplerless_texture_functions : enable

// Linear RGB, attenuation coefficients for water at roughly R, G, B wavelengths.
// See https://en.wikipedia.org/wiki/Electromagnetic_absorption_by_water
const vec3 MU_WATER = vec3(0.6, 0.04, 0.01);

//https://gamedev.stackexchange.com/questions/92015/optimized-linear-to-srgb-glsl
vec3 srgb_to_linear(vec3 srgb) {
    bvec3 cutoff = lessThan(srgb, vec3(0.04045));
    vec3 higher = pow((srgb + vec3(0.055))/vec3(1.055), vec3(2.4));
    vec3 lower = srgb/vec3(12.92);

    return mix(higher, lower, cutoff);
}

vec3 linear_to_srgb(vec3 col) {
    vec3 s1 = vec3(sqrt(col.r), sqrt(col.g), sqrt(col.b));
    vec3 s2 = vec3(sqrt(s1.r), sqrt(s1.g), sqrt(s1.b));
    vec3 s3 = vec3(sqrt(s2.r), sqrt(s2.g), sqrt(s2.b));
    return vec3(
            mix(11.500726 * col.r, (0.585122381 * s1.r + 0.783140355 * s2.r - 0.368262736 * s3.r), clamp((col.r - 0.0060) * 10000.0, 0.0, 1.0)),
            mix(11.500726 * col.g, (0.585122381 * s1.g + 0.783140355 * s2.g - 0.368262736 * s3.g), clamp((col.g - 0.0060) * 10000.0, 0.0, 1.0)),
            mix(11.500726 * col.b, (0.585122381 * s1.b + 0.783140355 * s2.b - 0.368262736 * s3.b), clamp((col.b - 0.0060) * 10000.0, 0.0, 1.0))
    );
}

float pow5(float x) {
    float x2 = x * x;
    return x2 * x2 * x;
}

vec4 pow5(vec4 x) {
    vec4 x2 = x * x;
    return x2 * x2 * x;
}

// Fresnel angle for perfectly specular dialectric materials.

// Schlick approximation
vec3 schlick_fresnel(vec3 Rs, float cosTheta) {
    return Rs + pow5(1.0 - cosTheta) * (1.0 - Rs);
}

// Beckmann Distribution
float BeckmannDistribution_D(float NdotH, float alpha) {
    const float PI = 3.1415926535897932384626433832795;
    float NdotH2 = NdotH * NdotH;
    float NdotH2m2 = NdotH2 * alpha * alpha;
    float k_spec = exp((NdotH2 - 1.0) / NdotH2m2) / (PI * NdotH2m2 * NdotH2);
    return mix(k_spec, 0.0, NdotH == 0.0);
}

// Voxel Distribution
float BeckmannDistribution_D_Voxel(vec3 wh, vec3 voxel_norm, float alpha) {
    vec3 sides = sign(voxel_norm);
    
    vec3 NdotH = wh * sides;

    const float PI = 3.1415926535897932384626433832795;
    vec3 NdotH2 = NdotH * NdotH;
    vec3 NdotH2m2 = NdotH2 * alpha * alpha;
    vec3 k_spec = exp((NdotH2 - 1.0) / NdotH2m2) / (PI * NdotH2m2 * NdotH2);
    return dot(mix(k_spec, vec3(0.0), equal(NdotH, vec3(0.0))), abs(voxel_norm));
}

float TrowbridgeReitzDistribution_D_Voxel(vec3 wh, vec3 voxel_norm, float alpha) {
    vec3 sides = sign(voxel_norm);

    vec3 NdotH = wh * sides;

    const float PI = 3.1415926535897932384626433832795;
    vec3 NdotH2 = NdotH * NdotH;
    vec3 NdotH2m2 = NdotH2 * alpha * alpha;
    vec3 e = (1.0 - NdotH2) / NdotH2m2;
    vec3 k_spec = 1.0 / (PI * NdotH2m2 * NdotH2 * (1.0 + e) * (1.0 + e));
    return dot(mix(k_spec, vec3(0.0), equal(NdotH, vec3(0.0))), abs(voxel_norm));
}

float BeckmannDistribution_Lambda(vec3 norm, vec3 dir, float alpha) {
    float CosTheta = dot(norm, dir);
    float SinTheta = sqrt(1.0 - CosTheta * CosTheta);
    float TanTheta = SinTheta / CosTheta;
    float absTanTheta = abs(TanTheta);
    float a = 1.0 / (alpha * absTanTheta);
    
    return mix(max(0.0, (1.0 - 1.259 * a + 0.396 * a * a) / (3.535 * a + 2.181 * a * a)), 0.0, isinf(absTanTheta) || a >= 1.6);
}

float BeckmannDistribution_G(vec3 norm, vec3 dir, vec3 light_dir, float alpha) {
    return 1.0 / (1.0 + BeckmannDistribution_Lambda(norm, dir, alpha) + BeckmannDistribution_Lambda(norm, -light_dir, alpha));
}

// Fresnel blending
//
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Microfacet_Models.html#fragment-MicrofacetDistributionPublicMethods-2
// and
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Fresnel_Incidence_Effects.html
vec3 FresnelBlend_f(vec3 norm, vec3 dir, vec3 light_dir, vec3 R_d, vec3 R_s, float alpha) {
    const float PI = 3.1415926535897932384626433832795;
    alpha = alpha * sqrt(2.0);
    float cos_wi = dot(-light_dir, norm);
    float cos_wo = dot(dir, norm);

    vec3 diffuse = (28.0 / (23.0 * PI)) * R_d *
        (1.0 - R_s) *
        (1.0 - pow5(1.0 - 0.5 * abs(cos_wi))) *
        (1.0 - pow5(1.0 - 0.5 * abs(cos_wo)));
    vec3 wh = -light_dir + dir;
#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    bool is_blocked = cos_wi == 0.0 || cos_wo == 0.0;
#else
    bool is_blocked = cos_wi <= 0.0 || cos_wo <= 0.0;
#endif
    if (is_blocked) {
        return vec3(0.0);
    }
    wh = normalize(wh);
    float dot_wi_wh = dot(-light_dir, wh);
    vec3 specular = dot(norm, dir) > 0.0 ? vec3(0.0) : (BeckmannDistribution_D(dot(wh, norm), alpha) /
        (4.0 * abs(dot_wi_wh) *
        max(abs(cos_wi), abs(cos_wo))) *
        schlick_fresnel(R_s, dot_wi_wh));
    return mix(diffuse + specular, vec3(0.0), bvec3(all(equal(light_dir, dir))));
}

// Fresnel blending
//
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Microfacet_Models.html#fragment-MicrofacetDistributionPublicMethods-2
// and
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Fresnel_Incidence_Effects.html
vec3 FresnelBlend_Voxel_f(vec3 norm, vec3 dir, vec3 light_dir, vec3 R_d, vec3 R_s, float alpha, vec3 voxel_norm, float dist) {
    const float PI = 3.1415926535897932384626433832795;
    alpha = alpha * sqrt(2.0);
    float cos_wi = dot(-light_dir, norm);
    float cos_wo = dot(dir, norm);

#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    vec4 AbsNdotL = abs(vec4(light_dir, cos_wi));
    vec4 AbsNdotV = abs(vec4(dir, cos_wo));
#else
    vec3 sides = sign(voxel_norm);
    vec4 AbsNdotL = vec4(max(-light_dir * sides, 0.0), abs(cos_wi));
    vec4 AbsNdotV = vec4(max(dir * sides, 0.0), abs(cos_wo));
#endif

    vec4 diffuse_factor = (1.0 - pow5(1.0 - 0.5 * AbsNdotL)) * (1.0 - pow5(1.0 - 0.5 * AbsNdotV));

    vec3 diffuse = (28.0 / (23.0 * PI)) * R_d * (1.0 - R_s) * dot(diffuse_factor, /*R_r * */vec4(abs(norm) * (1.0 - dist), dist));

    vec3 wh = -light_dir + dir;
#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    bool is_blocked = cos_wi == 0.0 || cos_wo == 0.0;
#else
    bool is_blocked = cos_wi <= 0.0 || cos_wo <= 0.0;
#endif
    if (is_blocked) {
        return vec3(0.0);
    }
    wh = normalize(wh);
    float dot_wi_wh = dot(-light_dir, wh);
    float distr = BeckmannDistribution_D_Voxel(wh, voxel_norm, alpha);
    vec3 specular = distr /
        (4.0 * abs(dot_wi_wh) *
        max(abs(cos_wi), abs(cos_wo))) *
        schlick_fresnel(R_s, dot_wi_wh);
    return mix(diffuse + specular, vec3(0.0), bvec3(all(equal(light_dir, dir))));
}

// Phong reflection.
//
// Note: norm, dir, light_dir must all be normalizd.
vec3 light_reflection_factor2(vec3 norm, vec3 dir, vec3 light_dir, vec3 k_d, vec3 k_s, float alpha) {
    // TODO: These are supposed to be the differential changes in the point location p, in tangent space.
    // That is, assuming we can parameterize a 2D surface by some function p : R² → R³, mapping from
    // points in a plane to 3D points on the surface, we can define
    // ∂p(u,v)/∂u and ∂p(u,v)/∂v representing the changes in the pont location as we move along these
    // coordinates.
    //
    // Then we can define the normal at a point, n(u,v) = ∂p(u,v)/∂u × ∂p(u,v)/∂v.
    //
    // Additionally, we can define the change in *normals* at each point using the
    // Weingarten equations (see http://www.pbr-book.org/3ed-2018/Shapes/Spheres.html):
    //
    // ∂n/∂u = (fF - eG) / (EG - F²) ∂p/∂u + (eF - fE) / (EG - F²) ∂p/∂v
    // ∂n/∂v = (gF - fG) / (EG - F²) ∂p/∂u + (fF - gE) / (EG - F²) ∂p/∂v
    //
    // where
    //
    // E = |∂p/∂u ⋅ ∂p/∂u|
    // F = ∂p/∂u ⋅ ∂p/∂u
    // G = |∂p/∂v ⋅ ∂p/∂v|
    //
    // and
    //
    // e = n ⋅ ∂²p/∂u²
    // f = n ⋅ ∂²p/(∂u∂v)
    // g = n ⋅ ∂²p/∂v²
    //
    // For planes (see http://www.pbr-book.org/3ed-2018/Shapes/Triangle_Meshes.html) we have
    // e = f = g = 0 (since the plane has no curvature of any sort) so we get:
    //
    // ∂n/∂u = (0, 0, 0)
    // ∂n/∂v = (0, 0, 0)
    //
    // To find ∂p/∂u and ∂p/∂v, we first write p and u parametrically:
    //    p(u, v) = p0 + u ∂p/∂u + v ∂p/∂v
    //
    // ( u₀ - u₂    v₀ - v₂
    //   u₁ - u₂    v₁ - v₂ )
    //
    // Basis: plane norm = norm = (0, 0, 1), x vector = any orthgonal vector on the plane.
    // vec3 w_i =
    // vec3 w_i = vec3(view_mat * vec4(-light_dir, 1.0));
    // vec3 w_o = vec3(view_mat * vec4(light_dir, 1.0));
    return FresnelBlend_f(norm, dir, light_dir, k_d, k_s, alpha);
}

vec3 light_reflection_factor(vec3 norm, vec3 dir, vec3 light_dir, vec3 k_d, vec3 k_s, float alpha, vec3 voxel_norm, float voxel_lighting) {
#if (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_LAMBERTIAN)
    const float PI = 3.141592;
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    vec4 AbsNdotL = abs(vec4(light_dir, dot(norm, light_dir)));
        #else
    vec3 sides = sign(voxel_norm);
    vec4 AbsNdotL = max(vec4(-light_dir * sides, dot(norm, -light_dir)), 0.0);
        #endif
    float diffuse = dot(AbsNdotL, vec4(abs(voxel_norm) * (1.0 - voxel_lighting), voxel_lighting));
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    float diffuse = abs(dot(norm, light_dir));
        #else
    float diffuse = max(dot(norm, -light_dir), 0.0);
        #endif
    #endif
    return k_d / PI * diffuse;
#elif (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_BLINN_PHONG)
    const float PI = 3.141592;
    alpha = alpha * sqrt(2.0);
    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    float ndotL = abs(dot(norm, light_dir));
    #else
    float ndotL = max(dot(norm, -light_dir), 0.0);
    #endif

    if (ndotL > 0.0) {
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        vec4 AbsNdotL = abs(vec4(light_dir, ndotL));
        #else
        vec3 sides = sign(voxel_norm);
        vec4 AbsNdotL = max(vec4(-light_dir * sides, ndotL), 0.0);
        #endif
        float diffuse = dot(AbsNdotL, vec4(abs(voxel_norm) * (1.0 - voxel_lighting), voxel_lighting));
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        float diffuse = ndotL;
    #endif
        vec3 H = normalize(-light_dir + dir);

    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        float NdotH = abs(dot(norm, H));
    #else
        float NdotH = max(dot(norm, H), 0.0);
    #endif
        return (1.0 - k_s) / PI * k_d * diffuse + k_s * pow(NdotH, alpha/* * 4.0*/);
    }

    return vec3(0.0);
#elif (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_ASHIKHMIN)
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        return FresnelBlend_Voxel_f(norm, dir, light_dir, k_d, k_s, alpha, voxel_norm, voxel_lighting);
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        return FresnelBlend_f(norm, dir, light_dir, k_d, k_s, alpha);
    #endif
#endif
}

float rel_luminance(vec3 rgb)
{
    // https://en.wikipedia.org/wiki/Relative_luminance
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    return dot(rgb, W);
}

// From https://discourse.vvvv.org/t/infinite-ray-intersects-with-infinite-plane/10537
// out of laziness.
bool IntersectRayPlane(vec3 rayOrigin, vec3 rayDirection, vec3 posOnPlane, vec3 planeNormal, inout vec3 intersectionPoint)
{
  float rDotn = dot(rayDirection, planeNormal);

  //parallel to plane or pointing away from plane?
  if (rDotn < 0.0000001 )
    return false;

  float s = dot(planeNormal, (posOnPlane - rayOrigin)) / rDotn;

  intersectionPoint = rayOrigin + s * rayDirection;

  return true;
}

// Compute uniform attenuation due to beam passing through a substance that fills an area below a horizontal plane
// (e.g. in most cases, water below the water surface depth) using the simplest form of the Beer-Lambert law
// (https://en.wikipedia.org/wiki/Beer%E2%80%93Lambert_law):
//
// I(z) = I₀ e^(-μz)
//
// We compute this value, except for the initial intensity which may be multiplied out later.
//
// wpos is the position of the point being hit.
// ray_dir is the reversed direction of the ray (going "out" of the point being hit).
// mu is the attenuation coefficient for R, G, and B wavelenghts.
// surface_alt is the estimated altitude of the horizontal surface separating the substance from air.
// defaultpos is the position to use in computing the distance along material at this point if there was a failure.
//
// Ideally, defaultpos is set so we can avoid branching on error.
vec3 compute_attenuation(vec3 wpos, vec3 ray_dir, vec3 mu, float surface_alt, vec3 defaultpos) {
#if (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_IMPORTANCE)
    return vec3(1.0);
#elif (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_RADIANCE)
    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        return vec3(1.0);
    #else
    ray_dir = faceforward(ray_dir, vec3(0.0, 0.0, -1.0), ray_dir);
    vec3 surface_dir = surface_alt < wpos.z ? vec3(0.0, 0.0, -1.0) : vec3(0.0, 0.0, 1.0);
    bool _intersects_surface = IntersectRayPlane(wpos, ray_dir, vec3(0.0, 0.0, surface_alt), surface_dir, defaultpos);
    float depth = length(defaultpos - wpos);
    return exp(-mu * depth);
    #endif
#endif
}

// Same as compute_attenuation but since both point are known, set a maximum to make sure we don't exceed the length
// from the default point.
vec3 compute_attenuation_point(vec3 wpos, vec3 ray_dir, vec3 mu, float surface_alt, vec3 defaultpos) {
#if (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_IMPORTANCE)
    return pow(1.0 - mu, vec3(3));
#elif (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_RADIANCE)
    return vec3(1.0);
#endif
}

vec3 greedy_extract_col_light_attr(texture2D t_col_light, sampler s_col_light, vec2 f_uv_pos, out float f_light, out float f_glow, out float f_ao, out uint f_attr, out float f_sky_exposure) {
    // TODO: Figure out how to use `texture` and modulation to avoid needing to do manual filtering
    // TODO: Use `texture` instead

    uvec4 tex_00 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(0, 0), 0) * 255.0);
    uvec4 tex_10 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(1, 0), 0) * 255.0);
    uvec4 tex_01 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(0, 1), 0) * 255.0);
    uvec4 tex_11 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(1, 1), 0) * 255.0);
    vec3 light_00 = vec3(tex_00.rg >> 3u, tex_00.a & 1u);
    vec3 light_10 = vec3(tex_10.rg >> 3u, tex_10.a & 1u);
    vec3 light_01 = vec3(tex_01.rg >> 3u, tex_01.a & 1u);
    vec3 light_11 = vec3(tex_11.rg >> 3u, tex_11.a & 1u);
    vec3 light_0 = mix(light_00, light_01, fract(f_uv_pos.y));
    vec3 light_1 = mix(light_10, light_11, fract(f_uv_pos.y));
    vec3 light = mix(light_0, light_1, fract(f_uv_pos.x));

    vec3 f_col = vec3(
        float(((tex_00.r & 0x7u) << 1u) | (tex_00.b & 0xF0u)),
        float(tex_00.a & 0xFEu),
        float(((tex_00.g & 0x7u) << 1u) | ((tex_00.b & 0x0Fu) << 4u))
    ) / 255.0;

    f_ao = light.z;
    f_light = light.x / 31.0;
    f_sky_exposure = light.x / 31.0 + (1.0 - f_ao) * 0.5;
    f_glow = light.y / 31.0;
    f_attr = tex_00.g >> 3u;
    return srgb_to_linear(f_col);
}

vec3 greedy_extract_col_light_kind_terrain(
    texture2D t_col_light, sampler s_col_light,
    utexture2D t_kind,
    vec2 f_uv_pos,
    out float f_light, out float f_glow, out float f_ao, out float f_sky_exposure, out uint f_kind
) {
    uint _f_attr;
    f_kind = uint(texelFetch(t_kind, ivec2(f_uv_pos), 0).r);
    return greedy_extract_col_light_attr(t_col_light, s_col_light, f_uv_pos, f_light, f_glow, f_ao, _f_attr, f_sky_exposure);
}

vec3 greedy_extract_col_light_figure(texture2D t_col_light, sampler s_col_light, vec2 f_uv_pos, out float f_light, out uint f_attr) {
    float _f_sky_exposure, _f_light, _f_glow, _f_ao;
    return greedy_extract_col_light_attr(t_col_light, s_col_light, f_uv_pos, f_light, _f_glow, _f_ao, f_attr, _f_sky_exposure);
}

#endif

#ifndef RANDOM_GLSL
#define RANDOM_GLSL

layout(set = 0, binding = 1) uniform texture2D t_noise;
layout(set = 0, binding = 2) uniform sampler s_noise;

float hash(vec4 p) {
    p = fract(p * 0.3183099 + 0.1) - fract(p + 23.22121);
    p *= 17.0;
    return (fract(p.x * p.y * (1.0 - p.z) * p.w * (p.x + p.y + p.z + p.w)) - 0.5) * 2.0;
}

#define M1 2047667443U
#define M2 3883706873U
#define M3 3961281721U

float hash_one(uint q) {
    uint n = ((M3 * q) ^ M2) * M1;

    return float(n) * (1.0 / float(0xffffffffU));
}

float hash_two(uvec2 q) {
    q *= uvec2(M1, M2);
    uint n = q.x ^ q.y;
    n = n * (n ^ (n >> 15));
    return float(n) * (1.0 / float(0xffffffffU));
}

vec3 hash_two_3(uvec2 q) {
    q *= uvec2(M1, M2);
    uvec3 n = uvec3(q.x ^ q.y ^ uvec3(M1, M2, M3));
    n = n * (n ^ (n >> 15));
    return vec3(n) * (1.0 / vec3(0xffffffffU));
}

float hash_three(uvec3 q) {
    q *= uvec3(M1, M2, M3);
    uint n = q.x ^ q.y ^ q.z;
    n = n * (n ^ (n >> 15));
    return float(n) * (1.0 / float(0xffffffffU));
}

float hash_fast(uvec3 q) {
    q *= uvec3(M1, M2, M3);

    uint n = (q.x ^ q.y ^ q.z) * M1;

    return float(n) * (1.0 / float(0xffffffffU));
}

// 2D, but using shifted 2D textures
float noise_2d(vec2 pos) {
    return textureLod(sampler2D(t_noise, s_noise), pos, 0.0).x;
}

// 3D, but using shifted 2D textures
float noise_3d(vec3 pos) {
    pos.z *= 15.0;
    uint z = uint(trunc(pos.z));
    vec2 offs0 = vec2(hash_one(z), hash_one(z + 73u));
    vec2 offs1 = vec2(hash_one(z + 1u), hash_one(z + 1u + 73u));
    return mix(textureLod(sampler2D(t_noise, s_noise), pos.xy + offs0, 0.0).x, textureLod(sampler2D(t_noise, s_noise), pos.xy + offs1, 0.0).x, fract(pos.z));
}

// 3D version of `snoise`
float snoise3(in vec3 x) {
    uvec3 p = uvec3(floor(x) + 10000.0);
    vec3 f = fract(x);
    //f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(hash_fast(p + uvec3(0, 0, 0)), hash_fast(p + uvec3(1, 0, 0)), f.x),
            mix(hash_fast(p + uvec3(0, 1, 0)), hash_fast(p + uvec3(1, 1, 0)), f.x),
            f.y),
        mix(
            mix(hash_fast(p + uvec3(0, 0, 1)), hash_fast(p + uvec3(1, 0, 1)), f.x),
            mix(hash_fast(p + uvec3(0, 1, 1)), hash_fast(p + uvec3(1, 1, 1)), f.x),
            f.y),
        f.z);
}

// 4D noise
float snoise(in vec4 x) {
    vec4 p = floor(x);
    vec4 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(
                mix(hash(p + vec4(0, 0, 0, 0)), hash(p + vec4(1, 0, 0, 0)), f.x),
                mix(hash(p + vec4(0, 1, 0, 0)), hash(p + vec4(1, 1, 0, 0)), f.x),
                f.y),
            mix(
                mix(hash(p + vec4(0, 0, 1, 0)), hash(p + vec4(1, 0, 1, 0)), f.x),
                mix(hash(p + vec4(0, 1, 1, 0)), hash(p + vec4(1, 1, 1, 0)), f.x),
                f.y),
            f.z),
        mix(
            mix(
                mix(hash(p + vec4(0, 0, 0, 1)), hash(p + vec4(1, 0, 0, 1)), f.x),
                mix(hash(p + vec4(0, 1, 0, 1)), hash(p + vec4(1, 1, 0, 1)), f.x),
                f.y),
            mix(
                mix(hash(p + vec4(0, 0, 1, 1)), hash(p + vec4(1, 0, 1, 1)), f.x),
                mix(hash(p + vec4(0, 1, 1, 1)), hash(p + vec4(1, 1, 1, 1)), f.x),
                f.y),
            f.z),
        f.w);
}

vec3 rand_perm_3(vec3 pos) {
    return abs(sin(pos * vec3(1473.7 * pos.z + 472.3, 8891.1 * pos.x + 723.1, 3813.3 * pos.y + 982.5)));
}

vec4 rand_perm_4(vec4 pos) {
    return sin(473.3 * pos * vec4(317.3 * pos.w + 917.7, 1473.7 * pos.z + 472.3, 8891.1 * pos.x + 723.1, 3813.3 * pos.y + 982.5) / pos.yxwz);
}

vec3 smooth_rand(vec3 pos, float lerp_axis) {
    return vec3(snoise(vec4(pos, lerp_axis)), snoise(vec4(pos + 400.0, lerp_axis)), snoise(vec4(pos + 1000.0, lerp_axis)));
}

// Transform normal distribution to triangle distribution.
float norm2tri(float n) {
   // TODO: compare perf with adding two normal noise distributions
   bool flip = n > 0.5;
   n = flip ? 1.0 - n : n;
   n = sqrt(n / 2.0);
   n = flip ? 1.0 - n : n;
   return n;
}

// Caustics, ported and modified from https://www.shadertoy.com/view/3tlfR7, originally David Hoskins.
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License: https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode.
// Modifying these three functions mean that you agree to release your changes under the above license, *not* under GPL 3 as with the rest of the project.

float hashvec2(vec2 p) {return fract(sin(p.x * 1e2 + p.y) * 1e5 + sin(p.y * 1e3) * 1e3 + sin(p.x * 735. + p.y * 11.1) * 1.5e2); }

float n12(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f *= f * (3.-2.*f);
    return mix(
        mix(hashvec2(i+vec2(0.,0.)),hashvec2(i+vec2(1.,0.)),f.x),
        mix(hashvec2(i+vec2(0.,1.)),hashvec2(i+vec2(1.,1.)),f.x),
        f.y
    );
}

float caustics(vec2 p, float t) {
    vec3 k = vec3(p,t);
    float l;
    mat3 m = mat3(-2.,-1.,2.,3.,-2.,1.,1.,2.,2.);
    float n = n12(p);
    k = k*m*.5;
    l = length(.5 - fract(k+n));
    k = k*m*.4;
    l = min(l, length(.5-fract(k+n)));
    k = k*m*.3;
    l = min(l, length(.5-fract(k+n)));
    return pow(l,3.)*5.5;
}

#ifdef EXPERIMENTAL_DISCARDTRANSPARENCY
bool dither(vec2 frag_coord, float a, uint id) {
    if (a < 1.0 / 17.0) {
        return true;
    }
    if (a > 16.0 / 17.0) {
        return false;
    }

    // Use the id to try to discard different pixels from different objects, causing
    // them to be visible behind eachother.
    float r0 = floor(hash_one(id) * 16.0);
    vec2 r1 = vec2(floor(r0 * 0.25), mod(r0, 4.0));

    // We sample the bayer multiple times to have a smoother gradient of dithering.
    // This could be achieved by having a larger bayer matrix, but would then have
    // to define a larger one and not sure it would be much more efficient.
    uvec2 pos0 = uvec2(frag_coord + r1) % 4;
    uvec2 pos1 = uvec2(frag_coord / 4.0 + r1) % 4;
    uvec2 pos2 = uvec2(frag_coord / 16.0 + r1) % 4;

    mat4 bayer = mat4(
        16.0, 4.0, 13.0, 1.0,
        8.0, 12.0, 5.0, 9.0,
        14.0, 2.0, 15.0, 3.0,
        6.0, 10.0, 7.0, 11.0
    );
    mat4 bayer0 = bayer / 17.0;
    mat4 bayer1 = bayer / (17.0 * 17.0);
    mat4 bayer2 = bayer / (17.0 * 17.0 * 17.0);

    return a < bayer0[pos0.x][pos0.y] + bayer1[pos1.x][pos1.y] + bayer2[pos2.x][pos2.y];
}
#endif

#endif

#ifndef LOD_GLSL
#define LOD_GLSL

#ifndef RANDOM_GLSL
#define RANDOM_GLSL

layout(set = 0, binding = 1) uniform texture2D t_noise;
layout(set = 0, binding = 2) uniform sampler s_noise;

float hash(vec4 p) {
    p = fract(p * 0.3183099 + 0.1) - fract(p + 23.22121);
    p *= 17.0;
    return (fract(p.x * p.y * (1.0 - p.z) * p.w * (p.x + p.y + p.z + p.w)) - 0.5) * 2.0;
}

#define M1 2047667443U
#define M2 3883706873U
#define M3 3961281721U

float hash_one(uint q) {
    uint n = ((M3 * q) ^ M2) * M1;

    return float(n) * (1.0 / float(0xffffffffU));
}

float hash_two(uvec2 q) {
    q *= uvec2(M1, M2);
    uint n = q.x ^ q.y;
    n = n * (n ^ (n >> 15));
    return float(n) * (1.0 / float(0xffffffffU));
}

vec3 hash_two_3(uvec2 q) {
    q *= uvec2(M1, M2);
    uvec3 n = uvec3(q.x ^ q.y ^ uvec3(M1, M2, M3));
    n = n * (n ^ (n >> 15));
    return vec3(n) * (1.0 / vec3(0xffffffffU));
}

float hash_three(uvec3 q) {
    q *= uvec3(M1, M2, M3);
    uint n = q.x ^ q.y ^ q.z;
    n = n * (n ^ (n >> 15));
    return float(n) * (1.0 / float(0xffffffffU));
}

float hash_fast(uvec3 q) {
    q *= uvec3(M1, M2, M3);

    uint n = (q.x ^ q.y ^ q.z) * M1;

    return float(n) * (1.0 / float(0xffffffffU));
}

// 2D, but using shifted 2D textures
float noise_2d(vec2 pos) {
    return textureLod(sampler2D(t_noise, s_noise), pos, 0.0).x;
}

// 3D, but using shifted 2D textures
float noise_3d(vec3 pos) {
    pos.z *= 15.0;
    uint z = uint(trunc(pos.z));
    vec2 offs0 = vec2(hash_one(z), hash_one(z + 73u));
    vec2 offs1 = vec2(hash_one(z + 1u), hash_one(z + 1u + 73u));
    return mix(textureLod(sampler2D(t_noise, s_noise), pos.xy + offs0, 0.0).x, textureLod(sampler2D(t_noise, s_noise), pos.xy + offs1, 0.0).x, fract(pos.z));
}

// 3D version of `snoise`
float snoise3(in vec3 x) {
    uvec3 p = uvec3(floor(x) + 10000.0);
    vec3 f = fract(x);
    //f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(hash_fast(p + uvec3(0, 0, 0)), hash_fast(p + uvec3(1, 0, 0)), f.x),
            mix(hash_fast(p + uvec3(0, 1, 0)), hash_fast(p + uvec3(1, 1, 0)), f.x),
            f.y),
        mix(
            mix(hash_fast(p + uvec3(0, 0, 1)), hash_fast(p + uvec3(1, 0, 1)), f.x),
            mix(hash_fast(p + uvec3(0, 1, 1)), hash_fast(p + uvec3(1, 1, 1)), f.x),
            f.y),
        f.z);
}

// 4D noise
float snoise(in vec4 x) {
    vec4 p = floor(x);
    vec4 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(
                mix(hash(p + vec4(0, 0, 0, 0)), hash(p + vec4(1, 0, 0, 0)), f.x),
                mix(hash(p + vec4(0, 1, 0, 0)), hash(p + vec4(1, 1, 0, 0)), f.x),
                f.y),
            mix(
                mix(hash(p + vec4(0, 0, 1, 0)), hash(p + vec4(1, 0, 1, 0)), f.x),
                mix(hash(p + vec4(0, 1, 1, 0)), hash(p + vec4(1, 1, 1, 0)), f.x),
                f.y),
            f.z),
        mix(
            mix(
                mix(hash(p + vec4(0, 0, 0, 1)), hash(p + vec4(1, 0, 0, 1)), f.x),
                mix(hash(p + vec4(0, 1, 0, 1)), hash(p + vec4(1, 1, 0, 1)), f.x),
                f.y),
            mix(
                mix(hash(p + vec4(0, 0, 1, 1)), hash(p + vec4(1, 0, 1, 1)), f.x),
                mix(hash(p + vec4(0, 1, 1, 1)), hash(p + vec4(1, 1, 1, 1)), f.x),
                f.y),
            f.z),
        f.w);
}

vec3 rand_perm_3(vec3 pos) {
    return abs(sin(pos * vec3(1473.7 * pos.z + 472.3, 8891.1 * pos.x + 723.1, 3813.3 * pos.y + 982.5)));
}

vec4 rand_perm_4(vec4 pos) {
    return sin(473.3 * pos * vec4(317.3 * pos.w + 917.7, 1473.7 * pos.z + 472.3, 8891.1 * pos.x + 723.1, 3813.3 * pos.y + 982.5) / pos.yxwz);
}

vec3 smooth_rand(vec3 pos, float lerp_axis) {
    return vec3(snoise(vec4(pos, lerp_axis)), snoise(vec4(pos + 400.0, lerp_axis)), snoise(vec4(pos + 1000.0, lerp_axis)));
}

// Transform normal distribution to triangle distribution.
float norm2tri(float n) {
   // TODO: compare perf with adding two normal noise distributions
   bool flip = n > 0.5;
   n = flip ? 1.0 - n : n;
   n = sqrt(n / 2.0);
   n = flip ? 1.0 - n : n;
   return n;
}

// Caustics, ported and modified from https://www.shadertoy.com/view/3tlfR7, originally David Hoskins.
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License: https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode.
// Modifying these three functions mean that you agree to release your changes under the above license, *not* under GPL 3 as with the rest of the project.

float hashvec2(vec2 p) {return fract(sin(p.x * 1e2 + p.y) * 1e5 + sin(p.y * 1e3) * 1e3 + sin(p.x * 735. + p.y * 11.1) * 1.5e2); }

float n12(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f *= f * (3.-2.*f);
    return mix(
        mix(hashvec2(i+vec2(0.,0.)),hashvec2(i+vec2(1.,0.)),f.x),
        mix(hashvec2(i+vec2(0.,1.)),hashvec2(i+vec2(1.,1.)),f.x),
        f.y
    );
}

float caustics(vec2 p, float t) {
    vec3 k = vec3(p,t);
    float l;
    mat3 m = mat3(-2.,-1.,2.,3.,-2.,1.,1.,2.,2.);
    float n = n12(p);
    k = k*m*.5;
    l = length(.5 - fract(k+n));
    k = k*m*.4;
    l = min(l, length(.5-fract(k+n)));
    k = k*m*.3;
    l = min(l, length(.5-fract(k+n)));
    return pow(l,3.)*5.5;
}

#ifdef EXPERIMENTAL_DISCARDTRANSPARENCY
bool dither(vec2 frag_coord, float a, uint id) {
    if (a < 1.0 / 17.0) {
        return true;
    }
    if (a > 16.0 / 17.0) {
        return false;
    }

    // Use the id to try to discard different pixels from different objects, causing
    // them to be visible behind eachother.
    float r0 = floor(hash_one(id) * 16.0);
    vec2 r1 = vec2(floor(r0 * 0.25), mod(r0, 4.0));

    // We sample the bayer multiple times to have a smoother gradient of dithering.
    // This could be achieved by having a larger bayer matrix, but would then have
    // to define a larger one and not sure it would be much more efficient.
    uvec2 pos0 = uvec2(frag_coord + r1) % 4;
    uvec2 pos1 = uvec2(frag_coord / 4.0 + r1) % 4;
    uvec2 pos2 = uvec2(frag_coord / 16.0 + r1) % 4;

    mat4 bayer = mat4(
        16.0, 4.0, 13.0, 1.0,
        8.0, 12.0, 5.0, 9.0,
        14.0, 2.0, 15.0, 3.0,
        6.0, 10.0, 7.0, 11.0
    );
    mat4 bayer0 = bayer / 17.0;
    mat4 bayer1 = bayer / (17.0 * 17.0);
    mat4 bayer2 = bayer / (17.0 * 17.0 * 17.0);

    return a < bayer0[pos0.x][pos0.y] + bayer1[pos1.x][pos1.y] + bayer2[pos2.x][pos2.y];
}
#endif

#endif

#ifndef SKY_GLSL
#define SKY_GLSL

#ifndef RANDOM_GLSL
#define RANDOM_GLSL

layout(set = 0, binding = 1) uniform texture2D t_noise;
layout(set = 0, binding = 2) uniform sampler s_noise;

float hash(vec4 p) {
    p = fract(p * 0.3183099 + 0.1) - fract(p + 23.22121);
    p *= 17.0;
    return (fract(p.x * p.y * (1.0 - p.z) * p.w * (p.x + p.y + p.z + p.w)) - 0.5) * 2.0;
}

#define M1 2047667443U
#define M2 3883706873U
#define M3 3961281721U

float hash_one(uint q) {
    uint n = ((M3 * q) ^ M2) * M1;

    return float(n) * (1.0 / float(0xffffffffU));
}

float hash_two(uvec2 q) {
    q *= uvec2(M1, M2);
    uint n = q.x ^ q.y;
    n = n * (n ^ (n >> 15));
    return float(n) * (1.0 / float(0xffffffffU));
}

vec3 hash_two_3(uvec2 q) {
    q *= uvec2(M1, M2);
    uvec3 n = uvec3(q.x ^ q.y ^ uvec3(M1, M2, M3));
    n = n * (n ^ (n >> 15));
    return vec3(n) * (1.0 / vec3(0xffffffffU));
}

float hash_three(uvec3 q) {
    q *= uvec3(M1, M2, M3);
    uint n = q.x ^ q.y ^ q.z;
    n = n * (n ^ (n >> 15));
    return float(n) * (1.0 / float(0xffffffffU));
}

float hash_fast(uvec3 q) {
    q *= uvec3(M1, M2, M3);

    uint n = (q.x ^ q.y ^ q.z) * M1;

    return float(n) * (1.0 / float(0xffffffffU));
}

// 2D, but using shifted 2D textures
float noise_2d(vec2 pos) {
    return textureLod(sampler2D(t_noise, s_noise), pos, 0.0).x;
}

// 3D, but using shifted 2D textures
float noise_3d(vec3 pos) {
    pos.z *= 15.0;
    uint z = uint(trunc(pos.z));
    vec2 offs0 = vec2(hash_one(z), hash_one(z + 73u));
    vec2 offs1 = vec2(hash_one(z + 1u), hash_one(z + 1u + 73u));
    return mix(textureLod(sampler2D(t_noise, s_noise), pos.xy + offs0, 0.0).x, textureLod(sampler2D(t_noise, s_noise), pos.xy + offs1, 0.0).x, fract(pos.z));
}

// 3D version of `snoise`
float snoise3(in vec3 x) {
    uvec3 p = uvec3(floor(x) + 10000.0);
    vec3 f = fract(x);
    //f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(hash_fast(p + uvec3(0, 0, 0)), hash_fast(p + uvec3(1, 0, 0)), f.x),
            mix(hash_fast(p + uvec3(0, 1, 0)), hash_fast(p + uvec3(1, 1, 0)), f.x),
            f.y),
        mix(
            mix(hash_fast(p + uvec3(0, 0, 1)), hash_fast(p + uvec3(1, 0, 1)), f.x),
            mix(hash_fast(p + uvec3(0, 1, 1)), hash_fast(p + uvec3(1, 1, 1)), f.x),
            f.y),
        f.z);
}

// 4D noise
float snoise(in vec4 x) {
    vec4 p = floor(x);
    vec4 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(
                mix(hash(p + vec4(0, 0, 0, 0)), hash(p + vec4(1, 0, 0, 0)), f.x),
                mix(hash(p + vec4(0, 1, 0, 0)), hash(p + vec4(1, 1, 0, 0)), f.x),
                f.y),
            mix(
                mix(hash(p + vec4(0, 0, 1, 0)), hash(p + vec4(1, 0, 1, 0)), f.x),
                mix(hash(p + vec4(0, 1, 1, 0)), hash(p + vec4(1, 1, 1, 0)), f.x),
                f.y),
            f.z),
        mix(
            mix(
                mix(hash(p + vec4(0, 0, 0, 1)), hash(p + vec4(1, 0, 0, 1)), f.x),
                mix(hash(p + vec4(0, 1, 0, 1)), hash(p + vec4(1, 1, 0, 1)), f.x),
                f.y),
            mix(
                mix(hash(p + vec4(0, 0, 1, 1)), hash(p + vec4(1, 0, 1, 1)), f.x),
                mix(hash(p + vec4(0, 1, 1, 1)), hash(p + vec4(1, 1, 1, 1)), f.x),
                f.y),
            f.z),
        f.w);
}

vec3 rand_perm_3(vec3 pos) {
    return abs(sin(pos * vec3(1473.7 * pos.z + 472.3, 8891.1 * pos.x + 723.1, 3813.3 * pos.y + 982.5)));
}

vec4 rand_perm_4(vec4 pos) {
    return sin(473.3 * pos * vec4(317.3 * pos.w + 917.7, 1473.7 * pos.z + 472.3, 8891.1 * pos.x + 723.1, 3813.3 * pos.y + 982.5) / pos.yxwz);
}

vec3 smooth_rand(vec3 pos, float lerp_axis) {
    return vec3(snoise(vec4(pos, lerp_axis)), snoise(vec4(pos + 400.0, lerp_axis)), snoise(vec4(pos + 1000.0, lerp_axis)));
}

// Transform normal distribution to triangle distribution.
float norm2tri(float n) {
   // TODO: compare perf with adding two normal noise distributions
   bool flip = n > 0.5;
   n = flip ? 1.0 - n : n;
   n = sqrt(n / 2.0);
   n = flip ? 1.0 - n : n;
   return n;
}

// Caustics, ported and modified from https://www.shadertoy.com/view/3tlfR7, originally David Hoskins.
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License: https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode.
// Modifying these three functions mean that you agree to release your changes under the above license, *not* under GPL 3 as with the rest of the project.

float hashvec2(vec2 p) {return fract(sin(p.x * 1e2 + p.y) * 1e5 + sin(p.y * 1e3) * 1e3 + sin(p.x * 735. + p.y * 11.1) * 1.5e2); }

float n12(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f *= f * (3.-2.*f);
    return mix(
        mix(hashvec2(i+vec2(0.,0.)),hashvec2(i+vec2(1.,0.)),f.x),
        mix(hashvec2(i+vec2(0.,1.)),hashvec2(i+vec2(1.,1.)),f.x),
        f.y
    );
}

float caustics(vec2 p, float t) {
    vec3 k = vec3(p,t);
    float l;
    mat3 m = mat3(-2.,-1.,2.,3.,-2.,1.,1.,2.,2.);
    float n = n12(p);
    k = k*m*.5;
    l = length(.5 - fract(k+n));
    k = k*m*.4;
    l = min(l, length(.5-fract(k+n)));
    k = k*m*.3;
    l = min(l, length(.5-fract(k+n)));
    return pow(l,3.)*5.5;
}

#ifdef EXPERIMENTAL_DISCARDTRANSPARENCY
bool dither(vec2 frag_coord, float a, uint id) {
    if (a < 1.0 / 17.0) {
        return true;
    }
    if (a > 16.0 / 17.0) {
        return false;
    }

    // Use the id to try to discard different pixels from different objects, causing
    // them to be visible behind eachother.
    float r0 = floor(hash_one(id) * 16.0);
    vec2 r1 = vec2(floor(r0 * 0.25), mod(r0, 4.0));

    // We sample the bayer multiple times to have a smoother gradient of dithering.
    // This could be achieved by having a larger bayer matrix, but would then have
    // to define a larger one and not sure it would be much more efficient.
    uvec2 pos0 = uvec2(frag_coord + r1) % 4;
    uvec2 pos1 = uvec2(frag_coord / 4.0 + r1) % 4;
    uvec2 pos2 = uvec2(frag_coord / 16.0 + r1) % 4;

    mat4 bayer = mat4(
        16.0, 4.0, 13.0, 1.0,
        8.0, 12.0, 5.0, 9.0,
        14.0, 2.0, 15.0, 3.0,
        6.0, 10.0, 7.0, 11.0
    );
    mat4 bayer0 = bayer / 17.0;
    mat4 bayer1 = bayer / (17.0 * 17.0);
    mat4 bayer2 = bayer / (17.0 * 17.0 * 17.0);

    return a < bayer0[pos0.x][pos0.y] + bayer1[pos1.x][pos1.y] + bayer2[pos2.x][pos2.y];
}
#endif

#endif

#ifndef SRGB_GLSL
#define SRGB_GLSL

#extension GL_EXT_samplerless_texture_functions : enable

// Linear RGB, attenuation coefficients for water at roughly R, G, B wavelengths.
// See https://en.wikipedia.org/wiki/Electromagnetic_absorption_by_water
const vec3 MU_WATER = vec3(0.6, 0.04, 0.01);

//https://gamedev.stackexchange.com/questions/92015/optimized-linear-to-srgb-glsl
vec3 srgb_to_linear(vec3 srgb) {
    bvec3 cutoff = lessThan(srgb, vec3(0.04045));
    vec3 higher = pow((srgb + vec3(0.055))/vec3(1.055), vec3(2.4));
    vec3 lower = srgb/vec3(12.92);

    return mix(higher, lower, cutoff);
}

vec3 linear_to_srgb(vec3 col) {
    vec3 s1 = vec3(sqrt(col.r), sqrt(col.g), sqrt(col.b));
    vec3 s2 = vec3(sqrt(s1.r), sqrt(s1.g), sqrt(s1.b));
    vec3 s3 = vec3(sqrt(s2.r), sqrt(s2.g), sqrt(s2.b));
    return vec3(
            mix(11.500726 * col.r, (0.585122381 * s1.r + 0.783140355 * s2.r - 0.368262736 * s3.r), clamp((col.r - 0.0060) * 10000.0, 0.0, 1.0)),
            mix(11.500726 * col.g, (0.585122381 * s1.g + 0.783140355 * s2.g - 0.368262736 * s3.g), clamp((col.g - 0.0060) * 10000.0, 0.0, 1.0)),
            mix(11.500726 * col.b, (0.585122381 * s1.b + 0.783140355 * s2.b - 0.368262736 * s3.b), clamp((col.b - 0.0060) * 10000.0, 0.0, 1.0))
    );
}

float pow5(float x) {
    float x2 = x * x;
    return x2 * x2 * x;
}

vec4 pow5(vec4 x) {
    vec4 x2 = x * x;
    return x2 * x2 * x;
}

// Fresnel angle for perfectly specular dialectric materials.

// Schlick approximation
vec3 schlick_fresnel(vec3 Rs, float cosTheta) {
    return Rs + pow5(1.0 - cosTheta) * (1.0 - Rs);
}

// Beckmann Distribution
float BeckmannDistribution_D(float NdotH, float alpha) {
    const float PI = 3.1415926535897932384626433832795;
    float NdotH2 = NdotH * NdotH;
    float NdotH2m2 = NdotH2 * alpha * alpha;
    float k_spec = exp((NdotH2 - 1.0) / NdotH2m2) / (PI * NdotH2m2 * NdotH2);
    return mix(k_spec, 0.0, NdotH == 0.0);
}

// Voxel Distribution
float BeckmannDistribution_D_Voxel(vec3 wh, vec3 voxel_norm, float alpha) {
    vec3 sides = sign(voxel_norm);
    
    vec3 NdotH = wh * sides;

    const float PI = 3.1415926535897932384626433832795;
    vec3 NdotH2 = NdotH * NdotH;
    vec3 NdotH2m2 = NdotH2 * alpha * alpha;
    vec3 k_spec = exp((NdotH2 - 1.0) / NdotH2m2) / (PI * NdotH2m2 * NdotH2);
    return dot(mix(k_spec, vec3(0.0), equal(NdotH, vec3(0.0))), abs(voxel_norm));
}

float TrowbridgeReitzDistribution_D_Voxel(vec3 wh, vec3 voxel_norm, float alpha) {
    vec3 sides = sign(voxel_norm);

    vec3 NdotH = wh * sides;

    const float PI = 3.1415926535897932384626433832795;
    vec3 NdotH2 = NdotH * NdotH;
    vec3 NdotH2m2 = NdotH2 * alpha * alpha;
    vec3 e = (1.0 - NdotH2) / NdotH2m2;
    vec3 k_spec = 1.0 / (PI * NdotH2m2 * NdotH2 * (1.0 + e) * (1.0 + e));
    return dot(mix(k_spec, vec3(0.0), equal(NdotH, vec3(0.0))), abs(voxel_norm));
}

float BeckmannDistribution_Lambda(vec3 norm, vec3 dir, float alpha) {
    float CosTheta = dot(norm, dir);
    float SinTheta = sqrt(1.0 - CosTheta * CosTheta);
    float TanTheta = SinTheta / CosTheta;
    float absTanTheta = abs(TanTheta);
    float a = 1.0 / (alpha * absTanTheta);
    
    return mix(max(0.0, (1.0 - 1.259 * a + 0.396 * a * a) / (3.535 * a + 2.181 * a * a)), 0.0, isinf(absTanTheta) || a >= 1.6);
}

float BeckmannDistribution_G(vec3 norm, vec3 dir, vec3 light_dir, float alpha) {
    return 1.0 / (1.0 + BeckmannDistribution_Lambda(norm, dir, alpha) + BeckmannDistribution_Lambda(norm, -light_dir, alpha));
}

// Fresnel blending
//
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Microfacet_Models.html#fragment-MicrofacetDistributionPublicMethods-2
// and
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Fresnel_Incidence_Effects.html
vec3 FresnelBlend_f(vec3 norm, vec3 dir, vec3 light_dir, vec3 R_d, vec3 R_s, float alpha) {
    const float PI = 3.1415926535897932384626433832795;
    alpha = alpha * sqrt(2.0);
    float cos_wi = dot(-light_dir, norm);
    float cos_wo = dot(dir, norm);

    vec3 diffuse = (28.0 / (23.0 * PI)) * R_d *
        (1.0 - R_s) *
        (1.0 - pow5(1.0 - 0.5 * abs(cos_wi))) *
        (1.0 - pow5(1.0 - 0.5 * abs(cos_wo)));
    vec3 wh = -light_dir + dir;
#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    bool is_blocked = cos_wi == 0.0 || cos_wo == 0.0;
#else
    bool is_blocked = cos_wi <= 0.0 || cos_wo <= 0.0;
#endif
    if (is_blocked) {
        return vec3(0.0);
    }
    wh = normalize(wh);
    float dot_wi_wh = dot(-light_dir, wh);
    vec3 specular = dot(norm, dir) > 0.0 ? vec3(0.0) : (BeckmannDistribution_D(dot(wh, norm), alpha) /
        (4.0 * abs(dot_wi_wh) *
        max(abs(cos_wi), abs(cos_wo))) *
        schlick_fresnel(R_s, dot_wi_wh));
    return mix(diffuse + specular, vec3(0.0), bvec3(all(equal(light_dir, dir))));
}

// Fresnel blending
//
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Microfacet_Models.html#fragment-MicrofacetDistributionPublicMethods-2
// and
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Fresnel_Incidence_Effects.html
vec3 FresnelBlend_Voxel_f(vec3 norm, vec3 dir, vec3 light_dir, vec3 R_d, vec3 R_s, float alpha, vec3 voxel_norm, float dist) {
    const float PI = 3.1415926535897932384626433832795;
    alpha = alpha * sqrt(2.0);
    float cos_wi = dot(-light_dir, norm);
    float cos_wo = dot(dir, norm);

#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    vec4 AbsNdotL = abs(vec4(light_dir, cos_wi));
    vec4 AbsNdotV = abs(vec4(dir, cos_wo));
#else
    vec3 sides = sign(voxel_norm);
    vec4 AbsNdotL = vec4(max(-light_dir * sides, 0.0), abs(cos_wi));
    vec4 AbsNdotV = vec4(max(dir * sides, 0.0), abs(cos_wo));
#endif

    vec4 diffuse_factor = (1.0 - pow5(1.0 - 0.5 * AbsNdotL)) * (1.0 - pow5(1.0 - 0.5 * AbsNdotV));

    vec3 diffuse = (28.0 / (23.0 * PI)) * R_d * (1.0 - R_s) * dot(diffuse_factor, /*R_r * */vec4(abs(norm) * (1.0 - dist), dist));

    vec3 wh = -light_dir + dir;
#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    bool is_blocked = cos_wi == 0.0 || cos_wo == 0.0;
#else
    bool is_blocked = cos_wi <= 0.0 || cos_wo <= 0.0;
#endif
    if (is_blocked) {
        return vec3(0.0);
    }
    wh = normalize(wh);
    float dot_wi_wh = dot(-light_dir, wh);
    float distr = BeckmannDistribution_D_Voxel(wh, voxel_norm, alpha);
    vec3 specular = distr /
        (4.0 * abs(dot_wi_wh) *
        max(abs(cos_wi), abs(cos_wo))) *
        schlick_fresnel(R_s, dot_wi_wh);
    return mix(diffuse + specular, vec3(0.0), bvec3(all(equal(light_dir, dir))));
}

// Phong reflection.
//
// Note: norm, dir, light_dir must all be normalizd.
vec3 light_reflection_factor2(vec3 norm, vec3 dir, vec3 light_dir, vec3 k_d, vec3 k_s, float alpha) {
    // TODO: These are supposed to be the differential changes in the point location p, in tangent space.
    // That is, assuming we can parameterize a 2D surface by some function p : R² → R³, mapping from
    // points in a plane to 3D points on the surface, we can define
    // ∂p(u,v)/∂u and ∂p(u,v)/∂v representing the changes in the pont location as we move along these
    // coordinates.
    //
    // Then we can define the normal at a point, n(u,v) = ∂p(u,v)/∂u × ∂p(u,v)/∂v.
    //
    // Additionally, we can define the change in *normals* at each point using the
    // Weingarten equations (see http://www.pbr-book.org/3ed-2018/Shapes/Spheres.html):
    //
    // ∂n/∂u = (fF - eG) / (EG - F²) ∂p/∂u + (eF - fE) / (EG - F²) ∂p/∂v
    // ∂n/∂v = (gF - fG) / (EG - F²) ∂p/∂u + (fF - gE) / (EG - F²) ∂p/∂v
    //
    // where
    //
    // E = |∂p/∂u ⋅ ∂p/∂u|
    // F = ∂p/∂u ⋅ ∂p/∂u
    // G = |∂p/∂v ⋅ ∂p/∂v|
    //
    // and
    //
    // e = n ⋅ ∂²p/∂u²
    // f = n ⋅ ∂²p/(∂u∂v)
    // g = n ⋅ ∂²p/∂v²
    //
    // For planes (see http://www.pbr-book.org/3ed-2018/Shapes/Triangle_Meshes.html) we have
    // e = f = g = 0 (since the plane has no curvature of any sort) so we get:
    //
    // ∂n/∂u = (0, 0, 0)
    // ∂n/∂v = (0, 0, 0)
    //
    // To find ∂p/∂u and ∂p/∂v, we first write p and u parametrically:
    //    p(u, v) = p0 + u ∂p/∂u + v ∂p/∂v
    //
    // ( u₀ - u₂    v₀ - v₂
    //   u₁ - u₂    v₁ - v₂ )
    //
    // Basis: plane norm = norm = (0, 0, 1), x vector = any orthgonal vector on the plane.
    // vec3 w_i =
    // vec3 w_i = vec3(view_mat * vec4(-light_dir, 1.0));
    // vec3 w_o = vec3(view_mat * vec4(light_dir, 1.0));
    return FresnelBlend_f(norm, dir, light_dir, k_d, k_s, alpha);
}

vec3 light_reflection_factor(vec3 norm, vec3 dir, vec3 light_dir, vec3 k_d, vec3 k_s, float alpha, vec3 voxel_norm, float voxel_lighting) {
#if (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_LAMBERTIAN)
    const float PI = 3.141592;
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    vec4 AbsNdotL = abs(vec4(light_dir, dot(norm, light_dir)));
        #else
    vec3 sides = sign(voxel_norm);
    vec4 AbsNdotL = max(vec4(-light_dir * sides, dot(norm, -light_dir)), 0.0);
        #endif
    float diffuse = dot(AbsNdotL, vec4(abs(voxel_norm) * (1.0 - voxel_lighting), voxel_lighting));
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    float diffuse = abs(dot(norm, light_dir));
        #else
    float diffuse = max(dot(norm, -light_dir), 0.0);
        #endif
    #endif
    return k_d / PI * diffuse;
#elif (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_BLINN_PHONG)
    const float PI = 3.141592;
    alpha = alpha * sqrt(2.0);
    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    float ndotL = abs(dot(norm, light_dir));
    #else
    float ndotL = max(dot(norm, -light_dir), 0.0);
    #endif

    if (ndotL > 0.0) {
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        vec4 AbsNdotL = abs(vec4(light_dir, ndotL));
        #else
        vec3 sides = sign(voxel_norm);
        vec4 AbsNdotL = max(vec4(-light_dir * sides, ndotL), 0.0);
        #endif
        float diffuse = dot(AbsNdotL, vec4(abs(voxel_norm) * (1.0 - voxel_lighting), voxel_lighting));
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        float diffuse = ndotL;
    #endif
        vec3 H = normalize(-light_dir + dir);

    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        float NdotH = abs(dot(norm, H));
    #else
        float NdotH = max(dot(norm, H), 0.0);
    #endif
        return (1.0 - k_s) / PI * k_d * diffuse + k_s * pow(NdotH, alpha/* * 4.0*/);
    }

    return vec3(0.0);
#elif (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_ASHIKHMIN)
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        return FresnelBlend_Voxel_f(norm, dir, light_dir, k_d, k_s, alpha, voxel_norm, voxel_lighting);
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        return FresnelBlend_f(norm, dir, light_dir, k_d, k_s, alpha);
    #endif
#endif
}

float rel_luminance(vec3 rgb)
{
    // https://en.wikipedia.org/wiki/Relative_luminance
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    return dot(rgb, W);
}

// From https://discourse.vvvv.org/t/infinite-ray-intersects-with-infinite-plane/10537
// out of laziness.
bool IntersectRayPlane(vec3 rayOrigin, vec3 rayDirection, vec3 posOnPlane, vec3 planeNormal, inout vec3 intersectionPoint)
{
  float rDotn = dot(rayDirection, planeNormal);

  //parallel to plane or pointing away from plane?
  if (rDotn < 0.0000001 )
    return false;

  float s = dot(planeNormal, (posOnPlane - rayOrigin)) / rDotn;

  intersectionPoint = rayOrigin + s * rayDirection;

  return true;
}

// Compute uniform attenuation due to beam passing through a substance that fills an area below a horizontal plane
// (e.g. in most cases, water below the water surface depth) using the simplest form of the Beer-Lambert law
// (https://en.wikipedia.org/wiki/Beer%E2%80%93Lambert_law):
//
// I(z) = I₀ e^(-μz)
//
// We compute this value, except for the initial intensity which may be multiplied out later.
//
// wpos is the position of the point being hit.
// ray_dir is the reversed direction of the ray (going "out" of the point being hit).
// mu is the attenuation coefficient for R, G, and B wavelenghts.
// surface_alt is the estimated altitude of the horizontal surface separating the substance from air.
// defaultpos is the position to use in computing the distance along material at this point if there was a failure.
//
// Ideally, defaultpos is set so we can avoid branching on error.
vec3 compute_attenuation(vec3 wpos, vec3 ray_dir, vec3 mu, float surface_alt, vec3 defaultpos) {
#if (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_IMPORTANCE)
    return vec3(1.0);
#elif (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_RADIANCE)
    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        return vec3(1.0);
    #else
    ray_dir = faceforward(ray_dir, vec3(0.0, 0.0, -1.0), ray_dir);
    vec3 surface_dir = surface_alt < wpos.z ? vec3(0.0, 0.0, -1.0) : vec3(0.0, 0.0, 1.0);
    bool _intersects_surface = IntersectRayPlane(wpos, ray_dir, vec3(0.0, 0.0, surface_alt), surface_dir, defaultpos);
    float depth = length(defaultpos - wpos);
    return exp(-mu * depth);
    #endif
#endif
}

// Same as compute_attenuation but since both point are known, set a maximum to make sure we don't exceed the length
// from the default point.
vec3 compute_attenuation_point(vec3 wpos, vec3 ray_dir, vec3 mu, float surface_alt, vec3 defaultpos) {
#if (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_IMPORTANCE)
    return pow(1.0 - mu, vec3(3));
#elif (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_RADIANCE)
    return vec3(1.0);
#endif
}

vec3 greedy_extract_col_light_attr(texture2D t_col_light, sampler s_col_light, vec2 f_uv_pos, out float f_light, out float f_glow, out float f_ao, out uint f_attr, out float f_sky_exposure) {
    // TODO: Figure out how to use `texture` and modulation to avoid needing to do manual filtering
    // TODO: Use `texture` instead

    uvec4 tex_00 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(0, 0), 0) * 255.0);
    uvec4 tex_10 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(1, 0), 0) * 255.0);
    uvec4 tex_01 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(0, 1), 0) * 255.0);
    uvec4 tex_11 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(1, 1), 0) * 255.0);
    vec3 light_00 = vec3(tex_00.rg >> 3u, tex_00.a & 1u);
    vec3 light_10 = vec3(tex_10.rg >> 3u, tex_10.a & 1u);
    vec3 light_01 = vec3(tex_01.rg >> 3u, tex_01.a & 1u);
    vec3 light_11 = vec3(tex_11.rg >> 3u, tex_11.a & 1u);
    vec3 light_0 = mix(light_00, light_01, fract(f_uv_pos.y));
    vec3 light_1 = mix(light_10, light_11, fract(f_uv_pos.y));
    vec3 light = mix(light_0, light_1, fract(f_uv_pos.x));

    vec3 f_col = vec3(
        float(((tex_00.r & 0x7u) << 1u) | (tex_00.b & 0xF0u)),
        float(tex_00.a & 0xFEu),
        float(((tex_00.g & 0x7u) << 1u) | ((tex_00.b & 0x0Fu) << 4u))
    ) / 255.0;

    f_ao = light.z;
    f_light = light.x / 31.0;
    f_sky_exposure = light.x / 31.0 + (1.0 - f_ao) * 0.5;
    f_glow = light.y / 31.0;
    f_attr = tex_00.g >> 3u;
    return srgb_to_linear(f_col);
}

vec3 greedy_extract_col_light_kind_terrain(
    texture2D t_col_light, sampler s_col_light,
    utexture2D t_kind,
    vec2 f_uv_pos,
    out float f_light, out float f_glow, out float f_ao, out float f_sky_exposure, out uint f_kind
) {
    uint _f_attr;
    f_kind = uint(texelFetch(t_kind, ivec2(f_uv_pos), 0).r);
    return greedy_extract_col_light_attr(t_col_light, s_col_light, f_uv_pos, f_light, f_glow, f_ao, _f_attr, f_sky_exposure);
}

vec3 greedy_extract_col_light_figure(texture2D t_col_light, sampler s_col_light, vec2 f_uv_pos, out float f_light, out uint f_attr) {
    float _f_sky_exposure, _f_light, _f_glow, _f_ao;
    return greedy_extract_col_light_attr(t_col_light, s_col_light, f_uv_pos, f_light, _f_glow, _f_ao, f_attr, _f_sky_exposure);
}

#endif

#ifndef SHADOWS_GLSL
#define SHADOWS_GLSL

#ifdef HAS_SHADOW_MAPS
    #if (SHADOW_MODE == SHADOW_MODE_MAP)
        layout (std140, set = 0, binding = 9)
        uniform u_light_shadows {
            mat4 shadowMatrices;
            mat4 texture_mat;
        };
        
        // Use with sampler2DShadow
        layout(set = 1, binding = 2)
        uniform texture2D t_directed_shadow_maps;
        layout(set = 1, binding = 3)
        uniform samplerShadow s_directed_shadow_maps;
        
        // Use with samplerCubeShadow
        layout(set = 1, binding = 0)
        uniform textureCube t_point_shadow_maps;
        layout(set = 1, binding = 1)
        uniform samplerShadow s_point_shadow_maps;
        
        float VectorToDepth(vec3 Vec) {
            vec3 AbsVec = abs(Vec);
            float LocalZcomp = max(AbsVec.x, max(AbsVec.y, AbsVec.z));
        
            float NormZComp = shadow_proj_factors.x - shadow_proj_factors.y / LocalZcomp;
            return NormZComp;
        }
        
        const vec3 sampleOffsetDirections[20] = vec3[](
            vec3( 1,  1,  1), vec3( 1, -1,  1), vec3(-1, -1,  1), vec3(-1,  1,  1),
            vec3( 1,  1, -1), vec3( 1, -1, -1), vec3(-1, -1, -1), vec3(-1,  1, -1),
            vec3( 1,  1,  0), vec3( 1, -1,  0), vec3(-1, -1,  0), vec3(-1,  1,  0),
            vec3( 1,  0,  1), vec3(-1,  0,  1), vec3( 1,  0, -1), vec3(-1,  0, -1),
            vec3( 0,  1,  1), vec3( 0, -1,  1), vec3( 0, -1, -1), vec3( 0,  1, -1)
        );
        
        float ShadowCalculationPoint(uint lightIndex, vec3 fragToLight, vec3 fragNorm, vec3 fragPos) {
            if (lightIndex != 0u) {
                return 1.0;
            };
        
            float currentDepth = VectorToDepth(fragToLight);
        
            return textureGrad(samplerCubeShadow(t_point_shadow_maps, s_point_shadow_maps), vec4(fragToLight, currentDepth), vec3(0), vec3(0));
        }
        
        float ShadowCalculationDirected(in vec3 fragPos) {
            // Don't try to calculate directed shadows if there are no directed light sources
            // Applies, for example, in the char select menu
            if (light_shadow_count.z < 1) { return 1.0; }
        
            float bias = 0.0;
            float diskRadius = 0.01;
            vec4 sun_pos = texture_mat * vec4(fragPos, 1.0);
            return textureProj(sampler2DShadow(t_directed_shadow_maps, s_directed_shadow_maps), sun_pos);
        }
    #elif (SHADOW_MODE == SHADOW_MODE_NONE || SHADOW_MODE == SHADOW_MODE_CHEAP)
        float ShadowCalculationPoint(uint lightIndex, vec3 fragToLight, vec3 fragNorm, vec3 fragPos) {
            return 1.0;
        }
    #endif
#else
    float ShadowCalculationPoint(uint lightIndex, vec3 fragToLight, vec3 fragNorm, vec3 fragPos) {
        return 1.0;
    }
#endif

#endif

#ifndef GLOBALS_GLSL
#define GLOBALS_GLSL

layout(std140, set = 0, binding = 0) uniform u_globals {
    mat4 view_mat;
    mat4 proj_mat;
    mat4 all_mat;
    vec4 cam_pos;
    vec4 focus_off;
    vec4 focus_pos;
    vec4 view_distance;
    // .x = time of day, repeats every day.
    // .y = a continuous value for what day it is. Repeats every `tick_overflow` for precisions sake.
    vec4 time_of_day;
    vec4 sun_dir;
    vec4 moon_dir;
    // .x = The `Time` resource, repeated every `tick_overflow`
    // .y = a floored (`Time` / `tick_overflow`)
    // .z = Time local to client, not synced between clients.
    vec4 tick;
    vec4 screen_res;
    uvec4 light_shadow_count;
    vec4 shadow_proj_factors;
    uvec4 medium;
    ivec4 select_pos;
    vec4 gamma_exposure;
    vec4 last_lightning;
    vec2 wind_vel;
    vec2 internal_res;
    float ambiance;
    // 0 - FirstPerson
    // 1 - ThirdPerson
    uint cam_mode;
    float sprite_render_distance;
    float u_rotation;
    float screen_fade;
};

float distance_divider = 2.0;
float shadow_dithering = 0.5;

float tick_overflow = 300000.0;

// Get a scaled time with an offset that loops at a period.
float tick_loop(float period, float scale, float offset) {
    float loop = tick_overflow * scale;
    float rem = mod(loop, period);
    float rest = rem * tick.y;

    return mod(rest + tick.x * scale + offset, period);
}

float tick_loop(float period) {
    return tick_loop(period, 1.0, 0.0);
}

vec3 tick_loop(float period, vec3 scale, vec3 offset) {
    vec3 loop = tick_overflow * scale;
    vec3 rem = mod(loop, period);
    vec3 rest = rem * tick.y;

    return mod(rest + tick.x * scale + offset, period);
}

// Only works if t happened within tick_overflow
float time_since(float t) {
    return tick.x < t ? (tick_overflow - t + tick.x) : (tick.x - t);
}

#endif


#ifndef RAIN_OCCLUSION_GLSL
#define RAIN_OCCLUSION_GLSL

// Use with sampler2DShadow
layout(set = 1, binding = 4)
uniform texture2D t_directed_occlusion_maps;
layout(set = 1, binding = 5)
uniform samplerShadow s_directed_occlusion_maps;

layout (std140, set = 0, binding = 14)
uniform u_rain_occlusion {
    mat4 rain_occlusion_matrices;
    mat4 rain_occlusion_texture_mat;
    mat4 rain_dir_mat;
    float integrated_rain_vel;
    float rain_density;
    vec2 occlusion_dummy; // Fix alignment.
};

float rain_occlusion_at(in vec3 fragPos)
{
    vec4 rain_pos = rain_occlusion_texture_mat * vec4(fragPos, 1.0);

    float visibility = textureProj(sampler2DShadow(t_directed_occlusion_maps, s_directed_occlusion_maps), rain_pos);

    return visibility;
}
#endif


// Information about an approximately directional light, like the sun or moon.
struct DirectionalLight {
    float shadow;
    // Fully blocks all light, including ambience
    float block;
};

const float PI = 3.141592653;

const vec3 SKY_DAWN_TOP = vec3(0.10, 0.1, 0.10);
const vec3 SKY_DAWN_MID = vec3(1.2, 0.3, 0.2);
const vec3 SKY_DAWN_BOT = vec3(0.0, 0.1, 0.23);
const vec3 DAWN_LIGHT   = vec3(5.0, 2.0, 1.15);
const vec3 SUN_HALO_DAWN = vec3(3.0, 0.5, 0.1);

const vec3 SKY_DAY_TOP = vec3(0.1, 0.5, 0.9);
const vec3 SKY_DAY_MID = vec3(0.18, 0.28, 0.6);
const vec3 SKY_DAY_BOT = vec3(0.1, 0.2, 0.3);
const vec3 DAY_LIGHT   = vec3(3.8, 3.0, 1.8);
const vec3 SUN_HALO_DAY = vec3(0.15, 0.15, 0.001);

const vec3 SKY_DUSK_TOP = vec3(1.06, 0.1, 0.20);
const vec3 SKY_DUSK_MID = vec3(2.5, 0.3, 0.1);
const vec3 SKY_DUSK_BOT = vec3(0.0, 0.1, 0.23);
const vec3 DUSK_LIGHT   = vec3(8.0, 1.5, 0.15);
const vec3 SUN_HALO_DUSK = vec3(3.0, 0.5, 0.05);

const vec3 SKY_NIGHT_TOP = vec3(0.001, 0.001, 0.0025);
const vec3 SKY_NIGHT_MID = vec3(0.001, 0.005, 0.02);
const vec3 SKY_NIGHT_BOT = vec3(0.002, 0.004, 0.004);
const vec3 NIGHT_LIGHT   = vec3(5.0, 0.75, 0.2);

// Linear RGB, scattering coefficients for atmosphere at roughly R, G, B wavelengths.
//
// See https://en.wikipedia.org/wiki/Diffuse_sky_radiation
const vec3 MU_SCATTER = vec3(0.05, 0.10, 0.23);

const float SUN_COLOR_FACTOR = 5.0;
const float MOON_COLOR_FACTOR = 5.0;

const float UNDERWATER_MIST_DIST = 100.0;

const float PERSISTENT_AMBIANCE = 1.0 / 32.0;

// Glow from static light sources
// Allowed to be > 1 due to HDR
const vec3 GLOW_COLOR = vec3(0.89, 0.95, 0.52);

// Calculate glow from static light sources, + some noise for flickering.
// TODO: Optionally disable the flickering for performance?
vec3 glow_light(vec3 pos) {
    #if (SHADOW_MODE <= SHADOW_MODE_NONE)
        return GLOW_COLOR;
    #else
        return GLOW_COLOR * (1.0 + (noise_3d(vec3(pos.xy * 0.005, tick.x * 0.5)) - 0.5) * 0.5);
    #endif
}

float cloud_avg_alt() { return view_distance.z + (view_distance.w - view_distance.z) * 1.25; }

const float wind_speed = 0.25;
vec2 wind_offset() { return vec2(time_of_day.y * wind_speed * (3600.0 * 24.0)); }

float cloud_scale() { return view_distance.z / 150.0; }

layout(set = 0, binding = 5) uniform texture2D t_alt;
layout(set = 0, binding = 6) uniform sampler s_alt;

// Transforms coordinate in the range 0..WORLD_SIZE to 0..1
vec2 wpos_to_uv(vec2 wpos) {
    // Want: (pixel + 0.5) / W
    vec2 texSize = textureSize(sampler2D(t_alt, s_alt), 0);
    vec2 uv_pos = (wpos + 16) / (32.0 * texSize);
    return vec2(uv_pos.x, uv_pos.y);
}

// Weather texture
layout(set = 0, binding = 12) uniform texture2D t_weather;
layout(set = 0, binding = 13) uniform sampler s_weather;

vec4 sample_weather(vec2 wpos) {
    return textureLod(sampler2D(t_weather, s_weather), wpos_to_uv(wpos), 0);
}

float cloud_tendency_at(vec2 wpos) {
    return sample_weather(wpos).r;
}

float rain_density_at(vec2 wpos) {
    return sample_weather(wpos).g;
}

float cloud_shadow(vec3 pos, vec3 light_dir) {
    #if (CLOUD_MODE <= CLOUD_MODE_MINIMAL)
        return 1.0;
    #else
        vec2 xy_offset = light_dir.xy * ((cloud_avg_alt() - pos.z) / -light_dir.z);

        // Fade out shadow if the sun angle is too steep (simulates a widening penumbra with distance)
        const vec2 FADE_RANGE = vec2(1500, 10000);
        float fade = 1.0 - clamp((length(xy_offset) - FADE_RANGE.x) / (FADE_RANGE.y - FADE_RANGE.x), 0, 1);
        float cloud = cloud_tendency_at(pos.xy + focus_off.xy - xy_offset);

        return clamp(1 - fade * cloud * 16.0, 0, 1);
    #endif
}

float magnetosphere() { return sin(time_of_day.y); }

vec3 magnetosphere_tint() {
    #if (CLOUD_MODE <= CLOUD_MODE_LOW)
        return vec3(1);
    #else
        float magnetosphere = magnetosphere();
        float magnetosphere2 = pow(magnetosphere, 2) * 2 - 1;
        float magnetosphere3 = pow(magnetosphere2, 2) * 2 - 1;
        vec3 magnetosphere_change = vec3(1.0) + vec3(
            (magnetosphere + 1.0) * 2.0,
            (-magnetosphere2 + 1.0) * 2.0,
            (-magnetosphere3 + 1.0) * 1.0
        ) * 0.4;
        return normalize(magnetosphere_change);
    #endif
 }

#if (CLOUD_MODE > CLOUD_MODE_FLAT)
float emission_strength() {
    return clamp((magnetosphere() - 0.3) * 1.3, 0, 1) * max(sun_dir.z, 0);
}

float emission_br() {
    #if (CLOUD_MODE >= CLOUD_MODE_MEDIUM)
        return abs(pow(fract(time_of_day.y * 0.5) * 2 - 1, 2));
    #else
        return 0.5;
    #endif
}
#endif


float get_sun_brightness() {
    return max(-sun_dir.z + 0.5, 0.0);
}

float get_moon_brightness() {
    return max(sun_dir.z + 0.6, 0.0) * 0.1;
}

vec3 get_sun_color() {
    vec3 light = (sun_dir.x > 0) ? DUSK_LIGHT : DAWN_LIGHT;

    return mix(
        mix(
            light * magnetosphere_tint(),
            NIGHT_LIGHT,
            max(sun_dir.z, 0)
        ),
        DAY_LIGHT,
        max(-sun_dir.z, 0)
    );
}

// Average sky colour (i.e: perfectly scattered light from the sky)
vec3 get_sky_color() {
    return mix(
        mix(
            (SKY_DUSK_TOP + SKY_DUSK_MID) / 2 * magnetosphere_tint(),
            (SKY_NIGHT_TOP + SKY_NIGHT_MID) / 2,
            max(sun_dir.z, 0)
        ),
        (SKY_DAY_TOP + SKY_DAY_MID) / 2,
        max(-sun_dir.z, 0)
    );
}

vec3 get_moon_color() {
    return vec3(0.5, 0.5, 1.6);
}

DirectionalLight get_sun_info(vec4 _dir, float shade_frac, vec3 f_pos) {
    float shadow = shade_frac;
    float block = 1.0;
#ifdef HAS_SHADOW_MAPS
    #if (SHADOW_MODE == SHADOW_MODE_MAP)
        if (sun_dir.z < 0.0) {
            shadow = min(shadow, ShadowCalculationDirected(f_pos));
        }
    #endif
#endif
    return DirectionalLight(shadow, block);
}

DirectionalLight get_moon_info(vec4 _dir, float shade_frac) {
    float shadow = shade_frac;
    float block = 1.0;
    return DirectionalLight(shadow, block);
}

const float LIGHTNING_HEIGHT = 25.0;
const float MAX_LIGHTNING_PERIOD = 5.0;

float lightning_intensity() {
    float time_since_lightning = time_since(last_lightning.w);
    return
        // Strength
        1000000
        // Flash
        * max(0.0, 1.0 - time_since_lightning * 1.0)
        // Reverb
        * max(sin(time_of_day.x * 0.4), 0.0);
}

vec3 lightning_at(vec3 wpos) {
    float time_since_lightning = time_since(last_lightning.w);
    if (time_since_lightning < MAX_LIGHTNING_PERIOD) {
        vec3 diff = wpos + focus_off.xyz - (last_lightning.xyz + vec3(0, 0, LIGHTNING_HEIGHT));
        float dist = length(diff);
        return vec3(0.5, 0.8, 1.0)
            * lightning_intensity()
            // Attenuation
            / pow(50.0 + dist, 2);
    } else {
        return vec3(0.0);
    }
}

// Returns computed maximum intensity.
//
// wpos is the position of this fragment.
// mu is the attenuation coefficient for any substance on a horizontal plane.
// cam_attenuation is the total light attenuation due to the substance for beams between the point and the camera.
// surface_alt is the altitude of the attenuating surface.
float get_sun_diffuse2(
    DirectionalLight sun_info,
    DirectionalLight moon_info,
    vec3 norm,
    vec3 dir,
    vec3 wpos,
    vec3 mu,
    vec3 cam_attenuation,
    float surface_alt,
    vec3 k_a,
    vec3 k_d,
    vec3 k_s,
    float alpha,
    vec3 voxel_norm,
    float voxel_lighting,
    out vec3 emitted_light,
    out vec3 reflected_light
) {
    const vec3 SUN_AMBIANCE = MU_SCATTER;
    #ifdef EXPERIMENTAL_PHOTOREALISTIC
        const vec3 MOON_AMBIANCE = MU_SCATTER;
    #else
        // Boost ambiance, because we don't properly compensate for pupil dilation (which should occur *before* HDR,
        // not in the end user's eye). Also, real nights are too dark to be fun.
        const vec3 MOON_AMBIANCE = vec3(0.15, 0.25, 0.23) * 5;
    #endif

    vec3 sun_dir = sun_dir.xyz;
    // TODO: Use real moon dir here and have other ways to light up night.
    // So this is a hack to just pretend the moon is still opposite to the sun
    // for this and `get_moon_brightness`.
    vec3 moon_dir = -sun_dir.xyz;

    float sun_light = get_sun_brightness() * sun_info.block;
    float moon_light = get_moon_brightness() * moon_info.block * ambiance;

    vec3 sun_color = get_sun_color() * SUN_COLOR_FACTOR;
    vec3 moon_color = get_moon_color() * MOON_COLOR_FACTOR;

    // If the sun is facing the wrong way, we currently just want zero light, hence default point is wpos.
    vec3 sun_attenuation = compute_attenuation(wpos, -sun_dir, mu, surface_alt, wpos);
    vec3 moon_attenuation = compute_attenuation(wpos, -moon_dir, mu, surface_alt, wpos);

    vec3 sun_chroma = sun_color * sun_light * cam_attenuation * sun_attenuation;
    vec3 moon_chroma = moon_color * moon_light * cam_attenuation * moon_attenuation;

    float sun_shadow = sun_info.shadow * cloud_shadow(wpos, sun_dir);
    float moon_shadow = moon_info.shadow * cloud_shadow(wpos, moon_dir);

    // https://en.m.wikipedia.org/wiki/Diffuse_sky_radiation
    //
    // HdRd radiation should come in at angle normal to us.
    // const float H_d = 0.23;
    //
    // Let β be the angle from horizontal
    // (for objects exposed to the sky, where positive when sloping towards south and negative when sloping towards north):
    //
    //     sin β = (north ⋅ norm) / |north||norm|
    //           = dot(vec3(0, 1, 0), norm)
    //
    //     cos β = sqrt(1.0 - dot(vec3(0, 1, 0), norm))
    //
    // Let h be the hour angle (180/0.0 at midnight, 90/1.0 at dawn, 0/0.0 at noon, -90/-1.0 at dusk, -180 at midnight/0.0):
    //     cos h = (midnight ⋅ -light_dir) / |midnight||-light_dir|
    //           = (noon ⋅ light_dir) / |noon||light_dir|
    //           = dot(vec3(0, 0, 1), light_dir)
    //
    // Let φ be the latitude at this point. 0 at equator, -90 at south pole / 90 at north pole.
    //
    // Let δ be the solar declination (angular distance of the sun's rays north [or south[]
    // of the equator), i.e. the angle made by the line joining the centers of the sun and Earth with its projection on the
    // equatorial plane.  Caused by axial tilt, and 0 at equinoxes.  Normally varies between -23.45 and 23.45 degrees.
    //
    // Let α (the solar altitude / altitud3 angle) be the vertical angle between the projection of the sun's rays on the
    // horizontal plane and the direction of the sun's rays (passing through a point).
    //
    // Let Θ_z be the vertical angle between sun's rays and a line perpendicular to the horizontal plane through a point,
    // i.e.
    //
    // Θ_z = (π/2) - α
    //
    // i.e. cos Θ_z = sin α and
    //      cos α = sin Θ_z
    //
    // Let γ_s be the horizontal angle measured from north to the horizontal projection of the sun's rays (positive when
    // measured westwise).
    //
    // cos Θ_z = cos φ cos h cos δ + sin φ sin δ
    // cos γ_s = sec α (cos φ sin δ - cos δ sin φ cos h)
    //         = (1  / √(1 - cos² Θ_z)) (cos φ sin δ - cos δ sin φ cos h)
    // sin γ_s = sec α cos δ sin h
    //         = (1 / cos α) cos δ sin h
    //         = (1 / sin Θ_z) cos δ sin h
    //         = (1  / √(1 - cos² Θ_z)) cos δ sin h
    //
    // R_b = (sin(δ)sin(φ - β) + cos(δ)cos(h)cos(φ - β))/(sin(δ)sin(φ) + cos(δ)cos(h)cos(φ))
    //
    // Assuming we are on the equator (i.e. φ = 0), and there is no axial tilt or we are at an equinox (i.e. δ = 0):
    //
    // cos Θ_z = 1 * cos h * 1 + 0 * 0 = cos h
    // cos γ_s = (1  / √(1 - cos² h)) (1 * 0 - 1 * 0 * cos h)
    //         = (1  / √(1 - cos² h)) * 0
    //         = 0
    // sin γ_s = (1  / √(1 - cos² h)) * sin h
    //         = sin h / sin h
    //         = 1
    //
    // R_b = (0 * sin(0 - β) + 1 * cos(h) * cos(0 - β))/(0 * 0 + 1 * cos(h) * 1)
    //     = (cos(h)cos(-β)) / cos(H)
    //     = cos(-β), the angle from horizontal.
    //
    // NOTE: cos(-β) = cos(β).
    // float cos_sun = dot(norm, /*-sun_dir*/vec3(0, 0, 1));
    // float cos_moon = dot(norm, -moon_dir);
    //
    // Let ζ = diffuse reflectance of surrounding ground for solar radiation, then we have
    //
    // R_d = (1 + cos β) / 2
    // R_r = ζ (1 - cos β) / 2
    //
    // H_t = H_b R_b + H_d R_d + (H_b + H_d) R_r
    float sin_beta = dot(vec3(0, 1, 0), norm);
    float R_b = sqrt(max(0.0, 1.0 - sin_beta * sin_beta));
    // Rough estimate of diffuse reflectance of rest of ground.
    // NOTE: zeta should be close to 0.7 with snow cover, 0.2 normally?  Maybe?
    vec3 zeta = max(vec3(0.2), k_d * (1.0 - k_s));
    float R_d = (1 + R_b) * 0.5;
    vec3 R_r = zeta * (1.0 - R_b) * 0.5;
    //
    // We can break this down into:
    //      H_t_b = H_b * (R_b + R_r) = light_intensity * (R_b + R_r)
    //      H_t_r = H_d * (R_d + R_r) = light_intensity * (R_d + R_r)
    vec3 R_t_b = R_b + R_r;
    vec3 R_t_r = R_d + R_r;

    #ifdef EXPERIMENTAL_PHOTOREALISTIC
        vec3 lrf = light_reflection_factor(norm, dir, -norm, k_d, vec3(0.0), alpha, voxel_norm, voxel_lighting);
    #else
        // In practice, for gameplay purposes, we often want extra light at earlier and later times, so we use a
        // non-physical LRF to boost light during dawn and dusk.
        float lrf = pow(dot(norm, vec3(0, 0, 1)) + 1, 2) * 0.25;
    #endif
    vec3 light_frac = R_t_b * (sun_chroma * SUN_AMBIANCE + moon_chroma * MOON_AMBIANCE) * lrf;

    emitted_light = light_frac;

    vec3 emission = vec3(0);
    #if (CLOUD_MODE > CLOUD_MODE_FLAT)
        if (emission_strength() > 0.0) {
            emission = mix(vec3(0, 0.5, 1), vec3(1, 0, 0), emission_br()) * emission_strength() * 0.025;
        }
    #endif

    #ifdef FLASHING_LIGHTS_ENABLED
        vec3 lightning = lightning_at(wpos);
    #else
        vec3 lightning = vec3(0);
    #endif

    reflected_light = R_t_r * (
        (1.0 - SUN_AMBIANCE) * sun_chroma * sun_shadow * light_reflection_factor(norm, dir, sun_dir, k_d, k_s, alpha, voxel_norm, voxel_lighting)
        + (1.0 - MOON_AMBIANCE) * moon_chroma * moon_shadow * light_reflection_factor(norm, dir, moon_dir, k_d, k_s, alpha, voxel_norm, voxel_lighting)
        + emission
    ) + lightning;

    return rel_luminance(emitted_light + reflected_light);
}

// This has been extracted into a function to allow quick exit when detecting a star.
float is_star_at(vec3 dir) {
    float star_scale = 80.0;

    // Star positions
    vec3 pos = (floor(dir * star_scale) - 0.5) / star_scale;

    // Noisy offsets
    pos += (3.0 / star_scale) * (1.0 + hash(pos.yxzz) * 0.85);

    // Find distance to fragment
    float dist = length(pos - dir);

    #if (CLOUD_MODE == CLOUD_MODE_FLAT)
        const float power = 5.0;
    #else
        const float power = 50.0;
    #endif
    return power * max(sun_dir.z, 0.1) / (1.0 + pow(dist * 750, 8));
}

vec3 get_sky_light(vec3 dir, bool with_stars, float is_moon) {
    // Add white dots for stars. Note these flicker and jump due to FXAA
    float star = 0.0;
    if (with_stars) {
        vec3 star_dir = sun_dir.xyz * dir.z + cross(sun_dir.xyz, vec3(0, 1, 0)) * dir.x + vec3(0, 1, 0) * dir.y;
        star = is_star_at(star_dir) * (1.0 - is_moon);
    }

    vec3 sky_twilight_top = vec3(0.0, 0.0, 0.0);
    vec3 sky_twilight_mid = vec3(0.0, 0.0, 0.0);
    vec3 sky_twilight_bot = vec3(0.0, 0.0, 0.0);
    if (sun_dir.x > 0) {
      sky_twilight_top = SKY_DUSK_TOP;
      sky_twilight_mid = SKY_DUSK_MID;
      sky_twilight_bot = SKY_DUSK_BOT;
    } else {
      sky_twilight_top = SKY_DAWN_TOP;
      sky_twilight_mid = SKY_DAWN_MID;
      sky_twilight_bot = SKY_DAWN_BOT;
    }

    vec3 sky_top = mix(
        mix(
            sky_twilight_top * magnetosphere_tint(),
            SKY_NIGHT_TOP,
            pow(max(sun_dir.z, 0.0), 0.2)
        ) + star,
        SKY_DAY_TOP,
        max(-sun_dir.z, 0)
    );

    vec3 sky_mid = mix(
        mix(
            sky_twilight_mid * magnetosphere_tint(),
            SKY_NIGHT_MID,
            pow(max(sun_dir.z, 0.0), 0.1)
        ),
        SKY_DAY_MID,
        max(-sun_dir.z, 0)
    );

    vec3 sky_bot = mix(
        mix(
            sky_twilight_bot * magnetosphere_tint(),
            SKY_NIGHT_BOT,
            pow(max(sun_dir.z, 0.0), 0.2)
        ),
        SKY_DAY_BOT,
        max(-sun_dir.z, 0)
    );

    vec3 sky_color = mix(
        mix(
            sky_mid,
            sky_bot,
            max(-dir.z, 0)
        ),
        sky_top,
        max(dir.z, 0)
    );

    return sky_color * magnetosphere_tint();
}

vec3 get_sky_color(vec3 dir, vec3 origin, vec3 f_pos, float quality, bool with_features, float refractionIndex, bool fake_clouds, float sun_shade_frac) {
    // Sky color
    vec3 sun_dir = sun_dir.xyz;
    vec3 moon_dir = moon_dir.xyz;


    // Sun
    const vec3 SUN_SURF_COLOR = vec3(1.5, 0.9, 0.35) * 10.0;

    vec3 sun_halo_color = mix(
        (sun_dir.x > 0 ? SUN_HALO_DUSK : SUN_HALO_DAWN)* magnetosphere_tint(),
        SUN_HALO_DAY,
        pow(max(-sun_dir.z, 0.0), 0.5)
    );

    float sun_halo_power = 20.0;
    if (fake_clouds || medium.x == MEDIUM_WATER) {
        sun_halo_power = 30.0;
        sun_halo_color *= 0.01;
    }

    vec3 sun_halo = sun_halo_color * 25 * pow(max(dot(dir, -sun_dir), 0), sun_halo_power);
    vec3 sun_surf = vec3(0);
    if (with_features) {
        float angle = 0.00035;
        sun_surf = clamp((dot(dir, -sun_dir) - (1.0 - angle)) * 4 / angle, 0, 1)
            * SUN_SURF_COLOR
            * SUN_COLOR_FACTOR
            * sun_shade_frac;
    }
    #if (CLOUD_MODE == CLOUD_MODE_FLAT)
        if (true) {
    #else
        if (fake_clouds || medium.x == MEDIUM_WATER) {
    #endif
        sun_surf *= 0.1;
    }
    vec3 sun_light = sun_halo + sun_surf;

    // Moon
    const vec3 MOON_SURF_COLOR = vec3(0.7, 1.0, 1.5) * 250.0;
    const vec3 MOON_HALO_COLOR = vec3(0.015, 0.015, 0.05) * 250;

    vec3 moon_halo_color = MOON_HALO_COLOR;

    float moon_halo_power = 20.0;

    vec3 moon_surf = vec3(0);

    #if (CLOUD_MODE == CLOUD_MODE_FLAT)
        if (true) {
    #else
        if (fake_clouds || medium.x == MEDIUM_WATER) {
    #endif
        moon_halo_power = 50.0;
    }

    float is_moon = 0.0;

    if (with_features) {
        float moon_radius = 0.035;
        
        float tca = dot(-moon_dir, dir);

        float radius2 = moon_radius * moon_radius;
        float d2 = 1.0 - tca * tca;

        float diff = radius2 - d2;

        is_moon = clamp(tca * 2000.0, 0.0, 1.0) * clamp(diff * 4000.0, 0.0, 1.0);

        if (is_moon > 0.0) {
            float thc = sqrt(diff);

            float t0 = tca - thc;

            vec3 moon_normal = (t0 * dir + moon_dir) * (1.0 / moon_radius);

            float noise = snoise3(moon_normal * 8.2) + snoise3(moon_normal * 25.0) * 0.4;

            float direct_sunlight = max(dot(moon_normal, -sun_dir), 0.0);

            float planet_albedo = 0.12;
            float planet_reflected_light = (1.0 - abs(dot(moon_dir, sun_dir))) * max(dot(moon_normal, moon_dir), 0.0) * planet_albedo;
            float light = max(direct_sunlight + planet_reflected_light, 0.001);

            // ~sun is the same direction from the moon as it is to us.
            float surface_light = pow(light * (0.4 + 0.3 * noise), 2.0);

            moon_surf = MOON_SURF_COLOR * surface_light * is_moon;
        }
    }
    #if (CLOUD_MODE == CLOUD_MODE_FLAT)
        if (true) {
    #else
        if (fake_clouds || medium.x == MEDIUM_WATER) {
    #endif
        moon_halo_color *= 0.2;
        moon_surf *= 0.05;
    }
    vec3 moon_halo = moon_halo_color * pow(max(dot(dir, -moon_dir), 0) * max(dot(sun_dir, -moon_dir), 0), moon_halo_power);
    vec3 moon_light = moon_halo + moon_surf;

    // Replaced all clamp(sun_dir, 0, 1) with max(sun_dir, 0) because sun_dir is calculated from sin and cos, which are never > 1

    vec3 sky_color;
    #if (CLOUD_MODE == CLOUD_MODE_FLAT)
        if (true) {
    #else
        if (fake_clouds || medium.x == MEDIUM_WATER) {
    #endif
        sky_color = get_sky_light(dir, !fake_clouds, is_moon);
    } else {
        if (medium.x == MEDIUM_WATER) {
            sky_color = get_sky_light(dir, true, is_moon);
        } else {
            vec3 star_dir = normalize(sun_dir.xyz * dir.z + cross(sun_dir.xyz, vec3(0, 1, 0)) * dir.x + vec3(0, 1, 0) * dir.y);
            float star = is_star_at(star_dir) * (1.0 - is_moon);
            sky_color = vec3(0) + star;
        }
    }

    return sky_color + sun_light + moon_light;
}

float fog(vec3 f_pos, vec3 focus_pos, uint medium) {
    return max(1.0 - 5000.0 / (1.0 + distance(f_pos.xy, focus_pos.xy)), 0.0);
}

vec3 illuminate(float max_light, vec3 view_dir, vec3 emitted, vec3 reflected) {
    return emitted + reflected;
}

vec3 simple_lighting(vec3 pos, vec3 col, float shade) {
    // Bad fake lantern so we can see in caves
    vec3 d = pos.xyz - focus_pos.xyz;
    return col * clamp(2.5 / dot(d, d), shade * (get_sun_brightness() + 0.01), 1);
}

float wind_wave(float off, float scaling, float speed, float strength) {
    float aspeed = abs(speed);

    // TODO: Right now, the wind model is pretty simplistic. This means that there is frequently no wind at all, which
    // looks bad. For now, we add a lower bound on the wind speed to keep things looking nice.
    strength = max(strength, 6.0);
    aspeed = max(aspeed, 5.0);

    return (sin(tick_loop(2.0 * PI, 0.35 * scaling * floor(aspeed), off)) * (1.0 - fract(aspeed))
        + sin(tick_loop(2.0 * PI, 0.35 * scaling * ceil(aspeed), off)) * fract(aspeed)) * abs(strength) * 0.25;
}

#endif

#ifndef SRGB_GLSL
#define SRGB_GLSL

#extension GL_EXT_samplerless_texture_functions : enable

// Linear RGB, attenuation coefficients for water at roughly R, G, B wavelengths.
// See https://en.wikipedia.org/wiki/Electromagnetic_absorption_by_water
const vec3 MU_WATER = vec3(0.6, 0.04, 0.01);

//https://gamedev.stackexchange.com/questions/92015/optimized-linear-to-srgb-glsl
vec3 srgb_to_linear(vec3 srgb) {
    bvec3 cutoff = lessThan(srgb, vec3(0.04045));
    vec3 higher = pow((srgb + vec3(0.055))/vec3(1.055), vec3(2.4));
    vec3 lower = srgb/vec3(12.92);

    return mix(higher, lower, cutoff);
}

vec3 linear_to_srgb(vec3 col) {
    vec3 s1 = vec3(sqrt(col.r), sqrt(col.g), sqrt(col.b));
    vec3 s2 = vec3(sqrt(s1.r), sqrt(s1.g), sqrt(s1.b));
    vec3 s3 = vec3(sqrt(s2.r), sqrt(s2.g), sqrt(s2.b));
    return vec3(
            mix(11.500726 * col.r, (0.585122381 * s1.r + 0.783140355 * s2.r - 0.368262736 * s3.r), clamp((col.r - 0.0060) * 10000.0, 0.0, 1.0)),
            mix(11.500726 * col.g, (0.585122381 * s1.g + 0.783140355 * s2.g - 0.368262736 * s3.g), clamp((col.g - 0.0060) * 10000.0, 0.0, 1.0)),
            mix(11.500726 * col.b, (0.585122381 * s1.b + 0.783140355 * s2.b - 0.368262736 * s3.b), clamp((col.b - 0.0060) * 10000.0, 0.0, 1.0))
    );
}

float pow5(float x) {
    float x2 = x * x;
    return x2 * x2 * x;
}

vec4 pow5(vec4 x) {
    vec4 x2 = x * x;
    return x2 * x2 * x;
}

// Fresnel angle for perfectly specular dialectric materials.

// Schlick approximation
vec3 schlick_fresnel(vec3 Rs, float cosTheta) {
    return Rs + pow5(1.0 - cosTheta) * (1.0 - Rs);
}

// Beckmann Distribution
float BeckmannDistribution_D(float NdotH, float alpha) {
    const float PI = 3.1415926535897932384626433832795;
    float NdotH2 = NdotH * NdotH;
    float NdotH2m2 = NdotH2 * alpha * alpha;
    float k_spec = exp((NdotH2 - 1.0) / NdotH2m2) / (PI * NdotH2m2 * NdotH2);
    return mix(k_spec, 0.0, NdotH == 0.0);
}

// Voxel Distribution
float BeckmannDistribution_D_Voxel(vec3 wh, vec3 voxel_norm, float alpha) {
    vec3 sides = sign(voxel_norm);
    
    vec3 NdotH = wh * sides;

    const float PI = 3.1415926535897932384626433832795;
    vec3 NdotH2 = NdotH * NdotH;
    vec3 NdotH2m2 = NdotH2 * alpha * alpha;
    vec3 k_spec = exp((NdotH2 - 1.0) / NdotH2m2) / (PI * NdotH2m2 * NdotH2);
    return dot(mix(k_spec, vec3(0.0), equal(NdotH, vec3(0.0))), abs(voxel_norm));
}

float TrowbridgeReitzDistribution_D_Voxel(vec3 wh, vec3 voxel_norm, float alpha) {
    vec3 sides = sign(voxel_norm);

    vec3 NdotH = wh * sides;

    const float PI = 3.1415926535897932384626433832795;
    vec3 NdotH2 = NdotH * NdotH;
    vec3 NdotH2m2 = NdotH2 * alpha * alpha;
    vec3 e = (1.0 - NdotH2) / NdotH2m2;
    vec3 k_spec = 1.0 / (PI * NdotH2m2 * NdotH2 * (1.0 + e) * (1.0 + e));
    return dot(mix(k_spec, vec3(0.0), equal(NdotH, vec3(0.0))), abs(voxel_norm));
}

float BeckmannDistribution_Lambda(vec3 norm, vec3 dir, float alpha) {
    float CosTheta = dot(norm, dir);
    float SinTheta = sqrt(1.0 - CosTheta * CosTheta);
    float TanTheta = SinTheta / CosTheta;
    float absTanTheta = abs(TanTheta);
    float a = 1.0 / (alpha * absTanTheta);
    
    return mix(max(0.0, (1.0 - 1.259 * a + 0.396 * a * a) / (3.535 * a + 2.181 * a * a)), 0.0, isinf(absTanTheta) || a >= 1.6);
}

float BeckmannDistribution_G(vec3 norm, vec3 dir, vec3 light_dir, float alpha) {
    return 1.0 / (1.0 + BeckmannDistribution_Lambda(norm, dir, alpha) + BeckmannDistribution_Lambda(norm, -light_dir, alpha));
}

// Fresnel blending
//
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Microfacet_Models.html#fragment-MicrofacetDistributionPublicMethods-2
// and
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Fresnel_Incidence_Effects.html
vec3 FresnelBlend_f(vec3 norm, vec3 dir, vec3 light_dir, vec3 R_d, vec3 R_s, float alpha) {
    const float PI = 3.1415926535897932384626433832795;
    alpha = alpha * sqrt(2.0);
    float cos_wi = dot(-light_dir, norm);
    float cos_wo = dot(dir, norm);

    vec3 diffuse = (28.0 / (23.0 * PI)) * R_d *
        (1.0 - R_s) *
        (1.0 - pow5(1.0 - 0.5 * abs(cos_wi))) *
        (1.0 - pow5(1.0 - 0.5 * abs(cos_wo)));
    vec3 wh = -light_dir + dir;
#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    bool is_blocked = cos_wi == 0.0 || cos_wo == 0.0;
#else
    bool is_blocked = cos_wi <= 0.0 || cos_wo <= 0.0;
#endif
    if (is_blocked) {
        return vec3(0.0);
    }
    wh = normalize(wh);
    float dot_wi_wh = dot(-light_dir, wh);
    vec3 specular = dot(norm, dir) > 0.0 ? vec3(0.0) : (BeckmannDistribution_D(dot(wh, norm), alpha) /
        (4.0 * abs(dot_wi_wh) *
        max(abs(cos_wi), abs(cos_wo))) *
        schlick_fresnel(R_s, dot_wi_wh));
    return mix(diffuse + specular, vec3(0.0), bvec3(all(equal(light_dir, dir))));
}

// Fresnel blending
//
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Microfacet_Models.html#fragment-MicrofacetDistributionPublicMethods-2
// and
// http://www.pbr-book.org/3ed-2018/Reflection_Models/Fresnel_Incidence_Effects.html
vec3 FresnelBlend_Voxel_f(vec3 norm, vec3 dir, vec3 light_dir, vec3 R_d, vec3 R_s, float alpha, vec3 voxel_norm, float dist) {
    const float PI = 3.1415926535897932384626433832795;
    alpha = alpha * sqrt(2.0);
    float cos_wi = dot(-light_dir, norm);
    float cos_wo = dot(dir, norm);

#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    vec4 AbsNdotL = abs(vec4(light_dir, cos_wi));
    vec4 AbsNdotV = abs(vec4(dir, cos_wo));
#else
    vec3 sides = sign(voxel_norm);
    vec4 AbsNdotL = vec4(max(-light_dir * sides, 0.0), abs(cos_wi));
    vec4 AbsNdotV = vec4(max(dir * sides, 0.0), abs(cos_wo));
#endif

    vec4 diffuse_factor = (1.0 - pow5(1.0 - 0.5 * AbsNdotL)) * (1.0 - pow5(1.0 - 0.5 * AbsNdotV));

    vec3 diffuse = (28.0 / (23.0 * PI)) * R_d * (1.0 - R_s) * dot(diffuse_factor, /*R_r * */vec4(abs(norm) * (1.0 - dist), dist));

    vec3 wh = -light_dir + dir;
#if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    bool is_blocked = cos_wi == 0.0 || cos_wo == 0.0;
#else
    bool is_blocked = cos_wi <= 0.0 || cos_wo <= 0.0;
#endif
    if (is_blocked) {
        return vec3(0.0);
    }
    wh = normalize(wh);
    float dot_wi_wh = dot(-light_dir, wh);
    float distr = BeckmannDistribution_D_Voxel(wh, voxel_norm, alpha);
    vec3 specular = distr /
        (4.0 * abs(dot_wi_wh) *
        max(abs(cos_wi), abs(cos_wo))) *
        schlick_fresnel(R_s, dot_wi_wh);
    return mix(diffuse + specular, vec3(0.0), bvec3(all(equal(light_dir, dir))));
}

// Phong reflection.
//
// Note: norm, dir, light_dir must all be normalizd.
vec3 light_reflection_factor2(vec3 norm, vec3 dir, vec3 light_dir, vec3 k_d, vec3 k_s, float alpha) {
    // TODO: These are supposed to be the differential changes in the point location p, in tangent space.
    // That is, assuming we can parameterize a 2D surface by some function p : R² → R³, mapping from
    // points in a plane to 3D points on the surface, we can define
    // ∂p(u,v)/∂u and ∂p(u,v)/∂v representing the changes in the pont location as we move along these
    // coordinates.
    //
    // Then we can define the normal at a point, n(u,v) = ∂p(u,v)/∂u × ∂p(u,v)/∂v.
    //
    // Additionally, we can define the change in *normals* at each point using the
    // Weingarten equations (see http://www.pbr-book.org/3ed-2018/Shapes/Spheres.html):
    //
    // ∂n/∂u = (fF - eG) / (EG - F²) ∂p/∂u + (eF - fE) / (EG - F²) ∂p/∂v
    // ∂n/∂v = (gF - fG) / (EG - F²) ∂p/∂u + (fF - gE) / (EG - F²) ∂p/∂v
    //
    // where
    //
    // E = |∂p/∂u ⋅ ∂p/∂u|
    // F = ∂p/∂u ⋅ ∂p/∂u
    // G = |∂p/∂v ⋅ ∂p/∂v|
    //
    // and
    //
    // e = n ⋅ ∂²p/∂u²
    // f = n ⋅ ∂²p/(∂u∂v)
    // g = n ⋅ ∂²p/∂v²
    //
    // For planes (see http://www.pbr-book.org/3ed-2018/Shapes/Triangle_Meshes.html) we have
    // e = f = g = 0 (since the plane has no curvature of any sort) so we get:
    //
    // ∂n/∂u = (0, 0, 0)
    // ∂n/∂v = (0, 0, 0)
    //
    // To find ∂p/∂u and ∂p/∂v, we first write p and u parametrically:
    //    p(u, v) = p0 + u ∂p/∂u + v ∂p/∂v
    //
    // ( u₀ - u₂    v₀ - v₂
    //   u₁ - u₂    v₁ - v₂ )
    //
    // Basis: plane norm = norm = (0, 0, 1), x vector = any orthgonal vector on the plane.
    // vec3 w_i =
    // vec3 w_i = vec3(view_mat * vec4(-light_dir, 1.0));
    // vec3 w_o = vec3(view_mat * vec4(light_dir, 1.0));
    return FresnelBlend_f(norm, dir, light_dir, k_d, k_s, alpha);
}

vec3 light_reflection_factor(vec3 norm, vec3 dir, vec3 light_dir, vec3 k_d, vec3 k_s, float alpha, vec3 voxel_norm, float voxel_lighting) {
#if (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_LAMBERTIAN)
    const float PI = 3.141592;
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    vec4 AbsNdotL = abs(vec4(light_dir, dot(norm, light_dir)));
        #else
    vec3 sides = sign(voxel_norm);
    vec4 AbsNdotL = max(vec4(-light_dir * sides, dot(norm, -light_dir)), 0.0);
        #endif
    float diffuse = dot(AbsNdotL, vec4(abs(voxel_norm) * (1.0 - voxel_lighting), voxel_lighting));
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    float diffuse = abs(dot(norm, light_dir));
        #else
    float diffuse = max(dot(norm, -light_dir), 0.0);
        #endif
    #endif
    return k_d / PI * diffuse;
#elif (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_BLINN_PHONG)
    const float PI = 3.141592;
    alpha = alpha * sqrt(2.0);
    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
    float ndotL = abs(dot(norm, light_dir));
    #else
    float ndotL = max(dot(norm, -light_dir), 0.0);
    #endif

    if (ndotL > 0.0) {
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        vec4 AbsNdotL = abs(vec4(light_dir, ndotL));
        #else
        vec3 sides = sign(voxel_norm);
        vec4 AbsNdotL = max(vec4(-light_dir * sides, ndotL), 0.0);
        #endif
        float diffuse = dot(AbsNdotL, vec4(abs(voxel_norm) * (1.0 - voxel_lighting), voxel_lighting));
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        float diffuse = ndotL;
    #endif
        vec3 H = normalize(-light_dir + dir);

    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        float NdotH = abs(dot(norm, H));
    #else
        float NdotH = max(dot(norm, H), 0.0);
    #endif
        return (1.0 - k_s) / PI * k_d * diffuse + k_s * pow(NdotH, alpha/* * 4.0*/);
    }

    return vec3(0.0);
#elif (LIGHTING_ALGORITHM == LIGHTING_ALGORITHM_ASHIKHMIN)
    #if (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_VOXEL)
        return FresnelBlend_Voxel_f(norm, dir, light_dir, k_d, k_s, alpha, voxel_norm, voxel_lighting);
    #elif (LIGHTING_DISTRIBUTION_SCHEME == LIGHTING_DISTRIBUTION_SCHEME_MICROFACET)
        return FresnelBlend_f(norm, dir, light_dir, k_d, k_s, alpha);
    #endif
#endif
}

float rel_luminance(vec3 rgb)
{
    // https://en.wikipedia.org/wiki/Relative_luminance
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    return dot(rgb, W);
}

// From https://discourse.vvvv.org/t/infinite-ray-intersects-with-infinite-plane/10537
// out of laziness.
bool IntersectRayPlane(vec3 rayOrigin, vec3 rayDirection, vec3 posOnPlane, vec3 planeNormal, inout vec3 intersectionPoint)
{
  float rDotn = dot(rayDirection, planeNormal);

  //parallel to plane or pointing away from plane?
  if (rDotn < 0.0000001 )
    return false;

  float s = dot(planeNormal, (posOnPlane - rayOrigin)) / rDotn;

  intersectionPoint = rayOrigin + s * rayDirection;

  return true;
}

// Compute uniform attenuation due to beam passing through a substance that fills an area below a horizontal plane
// (e.g. in most cases, water below the water surface depth) using the simplest form of the Beer-Lambert law
// (https://en.wikipedia.org/wiki/Beer%E2%80%93Lambert_law):
//
// I(z) = I₀ e^(-μz)
//
// We compute this value, except for the initial intensity which may be multiplied out later.
//
// wpos is the position of the point being hit.
// ray_dir is the reversed direction of the ray (going "out" of the point being hit).
// mu is the attenuation coefficient for R, G, and B wavelenghts.
// surface_alt is the estimated altitude of the horizontal surface separating the substance from air.
// defaultpos is the position to use in computing the distance along material at this point if there was a failure.
//
// Ideally, defaultpos is set so we can avoid branching on error.
vec3 compute_attenuation(vec3 wpos, vec3 ray_dir, vec3 mu, float surface_alt, vec3 defaultpos) {
#if (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_IMPORTANCE)
    return vec3(1.0);
#elif (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_RADIANCE)
    #if (LIGHTING_TYPE & LIGHTING_TYPE_TRANSMISSION) != 0
        return vec3(1.0);
    #else
    ray_dir = faceforward(ray_dir, vec3(0.0, 0.0, -1.0), ray_dir);
    vec3 surface_dir = surface_alt < wpos.z ? vec3(0.0, 0.0, -1.0) : vec3(0.0, 0.0, 1.0);
    bool _intersects_surface = IntersectRayPlane(wpos, ray_dir, vec3(0.0, 0.0, surface_alt), surface_dir, defaultpos);
    float depth = length(defaultpos - wpos);
    return exp(-mu * depth);
    #endif
#endif
}

// Same as compute_attenuation but since both point are known, set a maximum to make sure we don't exceed the length
// from the default point.
vec3 compute_attenuation_point(vec3 wpos, vec3 ray_dir, vec3 mu, float surface_alt, vec3 defaultpos) {
#if (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_IMPORTANCE)
    return pow(1.0 - mu, vec3(3));
#elif (LIGHTING_TRANSPORT_MODE == LIGHTING_TRANSPORT_MODE_RADIANCE)
    return vec3(1.0);
#endif
}

vec3 greedy_extract_col_light_attr(texture2D t_col_light, sampler s_col_light, vec2 f_uv_pos, out float f_light, out float f_glow, out float f_ao, out uint f_attr, out float f_sky_exposure) {
    // TODO: Figure out how to use `texture` and modulation to avoid needing to do manual filtering
    // TODO: Use `texture` instead

    uvec4 tex_00 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(0, 0), 0) * 255.0);
    uvec4 tex_10 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(1, 0), 0) * 255.0);
    uvec4 tex_01 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(0, 1), 0) * 255.0);
    uvec4 tex_11 = uvec4(texelFetch(sampler2D(t_col_light, s_col_light), ivec2(f_uv_pos) + ivec2(1, 1), 0) * 255.0);
    vec3 light_00 = vec3(tex_00.rg >> 3u, tex_00.a & 1u);
    vec3 light_10 = vec3(tex_10.rg >> 3u, tex_10.a & 1u);
    vec3 light_01 = vec3(tex_01.rg >> 3u, tex_01.a & 1u);
    vec3 light_11 = vec3(tex_11.rg >> 3u, tex_11.a & 1u);
    vec3 light_0 = mix(light_00, light_01, fract(f_uv_pos.y));
    vec3 light_1 = mix(light_10, light_11, fract(f_uv_pos.y));
    vec3 light = mix(light_0, light_1, fract(f_uv_pos.x));

    vec3 f_col = vec3(
        float(((tex_00.r & 0x7u) << 1u) | (tex_00.b & 0xF0u)),
        float(tex_00.a & 0xFEu),
        float(((tex_00.g & 0x7u) << 1u) | ((tex_00.b & 0x0Fu) << 4u))
    ) / 255.0;

    f_ao = light.z;
    f_light = light.x / 31.0;
    f_sky_exposure = light.x / 31.0 + (1.0 - f_ao) * 0.5;
    f_glow = light.y / 31.0;
    f_attr = tex_00.g >> 3u;
    return srgb_to_linear(f_col);
}

vec3 greedy_extract_col_light_kind_terrain(
    texture2D t_col_light, sampler s_col_light,
    utexture2D t_kind,
    vec2 f_uv_pos,
    out float f_light, out float f_glow, out float f_ao, out float f_sky_exposure, out uint f_kind
) {
    uint _f_attr;
    f_kind = uint(texelFetch(t_kind, ivec2(f_uv_pos), 0).r);
    return greedy_extract_col_light_attr(t_col_light, s_col_light, f_uv_pos, f_light, f_glow, f_ao, _f_attr, f_sky_exposure);
}

vec3 greedy_extract_col_light_figure(texture2D t_col_light, sampler s_col_light, vec2 f_uv_pos, out float f_light, out uint f_attr) {
    float _f_sky_exposure, _f_light, _f_glow, _f_ao;
    return greedy_extract_col_light_attr(t_col_light, s_col_light, f_uv_pos, f_light, _f_glow, _f_ao, f_attr, _f_sky_exposure);
}

#endif


layout(set = 0, binding = 7) uniform texture2D t_horizon;
layout(set = 0, binding = 8) uniform sampler s_horizon;


const float MIN_SHADOW = 0.33;

vec2 pos_to_tex(vec2 pos) {
    // Want: (pixel + 0.5)
    vec2 uv_pos = (focus_off.xy + pos + 16) / 32.0;
    return vec2(uv_pos.x, uv_pos.y);
}

// textureBicubic from https://stackoverflow.com/a/42179924
vec4 cubic(float v) {
    vec4 n = vec4(1.0, 2.0, 3.0, 4.0) - v;
    vec4 s = n * n * n;
    float x = s.x;
    float y = s.y - 4.0 * s.x;
    float z = s.z - 4.0 * s.y + 6.0 * s.x;
    float w = 6.0 - x - y - z;
    return vec4(x, y, z, w) * (1.0/6.0);
}

// Computes atan(y, x), except with more stability when x is near 0.
float atan2(in float y, in float x) {
    bool s = (abs(x) > abs(y));
    return mix(PI/2.0 - atan(x,y), atan(y,x), s);
}

// NOTE: We assume the sampled coordinates are already in "texture pixels".
vec4 textureBicubic(texture2D tex, sampler sampl, vec2 texCoords) {
    // TODO: remove all textureSize calls and replace with constants
   vec2 texSize = textureSize(sampler2D(tex, sampl), 0);
   vec2 invTexSize = 1.0 / texSize;

   texCoords = texCoords/* * texSize */ - 0.5;


    vec2 fxy = fract(texCoords);
    texCoords -= fxy;

    vec4 xcubic = cubic(fxy.x);
    vec4 ycubic = cubic(fxy.y);

    vec4 c = texCoords.xxyy + vec2 (-0.5, +1.5).xyxy;

    vec4 s = vec4(xcubic.xz + xcubic.yw, ycubic.xz + ycubic.yw);
    vec4 offset = c + vec4 (xcubic.yw, ycubic.yw) / s;

    offset *= invTexSize.xxyy;

    vec4 sample0 = texture(sampler2D(tex, sampl), offset.xz);
    vec4 sample1 = texture(sampler2D(tex, sampl), offset.yz);
    vec4 sample2 = texture(sampler2D(tex, sampl), offset.xw);
    vec4 sample3 = texture(sampler2D(tex, sampl), offset.yw);

    float sx = s.x / (s.x + s.y);
    float sy = s.z / (s.z + s.w);

    return mix(
       mix(sample3, sample2, sx), mix(sample1, sample0, sx)
    , sy);
}

vec4 textureMaybeBicubic(texture2D tex, sampler sampl, vec2 texCoords) {
    // TODO: Allow regular `texture` to be used when cause of light leaking issues is found
    //#if (CLOUD_MODE >= CLOUD_MODE_HIGH)
        return textureBicubic(tex, sampl, texCoords);
    //#else
    //    vec2 offset = (texCoords + vec2(-1.0, 0.5)) / textureSize(sampler2D(tex, sampl), 0);
    //    return texture(sampler2D(tex, sampl), offset);
    //#endif
}

// 16 bit version (each of the 2 8-bit components are combined after bilinear sampling)
// NOTE: We assume the sampled coordinates are already in "texture pixels".
vec2 textureBicubic16(texture2D tex, sampler sampl, vec2 texCoords) {
   vec2 texSize = textureSize(sampler2D(tex, sampl), 0);
   vec2 invTexSize = 1.0 / texSize;

   texCoords = texCoords - 0.5;


    vec2 fxy = fract(texCoords);
    texCoords -= fxy;

    vec4 xcubic = cubic(fxy.x);
    vec4 ycubic = cubic(fxy.y);

    vec4 c = texCoords.xxyy + vec2 (-0.5, +1.5).xyxy;

    vec4 s = vec4(xcubic.xz + xcubic.yw, ycubic.xz + ycubic.yw);
    vec4 offset = c + vec4 (xcubic.yw, ycubic.yw) / s;

    offset *= invTexSize.xxyy;

    vec4 sample0_v4 = textureLod(sampler2D(tex, sampl), offset.xz, 0);
    vec4 sample1_v4 = textureLod(sampler2D(tex, sampl), offset.yz, 0);
    vec4 sample2_v4 = textureLod(sampler2D(tex, sampl), offset.xw, 0);
    vec4 sample3_v4 = textureLod(sampler2D(tex, sampl), offset.yw, 0);
    vec2 sample0 = sample0_v4.rb / 256.0 + sample0_v4.ga;
    vec2 sample1 = sample1_v4.rb / 256.0 + sample1_v4.ga;
    vec2 sample2 = sample2_v4.rb / 256.0 + sample2_v4.ga;
    vec2 sample3 = sample3_v4.rb / 256.0 + sample3_v4.ga;

    float sx = s.x / (s.x + s.y);
    float sy = s.z / (s.z + s.w);

    return mix(mix(sample3, sample2, sx), mix(sample1, sample0, sx), sy);
}

// Gets the altitude at a position relative to focus_off.
float alt_at(vec2 pos) {
    vec4 alt_sample = textureLod(sampler2D(t_alt, s_alt), wpos_to_uv(focus_off.xy + pos), 0);
    return (((alt_sample.r * (1.0 / 256.0) + alt_sample.g) * view_distance.w) + view_distance.z - focus_off.z);
}

float alt_at_real(vec2 pos) {
    return ((textureBicubic16(t_alt, s_alt, pos_to_tex(pos)).r * view_distance.w) + view_distance.z - focus_off.z);
}


float horizon_at2(vec4 f_horizons, float alt, vec3 pos, vec4 light_dir) {
    const float PI_2 = 3.1415926535897932384626433832795 / 2.0;
    const float MIN_LIGHT = 0.0;
    
    vec2 f_horizon = mix(f_horizons.rg, f_horizons.ba, bvec2(light_dir.x < 0.0));
    float angle = tan(f_horizon.x * PI_2);
    float height = f_horizon.y * view_distance.w + view_distance.z;
    const float w = 0.1;
    float deltah = height - alt - focus_off.z;
    float lighta = -light_dir.z / max(abs(light_dir.x), 0.0001);
    // NOTE: Ideally, deltah <= 0.0 is a sign we have an oblique horizon angle.
    float deltax = deltah / max(angle, 0.0001);
    float lighty = lighta * deltax;
    float deltay = lighty - deltah + max(pos.z - alt, 0.0);
    // NOTE: the "real" deltah should always be >= 0, so we know we're only handling the 0 case with max.
    float s = mix(max(min(max(deltay, 0.0) / max(deltax, 0.0001) / w, 1.0), 0.0), 1.0, deltah <= 0);
    return max(s * s * (3.0 - 2.0 * s), MIN_LIGHT);
}

vec2 splay(vec2 pos) {
    vec2 scale = textureSize(sampler2D(t_alt, s_alt), 0) * 32.0;
    float lod_dist = view_distance.x * 0.95 / max(scale.x, scale.y);
    float dist = abs(pos.x) + abs(pos.y);
    float stretch = (pow(dist, 5.5) * 0.75 + dist * 0.25) * (1.0 - lod_dist) + lod_dist;
    vec2 splayed = pos * stretch * scale;
    if (abs(pos.x) > 0.99 || abs(pos.y) > 0.99) {
        splayed *= 50.0;
    }
    return splayed;
}

vec3 lod_norm(vec2 f_pos/*vec3 pos*/, vec4 square) {
    float altx0 = alt_at(vec2(square.x, f_pos.y));
    float altx1 = alt_at(vec2(square.z, f_pos.y));
    float alty0 = alt_at(vec2(f_pos.x, square.y));
    float alty1 = alt_at(vec2(f_pos.x, square.w));
    float slope = abs(altx1 - altx0) + abs(alty0 - alty1);

    vec3 norm = normalize(vec3(
        (altx0 - altx1) / (square.z - square.x),
        (alty0 - alty1) / (square.w - square.y),
        1.0
    ));

    return faceforward(norm, vec3(0.0, 0.0, -1.0), norm);
}

vec3 lod_norm(vec2 f_pos) {
    const float SAMPLE_W = 32;
    return lod_norm(f_pos, vec4(f_pos - vec2(SAMPLE_W), f_pos + vec2(SAMPLE_W)));
}


vec3 lod_pos(vec2 pos, vec2 focus_pos) {
    // Remove spiking by "pushing" vertices towards local optima
    vec2 delta = splay(pos);
    vec2 hpos = focus_pos + delta;

    vec2 dir = normalize(pos);
    float shift = 150.0 * pow(length(pos), 3.0);
    for (int i = 1; i < 10; i ++) {
        hpos -= dir * dot(normalize(lod_norm(hpos)).xy, dir) * shift / float(i);
    }

    return vec3(hpos, alt_at_real(hpos));
}

#ifdef HAS_LOD_FULL_INFO
layout(set = 0, binding = 10)
uniform texture2D t_map;
layout(set = 0, binding = 11)
uniform sampler s_map;

vec3 lod_col(vec2 pos) {
    #ifdef EXPERIMENTAL_PROCEDURALLODDETAIL
        vec2 wpos = pos + focus_off.xy;
        vec2 shift = vec2(
            textureLod(sampler2D(t_noise, s_noise), wpos / 200, 0).x - 0.5,
            textureLod(sampler2D(t_noise, s_noise), wpos / 200 + 0.5, 0).x - 0.5
        ) * 32 + vec2(
            textureLod(sampler2D(t_noise, s_noise), wpos / 50, 0).x - 0.5,
            textureLod(sampler2D(t_noise, s_noise), wpos / 50 + 0.5, 0).x - 0.5
        ) * 16;
        pos += shift;
        wpos += shift;
    #endif

    vec3 col = textureBicubic(t_map, s_map, pos_to_tex(pos)).rgb;

    return col;
}
#endif

vec3 water_diffuse(vec3 color, vec3 dir, float max_dist) {
    if (medium.x == 1) {
        float f_alt = alt_at(cam_pos.xy);
        float fluid_alt = max(cam_pos.z + 1, floor(f_alt + 1));

        float water_dist = clamp((fluid_alt - cam_pos.z) / pow(max(dir.z, 0), 2), 0, max_dist);

        float fade = pow(0.95, water_dist);

        return mix(vec3(0.0, 0.2, 0.5)
            * (get_sun_brightness() * get_sun_color() + get_moon_brightness() * get_moon_color())
            * pow(0.99, max((fluid_alt - cam_pos.z) * 12.0 - dir.z * 200, 0)), color.rgb * exp(-MU_WATER * water_dist * 0.1), fade);
    } else {
        return color;
    }
}

void lod_voxels(vec3 f_pos, vec3 f_norm, vec3 cam_dir, out vec3 voxel_pos, out vec3 voxel_norm, out float voxel_sz, out float f_ao) {
    voxel_pos = f_pos;
    voxel_norm = f_norm;
    voxel_sz = 1.0;
    f_ao = 1.0;
    
    #ifndef EXPERIMENTAL_NOLODVOXELS
        const float VOXEL_SCALE_FACTOR = 100000.0;
        vec3 wpos = f_pos + focus_off.xyz;
        
        voxel_sz = clamp(exp(floor(log(distance(cam_pos.xy, f_pos.xy) * 0.0001 + noise_2d(wpos.xy * 0.01) * 0.02) * 3) / 3) * VOXEL_SCALE_FACTOR / (internal_res.x + internal_res.y), 1.0, 128.0);
        
        #ifdef EXPERIMENTAL_PROCEDURALLODDETAIL
            const float MARCH_THRESHOLD = 4.0;
        #else
            const float MARCH_THRESHOLD = 2.0;
        #endif
        
        float t = -MARCH_THRESHOLD * voxel_sz;
        int i = 0;
        while (t < MARCH_THRESHOLD * voxel_sz && i++<40) {
            vec3 deltas = (fract((wpos + cam_dir * t) / voxel_sz) - step(vec3(0), cam_dir * voxel_sz)) / -cam_dir * voxel_sz;
            t += max(min(min(deltas.x, deltas.y), deltas.z), 0.001);

            voxel_pos = (floor((wpos + cam_dir * t) / voxel_sz) + 0.5) * voxel_sz;
            float surf_depth = 0.0;
            #ifdef EXPERIMENTAL_PROCEDURALLODDETAIL
                surf_depth = (noise_3d(voxel_pos / voxel_sz * 0.01) - 0.5)
                    * 10.0
                    * voxel_sz
                    * pow(mix(0.0, mix(1.0, 0.0, max(f_norm.z, 0.0)), max(f_norm.z, 0.0)), 0.5);
            #endif
            if (dot(voxel_pos - wpos, -f_norm) > surf_depth) {
                vec3 to_center = abs(voxel_pos - (wpos + cam_dir * t));
                voxel_norm = step(max(max(to_center.x, to_center.y), to_center.z), to_center) * sign(-cam_dir);
                float dist = dot(cam_dir * t, f_norm) + surf_depth;
                f_ao = clamp(dist / voxel_sz + max(f_norm.z, 0.5), 0.25, 1.0);
                voxel_pos -= focus_off.xyz;
                return;
            }
        }
        voxel_pos = f_pos;
        // Fallback, if we didn't hit any voxels
        voxel_norm = step(max(max(f_norm.x, f_norm.y), f_norm.z), f_norm) * sign(-cam_dir);
    #endif
}

#endif


layout(location = 0) in vec3 v_pos;
layout(location = 1) in uint v_norm_ao;
layout(location = 2) in float inst_time;
layout(location = 3) in float inst_lifespan;
layout(location = 4) in float inst_entropy;
layout(location = 5) in int inst_mode;
layout(location = 6) in vec3 inst_dir;
layout(location = 7) in vec3 inst_pos;
layout(location = 8) in vec2 inst_start_wind_vel;
layout(location = 9) in vec2 inst_voxel_light;

layout(location = 0) out vec3 f_pos;
layout(location = 1) flat out vec3 f_norm;
layout(location = 2) out vec4 f_col;
layout(location = 3) out float f_reflect;
layout(location = 4) flat out int f_mode;
layout(location = 5) out vec2 f_voxel_light;

const float SCALE = 1.0 / 11.0;

// Modes
const int SMOKE = 0;
const int CAMPFIRE = 1;
const int GUN_POWDER_SPARK = 2;
const int SHRAPNEL = 3;
const int FIREWORK_BLUE = 4;
const int FIREWORK_GREEN = 5;
const int FIREWORK_PURPLE = 6;
const int FIREWORK_RED = 7;
const int FIREWORK_WHITE = 8;
const int FIREWORK_YELLOW = 9;
const int LEAF = 10;
const int FIREFLY = 11;
const int BEE = 12;
const int GROUND_SHOCKWAVE = 13;
const int ENERGY_HEALING = 14;
const int ENERGY_NATURE = 15;
const int FLAMETHROWER = 16;
const int FIRE_SHOCKWAVE = 17;
const int FIRE_BOWL = 18;
const int SNOW = 19;
const int EXPLOSION = 20;
const int ICE = 21;
const int LIFESTEAL_BEAM = 22;
const int CULTIST_FLAME = 23;
const int STATIC_SMOKE = 24;
const int BLOOD = 25;
const int ENRAGED = 26;
const int BIG_SHRAPNEL = 27;
const int LASER = 28;
const int BUBBLES = 29;
const int WATER = 30;
const int ICE_SPIKES = 31;
const int DRIP = 32;
const int TORNADO = 33;
const int DEATH = 34;
const int ENERGY_BUFFING = 35;
const int WEB_STRAND = 36;
const int BLACK_SMOKE = 37;
const int LIGHTNING = 38;
const int STEAM = 39;
const int BARRELORGAN = 40;
const int POTION_SICKNESS = 41;
const int GIGA_SNOW = 42;
const int CYCLOPS_CHARGE = 43;
const int PORTAL_FIZZ = 45;
const int INK = 46;
const int ICE_WHIRLWIND = 47;
const int FIERY_BURST = 48;
const int FIERY_BURST_VORTEX = 49;
const int FIERY_BURST_SPARKS = 50;
const int FIERY_BURST_ASH = 51;
const int FIERY_TORNADO = 52;
const int PHOENIX_CLOUD = 53;
const int FIERY_DROPLET_TRACE = 54;
const int ENERGY_PHOENIX = 55;
const int PHOENIX_BEAM = 56;
const int PHOENIX_BUILD_UP_AIM = 57;
const int CLAY_SHRAPNEL = 58;
const int AIRFLOW = 59;
const int SPORE = 60;
const int SURPRISE_EGG = 61;
const int FLAME_TORNADO = 62;
const int POISON = 63;
const int WATER_FOAM = 64;
const int ENGINE_JET = 65;
const int TRANSFORMATION = 66;
const int FIRE_GIGAS_ASH = 67;
const int FIRE_GIGAS_WHIRLWIND = 68;
const int FIRE_GIGAS_OVERHEAT = 69;
const int FIRE_GIGAS_EXPLOSION = 70;
const int FIRE_PILLAR_INDICATOR = 71;
const int FIRE_PILLAR = 72;
const int FIRE_LOW_SHOCKWAVE = 73;
const int PIPE_SMOKE = 74;
const int TRAIN_SMOKE = 75;
const int BUBBLE = 76;
const int ELEPHANT_VACUUM = 77;
const int ELECTRIC_SPARKS = 78;
const int FLAMETHROWER_BLUE = 79;
const int FLAME_CLOAK_ORBIT = 80;
const int DUST = 81;
const int CAVE_DUST = 82;
const int BUBBLE_AMBIENT = 83;

// meters per second squared (acceleration)
const float earth_gravity = 9.807;

struct Attr {
    vec3 offs;
    vec3 scale;
    vec4 col;
    mat4 rot;
};

float lifetime() { return time_since(inst_time); }

// Retrieves inst_time, repeating over a period. This will be consistent
// over a time overflow.
float loop_inst_time(float period, float scale) {
    if (tick.x < inst_time) {
        return mod(mod(tick_overflow * scale, period) + inst_time * scale, period);
    } else {
        return mod(inst_time * scale, period);
    }
}

vec3 linear_motion(vec3 init_offs, vec3 vel) {
    return init_offs + vel * lifetime();
}

vec3 on_floor(float z, float bounce, vec3 pos) {
    if (pos.z < z) {
        return vec3(pos.xy, z + abs(sin(z - pos.z)) * bounce / (1.0 + z - pos.z));
    } else {
        return pos;
    }
}

vec3 quadratic_bezier_motion(vec3 start, vec3 ctrl0, vec3 end) {
    float t = lifetime();
    float u = 1 - lifetime();
    return u*u*start + t*u*ctrl0 + t*t*end;
}

vec3 grav_vel(float grav) {
    return vec3(0, 0, -grav * lifetime());
}

float exp_scale(float factor) {
    return 1 / (1 - lifetime() * factor);
}

float linear_scale(float factor) {
    return lifetime() * factor;
}

float percent() {
    return lifetime() / inst_lifespan;
}

float slow_end(float factor) {
    return (1 + factor) * percent() / (percent() + factor);
}

float slow_start(float factor) {
    return 1-(1 + factor) * (1-percent()) / ((1-percent()) + factor);
}

float start_end(float from, float to) {
    return mix(from, to, lifetime() / inst_lifespan);
}

mat4 spin_in_axis(vec3 axis, float angle)
{
    axis = normalize(axis);
    float s = sin(angle);
    float c = cos(angle);
    float oc = 1.0 - c;

    return mat4(
        oc * axis.x * axis.x + c,
        oc * axis.x * axis.y - axis.z * s,
        oc * axis.z * axis.x + axis.y * s,
        0,

        oc * axis.x * axis.y + axis.z * s,
        oc * axis.y * axis.y + c,
        oc * axis.y * axis.z - axis.x * s,
        0,

        oc * axis.z * axis.x - axis.y * s,
        oc * axis.y * axis.z + axis.x * s,
        oc * axis.z * axis.z + c,
        0,

        0, 0, 0, 1
    );
}

mat4 align_to_axis(vec3 axis)
{
    axis = normalize(axis);
    float r_xy = sqrt(axis.x * axis.x + axis.y * axis.y);
    float c;
    float s;
    if (r_xy < 0.001) {
        s = 0;
        c = 1;
    } else {
        s = axis.y / r_xy;
        c = axis.x / r_xy;
    }

    return mat4(
        axis.x, -s, -axis.z * c,    0,
        axis.y, c,  -axis.z * s,    0,
        axis.z, 0,  r_xy,           0,
        0,      0,  0,              1
    );
}

mat4 identity() {
    return mat4(
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    );
}

vec3 perp_axis1(vec3 axis) {
    return normalize(vec3(axis.y + axis.z, -axis.x + axis.z, -axis.x - axis.y));
}

vec3 perp_axis2(vec3 axis1, vec3 axis2) {
    return normalize(vec3(axis1.y * axis2.z - axis1.z * axis2.y, axis1.z * axis2.x - axis1.x * axis2.z, axis1.x * axis2.y - axis1.y * axis2.x));
}

// Line is the axis of the spiral, it goes from the start position to the end position
// Radius is the distance from the axis the particle is
// Time function is some value that ideally goes from 0 to 1. When it is 0, it is as
// the point (0, 0, 0), when it is 1, it is at the point provided by the coordinates of line
// Frequency increases the frequency of rotation
// Offset is an offset to the angle of the rotation
vec3 spiral_motion(vec3 line, float radius, float time_function, float frequency, float offset) {
    vec3 axis2 = perp_axis1(line);
    vec3 axis3 = perp_axis2(line, axis2);

    return line * time_function + vec3(
        radius * cos(frequency * time_function - offset) * axis2.x + radius * sin(frequency * time_function - offset) * axis3.x,
        radius * cos(frequency * time_function - offset) * axis2.y + radius * sin(frequency * time_function - offset) * axis3.y,
        radius * cos(frequency * time_function - offset) * axis2.z + radius * sin(frequency * time_function - offset) * axis3.z);
}

vec3 blown_by_wind(float mass, float drift_factor) {
    float factor = pow(percent(), mass) * drift_factor;
    float rand = hash(vec4(inst_entropy + 45));
    return vec3(inst_start_wind_vel * lifetime() * factor, 0.0)
        + sin(tick_loop(2.0 * PI, vec3(0.25), vec3(0.0, 10.0, 20.0) + lifetime() * (1.0 + rand * factor)))
            * sin(tick_loop(2.0 * PI, 0.9 * vec3(1.0, 1.1, 1.2), vec3(0.0)))
            * length(inst_start_wind_vel)
            * factor;
}

void main() {
    float rand0 = hash(vec4(inst_entropy + 0));
    float rand1 = hash(vec4(inst_entropy + 1));
    float rand2 = hash(vec4(inst_entropy + 2));
    float rand3 = hash(vec4(inst_entropy + 3));
    float rand4 = hash(vec4(inst_entropy + 4));
    float rand5 = hash(vec4(inst_entropy + 5));
    float rand6 = hash(vec4(inst_entropy + 6));
    float rand7 = hash(vec4(inst_entropy + 7));
    float rand8 = hash(vec4(inst_entropy + 8));
    float rand9 = hash(vec4(inst_entropy + 9));

    vec3 start_pos = inst_pos - focus_off.xyz;

    Attr attr;
    f_reflect = 1.0;

    switch(inst_mode) {
        case SMOKE:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(rand2 * 0.1, rand3 * 0.1, 1.0 + rand4 * 0.1)
                ) + blown_by_wind(1.0, 0.25),
                vec3(linear_scale(0.5)),
                vec4(vec3(0.8, 0.8, 1) * 0.125 * (3.8 + rand0), start_end(1.0, 0.0)),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 2.5)
            );
            break;
        case BLACK_SMOKE:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(rand2 * 0.02, rand3 * 0.02, 1.0 + rand4 * 0.1)
                ) + blown_by_wind(7.0, 0.5),
                vec3(linear_scale(0.5)),
                vec4(vec3(0.8, 0.8, 1) * 0.125 * (1.8 + rand0), start_end(1.0, 0.0)),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 0.5)
            );
            break;
        case CAMPFIRE:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            attr = Attr(
                linear_motion(
                    vec3(0.0),
                    vec3(rand2 * 0.1, rand3 * 0.1, 1.25 + rand4 * 0.2)
                ) + vec3(sin(vec2(1.3, 1.7) * lifetime() * 10.0) * 0.05, 0.0),
                vec3(1.0 - slow_start(0.5)) * pow(percent(), 0.25) * 1.5,
                vec4(10, 3 + rand5 * 0.3 - 0.8 * percent(), 0.4, 1) * start_end(1.5, 0.1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3)
            );
            break;
        case FIRE_BOWL:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            attr = Attr(
                linear_motion(
                    vec3(normalize(vec2(rand0, rand1)) * 0.1, 0.6),
                    vec3(rand2 * 0.2, rand3 * 0.5, 0.8 + rand4 * 0.5)
                ),
                vec3(0.2), // Size
                vec4(2, 1.5 + rand5 * 0.5, 0, start_end(1.0, 0.0)), // Colour
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3)
            );
            break;
        case GUN_POWDER_SPARK:
            attr = Attr(
                linear_motion(
                    normalize(vec3(rand0, rand1, rand3)) * 0.3,
                    normalize(vec3(rand4, rand5, rand6)) * 4.0 + grav_vel(earth_gravity)
                ),
                vec3(1.0),
                vec4(3.5, 3 + rand7, 0, 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case SHRAPNEL:
            vec2 vel = vec2(rand4, rand5) * 2.0;
            float momentum = 1.0 - 1.0 / (1 + lifetime() * 1.0);
            attr = Attr(
                vec3(
                    vel * momentum,
                    on_floor(-0.4, 0.25, linear_motion(vec3(0), vec3(vec2(0), 4.0 + rand6) + grav_vel(earth_gravity))).z
                ),
                vec3(1.5 + rand1 * 0.25) * (1.0 - slow_start(0.025)),
                vec4(mix(vec3(0.1, 0.1, 0.15), vec3(0.15, 0.1, 0.05), abs(rand2)), 1),
                spin_in_axis(vec3(vel.yx * vec2(-1, 1),0), momentum * 1.5 * (10.0 + rand5 * 5.0))
            );
            break;
        case BIG_SHRAPNEL:
            float brown_color = 0.05 + 0.1 * rand1;
            attr = Attr(
                linear_motion(
                    vec3(0),
                    normalize(vec3(rand4, rand5, rand6)) * 15.0 + grav_vel(earth_gravity)
                ),
                vec3(5 * (1 - percent())),
                vec4(vec3(brown_color, brown_color / 2, 0), 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case FIREWORK_BLUE:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            momentum = 1.0 - 1.0 / (1 + lifetime() * 2.5);
            attr = Attr(
                normalize(vec3(rand1, rand2, rand3)) * (50.0 + rand0 * 5.0) * momentum + grav_vel(earth_gravity),
                vec3(4.0) * slow_end(0.2),
                vec4(mix(vec3(0.2, 0.2, 1), vec3(0, 0.3, 0.2), percent()) * (15.0 + sin(lifetime() * 8.0 + rand5 * 30.0) * 12.0), 1),
                spin_in_axis(vec3(1,1,1),percent() * rand1 * 30.0)
            );
            break;
        case FIREWORK_GREEN:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            momentum = 1.0 - 1.0 / (1 + lifetime() * 2.5);
            attr = Attr(
                normalize(vec3(rand1, rand2, rand3)) * (50.0 + rand0 * 5.0) * momentum + grav_vel(earth_gravity),
                vec3(4.0) * slow_end(0.2),
                vec4(mix(vec3(0.2, 1, 0.2), vec3(0.4, 0.3, 0), percent()) * (15.0 + sin(lifetime() * 8.0 + rand5 * 30.0) * 12.0), 1),
                spin_in_axis(vec3(1,1,1),percent() * rand1 * 30.0)
            );
            break;
        case FIREWORK_PURPLE:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            momentum = 1.0 - 1.0 / (1 + lifetime() * 2.5);
            attr = Attr(
                normalize(vec3(rand1, rand2, rand3)) * (50.0 + rand0 * 5.0) * momentum + grav_vel(earth_gravity),
                vec3(4.0) * slow_end(0.2),
                vec4(mix(vec3(0.5, 0.2, 1), vec3(0.2, 0.0, 0.1), percent()) * (15.0 + sin(lifetime() * 8.0 + rand5 * 30.0) * 12.0), 1),
                spin_in_axis(vec3(1,1,1),percent() * rand1 * 30.0)
            );
            break;
        case FIREWORK_RED:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            momentum = 1.0 - 1.0 / (1 + lifetime() * 2.5);
            attr = Attr(
                normalize(vec3(rand1, rand2, rand3)) * (50.0 + rand0 * 5.0) * momentum + grav_vel(earth_gravity),
                vec3(4.0) * slow_end(0.2),
                vec4(mix(vec3(1, 0.2, 0.2), vec3(0.4, 0.25, 0), percent()) * (15.0 + sin(lifetime() * 8.0 + rand5 * 30.0) * 12.0), 1),
                spin_in_axis(vec3(1,1,1),percent() * rand1 * 30.0)
            );
            break;
        case FIREWORK_WHITE:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            momentum = 1.0 - 1.0 / (1 + lifetime() * 2.5);
            attr = Attr(
                normalize(vec3(rand1, rand2, rand3)) * (50.0 + rand0 * 5.0) * momentum + grav_vel(earth_gravity),
                vec3(4.0) * slow_end(0.2),
                vec4(mix(vec3(0.7), vec3(0.1, 0.15, 0.2), percent()) * (15.0 + sin(lifetime() * 8.0 + rand5 * 30.0) * 12.0), 1),
                spin_in_axis(vec3(1,1,1),percent() * rand1 * 30.0)
            );
            break;
        case FIREWORK_YELLOW:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            momentum = 1.0 - 1.0 / (1 + lifetime() * 2.5);
            attr = Attr(
                normalize(vec3(rand1, rand2, rand3)) * (50.0 + rand0 * 5.0) * momentum + grav_vel(earth_gravity),
                vec3(4.0) * slow_end(0.2),
                vec4(mix(vec3(1, 0.8, 0), vec3(0.3, 0.1, 0.1), percent()) * (15.0 + sin(lifetime() * 8.0 + rand5 * 30.0) * 12.0), 1),
                spin_in_axis(vec3(1,1,1),percent() * rand1 * 30.0)
            );
            break;
        case LEAF:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(0, 0, -2)
                )
                    + vec3(sin(lifetime()), sin(lifetime() + 0.7), sin(lifetime() * 0.5)) * 2.0
                    + blown_by_wind(1.0, 1.0),
                vec3(4),
                vec4(vec3(0.2 + rand7 * 0.2, 0.2 + (0.25 + rand6 * 0.5) * 0.3, 0) * (0.75 + rand1 * 0.5), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 5)
            );
            break;
        case SNOW:
            float height = mix(-4, 60, pow(start_end(1, 0), 3));
            vec3 offset = linear_motion(vec3(0), vec3(inst_start_wind_vel, 0.0));
            float end_alt = alt_at(start_pos.xy + offset.xy);
            attr = Attr(
                offset + vec3(0, 0, end_alt - start_pos.z + height) + vec3(sin(lifetime()), sin(lifetime() + 0.7), sin(lifetime() * 0.5)) * 3,
                vec3(mix(4, 0, pow(start_end(1, 0), 4))),
                vec4(1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 5)
            );
            break;
        case FIREFLY:
            float raise = pow(sin(3.1416 * lifetime() / inst_lifespan), 0.2);
            attr = Attr(
                vec3(0, 0, raise * 5.0) + vec3(
                    sin(lifetime() * 1.0 + rand0) + sin(lifetime() * 7.0 + rand3) * 0.3,
                    sin(lifetime() * 3.0 + rand1) + sin(lifetime() * 8.0 + rand4) * 0.3,
                    sin(lifetime() * 2.0 + rand2) + sin(lifetime() * 9.0 + rand5) * 0.3
                ),
                vec3(raise),
                vec4(vec3(10.3, 9, 1.5), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 5)
            );
            break;
        case BEE:
            float lower = pow(sin(3.1416 * lifetime() / inst_lifespan), 0.2);
            attr = Attr(
                vec3(0, 0, lower * -0.5) + vec3(
                    sin(lifetime() * 2.0 + rand0) + sin(lifetime() * 9.0 + rand3) * 0.3,
                    sin(lifetime() * 3.0 + rand1) + sin(lifetime() * 10.0 + rand4) * 0.3,
                    sin(lifetime() * 4.0 + rand2) + sin(lifetime() * 11.0 + rand5) * 0.3
                ) * 0.5,
                vec3(lower),
                vec4(vec3(1, 0.7, 0), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 5)
            );
            break;
        case GROUND_SHOCKWAVE:
            attr = Attr(
                vec3(0.0),
                vec3(11.0, 11.0, (33.0 * rand0 * sin(2.0 * lifetime() * 3.14 * 2.0))) / 3,
                vec4(vec3(0.32 + (rand0 * 0.04), 0.22 + (rand1 * 0.03), 0.05 + (rand2 * 0.01)), 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case ENERGY_HEALING:
            f_reflect = 0.0;
            float spiral_radius = start_end(1 - pow(abs(rand5), 5), 1) * length(inst_dir);
            attr = Attr(
                spiral_motion(vec3(0, 0, rand3 + 1), spiral_radius, lifetime(), abs(rand0), rand1 * 2 * PI) + vec3(0, 0, rand2),
                vec3(6 * abs(rand4) * (1 - slow_start(2)) * pow(spiral_radius / length(inst_dir), 0.5)),
                vec4(vec3(0, 1.7, 0.7) * 3, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3)
            );
            break;
        case LIFESTEAL_BEAM:
            f_reflect = 0.0;
            float green_col = 0.8 + 0.8 * sin(tick_loop(2 * PI, 5, lifetime() * 5));
            float purple_col = 0.6 + 0.5 * sin(loop_inst_time(2 * PI, 4)) - min(max(green_col - 1, 0), 0.3);
            float red_col = 1.15 + 0.1 * sin(loop_inst_time(2 * PI, 3)) - min(max(green_col - 1, 0), 0.3) - max(purple_col - 0.5, 0);
            attr = Attr(
                spiral_motion(inst_dir, 0.3 * (floor(2 * rand0 + 0.5) - 0.5) * min(linear_scale(10), 1), lifetime() / inst_lifespan, 10.0, loop_inst_time(2.0 * PI, 1.0)),
                vec3((1.7 - 0.7 * abs(floor(2 * rand0 - 0.5) + 0.5)) * (1.5 + 0.5 * sin(tick_loop(2 * PI, 10, -lifetime() * 4)))),
                vec4(vec3(red_col + purple_col * 0.6, green_col + purple_col * 0.35, purple_col), 1),
                spin_in_axis(inst_dir, tick_loop(2 * PI))
            );
            break;
        case ENERGY_NATURE:
            f_reflect = 0.0;
            spiral_radius = start_end(1 - pow(abs(rand5), 5), 1) * length(inst_dir);
            attr = Attr(
                spiral_motion(vec3(0, 0, rand3 + 1), spiral_radius, lifetime(), abs(rand0), rand1 * 2 * PI) + vec3(0, 0, rand2),
                vec3(6 * abs(rand4) * (1 - slow_start(2)) * pow(spiral_radius / length(inst_dir), 0.5)),
                vec4(vec3(0, 1.7, 1.3), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3)
            );
            break;
        case FLAMETHROWER:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1 + blown_by_wind(1.0, 0.1) * 2.5,
                vec3((2.5 * (1 - slow_start(0.2)))),
                vec4(6, 3 + rand5 * 0.6 - 0.8 * percent(), 0.4, 1) * start_end(1.0, 0.0),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case EXPLOSION:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            attr = Attr(
                inst_dir * ((rand0+1.0)/2 + 0.4) * slow_end(0.25) + 0.3 * grav_vel(earth_gravity),
                vec3((3 * (1 - slow_start(0.1)))),
                vec4(6, 3 + rand5 * 0.3 - 0.8 * percent(), 0.4, 1) * start_end(3.0, 0.0),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case ICE:
            f_reflect = 0.0; // Ice doesn't reflect to look like magic
            float ice_color = 1.9 + rand5 * 0.3;
            attr = Attr(
                inst_dir * ((rand0+1.0)/2 + 0.4) * slow_end(2.0) + 0.3 * grav_vel(earth_gravity),
                vec3((5 * (1 - slow_start(.1)))),
                vec4(0.8 * ice_color, 0.9 * ice_color, ice_color, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 5 + 3 * rand9)
            );
            break;
        case FIRE_SHOCKWAVE:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            attr = Attr(
                vec3(rand0, rand1, lifetime() * 10 + rand2),
                vec3((5 * (1 - slow_start(0.5)))),
                vec4(6, 3 + rand5 * 0.6 - 0.8 * percent(), 0.4, 1),
                spin_in_axis(vec3(rand3, rand4, rand5), rand6)
            );
            break;
        case FIRE_LOW_SHOCKWAVE:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            attr = Attr(
                linear_motion(
                    vec3(0),
                    normalize(vec3(rand4, rand5, rand6)) * 15.0 + grav_vel(earth_gravity)
                ),
                vec3(5 * (1 - percent())),
                vec4(6, 3 + rand5 * 0.6 - 0.8 * percent(), 0.4, 1),
                spin_in_axis(vec3(rand3, rand4, rand5), rand6)
            );
            break;
        case CULTIST_FLAME:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            float purp_color = 0.1 + 0.2 * rand3;
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3((3.5 * (1 - slow_start(0.2)))),
                vec4(purp_color, 0.0, purp_color, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case STATIC_SMOKE:
            attr = Attr(
                vec3(0),
                vec3((0.5 * (1 - slow_start(0.8)))),
                vec4(1.0),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9)
            );
            break;
        case BLOOD:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    normalize(vec3(rand4, rand5, rand6)) * 5.0 + grav_vel(earth_gravity)
                ),
                vec3((2.0 * (1 - slow_start(0.8)))),
                vec4(1, 0, 0, 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case ENRAGED:
            f_reflect = 0.0;
            float red_color = 1.2 + 0.3 * rand3;
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3((3.5 * (1 - slow_start(0.2)))),
                vec4(red_color, 0.0, 0.0, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case LASER:
            f_reflect = 0.0;
            vec3 perp_axis = normalize(cross(inst_dir, vec3(0.0, 0.0, 1.0)));
            attr = Attr(
                inst_dir * percent(),
                vec3(1.0, 1.0, 50.0),
                vec4(vec3(2.0, 0.0, 0.0), 1),
                spin_in_axis(perp_axis, asin(inst_dir.z / length(inst_dir)) + PI / 2.0)
            );
            break;
        case BUBBLES:
            f_reflect = 0.0; // Magic water doesn't reflect light, it emits it
            float blue_color = 1.5 + 0.2 * rand3 + 1.5 * max(floor(rand4 + 0.3), 0.0);
            float size = 8.0 * (1 - slow_start(0.1)) * slow_end(0.15);
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(size),
                vec4(0.5 * blue_color, 0.75 * blue_color, blue_color, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case WATER:
            f_reflect = 0.0; // Magic water doesn't reflect light, it emits it
            blue_color = 1.25 + 0.2 * rand3 + 1.75 * max(floor(rand4 + 0.15), 0.0);
            size = 8.0 * (1 - slow_start(0.1)) * slow_end(0.15);
            attr = Attr(
                (inst_dir * slow_end(0.2)) + vec3(rand0, rand1, rand2) * 0.5,
                vec3(size),
                vec4(0.5 * blue_color, 0.9 * blue_color, blue_color, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 5 + 3 * rand9)
            );
            break;
        case ICE_SPIKES:
            f_reflect = 0.0; // Ice doesn't reflect to look like magic
            ice_color = 1.7 + rand5 * 0.2;
            attr = Attr(
                vec3(0.0),
                vec3(11.0, 11.0, 11.0 * length(inst_dir) * 2.0 * (0.5 - abs(0.5 - slow_end(0.5)))) / 3,
                vec4(0.8 * ice_color, 0.9 * ice_color, ice_color, 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case DRIP:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    normalize(vec3(rand4, rand5, rand6))  + grav_vel(earth_gravity)
                ),
                vec3((2.0 * (1 - slow_start(0.2)))),
                vec4(1, 1, 0, 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case TORNADO:
            f_reflect = 0.0;
            attr = Attr(
                spiral_motion(vec3(0, 0, 5), abs(rand0) + abs(rand1) * percent() * 3.0, percent(), 15.0 * abs(rand2), rand3),
                vec3((2.5 * (1 - slow_start(0.05)))),
                vec4(vec3(1.2 + 0.5 * percent()), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case DEATH:
            f_reflect = 0.0;
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(rand2 * 0.02, rand3 * 0.02, 2.0 + rand4 * 0.6)
                ),
                vec3((1.2 * (1 - slow_start(.1)))),
                vec4(vec3(1.2 + 0.5 * percent()), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case ENERGY_BUFFING:
            f_reflect = 0.0;
            spiral_radius = start_end(1 - pow(abs(rand5), 5), 1) * length(inst_dir);
            attr = Attr(
                spiral_motion(vec3(0, 0, rand3 + 1), spiral_radius, lifetime(), abs(rand0), rand1 * 2 * PI) + vec3(0, 0, rand2),
                vec3(6 * abs(rand4) * (1 - slow_start(2)) * pow(spiral_radius / length(inst_dir), 0.5)),
                vec4(vec3(1.4), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3)
            );
            break;
        case WEB_STRAND:
            f_reflect = 0.0;
            perp_axis = normalize(cross(inst_dir, vec3(0.0, 0.0, 1.0)));
            attr = Attr(
                inst_dir * percent(),
                vec3(1.0, 1.0, 50.0),
                vec4(vec3(2.0), 1),
                spin_in_axis(perp_axis, asin(inst_dir.z / length(inst_dir)) + PI / 2.0)
            );
            break;
        case LIGHTNING:
            f_reflect = 0.0;
            perp_axis = normalize(cross(inst_dir, vec3(0.0, 0.0, 1.0)));
            float z = inst_dir.z * (percent() - 1.0);
            vec3 start_off = vec3(abs(fract(vec3(vec2(z) * vec2(0.015, 0.01), 0)) - 0.5) * z * 0.4);
            attr = Attr(
                inst_dir * percent() + start_off,
                vec3(max(3.0, 0.25 * length(start_pos + inst_dir * percent()))),
                vec4(10.0, 10.0, 25.0, 1.0),// * (1.0 - length(inst_dir) * 0.1),
                identity()//spin_in_axis(perp_axis, asin(inst_dir.z / length(inst_dir)) + PI / 2.0)
            );
            break;
        case STEAM:
            f_reflect = 0.0; // Magic steam doesn't reflect light, it emits it
            float steam_size = 8.0 * (1 - slow_start(0.1)) * slow_end(0.15);
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(steam_size),
                vec4(vec3(0.7, 2.7, 1.3), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case BARRELORGAN:
            attr = Attr(
                linear_motion(
                    vec3(rand0 * 0.25, rand1 * 0.25, 1.7 + rand5),
                    vec3(rand2 * 0.1, rand3 * 0.1, 1.0 + rand4 * 0.5)
                ),
                vec3(exp_scale(-0.2)) * rand0,
                vec4(vec3(0.7, 2.7, 1.3), 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case POTION_SICKNESS:
            attr = Attr(
                quadratic_bezier_motion(
                    vec3(0.0),
                    vec3(inst_dir.xy, 0.0),
                    inst_dir
                ),
                vec3((2.0 * (1 - slow_start(0.8)))),
                vec4(0.075, 0.625, 0, 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case GIGA_SNOW:
            f_reflect = 0.0;
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3((3.5 * (1 - slow_start(0.2)))),
                vec4(vec3(2, 2, 2), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case CYCLOPS_CHARGE:
            f_reflect = 0.0;
            float burn_size = 8.0 * (1 - slow_start(0.1)) * slow_end(0.15);
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(burn_size),
                vec4(vec3(6.9, 0.0, 0.0), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case PORTAL_FIZZ:
            attr = Attr(
                inst_dir * (0.7 + pow(percent(), 5)) + vec3(
                    sin(lifetime() * 1.25 + rand0 * 10) + sin(lifetime() * 1.3 + rand3 * 10),
                    sin(lifetime() * 1.2 + rand1 * 10) + sin(lifetime() * 1.4 + rand4 * 10),
                    sin(lifetime() * 5 + rand2)
                ) * 0.03,
                vec3(pow(1.0 - abs(percent() - 0.5) * 2.0, 0.2)),
                mix(
                    vec4(mix(vec3(0.4, 0.8, 0.2), vec3(5, 10, 2), pow(percent(), 2)), 1),
                    vec4(mix(vec3(0.6, 0.2, 0.8), vec3(9, 2, 10), pow(percent(), 2)), 1),
                    clamp((dot(normalize(focus_pos.xyz - start_pos), inst_dir) - 0.25) * 3.0, 0.0, 1.0)
                ),
                /* vec4(vec3(1.8 - percent() * 2, 0.4 + percent() * 2, 5.0 + rand6), 1), */
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 5)
            );
            break;
        case INK:
            f_reflect = 0.0; // Magic water doesn't reflect light, it emits it
            float black_color = 0.3 + 0.2 * rand3 + 0.3 * max(floor(rand4 + 0.3), 0.0);
            float ink_size = 8.0 * (1 - slow_start(0.1)) * slow_end(0.15);
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(ink_size),
                vec4(0.5 * black_color, 0.75 * black_color, black_color, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case ICE_WHIRLWIND:
            f_reflect = 0.0;
            attr = Attr(
                spiral_motion(vec3(0, 0, 3), abs(rand0) * 3 + percent() * 20.5, percent(), -8.0 + (rand0 * 3), rand1 * 360.),
                vec3((-2.5 * (1 - slow_start(0.05)))),
                vec4(vec3(1.3, 1.8, 2), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIERY_BURST:
            f_reflect = 0.0;
            float fiery_radius = start_end(1.0 - pow(abs(rand5), 5.0), 1.0) * length(inst_dir);
            float fiery_color1 = (7.0 + 1.0 * percent()) * min(1.0, percent() * 4.0) * 1.5;
            float fiery_color2 = (4.0 - 2.0 * percent() + 1.3 * rand5 * slow_end(0.0)) * min(1.0, percent() * 4.0) * 1.3;
            float fiery_color3 = 1.0 + 0.3 * percent();
            attr = Attr(
                spiral_motion(
                    vec3(
                        0.0,
                        0.0,
                        (rand3 + 1.0)
                        * max(
                            ((percent() * 8.0) * (1.0 - step(0.2, percent()))),
                            ((2.0 * (1.0 - percent())) * (step(0.2, percent())))
                        )
                    ),
                    fiery_radius,
                    lifetime(),
                    max(0.1, step(0.6, percent())) * 3.0 * abs(rand0),
                    rand1 * 2.0 * PI) + vec3(0.0, 0.0, rand2),
                vec3(6.0 * abs(rand4) * (1.0 - slow_start(2.0)) * pow(fiery_radius / length(inst_dir), 0.5)),
                vec4(fiery_color1, fiery_color2, fiery_color3, slow_end(0.4)),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3.0)
            );
            break;
        case FIERY_BURST_VORTEX:
            f_reflect = 0.0;
            float fiery_vortex_color1 = (min(1, percent() * 2) * (5 + 1 * percent() + 1 * slow_end(0)) * 1.5);
            float fiery_vortex_color2 = (min(1, percent() * 2) * (4 - 2.4 * percent() + 1.3 * rand5 * slow_end(0)) * 1.3);
            float fiery_vortex_color3 = 0;
            attr = Attr(
                spiral_motion(
                    vec3(
                        0,
                        0,
                        (0 + 0.5 * rand4 ) + 4.0
                            * max(
                                ((percent() * 8) * (1 - step(0.2, percent()))), // first 20% of lifetime particle moves up, then goes down
                                ((2 * (1 - percent())) * (step(0.2, percent())))// to avoid tearing multi should have same proportion as edge(here: 8 before, 2 after)
                            )
                    ),
                    abs(rand0) + 0.5 * 10 * percent(),
                    percent(),
                    10.0 * abs(rand2),
                    rand3),
                vec3((2.5 * (1 - slow_start(0.05)))),
                vec4(fiery_vortex_color1, fiery_vortex_color2, fiery_vortex_color3, start_end(0.5, 1.5) * abs(rand2)),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIERY_BURST_SPARKS:
            f_reflect = 0.0;
            // sparks should flicker, so it stops glowing for 18% of time 4 times per second, same thing used in 4th float of RGBA vector
            float fiery_sparks_color1 = 2 + 1 * rand2 + 2 * step(0.18, fract(tick.x*4));
            float fiery_sparks_color2 = 4 + 1 * rand2 + 4 * step(0.18, fract(tick.x*4));
            float fiery_sparks_color3 = 4 + 6 * step(0.18, fract(tick.x*4));
            attr = Attr(
                spiral_motion(vec3(0, 0, 5), abs(rand0) + abs(rand1) * percent() * 4.0, percent(), 8.0 * abs(rand2), 0.0),
                vec3((2.5 * (1 - slow_start(0.05)))),
                vec4(fiery_sparks_color1, fiery_sparks_color2, fiery_sparks_color3, 0.5 + 0.5 * step(0.18, fract(tick.x*4))),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIERY_BURST_ASH:
            f_reflect = 0.0;
            /// inst_dir holds info about:
            /// .x: radius of random spawn
            float fiery_ash_rand_rad = inst_dir.x;
            /// .y:
            ///     in fract:   relative time of "setting on fire"
            ///     in int:     radius of curve
            float fiery_ash_radius = floor(inst_dir.y);
            float fiery_ash_edge = inst_dir.y - fiery_ash_radius;
            /// .z: height of the flight
            float fiery_ash_height = inst_dir.z;
            // {FOR PHOENIX "from the ashes"}sets ash on fire at 0.4 of lifetime, then makes it lose glow, representing losing heat
            float fiery_ash_color1 = (2 + 1 * percent() * slow_end(0))
                            * (max(
                                1,
                                8 * step(fiery_ash_edge, percent()) * (1.4 - percent()))
                            );
            float fiery_ash_color2 = (2 - 1 * percent() + 0.3 * abs(rand5) * slow_end(0.5))
                            * (max(
                                1,
                                6.5 * step(fiery_ash_edge, percent()) * (1.4 - percent()))
                            );
            float fiery_ash_color3 = 1.5;
            attr = Attr(
                spiral_motion(
                    vec3(
                        0.0,
                        0.0,
                        fiery_ash_height// {FOR PHOENIX "from the ashes"} 8.58
                    ),
                    abs(rand0 / 2.0 + 1.0)
                        * max(1.0, ((percent() * fiery_ash_radius * 0.8) * (1.0 - step(0.2, percent())))) // part of lifetime particle moves to periphery
                        * max(1.0, (fiery_ash_radius * 0.2 * (1.0 - percent()) * (step(0.2, percent())))),// then back to center
                    percent(),
                    6.0 * abs(rand2),
                    rand3 * 5.0
                )
                + vec3((rand6 + rand5) * fiery_ash_rand_rad, (rand8 + rand3) * fiery_ash_rand_rad, abs(rand0)),//makes it apear randomly above base animation (Fiery Burst)
                vec3((2.5 * (1 - slow_start(0.0)))),
                vec4(fiery_ash_color1, fiery_ash_color2, fiery_ash_color3, abs(rand2) * slow_end(0.3)),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIERY_TORNADO:
            f_reflect = 0.0;
            float fiery_tornado_color1 = (2.6 + 0.5 * percent())
                            * 4.0 * max(0.5, percent() * 1.2);
            float fiery_tornado_color2 = (1.7 - 0.6 * pow(1.0 - percent(), 2.0) + 0.3 * abs(rand5))
                            * 2.0 * max(0.45, percent() * 1.2);
            float fiery_tornado_color3 = 1.5 * max(0.6, percent());
            attr = Attr(
                spiral_motion(vec3(0, 0, 6.0 + rand3 * 1.5), abs(rand0) + abs(rand1) * percent() * 3.0, percent(), 15.0 * abs(rand2), -inst_time),
                vec3((2.5 * (1 - slow_start(0.05)))),
                vec4(fiery_tornado_color1, fiery_tornado_color2, fiery_tornado_color3, 0.5),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case PHOENIX_CLOUD:
            float PC_spin =  floor(inst_dir.x);
            float refl = floor(inst_dir.y);
            float PC_size = floor(inst_dir.z);
            //best is 0.4 - reflects some light but only part as
            f_reflect = refl * 0.1;
            // modifies by + 5% to -15%, if color is less than 0.5 it will get from +10% to +25% to it's value
            float PC_rand_color_factor = rand0 * 0.05;
            float PC_R = inst_dir.x - PC_spin;
                PC_R += PC_R * PC_rand_color_factor * step(0.05, PC_R) * -abs(PC_rand_color_factor * 2.0)
                    + PC_R * (1.0 - step(0.05, PC_R)) * max(abs(PC_rand_color_factor), 0.02) * 5.0;
            float PC_G = inst_dir.y - refl;
                PC_G += PC_G * PC_rand_color_factor * step(0.05, PC_G) * -abs(PC_rand_color_factor * 2.0)
                    + PC_G * (1.0 - step(0.05, PC_G)) * max(abs(PC_rand_color_factor), 0.02) * 5.0;
            float PC_B = inst_dir.z - PC_size;
                PC_B += PC_B * PC_rand_color_factor * step(0.05, PC_B) * -abs(PC_rand_color_factor * 2.0)
                    + PC_B * (1.0 - step(0.05, PC_B)) * max(abs(PC_rand_color_factor), 0.02) * 5.0;
            attr = Attr(
                linear_motion(
                    vec3(0.0, 0.0, 0.0),
                    vec3(rand4, rand5, rand6 * 2.5)
                ),
                vec3(8.0 * min(percent() * 3.0, 1.0) * min((1.0 - percent()) * 2.0, 1.0)),
                vec4(
                    PC_R,
                    PC_G,
                    PC_B,
                    PC_size * 1.2) * 10.0,
                spin_in_axis(vec3(rand6 + rand5, rand7 + rand9, rand8 + rand2), percent() * PC_spin)
            );
            break;
        case FIERY_DROPLET_TRACE:
            float m_r = 4.0;
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            float prcnt = percent(); //idk if compiler would optimize it or not but as we have a lot of those particles... i'll just try
            float droplet_color1 = 1 * (5 + 1 * prcnt + 1 * slow_end(0)) * 1.5;
            float droplet_color2 = 1 * (4 - 2.4 * prcnt + 1.3 * rand5 * slow_end(0)) * 1.3;
            float droplet_color3 = 0;
            attr = Attr(
                quadratic_bezier_motion(
                    vec3(0.0),
                    vec3(m_r * rand0, m_r * rand1, 0.0),
                    vec3(m_r * rand0, m_r * rand1, 4.0)
                ),
                vec3(1),
                vec4(droplet_color1,
                    droplet_color2,
                    droplet_color3,
                    1 * prcnt * (1 - step(0.5, prcnt)) + (1 - prcnt) * (step(0.5, prcnt))),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case ENERGY_PHOENIX:
            f_reflect = 0.0;
            float fiery_r = (2 + 1 * percent() * slow_end(0))
                            * 6 * (1.4 - percent());
            float fiery_g = (2 - 1 * percent() + 0.3 * abs(rand5) * slow_end(0.5))
                            * 4.5 * (1.4 - percent());
            float fiery_b = 1.5;
            spiral_radius = length(inst_dir);
            attr = Attr(
                spiral_motion(vec3(0.0, 0.0, 0.01), spiral_radius + abs(rand1), lifetime() / 0.5, abs(rand0), rand1 * 2.0 * PI) + vec3(0.0, 0.0, rand2),
                vec3(6.0 * abs(rand4) * (1 - slow_start(2.0))),
                vec4(vec3(fiery_r, fiery_g, fiery_b), 1.0),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3.0)
            );
            break;
        case PHOENIX_BEAM:
            f_reflect = 0.0; // Fire doesn't reflect light, it emits it
            float beam_r = 6.0 - (4.0 * percent()) + 15.0 * fract(percent() * 4 + rand0 * rand0) * (1 - percent());
            float beam_g = 2.0 + 6.6 * fract(percent() * 4 + rand0 * rand0) * (1 - percent());
            float beam_b = 1.4;

            vec3 factor_rand = vec3((rand0 * 0.2) * (rand5 * 0.1) + rand6 * 0.9, (rand1 * 0.2) * (rand4 * 0.1) + rand7 * 0.9, (rand2 * 0.2) * (rand3 * 0.1) + rand8 * 0.9);
            start_pos += factor_rand + normalize(inst_dir) * 0.6;
            attr = Attr(
                spiral_motion(inst_dir - factor_rand * 0.4, 0.3 * ((rand2 + 0.5) * 5.5) * (1.0 - min(linear_scale(1.5), 1.0)), lifetime() / inst_lifespan, 24.0, -inst_time * 8.0),
                vec3((2.5 * (1 - slow_start(0.2)))),
                vec4(beam_r, beam_g, beam_b, 1.0),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10.0 + 3.0 * rand9)
            );
            break;
        case PHOENIX_BUILD_UP_AIM:

            f_reflect = 0.0; // Fire doesn't reflect light, it emits it

            float perc_t = percent(); // in case compiler wont optimize, idk

            float aim_r = rand0 * 0.25 + 3.0 + 4.5 * perc_t * (1 - step(0.79, perc_t)) + 8.0 * step(0.81, perc_t) * perc_t;
            float aim_g = rand0 * 0.25 + 2.0 - 1.0 * perc_t * (1 - step(0.79, perc_t)) + 2.0 * step(0.81, perc_t) * perc_t;
            float aim_b = 1.4 * ((1 - perc_t) + step(0.74, perc_t));


            vec3 dir_aim = inst_dir * 1.0;
            vec3 rand_pos_aim = (cross(
                (1.0 - 2.0 * step(0.0, rand2)) * normalize(inst_dir),
                vec3(0.0, 0.0, 1.0)));

            vec3 rand_fact = vec3(rand1 * 1, rand0 * 1, rand2 * 1);
            start_pos += vec3(0.0, 0.0, 5.0) + rand_fact;
            attr = Attr(
                spiral_motion(
                    inst_dir + vec3(0.0, 0.0, -(6.0 - 3.0 * pow(perc_t, 2.5))) - rand_fact,
                    1.2 * rand9 * max(1.0 - perc_t, 0.0),
                    perc_t,
                    6.0,
                    inst_time * 8.0),
                vec3((1.9 * (1 - slow_start(0.2)))),
                vec4(aim_r, aim_g, aim_b, 1.0),
                spin_in_axis(vec3(rand6, rand7, rand8), perc_t * 10.0 + 3.0 * rand9)
            );
            break;
        case CLAY_SHRAPNEL:
            float clay_color = 0.025 + 0.02 * rand1;
            attr = Attr(
                linear_motion(
                    vec3(0),
                    normalize(vec3(rand4, rand5, rand6)) * 15.0 + grav_vel(earth_gravity)
                ),
                vec3(5 * (1 - percent())),
                vec4(vec3(clay_color * 3, clay_color * 2, clay_color), 1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
        case AIRFLOW:
            perp_axis = normalize(cross(inst_dir, vec3(1.0, 0.0, 0.0)));
            attr = Attr(
                // offsets
                inst_dir * 0.2 * length(inst_dir) * percent() + inst_dir * percent() * 0.08,
                // scale
                vec3(
                    0.3 * length(inst_dir),
                    0.3 * length(inst_dir),
                    3.0 * length(inst_dir) * percent() * (1 - percent())
                ),
                // color
                vec4(1.1, 1.1, 1.1, 0.3),
                // rotation
                spin_in_axis(perp_axis, asin(inst_dir.z / length(inst_dir)) + PI / 2.0)
            );
            break;
        case SPORE:
            f_reflect = 1.0;
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(0, 0, -1.1)
                ) + vec3(sin((lifetime() + rand9 * 0.1) * 0.5) * 3.0, sin((lifetime() + rand8 * 0.1) * 0.5) * 3.0, sin(lifetime() * 0.5) * 1.5),
                vec3(0.4 + 0.4 * abs(sin(lifetime()))),
                vec4(vec3(0.8, 6.0 + rand6 * 1.75, 7.5 + (1.75 + rand5 * 0.5)), 1),
                spin_in_axis(vec3(rand1, rand2, rand3), rand4 * 1.5 + lifetime())
            );
            break;
        case SURPRISE_EGG:
            f_reflect = 0.0;
            // sparks should flicker, so it stops glowing for 18% of time 4 times per second, same thing used in 4th float of RGBA vector
            float egg_color1 = 2 + 1 * rand2 + 2 * step(0.18, fract(tick.x*4));
            float egg_color2 = 0 + 1 * rand2 + 4 * step(0.18, fract(tick.x*4));
            float egg_color3 = 2 + 6 * step(0.18, fract(tick.x*4));
            attr = Attr(
                spiral_motion(vec3(0, 0, 5), abs(rand0) + abs(rand1) * percent() * 4.0, percent(), 8.0 * abs(rand2), rand3),
                vec3((2.5 * (1 - slow_start(0.05)))),
                vec4(egg_color1, egg_color2, egg_color3, 0.5 + 0.5 * step(0.18, fract(tick.x*4))),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FLAME_TORNADO:
            f_reflect = 0.0;
            attr = Attr(
                spiral_motion(vec3(0, 0, 3), abs(rand0) * 3 + percent() * 70.0, percent(), -8.0 + (rand0 * 3), rand1 * 360.),
                vec3((-2.5 * (1 - slow_start(0.05)))),
                vec4(6, 3 + rand5 * 0.3 - 0.8 * percent(), 0.4, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case POISON:
            f_reflect = 0.0; // Poison doesn't reflect to look like magic
            float poison_color = 1.9 + rand5 * 0.3;
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3((3.5 * (1 - slow_start(0.2)))),
                vec4(0.3 * poison_color , 0.7 * poison_color , 0.37 * poison_color , 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case WATER_FOAM:
            f_reflect = 0.1;
            attr = Attr(
                vec3(inst_dir.xyz * percent() - vec3(0, 0, pow(lifetime(), 2) * earth_gravity)),
                vec3((1.0 * (1 - slow_start(0.2)))),
                vec4(0.5, 0.75, 1.0, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case ENGINE_JET:
            f_reflect = 0.0;
            attr = Attr(
                linear_motion(vec3(0), vec3(rand6 - 0.5, rand7 - 0.5, 3 + rand8 * 0.8)) + blown_by_wind(1.0, 0.25),
                vec3((2.5 * (1 - slow_start(0.05)))) + percent(),
                mix(
                    mix(vec4(15, 8, 4, 1), vec4(12, 4, 0.0, 1), percent()),
                    vec4(0.1, 0.1, 0.1, 1),
                    pow(percent(), 0.05)
                ),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 3 + 3 * rand9)
            );
            break;
        case TRANSFORMATION:
            f_reflect = 0.0;
            vec3 trans_colors[3] = vec3[3](
                // light blue
                vec3(0.35, 0.8, 0.95),
                // pink
                vec3(0.9, 0.62, 0.7),
                // white
                vec3(1)
            );
            uint color = uint(abs(rand0 * 1000.0)) % 3;
            float spiral = float((color + 1) * (uint(abs(rand1 * 1000.0)) % 3 + 1) - 1);
            float radius = abs(rand2) * percent() * 4.0 + abs(rand0);
            float frequency = 8.0 + rand3;
            attr = Attr(
                spiral_motion(vec3(0, 0, radius), radius, percent(), frequency, spiral / 9.0 * 2.0 * PI * frequency + radius),
                vec3((2.5 * (1 - slow_start(0.05)))),
                vec4(trans_colors[color] * 2.2, 1.0),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIRE_GIGAS_ASH:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(0, 0, -2)
                ) + vec3(sin(lifetime()), sin(lifetime() + 0.7), sin(lifetime() * 0.5)) * 2.0,
                vec3(4),
                vec4(vec3(0.1 + rand1 * 0.1, 0.1 + rand1 * 0.1, 0.1 + rand1 * 0.1), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 5)
            );
            break;
        case FIRE_GIGAS_WHIRLWIND:
            f_reflect = 0.0;
            attr = Attr(
                spiral_motion(vec3(0, 0, -2), abs(rand0) * 3 + percent() * 11.0, percent(), 4.0 - (rand0 * 3), rand1 * 360.0),
                vec3((-2.5 * (1 - slow_start(0.05)))),
                vec4(mix(vec3(10, 6, 3), vec3(1, 0.2, 0.2), percent()), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIRE_GIGAS_OVERHEAT:
            f_reflect = 0.0;
            attr = Attr(
                (inst_dir * slow_end(0.2)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(((6.5 + 3.5 * rand0) * (1 - min(slow_start(0.2), 0.5)))),
                vec4(mix(vec3(4, 2, 0.4), vec3(2, 1.0, 0.2), percent()), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FIRE_GIGAS_EXPLOSION:
            f_reflect = 0.0;
            attr = Attr(
                inst_dir * slow_end(0.05),
                vec3(((3 + 3 * rand0) * (1 - slow_start(0.1)))),
                vec4(5, 3 + rand5 * 0.3 - 0.8 * percent(), 0.4, 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 5 + 3 * rand9)
            );
            break;
        case FIRE_PILLAR_INDICATOR:
            f_reflect = 0.0;
            attr = Attr(
                spiral_motion(vec3(0, 0, 0.1), (length(inst_dir) + 0.8) * sqrt(percent()), percent(), start_end(6.0, 2.0 + 0.2 * rand0), 2 * PI * rand1),
                vec3((2.5 * (1 - slow_start(0.02)))),
                vec4(mix(vec3(3.0, 1.3, 0.8), vec3(2.0 + 0.1 * rand2, 0.8 + 0.1 * rand3, 0.3 + 0.1 * rand4), percent()), 0.8),
                spin_in_axis(vec3(rand5, rand6, rand7), percent() * 8 + 3 * rand8)
            );
            break;
        case FIRE_PILLAR:
            f_reflect = 0.0;
            attr = Attr(
                (1.3 * (1 - pow(rand0, 2)) * inst_dir * percent()) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(((5.0 + 3.0 * pow(rand0, 2)) * (1 - min(slow_start(0.05), 0.8)))),
                vec4(mix(vec3(5.0, 2.0 + 1.0 * rand2, 0.4), vec3(4.0, 1.2, 0.4), pow(percent(), 3)), 0.7),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case PIPE_SMOKE:
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(rand2 * 0.1, rand3 * 0.1, 1.0 + rand4 * 0.1)
                ) + blown_by_wind(2.0, 0.1),
                vec3(1.0 - slow_start(0.01)) * 0.5,
                vec4(vec3(0.8, 0.8, 1) * 0.125 * (3.8 + rand0), start_end(1.0, 0.0)),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 0.5)
            );
            break;
        case TRAIN_SMOKE:
            attr = Attr(
                vec3(rand2 * 4, rand3 * 4, 15 + rand4 * 3) * pow(lifetime(), 0.5) + blown_by_wind(1.0, 1.0),
                vec3(mix(15, 20, lifetime())),
                vec4(vec3(0.8, 0.8, 1) * 0.125 * (1.8 + rand0), start_end(1.0, 0.0)),
                spin_in_axis(vec3(rand6, rand7, rand8), rand9 * 3 + lifetime() * 0.5)
            );
            break;
        case BUBBLE:
            f_reflect = 1.0;
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(sin(lifetime() * vec2(rand2 * 5.0, rand3 * 3.0)) * 0.5, 1.0 + rand4 * 0.1)
                ),
                vec3(1.0 - slow_start(0.1)) * 1.5 * (1.0 + sin(lifetime() * 20.0) * 0.3 + rand2 * 0.3),
                vec4(mix(vec3(0.4, 0.7, 0.8), vec3(0.2, 0.75, 1.0), abs(rand3)), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 5 + 3 * rand9)
            );
            break;
        case BUBBLE_AMBIENT:
            f_reflect = 1.0;
            attr = Attr(
                vec3(sin(lifetime() * vec2(1.5, 3.0)) * 0.5, 30) * (percent() - 1.0),
                vec3(1.0 - slow_start(0.01)) * 1.5 * (1.0 + sin(lifetime() * 20.0) * 0.3 + rand2 * 0.3),
                vec4(mix(vec3(0.4, 0.7, 0.8), vec3(0.2, 0.75, 1.0), abs(rand3)), 1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 40 + 3 * rand9)
            );
            break;
        case ELEPHANT_VACUUM:
            float vacuum_particle_size = 4.0 * (1 - slow_start(0.1)) * slow_end(0.15);
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1,
                vec3(vacuum_particle_size),
                vec4(0.4, 0.4, 0.4, 0.1),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case ELECTRIC_SPARKS:
            float len = length(inst_dir) * 5 * percent() * (rand8 + 0.5);
            float electric_arc_color = rand1 * 2 + 8;
            float electric_arc_width = rand4 * 0.1 + 0.15;
            attr = Attr(
                inst_dir / 2 * percent() + vec3(rand5, rand6, rand7) * 0.1,
                vec3(len, electric_arc_width, electric_arc_width),
                vec4(electric_arc_color + rand2, electric_arc_color / 3, electric_arc_color + rand3, 1),
                align_to_axis(inst_dir)
            );
            break;
        case FLAMETHROWER_BLUE:
            f_reflect = 0.0;
            attr = Attr(
                (inst_dir * slow_end(1.5)) + vec3(rand0, rand1, rand2) * (percent() + 2) * 0.1 + blown_by_wind(1.0, 0.1) * 2.5,
                vec3((2.5 * (1 - slow_start(0.2)))),
                vec4(0.4, 3 + rand5 * 0.6 - 0.8 * percent(), 6, 1) * start_end(1.0, 0.0),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 10 + 3 * rand9)
            );
            break;
        case FLAME_CLOAK_ORBIT:
            f_reflect = 0.0;
            attr = Attr(
                spiral_motion(
                    vec3(0.0, 0.0, 2.5 + rand3 * 0.4),
                    0.35 * abs(rand0 + 0.5),
                    percent(),
                    10.0 * sign(rand2),
                    rand1 * 2.0 * PI
                ) + vec3(0.0, 0.0, rand4 * 0.2),
                vec3(1.8 * (1.0 - slow_start(0.15)) * slow_end(0.15)),
                vec4(5.0 + rand5 * 0.5, 2.5 - 1.5 * percent(), 0.3, 0.65),
                spin_in_axis(vec3(rand6, rand7, rand8), percent() * 6.0 + rand9 * 2.0)
            );
            break;
        case DUST:
            vel = vec2(rand4, rand5);
            momentum = 1.0 - 1.0 / (1 + lifetime() * 1.0);
            attr = Attr(
                vec3(
                    vel * 0.2 + vel * momentum,
                    on_floor(0.1, 0.25, linear_motion(vec3(0), vec3(vec2(0), 3.0 + rand6) + grav_vel(earth_gravity))).z
                ),
                vec3(1.0 - slow_start(0.05)) * 1.5,
                vec4(min(srgb_to_linear(inst_dir) * (1.0 + rand2 * 0.35), vec3(1)), 1),
                spin_in_axis(vec3(1,0,1), percent() * 3.0 + rand5 * 25.0)
            );
            break;
        case CAVE_DUST:
            vel = vec2(rand4, rand5);
            momentum = 1.0 - 1.0 / (1 + lifetime() * 1.0);
            attr = Attr(
                linear_motion(
                    vec3(0),
                    vec3(0, 0, -1)
                )
                    + vec3(sin(lifetime()), sin(lifetime() + 0.7), sin(lifetime() * 0.5)) * 0.5,
                vec3(1.0 - slow_start(0.05)),
                vec4(0.6, 0.65, 0.75, 1),
                spin_in_axis(vec3(1,1,1), lifetime() * 2.0)
            );
            break;
        default:
            attr = Attr(
                linear_motion(
                    vec3(rand0 * 0.25, rand1 * 0.25, 1.7 + rand5),
                    vec3(rand2 * 0.1, rand3 * 0.1, 1.0 + rand4 * 0.5)
                ),
                vec3(exp_scale(-0.2)) * rand0,
                vec4(1),
                spin_in_axis(vec3(1,0,0),0)
            );
            break;
    }

    // Temporary: use shrinking particles as a substitute for fading ones
    attr.scale *= pow(attr.col.a, 0.25);

    f_pos = start_pos + (v_pos * attr.scale * SCALE * mat3(attr.rot) + attr.offs);

    #ifdef EXPERIMENTAL_CURVEDWORLD
        f_pos.z -= pow(distance(f_pos.xy + focus_off.xy, focus_pos.xy + focus_off.xy) * 0.05, 2);
    #endif

    // First 3 normals are negative, next 3 are positive
    // TODO: Make particle normals match orientation
    vec4 normals[6] = vec4[](
        vec4(-1,0,0,0),
        vec4(1,0,0,0),
        vec4(0,-1,0,0),
        vec4(0,1,0,0),
        vec4(0,0,-1,0),
        vec4(0,0,1,0)
    );
    f_norm = normalize(((normals[(v_norm_ao >> 0) & 0x7u]) * attr.rot).xyz);

    f_col = vec4(attr.col.rgb, attr.col.a);

    f_mode = inst_mode;
    f_voxel_light = inst_voxel_light;

    gl_Position =
        all_mat *
        vec4(f_pos, 1);
}
