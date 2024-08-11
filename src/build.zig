const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.minor < 12) @compileError("Raylib requires zig version 0.12.0");
}

// NOTE(freakmangd): I don't like using a global here, but it prevents having to
// get the flags a second time when adding raygui
var raylib_flags_arr: std.ArrayListUnmanaged([]const u8) = .{};

/// we're not inside the actual build script recognized by the
/// zig build system; use this type where one would otherwise
/// use `@This()` when inside the actual entrypoint file.
const BuildScript = @import("../build.zig");

// This has been tested with zig version 0.12.0
pub fn addRaylib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options) !*std.Build.Step.Compile {
    const raylib_dep = b.dependencyFromBuildZig(BuildScript, .{
        .target = target,
        .optimize = optimize,
        .raudio = options.raudio,
        .rmodels = options.rmodels,
        .rshapes = options.rshapes,
        .rtext = options.rtext,
        .rtextures = options.rtextures,
        .platform_drm = options.platform_drm,
        .shared = options.shared,
        .linux_display_backend = options.linux_display_backend,
        .opengl_version = options.opengl_version,
        .config = options.config,
    });
    const raylib = raylib_dep.artifact("raylib");

    if (options.raygui) {
        const raygui_dep = b.dependency(options.raygui_dependency_name, .{});
        addRaygui(b, raylib, raygui_dep);
    }

    return raylib;
}

fn gen_header(b: *std.Build, options: Options) !void {
    const h_path = b.path("src/config.h");
    const h_path_abs = h_path.getPath(b);

    const h_orig_path = b.path("src/config.orig.h");
    const h_orig_path_abs = h_orig_path.getPath(b);
    
    // make backup if not exists
    blk: {
        const maybe_h_orig = std.fs.openFileAbsolute(h_orig_path_abs, .{});

        const h_orig = maybe_h_orig catch {
            break :blk try std.fs.renameAbsolute(h_path_abs, h_orig_path_abs);
        };
        h_orig.close();
    }

    const h_file = try std.fs.createFileAbsolute(
        h_path_abs,
        .{},
    );
    defer h_file.close();
    const file_writer = h_file.writer();

    try file_writer.print("#ifndef CONFIG_H\n#define CONFIG_H\n\n", .{});
    defer file_writer.print("\n#endif\n", .{}) catch unreachable;

    inline for (@typeInfo(ConfigHeaderOptions).Struct.fields) |field| {
        const value = @field(options.config, field.name);
        const v_type = @TypeOf(value);
        const t_info = @typeInfo(v_type);

        blk: {
            const val = if(t_info == .Optional) val: {
                if (value) |v| break :val v else break :blk;
            } else val: {
                break :val value;
            };

            var buf: [128]u8 = undefined;
            switch (@TypeOf(val)) {
                bool => {
                    const str = std.ascii.upperString(&buf, field.name);
                    if (val){
                        try file_writer.print("#define {s} 1\n", .{str});
                    } else {
                        std.debug.print("option: {s} should be omitted\n", .{ str });
                    }
                },
                i32 => {
                    const str = std.ascii.upperString(&buf, field.name);
                    try file_writer.print("#define {s} {d}\n", .{str, val});
                },
                f32 => {
                    const str = std.ascii.upperString(&buf, field.name);
                    try file_writer.print("#define {s} {d:.2}\n", .{str, val});
                },
                []const u8 => {
                    const str = std.ascii.upperString(&buf, field.name);
                    try file_writer.print("#define {s} \"{s}\"\n", .{str, val});
                },
                ConfigHeaderOptions.ma_formats => {
                    const str = std.ascii.upperString(&buf, field.name);
                    try file_writer.print("#define {s} {s}\n", .{str, @tagName(val)});
                },
                ConfigHeaderOptions.AppendF => {
                    const str = std.ascii.upperString(&buf, field.name);
                    try file_writer.print("#define {s} {d:.2}f\n", .{str, val.val});
                },
                else => {
                    @compileLog("Err: Received unhandled type: ", @TypeOf(val));
                },
            }
        }
    }
}

