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


#define LIGHTING_TYPE (LIGHTING_TYPE_TRANSMISSION | LIGHTING_TYPE_REFLECTION)

#define LIGHTING_REFLECTION_KIND LIGHTING_REFLECTION_KIND_SPECULAR

#if (FLUID_MODE == FLUID_MODE_LOW)
#define LIGHTING_TRANSPORT_MODE LIGHTING_TRANSPORT_MODE_IMPORTANCE
#elif (FLUID_MODE >= FLUID_MODE_MEDIUM)
#define LIGHTING_TRANSPORT_MODE LIGHTING_TRANSPORT_MODE_RADIANCE
#endif

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


layout(location = 0) out vec2 uv;

void main() {
    // Generate fullscreen triangle
    vec2 v_pos = vec2(
        float(gl_VertexIndex / 2) * 4.0 - 1.0,
        float(gl_VertexIndex % 2) * 4.0 - 1.0
    );

    uv = (v_pos * vec2(1.0, -1.0) + 1.0) * 0.5;

    gl_Position = vec4(v_pos, 0.0, 1.0);
}
