use image::{ImageBuffer, Rgba};
use std::sync::Arc;
use std::time::Instant;
use vulkano::{
    buffer::{BufferUsage, CpuAccessibleBuffer},
    command_buffer::{AutoCommandBufferBuilder, CommandBuffer},
    descriptor::{descriptor_set::PersistentDescriptorSet, PipelineLayoutAbstract},
    device::Device,
    format::Format,
    image::{Dimensions, ImageUsage, StorageImage},
    instance::{Instance, InstanceExtensions, PhysicalDevice},
    pipeline::ComputePipeline,
    sampler::Filter,
    swapchain::{ColorSpace, FullscreenExclusive, PresentMode, SurfaceTransform, Swapchain},
    sync::GpuFuture,
};
use vulkano_win::VkSurfaceBuild;
use winit::{
    dpi::{PhysicalSize, Size},
    event::{DeviceEvent, ElementState, Event, KeyboardInput, VirtualKeyCode},
    event_loop::{ControlFlow, EventLoop},
    window::WindowBuilder,
};

fn main() {
    // Setting up CLAP for argument parsing
    let yaml = clap::load_yaml!("cli.yml");
    let app = clap::App::from(yaml)
        .author(clap::crate_authors!())
        .version(clap::crate_version!());

    let matches = app.get_matches();

    let extensions = InstanceExtensions {
        khr_wayland_surface: true,
        ..vulkano_win::required_extensions()
    };
    let instance = Instance::new(None, &extensions, None).expect("failed to create instance");

    // Printing physical devices
    if matches.is_present("list-devices") {
        println!("Physical devices available on this system:");
        for (i, device) in PhysicalDevice::enumerate(&instance).enumerate() {
            println!("{}: {}", i, device.name());
        }
        return;
    }

    // Getting the physical device.
    let device_index = if let Some(i) = matches.value_of("device") {
        match i.parse::<usize>() {
            Ok(i) => i,
            Err(_) => {
                eprintln!("Invalid argument provided. Device must be an integer");
                return;
            }
        }
    } else {
        0
    };

    let physical = match PhysicalDevice::enumerate(&instance).nth(device_index) {
        Some(p) => p,
        None => {
            eprintln!(
                "Error: Could not find physical device with index {}",
                device_index
            );
            return;
        }
    };

    println!(
        "Using device: {} (type: {:?})",
        physical.name(),
        physical.ty()
    );

    let events_loop = EventLoop::new();

    // Creating the window

    let width = if let Some(w) = matches.value_of("width") {
        match w.parse::<u32>() {
            Ok(w) => w,
            Err(_) => {
                eprintln!("Invalid argument provided. Width must be an integer");
                return;
            }
        }
    } else {
        500
    };
    let height = if let Some(h) = matches.value_of("height") {
        match h.parse::<u32>() {
            Ok(h) => h,
            Err(_) => {
                eprintln!("Invalid argument provided. Height must be an integer");
                return;
            }
        }
    } else {
        500
    };

    // Picking a single queue for all operations
    let queue_family = physical
        .queue_families()
        .find(|&q| q.supports_graphics())
        .expect("couldn't find a graphical queue family");
    let (device, mut queues) = {
        let device_ext = vulkano::device::DeviceExtensions {
            khr_swapchain: true,
            ..vulkano::device::DeviceExtensions::none()
        };
        Device::new(
            physical,
            physical.supported_features(),
            &device_ext,
            [(queue_family, 0.5)].iter().cloned(),
        )
        .expect("failed to create device")
    };
    let queue = queues.next().unwrap();

    // Load the shader
    mod cs {
        vulkano_shaders::shader! {
            ty: "compute",
            path: "shaders/raytrace.glsl",
        }
    }
    let shader = cs::Shader::load(device.clone()).expect("failed to create shader module");

    let image = StorageImage::new(
        device.clone(),
        Dimensions::Dim2d { width, height },
        Format::R8G8B8A8Unorm,
        Some(queue.family()),
    )
    .unwrap();
    let now = Instant::now();

    let compute_pipeline = Arc::new(
        ComputePipeline::new(device.clone(), &shader.main_entry_point(), &())
            .expect("failed to create compute pipeline"),
    );

    let mut view_position = [0., 0., 0.];
    let mut view_angle = 0.0;
    let mut moving_forward = false;
    let mut moving_backward = false;
    let mut turning_left = false;
    let mut turning_right = false;

    if let Some(output) = matches.value_of("frame") {
        // Exporting an image

        let buf = CpuAccessibleBuffer::from_iter(
            device.clone(),
            BufferUsage::all(),
            false,
            (0..width * height * 4).map(|_| 0u8),
        )
        .expect("failed to create buffer");

        let params_buffer = CpuAccessibleBuffer::from_data(
            device.clone(),
            BufferUsage::all(),
            false,
            cs::ty::Input {
                width: width as i32,
                height: height as i32,
                view_position,
                view_angle,
                time: now.elapsed().as_secs_f32(),
                _dummy0: [0, 0, 0, 0, 0, 0, 0, 0],
            },
        )
        .expect("failed to create params buffer");

        let layout = compute_pipeline.layout().descriptor_set_layout(0).unwrap();
        let set = Arc::new(
            PersistentDescriptorSet::start(layout.clone())
                .add_image(image.clone())
                .unwrap()
                .add_buffer(params_buffer)
                .unwrap()
                .build()
                .unwrap(),
        );

        let mut builder = AutoCommandBufferBuilder::new(device.clone(), queue.family()).unwrap();
        builder
            .dispatch(
                [width / 8, height / 8, 1],
                compute_pipeline.clone(),
                set.clone(),
                (),
            )
            .unwrap()
            .copy_image_to_buffer(image.clone(), buf.clone())
            .unwrap();
        let command_buffer = builder.build().unwrap();

        let finished = command_buffer.execute(queue.clone()).unwrap();
        finished
            .then_signal_fence_and_flush()
            .unwrap()
            .wait(None)
            .unwrap();
        let buffer_content = buf.read().unwrap();
        let image =
            ImageBuffer::<Rgba<u8>, _>::from_raw(width, height, &buffer_content[..]).unwrap();
        image.save(format!("{}.png", output)).unwrap();
        return;
    } else {
        // Creating a window

        let surface = WindowBuilder::new()
            .with_resizable(false)
            .with_inner_size(Size::Physical(PhysicalSize { width, height }))
            .build_vk_surface(&events_loop, instance.clone())
            .unwrap();

        // Creating a swapchain
        let caps = surface
            .capabilities(physical)
            .expect("failed to get surface capabilities");
        let dimensions = caps.current_extent.unwrap_or([width, height]);
        let alpha = caps.supported_composite_alpha.iter().next().unwrap();
        let format = caps.supported_formats[0].0;

        let (swapchain, images) = Swapchain::new(
            device.clone(),
            surface.clone(),
            caps.min_image_count,
            format,
            dimensions,
            1,
            ImageUsage {
                color_attachment: true,
                transfer_destination: true,
                ..ImageUsage::none()
            },
            &queue,
            SurfaceTransform::Identity,
            alpha,
            PresentMode::Fifo,
            FullscreenExclusive::Default,
            true,
            ColorSpace::SrgbNonLinear,
        )
        .expect("failed to create swapchain");

        loop {
            // Handle window events
            events_loop.run(move |event, _, control_flow| match event {
                Event::WindowEvent {
                    event: winit::event::WindowEvent::CloseRequested,
                    ..
                } => {
                    *control_flow = ControlFlow::Exit;
                }
                Event::DeviceEvent {
                    event: DeviceEvent::Key(k),
                    ..
                } => match k {
                    // Check if up arrow is being pressed
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Up),
                        state: ElementState::Pressed,
                        ..
                    } => {
                        moving_forward = true;
                    }
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Up),
                        state: ElementState::Released,
                        ..
                    } => {
                        moving_forward = false;
                    }
                    // Check if down arrow is being pressed
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Down),
                        state: ElementState::Pressed,
                        ..
                    } => {
                        moving_backward = true;
                    }
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Down),
                        state: ElementState::Released,
                        ..
                    } => {
                        moving_backward = false;
                    }
                    // Check if left arrow is being pressed
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Left),
                        state: ElementState::Pressed,
                        ..
                    } => {
                        turning_left = true;
                    }
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Left),
                        state: ElementState::Released,
                        ..
                    } => {
                        turning_left = false;
                    }
                    // Check if right arrow is being pressed
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Right),
                        state: ElementState::Pressed,
                        ..
                    } => {
                        turning_right = true;
                    }
                    KeyboardInput {
                        virtual_keycode: Some(VirtualKeyCode::Right),
                        state: ElementState::Released,
                        ..
                    } => {
                        turning_right = false;
                    }
                    _ => {}
                },
                Event::MainEventsCleared => {
                    // Handle movement
                    if moving_forward {
                        view_position[0] += 0.01 * (view_angle * 0.01745_f32).sin();
                        view_position[2] -= 0.01 * (view_angle * 0.01745_f32).cos();
                    }
                    if moving_backward {
                        view_position[0] -= 0.01 * (view_angle * 0.01745_f32).sin();
                        view_position[2] += 0.01 * (view_angle * 0.01745_f32).cos();
                    }
                    // Handle turning
                    if turning_left {
                        view_angle -= 1.;
                    }
                    if turning_right {
                        view_angle += 1.;
                    }

                    let (image_num, _suboptimal, acquire_future) =
                        vulkano::swapchain::acquire_next_image(swapchain.clone(), None).unwrap();

                    let params_buffer = CpuAccessibleBuffer::from_data(
                        device.clone(),
                        BufferUsage::all(),
                        false,
                        cs::ty::Input {
                            width: width as i32,
                            height: height as i32,
                            view_position,
                            view_angle,
                            time: now.elapsed().as_secs_f32(),
                            _dummy0: [0, 0, 0, 0, 0, 0, 0, 0],
                        },
                    )
                    .expect("failed to create params buffer");
                    let layout = compute_pipeline.layout().descriptor_set_layout(0).unwrap();
                    let set = Arc::new(
                        PersistentDescriptorSet::start(layout.clone())
                            .add_image(image.clone())
                            .unwrap()
                            .add_buffer(params_buffer)
                            .unwrap()
                            .build()
                            .unwrap(),
                    );

                    let mut builder =
                        AutoCommandBufferBuilder::new(device.clone(), queue.family()).unwrap();
                    builder
                        .dispatch(
                            [width / 8, height / 8, 1],
                            compute_pipeline.clone(),
                            set.clone(),
                            (),
                        )
                        .unwrap()
                        .blit_image(
                            image.clone(),
                            [0, 0, 0],
                            [width as i32, height as i32, 1],
                            0,
                            0,
                            images[image_num].clone(),
                            [0, 0, 0],
                            [
                                images[image_num].dimensions()[0] as i32,
                                images[image_num].dimensions()[1] as i32,
                                1,
                            ],
                            0,
                            0,
                            1,
                            Filter::Linear,
                        )
                        .unwrap();
                    let command_buffer = builder.build().unwrap();

                    acquire_future
                        .then_execute(queue.clone(), command_buffer)
                        .unwrap()
                        .then_swapchain_present(queue.clone(), swapchain.clone(), image_num)
                        .then_signal_fence_and_flush()
                        .unwrap()
                        .wait(None)
                        .unwrap();
                }
                _ => (),
            });
        }
    }
}