fn compileRaylib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options) !*std.Build.Step.Compile {
    raylib_flags_arr.clearRetainingCapacity();

    const shared_flags = &[_][]const u8{
        "-fPIC",
        "-DBUILD_LIBTYPE_SHARED",
    };
    try raylib_flags_arr.appendSlice(b.allocator, &[_][]const u8{
        "-std=gnu99",
        "-D_GNU_SOURCE",
        "-DGL_SILENCE_DEPRECATION=199309L",
        "-fno-sanitize=undefined", // https://github.com/raysan5/raylib/issues/3674
    });
    if (options.shared) {
        try raylib_flags_arr.appendSlice(b.allocator, shared_flags);
    }

    const raylib = if (options.shared)
        b.addSharedLibrary(.{
            .name = "raylib",
            .target = target,
            .optimize = optimize,
        })
    else
        b.addStaticLibrary(.{
            .name = "raylib",
            .target = target,
            .optimize = optimize,
        });
    raylib.linkLibC();

    // No GLFW required on PLATFORM_DRM
    if (!options.platform_drm) {
        raylib.addIncludePath(b.path("src/external/glfw/include"));
    }

    // Generate config header && Back up original to `config.orig.h` if still present
    {
        try gen_header(b, options);
    }
    var c_source_files = try std.ArrayList([]const u8).initCapacity(b.allocator, 2);
    c_source_files.appendSliceAssumeCapacity(&.{ "rcore.c", "utils.c" });

    if (options.raudio) {
        try c_source_files.append("raudio.c");
    }
    if (options.rmodels) {
        try c_source_files.append("rmodels.c");
    }
    if (options.rshapes) {
        try c_source_files.append("rshapes.c");
    }
    if (options.rtext) {
        try c_source_files.append("rtext.c");
    }
    if (options.rtextures) {
        try c_source_files.append("rtextures.c");
    }

    if (options.opengl_version != .auto) {
        raylib.defineCMacro(options.opengl_version.toCMacroStr(), null);
    }

    switch (target.result.os.tag) {
        .windows => {
            try c_source_files.append("rglfw.c");
            raylib.linkSystemLibrary("winmm");
            raylib.linkSystemLibrary("gdi32");
            raylib.linkSystemLibrary("opengl32");

            raylib.defineCMacro("PLATFORM_DESKTOP", null);
        },
        .linux => {
            if (!options.platform_drm) {
                try c_source_files.append("rglfw.c");
                raylib.linkSystemLibrary("GL");
                raylib.linkSystemLibrary("rt");
                raylib.linkSystemLibrary("dl");
                raylib.linkSystemLibrary("m");

                raylib.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
                raylib.addIncludePath(.{ .cwd_relative = "/usr/include" });
                if (options.linux_display_backend == .X11 or options.linux_display_backend == .Both) {
                    raylib.defineCMacro("_GLFW_X11", null);
                    raylib.linkSystemLibrary("X11");
                }

                if (options.linux_display_backend == .Wayland or options.linux_display_backend == .Both) {
                    raylib.defineCMacro("_GLFW_WAYLAND", null);
                    raylib.linkSystemLibrary("wayland-client");
                    raylib.linkSystemLibrary("wayland-cursor");
                    raylib.linkSystemLibrary("wayland-egl");
                    raylib.linkSystemLibrary("xkbcommon");
                    raylib.addIncludePath(b.path("src"));
                    waylandGenerate(b, raylib, "wayland.xml", "wayland-client-protocol");
                    waylandGenerate(b, raylib, "xdg-shell.xml", "xdg-shell-client-protocol");
                    waylandGenerate(b, raylib, "xdg-decoration-unstable-v1.xml", "xdg-decoration-unstable-v1-client-protocol");
                    waylandGenerate(b, raylib, "viewporter.xml", "viewporter-client-protocol");
                    waylandGenerate(b, raylib, "relative-pointer-unstable-v1.xml", "relative-pointer-unstable-v1-client-protocol");
                    waylandGenerate(b, raylib, "pointer-constraints-unstable-v1.xml", "pointer-constraints-unstable-v1-client-protocol");
                    waylandGenerate(b, raylib, "fractional-scale-v1.xml", "fractional-scale-v1-client-protocol");
                    waylandGenerate(b, raylib, "xdg-activation-v1.xml", "xdg-activation-v1-client-protocol");
                    waylandGenerate(b, raylib, "idle-inhibit-unstable-v1.xml", "idle-inhibit-unstable-v1-client-protocol");
                }
                raylib.defineCMacro("PLATFORM_DESKTOP", null);
            } else {
                if (options.opengl_version == .auto) {
                    raylib.linkSystemLibrary("GLESv2");
                    raylib.defineCMacro("GRAPHICS_API_OPENGL_ES2", null);
                }

                raylib.linkSystemLibrary("EGL");
                raylib.linkSystemLibrary("drm");
                raylib.linkSystemLibrary("gbm");
                raylib.linkSystemLibrary("pthread");
                raylib.linkSystemLibrary("rt");
                raylib.linkSystemLibrary("m");
                raylib.linkSystemLibrary("dl");
                raylib.addIncludePath(.{ .cwd_relative = "/usr/include/libdrm" });

                raylib.defineCMacro("PLATFORM_DRM", null);
                raylib.defineCMacro("EGL_NO_X11", null);
                raylib.defineCMacro("DEFAULT_BATCH_BUFFER_ELEMENT", "2048");
            }
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            try c_source_files.append("rglfw.c");
            raylib.linkSystemLibrary("GL");
            raylib.linkSystemLibrary("rt");
            raylib.linkSystemLibrary("dl");
            raylib.linkSystemLibrary("m");
            raylib.linkSystemLibrary("X11");
            raylib.linkSystemLibrary("Xrandr");
            raylib.linkSystemLibrary("Xinerama");
            raylib.linkSystemLibrary("Xi");
            raylib.linkSystemLibrary("Xxf86vm");
            raylib.linkSystemLibrary("Xcursor");

            raylib.defineCMacro("PLATFORM_DESKTOP", null);
        },
        .macos => {
            // On macos rglfw.c include Objective-C files.
            try raylib_flags_arr.append(b.allocator, "-ObjC");
            raylib.root_module.addCSourceFile(.{
                .file = b.path("src/rglfw.c"),
                .flags = raylib_flags_arr.items,
            });
            _ = raylib_flags_arr.pop();
            raylib.linkFramework("Foundation");
            raylib.linkFramework("CoreServices");
            raylib.linkFramework("CoreGraphics");
            raylib.linkFramework("AppKit");
            raylib.linkFramework("IOKit");

            raylib.defineCMacro("PLATFORM_DESKTOP", null);
        },
        .emscripten => {
            raylib.defineCMacro("PLATFORM_WEB", null);
            if (options.opengl_version == .auto) {
                raylib.defineCMacro("GRAPHICS_API_OPENGL_ES2", null);
            }

            if (b.sysroot == null) {
                @panic("Pass '--sysroot \"$EMSDK/upstream/emscripten\"'");
            }

            const cache_include = std.fs.path.join(b.allocator, &.{ b.sysroot.?, "cache", "sysroot", "include" }) catch @panic("Out of memory");
            defer b.allocator.free(cache_include);

            var dir = std.fs.openDirAbsolute(cache_include, std.fs.Dir.OpenDirOptions{ .access_sub_paths = true, .no_follow = true }) catch @panic("No emscripten cache. Generate it!");
            dir.close();
            raylib.addIncludePath(.{ .cwd_relative = cache_include });
        },
        else => {
            @panic("Unsupported OS");
        },
    }

    raylib.addIncludePath(b.path("src"));
    raylib.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = c_source_files.items,
        .flags = raylib_flags_arr.items,
    });

    return raylib;
}

