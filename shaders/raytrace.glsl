#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D img;
layout(set = 0, binding = 1) uniform readonly Input {
    int width;
    int height;
    vec3 view_position;
    float view_angle;
    float time;
};

struct Surface {
    vec3 col;
    float reflectivity;
    float refractivity;
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
const Intersect miss = Intersect(0.0, vec3(0), Surface(vec3(0),0.0,0.0));

// Defining arrays that contain scene geometry
const int num_lights = 2;
Light lights [num_lights];

const int num_spheres = 5;
Sphere spheres [num_spheres];

const int num_planes = 1;
Plane planes [num_planes];

// Ray-Sphere intersection
Intersect intersect(const in Ray ray, const in Sphere s) {
    float t = dot(ray.direction, s.pos - ray.origin);
    vec3 p = ray.origin + ray.direction * t;
    float y = length(s.pos - p);
    if (s.rad >= y) { 
        float x = sqrt(s.rad * s.rad - y * y);
        float t1 = t - x;
        float t2 = t + x;
        float tc;
        if (t1 < 0.0 && t2 < 0.0) {
            return miss;
        } else if (t1 < 0.0) {
            tc = t2;
        } else if (t2 < 0.0) {
            tc = t1;
        } else {
            tc = min(t1, t2);
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

// Ray-Light intersection
float intersect(const in Ray ray, const in Light l) {
    float t = dot(ray.direction, l.pos - ray.origin);
    vec3 p = ray.origin + ray.direction * t;
    float y = length(l.pos - p);
    float size = l.brightness / 100.0;
    if (size >= y) { 
        float x = sqrt(size * size - y * y);
        float t1 = t - x;
        float t2 = t + x;
        float tc = min(t1, t2);
        if (tc < 0.0) {
            return 0.0;
        }
        return max(-smoothstep(size * 0.8,size,y)+1, 0.0);
    } else {
        return 0.0;
    }
}

// Create the ray that will be used to draw the current pixel
Ray createPrimeRay() {
    const float FOV = 90.0;
    vec3 camera_position = view_position;
    vec3 camera_direction = vec3(sin(view_angle*0.01745),0.,-cos(view_angle*0.01745));
    vec3 camera_up = vec3(0.,1.,0.);
    vec3 camera_right = -cross(camera_up, camera_direction);
    float view_plane_half_width = tan(FOV*0.008727);
    float ar = float(height)/float(width);
    float view_plane_half_height = view_plane_half_width * ar;
    vec3 view_plane_top_left = camera_direction + camera_up*view_plane_half_height 
        - camera_right*view_plane_half_width;
    vec3 x_inc = (camera_right*2.0*view_plane_half_width)/width;
    vec3 y_inc = (camera_up*2.0*view_plane_half_height)/height;
    
    vec3 ray_direction = normalize((view_plane_top_left + gl_GlobalInvocationID.x*x_inc - gl_GlobalInvocationID.y*y_inc));
    Ray ray = Ray(camera_position, ray_direction);
    return ray;
}

// Trace a ray. Returns the intersect with the shortest distance
Intersect trace(const in Ray ray) {
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

// Checks if the ray passes through any lights. If so it returns the brightness
// to increase the color by
float traceLights(const in Ray ray, Intersect closest) {
    float brightness = 0.0;
    for (int i = 0; i < num_lights; i++) {
        float dist = distance(ray.origin, lights[i].pos);
        if (lights[i].direction == vec3(0.0)) {
            if (closest.dist == 0.0 || dist < closest.dist) {
                brightness += intersect(ray, lights[i]);
            }
        }
    }
    return brightness;
}

// Get the color to be drawn on screen.
vec3 radience(Ray ray) {
    vec3 color = vec3(0.0);
    const float EPSILON = 1e-3;
    const float GAMMA = 2.2;


    const int recursive_depth = 10;

    Intersect intersect;
    float prev_reflectivity = 1.0;
    vec3 fresnel = vec3(0.0), mask = vec3(1.0);

    for (int i = 0; i < recursive_depth; i++) {
        vec3 shaded_color = vec3(0.0);
        intersect = trace(ray);
        float brightness = traceLights(ray, intersect);

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

            color += brightness * vec3(1.0);

            if (intersect.surface.refractivity == 0.0) {
                // reflection
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
                // refraction
                float refractivity = intersect.surface.refractivity;
                if (refractivity != 0.0) {
                    float i_dot_n = dot(ray.direction, intersect.norm);
                    vec3 normal = intersect.norm;
                    if (i_dot_n < 0.0) {
                        i_dot_n = -i_dot_n;
                        refractivity = 1.0/refractivity;
                    } else {
                        normal = -normal;
                    }
                    vec3 direction = refract(ray.direction, normal, refractivity);
                    ray = Ray(hit_point - EPSILON * normal, direction);
                }
            }
        } else {
            color += brightness * vec3(1.0);
            break;
        }

    }
    // Gamma encoding
    color = vec3(pow(color.r, 1.0 / GAMMA), pow(color.g, 1.0 / GAMMA), pow(color.b, 1.0 / GAMMA));
    return color;
}

void main() {
    // Initialising the scene
    lights[0] = Light(vec3(-1.0, 0.8*sin(time), -2.0), 20.0, vec3(0.0));
    lights[1] = Light(vec3(0.2*cos(time)+0.2, 0.8*sin(time)+1.0, -5.5), 10.0, vec3(0.0));
    //lights[2] = Light(vec3(0.0), 0.5, vec3(0.0,-1.0,0.0));
    spheres[0] = Sphere(vec3(0.0,0.0,-4.0),1.0,Surface(vec3(1.0),0.0,1.2));
    spheres[1] = Sphere(vec3(0.5*cos(time),0.5*sin(time*3.14159)+0.1,-2.0),0.2,Surface(vec3(1.0),0.0,0.0));
    spheres[2] = Sphere(vec3(2.0,-0.5,-4.0),0.5,Surface(vec3(0.2,0.7,0.0),0.8,0.0));
    spheres[3] = Sphere(vec3(-0.5,0.5*sin(time),-6.7),1.3,Surface(vec3(0.1,0.1,1.0),0.1,0.0));
    spheres[4] = Sphere(vec3(-1.1,-0.8,-2.5),0.2,Surface(vec3(1.0,0.0,0.0),0.3,0.0));
    planes[0] = Plane(vec3(0.0,-1.0,0.0),vec3(0.0,-1.0,0.0),Surface(vec3(1.0),0.5,0.0));

    // Create and trace the ray
    Ray ray = createPrimeRay();
    vec3 col = radience(ray);

    // Output image
    vec4 to_write = vec4(col, 1.0);
    imageStore(img, ivec2(gl_GlobalInvocationID.xy), to_write);
}
