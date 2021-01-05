# gpu-raytracer

A simple raytracer which runs on the GPU. Written in Rust using [Vulkano](https://vulkano.rs/). The GPU code is run as a compute shader using the Vulkan API.

## Capabilities

- Can render spheres and planes
- Both spherical and directional light sources
- Reflective and refractive surfaces
- Movable camera (controlled using arrow keys)

## Running

To run you must have both Rust and Vulkan installed.

Often computers will have both an integrated GPU and a discrete GPU, the latter of which you are more likely to want to use.
To prevent the program from defaulting to the wrong device, run `cargo run -- -l` to list available devices and their corresponding index.
Note the index of the device you want to use, and then run `cargo run -- -d <index>` to run the program with that device.

### Full list of command line arguments:
```
FLAGS:
        --help            Prints help information
    -l, --list-devices    List the physical devices available to Vulkan and their corresponding index
    -V, --version         Prints version information

OPTIONS:
    -d, --device <device>            Specify the index of the physical device for Vulkan to use
    -f, --frame <output-filename>    Export as a PNG rather than opening a new window
    -h, --height <height>            Specify the height in pixels. Default is 500
    -t, --time <time>                Set the time parameter of the shader to this value in seconds. Useful when you want
                                     to take a screen-shot at the specified time
    -w, --width <width>              Specify the width in pixels. Default is 500
```