/// This function does not need to be called if you passed .raygui = true to addRaylib
pub fn addRaygui(b: *std.Build, raylib: *std.Build.Step.Compile, raygui_dep: *std.Build.Dependency) void {
    if (raylib_flags_arr.items.len == 0) {
        @panic(
            \\argument 2 `raylib` in `addRaygui` must come from b.dependency("raylib", ...).artifact("raylib")
        );
    }

    var gen_step = b.addWriteFiles();
    raylib.step.dependOn(&gen_step.step);

    const raygui_c_path = gen_step.add("raygui.c", "#define RAYGUI_IMPLEMENTATION\n#include \"raygui.h\"\n");
    raylib.addCSourceFile(.{ .file = raygui_c_path, .flags = raylib_flags_arr.items });
    raylib.addIncludePath(raygui_dep.path("src"));

    raylib.installHeader(raygui_dep.path("src/raygui.h"), "raygui.h");
}

pub const Options = struct {
    raudio: bool = true,
    rmodels: bool = true,
    rshapes: bool = true,
    rtext: bool = true,
    rtextures: bool = true,
    raygui: bool = false,
    platform_drm: bool = false,
    shared: bool = false,
    linux_display_backend: LinuxDisplayBackend = .Both,
    opengl_version: OpenglVersion = .auto,
    config: ConfigHeaderOptions = .{},

    raygui_dependency_name: []const u8 = "raygui",
};

