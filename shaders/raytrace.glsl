#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D img;
layout(set = 0, binding = 1) uniform readonly Input {
    float time;
};

struct Surface {
    vec3 col;
    float reflectivity;
};

struct Sphere {
    vec3 pos;
    float rad;
    Surface surface;
};

struct Plane {
    vec3 pos;
    vec3 norm;
    Surface surface;
};

struct Light {
    vec3 pos;
    float brightness;
    vec3 direction;
};

struct Ray {
    vec3 origin;
    vec3 direction;
};

struct Intersect {
    float dist;
    vec3 norm;
    Surface surface;
};

// An intersect with a distance of 0. Used to represent a miss
const Intersect miss = Intersect(0.0, vec3(0), Surface(vec3(0),0.0));

// Ray-Sphere intersection
Intersect intersect(const in Ray ray, const in Sphere s) {
    float t = dot(ray.direction, s.pos - ray.origin);
    vec3 p = ray.origin + ray.direction * t;
    float y = length(s.pos - p);
    if (s.rad >= y) { 
        float x = sqrt(s.rad * s.rad - y * y);
        float t1 = t - x;
        float t2 = t + x;
        float tc = min(t1, t2);
        if (tc < 0.0) {
            return miss;
        }
        return Intersect(tc, (ray.origin + ray.direction*tc - s.pos)/s.rad, s.surface);
    } else {
        return miss;
    }
}

// Ray-Plane intersection
Intersect intersect(Ray ray, Plane p) {
    float denom = dot(p.norm, ray.direction);
    if (denom > 1e-3) {
        vec3 v = p.pos - ray.origin;
        float dist = dot(v,p.norm) / denom;
        if (dist >= 0.0) {
            return Intersect(dist, -p.norm, p.surface);
        }
    }
    return miss;
}

Ray createPrimeRay(const in vec2 uv) {
    Ray ray = Ray(vec3(0),normalize(vec3(uv.x*1.5,uv.y*1.5, -1.0)));
    return ray;
}

// Trace a ray. Returns the intersect with the shortest distance
Intersect trace(const in Ray ray) {
    const int num_spheres = 3;
    Sphere spheres [num_spheres];

    spheres[0] = Sphere(vec3(0.0,0.0,-4.0),1.0,Surface(vec3(1.0),0.7));
    spheres[1] = Sphere(vec3(0.5*cos(time),0.5*sin(time*3.14159)+0.1,-3.0),0.2,Surface(vec3(1.0,0.0,0.0), 0.0));
    spheres[2] = Sphere(vec3(2.0,-0.5,-4.0),0.5,Surface(vec3(0.2,0.7,0.0),0.0));

    const int num_planes = 1;
    Plane planes [num_planes];
    planes[0] = Plane(vec3(0.0,-1.0,0.0),vec3(0.0,-1.0,0.0),Surface(vec3(0.0,0.0,1.0),0.5));

    Intersect closest = miss;

    for (int i = 0; i < num_spheres; i++) {
        Intersect intersect = intersect(ray, spheres[i]);
        if (closest.dist == 0.0 && intersect.dist > 0.0) {
            closest = intersect;
        } else if (intersect.dist > 0.0 && intersect.dist < closest.dist) {
            closest = intersect;
        }
    }
    for (int i = 0; i < num_planes; i++) {
        Intersect intersect = intersect(ray, planes[i]);
        if (closest.dist == 0.0 && intersect.dist > 0.0) {
            closest = intersect;
        } else if (intersect.dist > 0.0 && intersect.dist < closest.dist) {
            closest = intersect;
        }
    }

    return closest;
}

// Get the color to be drawn on screen.
vec3 radience(Ray ray) {
    vec3 color = vec3(0.0);
    const float EPSILON = 1e-3;
    const float GAMMA = 2.2;

    const int num_lights = 2;
    Light lights [num_lights];
    lights[0] = Light(vec3(-1.0, 0.8*sin(time), -2.0), 20.0, vec3(0.0));
    lights[1] = Light(vec3(0.0), 0.5, vec3(0.0,-1.0,0.0));

    const int recursive_depth = 4;

    Intersect intersect;
    float prev_reflectivity = 1.0;
    vec3 fresnel = vec3(0.0), mask = vec3(1.0);

    for (int i = 0; i < recursive_depth; i++) {
        vec3 shaded_color = vec3(0.0);
        intersect = trace(ray);

        if (intersect != miss) {
            vec3 hit_point = ray.origin + ray.direction * intersect.dist;

            // fresnel
            vec3 r0 = intersect.surface.col.rgb * intersect.surface.reflectivity;
            float hv = clamp(dot(intersect.norm, -ray.direction), 0.0, 1.0);
            fresnel = r0 + (1.0 - r0) * pow(1.0 - hv, 5.0);
            mask *= fresnel;

            // diffuse shading
            for (int j = 0; j < num_lights; j++) {
                if (lights[j].direction == vec3(0.0)) {
                    // spherical light
                    vec3 direction_to_light = lights[j].pos - hit_point;
                    vec3 direction_to_light_norm = normalize(direction_to_light);
                    Intersect shadow_intersect = trace(Ray(hit_point + EPSILON * direction_to_light_norm, direction_to_light_norm));
                    if (shadow_intersect == miss || shadow_intersect.dist > length(hit_point - lights[i].pos)) {
                        float r2 = pow(length(direction_to_light),2.0);
                        float light_intensity = lights[j].brightness / (4.0 * 3.14159 * r2);
                        float light_power = max(dot(intersect.norm, direction_to_light),0.0) * light_intensity;
                        shaded_color += clamp(intersect.surface.col.rgb * light_power * (1.0 - intersect.surface.reflectivity),0.0,1.0) * (1.0 - fresnel) * mask / fresnel;
                    }
                } else {
                    // directional light
                    vec3 direction_to_light = normalize(-lights[j].direction);
                    Intersect shadow_intersect = trace(Ray(hit_point + EPSILON * direction_to_light, direction_to_light));
                    if (shadow_intersect == miss || shadow_intersect.dist > length(hit_point - lights[j].pos)) {
                        float light_power = max(dot(intersect.norm, direction_to_light),0.0) * lights[j].brightness;
                        shaded_color += clamp(intersect.surface.col * light_power * (1.0 - intersect.surface.reflectivity),0.0,1.0);
                    }
                }
            }

            float reflectivity = intersect.surface.reflectivity;
            if (reflectivity != 0.0) {
                vec3 reflection = reflect(ray.direction, intersect.norm);
                ray = Ray(hit_point + EPSILON * reflection, reflection);
            } else {
                color += shaded_color * prev_reflectivity;
                prev_reflectivity = reflectivity;
                break;
            }
            color += shaded_color * prev_reflectivity;
            prev_reflectivity = reflectivity;
        } else {
            break;
        }

    }
    // Gamma encoding
    color = vec3(pow(color.r, 1.0 / GAMMA), pow(color.g, 1.0 / GAMMA), pow(color.b, 1.0 / GAMMA));
    return color;
}

void main() {
    // Normalized pixel coordinates (from 0 to 1)
    vec2 coords = gl_GlobalInvocationID.xy;
    coords.y = 1024 - coords.y;
    vec2 uv = (coords - vec2(512, 512)) / 1024;

    // Create and trace the ray
    Ray ray = createPrimeRay(uv);
    vec3 col = radience(ray);

    // Output image
    vec4 to_write = vec4(col, 1.0);
    imageStore(img, ivec2(gl_GlobalInvocationID.xy), to_write);
}