pub const OpenglVersion = enum {
    auto,
    gl_1_1,
    gl_2_1,
    gl_3_3,
    gl_4_3,
    gles_2,
    gles_3,

    pub fn toCMacroStr(self: @This()) []const u8 {
        switch (self) {
            .auto => @panic("OpenglVersion.auto cannot be turned into a C macro string"),
            .gl_1_1 => return "GRAPHICS_API_OPENGL_11",
            .gl_2_1 => return "GRAPHICS_API_OPENGL_21",
            .gl_3_3 => return "GRAPHICS_API_OPENGL_33",
            .gl_4_3 => return "GRAPHICS_API_OPENGL_43",
            .gles_2 => return "GRAPHICS_API_OPENGL_ES2",
            .gles_3 => return "GRAPHICS_API_OPENGL_ES3",
        }
    }
};

pub const LinuxDisplayBackend = enum {
    X11,
    Wayland,
    Both,
};

pub const ConfigHeaderOptions = struct {
    pub const ma_formats = enum {
        ma_format_unknown,
        ma_format_u8,
        ma_format_s16,
        ma_format_s24,
        ma_format_s32,
        ma_format_f32,
        count,
    };
    pub const AppendF = struct {
        val: f32,
    };
    //------------------------------------------------------------------------------------
    // Module selection - Some modules could be avoided
    // Mandatory modules: rcore, rlgl, utils
    //------------------------------------------------------------------------------------
    support_module_rshapes: bool = true,
    support_module_rtextures: bool = true,
    support_module_rtext: bool = true, // SUPPORT_MODULE_RTEXTURES to load sprite font textures
    support_module_rmodels: bool = true,
    support_module_raudio: bool = true,

    //------------------------------------------------------------------------------------
    // Module: rcore - Configuration Flags
    //------------------------------------------------------------------------------------
    // Camera module is included (rcamera.h) and multiple predefined cameras are available: free, 1st/3rd person, orbital
    support_camera_system: bool = true,
    // Gestures module is included (rgestures.h) to support gestures detection: tap, hold, swipe, drag
    support_gestures_system: bool = true,
    // Include pseudo-random numbers generator (rprand.h), based on Xoshiro128** and SplitMix64
    support_rprand_generator: bool = true,
    // Mouse gestures are directly mapped like touches and processed by gestures system
    support_mouse_gestures: bool = true,
    // Reconfigure standard input to receive key inputs, works with SSH connection.
    support_ssh_keyboard_rpi: bool = true,
    // Setting a higher resolution can improve the accuracy of time-out intervals in wait functions.
    // However, it can also reduce overall system performance, because the thread scheduler switches tasks more often.
    support_winmm_highres_timer: bool = true,
    // Use busy wait loop for timing sync, if not defined, a high-resolution timer is set up and used
    support_busy_wait_loop: bool = false,
    // Use a partial-busy wait loop, in this case frame sleeps for most of the time, but then runs a busy loop at the end for accuracy
    support_partialbusy_wait_loop: bool = true,
    // Allow automatic screen capture of current screen pressing F12, defined in KeyCallback()
    support_screen_capture: bool = true,
    // Allow automatic gif recording of current screen pressing CTRL+F12, defined in KeyCallback()
    support_gif_recording: bool = true,
    // Support CompressData() and DecompressData() functions
    support_compression_api: bool = true,
    // Support automatic generated events, loading and recording of those events when required
    support_automation_events: bool = true,
    // Support custom frame control, only for advanced users
    // By default EndDrawing() does this job: draws everything + SwapScreenBuffer() + manage frame timing + PollInputEvents()
    // Enabling this flag allows manual control of the frame processes, use at your own risk
    support_custom_frame_control: bool = false,

    // rcore: Configuration values
    //------------------------------------------------------------------------------------
    max_filepath_capacity: i32 = 8192, // Maximum file paths capacity
    max_filepath_length: i32 = 4096, // Maximum length for filepaths (Linux PATH_MAX default value)

    max_keyboard_keys: i32 = 512, // Maximum number of keyboard keys supported
    max_mouse_buttons: i32 = 8, // Maximum number of mouse buttons supported
    max_gamepads: i32 = 4, // Maximum number of gamepads supported
    max_gamepad_axis: i32 = 8, // Maximum number of axis supported (per gamepad)
    max_gamepad_buttons: i32 = 32, // Maximum number of buttons supported (per gamepad)
    max_gamepad_vibration_time: AppendF = .{ .val = 2.0 }, // Maximum vibration time in seconds
    max_touch_points: i32 = 8, // Maximum number of touch points supported
    max_key_pressed_queue: i32 = 16, // Maximum number of keys in the key input queue
    max_char_pressed_queue: i32 = 16, // Maximum number of characters in the char input queue

    max_decompression_size: i32 = 64, // Max size allocated for decompression in MB

    max_automation_events: i32 = 16384, // Maximum number of automation events to record

    //------------------------------------------------------------------------------------
    // Module: rlgl - Configuration values
    //------------------------------------------------------------------------------------

    // Enable OpenGL Debug Context (only available on OpenGL 4.3)
    rlgl_enable_opengl_debug_context: bool = false,

    // Show OpenGL extensions and capabilities detailed logs on init
    rlgl_show_gl_details_info: bool = false,

    rl_default_batch_buffer_elements: ?i32 = null, // default: 4096 -- Default internal render batch elements limits
    rl_default_batch_buffers: i32 = 1, // Default number of batch buffers (multi-buffering)
    rl_default_batch_drawcalls: i32 = 256, // Default number of batch draw calls (by state changes: mode, texture)
    rl_default_batch_max_texture_units: i32 = 4, // Maximum number of textures units that can be activated on batch drawing (SetShaderValueTexture())

    rl_max_matrix_stack_size: i32 = 32, // Maximum size of internal Matrix stack

    rl_max_shader_locations: i32 = 32, // Maximum number of shader locations supported

    rl_cull_distance_near: f32 = 0.01, // Default projection matrix near cull distance
    rl_cull_distance_far: f32 = 1000.0, // Default projection matrix far cull distance

    // Default shader vertex attribute locations
    rl_default_shader_attrib_location_position: i32 = 0,
    rl_default_shader_attrib_location_texcoord: i32 = 1,
    rl_default_shader_attrib_location_normal: i32 = 2,
    rl_default_shader_attrib_location_color: i32 = 3,
    rl_default_shader_attrib_location_tangent: i32 = 4,
    rl_default_shader_attrib_location_texcoord2: i32 = 5,

    // Default shader vertex attribute names to set location points
    // NOTE: When a new shader is loaded, the following locations are tried to be set for convenience
    rl_default_shader_attrib_name_position: []const u8 = "vertexPosition", // Bound by default to shader location: RL_DEFAULT_SHADER_ATTRIB_LOCATION_POSITION
    rl_default_shader_attrib_name_texcoord: []const u8 = "vertexTexCoord", // Bound by default to shader location: RL_DEFAULT_SHADER_ATTRIB_LOCATION_TEXCOORD
    rl_default_shader_attrib_name_normal: []const u8 = "vertexNormal", // Bound by default to shader location: RL_DEFAULT_SHADER_ATTRIB_LOCATION_NORMAL
    rl_default_shader_attrib_name_color: []const u8 = "vertexColor", // Bound by default to shader location: RL_DEFAULT_SHADER_ATTRIB_LOCATION_COLOR
    rl_default_shader_attrib_name_tangent: []const u8 = "vertexTangent", // Bound by default to shader location: RL_DEFAULT_SHADER_ATTRIB_LOCATION_TANGENT
    rl_default_shader_attrib_name_texcoord2: []const u8 = "vertexTexCoord2", // Bound by default to shader location: RL_DEFAULT_SHADER_ATTRIB_LOCATION_TEXCOORD2

    rl_default_shader_uniform_name_mvp: []const u8 = "mvp", // model-view-projection matrix
    rl_default_shader_uniform_name_view: []const u8 = "matView", // view matrix
    rl_default_shader_uniform_name_projection: []const u8 = "matProjection", // projection matrix
    rl_default_shader_uniform_name_model: []const u8 = "matModel", // model matrix
    rl_default_shader_uniform_name_normal: []const u8 = "matNormal", // normal matrix (transpose(inverse(matModelView))
    rl_default_shader_uniform_name_color: []const u8 = "colDiffuse", // color diffuse (base tint color, multiplied by texture color)
    rl_default_shader_sampler2d_name_texture0: []const u8 = "texture0", // texture0 (texture slot active 0)
    rl_default_shader_sampler2d_name_texture1: []const u8 = "texture1", // texture1 (texture slot active 1)
    rl_default_shader_sampler2d_name_texture2: []const u8 = "texture2", // texture2 (texture slot active 2)

    //------------------------------------------------------------------------------------
    // Module: rshapes - Configuration Flags
    //------------------------------------------------------------------------------------
    // Use QUADS instead of TRIANGLES for drawing when possible
    // Some lines-based shapes could still use lines
    support_quads_draw_mode: i32 = 1,

    // rshapes: Configuration values
    //------------------------------------------------------------------------------------
    spline_segment_divisions: i32 = 24, // Spline segments subdivisions

    //------------------------------------------------------------------------------------
    // Module: rtextures - Configuration Flags
    //------------------------------------------------------------------------------------
    // Selecte desired fileformats to be supported for image data loading
    support_fileformat_png: bool = true,
    support_fileformat_bmp: bool = false,
    support_fileformat_tga: bool = false,
    support_fileformat_jpg: bool = false,
    support_fileformat_gif: bool = true,
    support_fileformat_qoi: bool = true,
    support_fileformat_psd: bool = false,
    support_fileformat_dds: bool = true,
    support_fileformat_hdr: bool = false,
    support_fileformat_pic: bool = false,
    support_fileformat_ktx: bool = false,
    support_fileformat_astc: bool = false,
    support_fileformat_pkm: bool = false,
    support_fileformat_pvr: bool = false,
    support_fileformat_svg: bool = false,

    // Support image export functionality (.png, .bmp, .tga, .jpg, .qoi)
    support_image_export: bool = true,
    // Support procedural image generation functionality (gradient, spot, perlin-noise, cellular)
    support_image_generation: bool = true,
    // Support multiple image editing functions to scale, adjust colors, flip, draw on images, crop...
    // If not defined, still some functions are supported: ImageFormat(), ImageCrop(), ImageToPOT()
    support_image_manipulation: bool = true,

    //------------------------------------------------------------------------------------
    // Module: rtext - Configuration Flags
    //------------------------------------------------------------------------------------
    // Default font is loaded on window initialization to be available for the user to render simple text
    // NOTE: If enabled, uses external module functions to load default raylib font
    support_default_font: bool = true,
    // Selected desired font fileformats to be supported for loading
    support_fileformat_ttf: bool = true,
    support_fileformat_fnt: bool = true,
    support_fileformat_bdf: bool = false,

    // Support text management functions
    // If not defined, still some functions are supported: TextLength(), TextFormat()
    support_text_manipulation: bool = true,

    // On font atlas image generation [GenImageFontAtlas()], add a 3x3 pixels white rectangle
    // at the bottom-right corner of the atlas. It can be useful to for shapes drawing, to allow
    // drawing text and shapes with a single draw call [SetShapesTexture()].
    support_font_atlas_white_rec: bool = true,

    // rtext: Configuration values
    //------------------------------------------------------------------------------------
    max_text_buffer_length: i32 = 1024, // Size of internal static buffers used on some functions:
    // TextFormat(), TextSubtext(), TextToUpper(), TextToLower(), TextToPascal(), TextSplit()
    max_textsplit_count: i32 = 128, // Maximum number of substrings to split: TextSplit()

    //------------------------------------------------------------------------------------
    // Module: rmodels - Configuration Flags
    //------------------------------------------------------------------------------------
    // Selected desired model fileformats to be supported for loading
    support_fileformat_obj: bool = true,
    support_fileformat_mtl: bool = true,
    support_fileformat_iqm: bool = true,
    support_fileformat_gltf: bool = true,
    support_fileformat_vox: bool = true,
    support_fileformat_m3d: bool = true,
    // Support procedural mesh generation functions, uses external par_shapes.h library
    // NOTE: Some generated meshes DO NOT include generated texture coordinates
    support_mesh_generation: bool = true,

    // rmodels: Configuration values
    //------------------------------------------------------------------------------------
    max_material_maps: i32 = 12, // Maximum number of shader maps supported
    max_mesh_vertex_buffers: i32 = 7, // Maximum vertex buffers (VBO) per mesh

    //------------------------------------------------------------------------------------
    // Module: raudio - Configuration Flags
    //------------------------------------------------------------------------------------
    // Desired audio fileformats to be supported for loading
    support_fileformat_wav: bool = true,
    support_fileformat_ogg: bool = true,
    support_fileformat_mp3: bool = true,
    support_fileformat_qoa: bool = true,
    support_fileformat_flac: bool = false,
    support_fileformat_xm: bool = true,
    support_fileformat_mod: bool = true,

    // raudio: Configuration values
    //------------------------------------------------------------------------------------
    audio_device_format: ma_formats = .ma_format_f32, // Device output format (miniaudio: float-32bit)
    audio_device_channels: i32 = 2, // Device output channels: stereo
    audio_device_sample_rate: i32 = 0, // Device sample rate (device default)

    max_audio_buffer_pool_channels: i32 = 16, // Maximum number of audio pool channels

    //------------------------------------------------------------------------------------
    // Module: utils - Configuration Flags
    //------------------------------------------------------------------------------------
    // Standard file io library (stdio.h) included
    support_standard_fileio: bool = true,
    // Show TRACELOG() output messages
    // NOTE: By default LOG_DEBUG traces not shown
    support_tracelog: bool = true,
    support_tracelog_debug: bool = false,

    // utils: Configuration values
    //------------------------------------------------------------------------------------
    max_tracelog_msg_length: i32 = 256, // Max length of one trace-log message
};


pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const defaults = Options{};
    const options = Options{
        .platform_drm = b.option(bool, "platform_drm", "Compile raylib in native mode (no X11)") orelse defaults.platform_drm,
        .raudio = b.option(bool, "raudio", "Compile with audio support") orelse defaults.raudio,
        .rmodels = b.option(bool, "rmodels", "Compile with models support") orelse defaults.rmodels,
        .rtext = b.option(bool, "rtext", "Compile with text support") orelse defaults.rtext,
        .rtextures = b.option(bool, "rtextures", "Compile with textures support") orelse defaults.rtextures,
        .rshapes = b.option(bool, "rshapes", "Compile with shapes support") orelse defaults.rshapes,
        .shared = b.option(bool, "shared", "Compile as shared library") orelse defaults.shared,
        .linux_display_backend = b.option(LinuxDisplayBackend, "linux_display_backend", "Linux display backend to use") orelse defaults.linux_display_backend,
        .opengl_version = b.option(OpenglVersion, "opengl_version", "OpenGL version to use") orelse defaults.opengl_version,
    };

    const lib = try compileRaylib(b, target, optimize, options);

    lib.installHeader(b.path("src/raylib.h"), "raylib.h");
    lib.installHeader(b.path("src/raymath.h"), "raymath.h");
    lib.installHeader(b.path("src/rlgl.h"), "rlgl.h");

    b.installArtifact(lib);
}

const waylandDir = "src/external/glfw/deps/wayland";

fn waylandGenerate(b: *std.Build, raylib: *std.Build.Step.Compile, comptime protocol: []const u8, comptime basename: []const u8) void {
    const protocolDir = waylandDir ++ "/" ++ protocol;
    const clientHeader = basename ++ ".h";
    const privateCode = basename ++ "-code.h";

    const client_step = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    client_step.addFileArg(b.path(protocolDir));
    raylib.addIncludePath(client_step.addOutputFileArg(clientHeader).dirname());

    const private_step = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    private_step.addFileArg(b.path(protocolDir));
    raylib.addIncludePath(private_step.addOutputFileArg(privateCode).dirname());

    raylib.step.dependOn(&client_step.step);
    raylib.step.dependOn(&private_step.step);
}
