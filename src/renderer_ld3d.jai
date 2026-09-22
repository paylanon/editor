renderer_init :: (wt: Window_Type) {

    window = wt;
    _, _, window_width, window_height = get_dimensions(wt, false);

    ld3d_options := LD3D_Options.{DEBUG_MODE, BACK_BUFFER_FORMAT, MAX_FRAMES_IN_FLIGHT};
    boot_ld3d(window, ld3d_options);

    for * command_lists it.* = create_command_list(.DIRECT, tprint("direct [%]", it_index));
    fence_holder = create_fence_holder(MAX_FRAMES_IN_FLIGHT);

    rtv_heap_desc: D3D12_DESCRIPTOR_HEAP_DESC;
    rtv_heap_desc.Type     = .RTV;
    rtv_heap_desc.Flags    = .NONE;
    rtv_heap_desc.NodeMask = 0;
    rtv_descriptors = create_descriptor_heap(MAX_FRAMES_IN_FLIGHT, *rtv_heap_desc, "rtv heap");

    srv_heap_desc: D3D12_DESCRIPTOR_HEAP_DESC;
    srv_heap_desc.Type     = .CBV_SRV_UAV;
    srv_heap_desc.Flags    = .SHADER_VISIBLE;
    srv_heap_desc.NodeMask = 0;
    srv_descriptors = create_descriptor_heap(MAX_SHADER_RESOURCES, *srv_heap_desc, "srv heap");

    create_window_targets();

    cmd_list = *command_lists[0];
    assert_closed(cmd_list);
    reset_and_open_command_list(cmd_list);
    at_init = true;

    shader_init();
    
    init_gpu_ring(*immediate_vertices);
    
    frame_props.texture_srv_index = Editor.TEXTURE_ID_GLYPH_ATLAS_SUBPIXEL - 1;
}

create_window_targets :: () {
    
    for index: 0..MAX_FRAMES_IN_FLIGHT-1 {
        res: *ID3D12Resource2;
        hrcheck( IDXGISwapChain_GetBuffer(ld3d_context().swapchain, index.(u32), *uid(ID3D12Resource2_UUID), xx *res));
        set_object_name(res, tprint("swapchain [%]", index));
        render_targets[index] = create_render_target_view(*rtv_descriptors, res, null);
    }

    viewport.TopLeftX = 0;
    viewport.TopLeftY = 0;
    viewport.Width    = window_width.(float);
    viewport.Height   = window_height.(float);
    viewport.MinDepth = 0;
    viewport.MaxDepth = 1;
}

resize_swapchain :: () {
    
    flush_command_queue(.DIRECT, *fence_holder);
    FFI = 0;
    
    for 0..MAX_FRAMES_IN_FLIGHT-1 free_resource_view(render_targets[it], false);
    
    reset_descriptor_heap(*rtv_descriptors);
    
    hrcheck(IDXGISwapChain_ResizeBuffers(
        ld3d_context().swapchain,
        MAX_FRAMES_IN_FLIGHT,
        window_width.(u32),
        window_height.(u32),
        .UNKNOWN,
        xx (DXGI_SWAP_CHAIN_FLAG.ALLOW_TEARING | DXGI_SWAP_CHAIN_FLAG.ALLOW_MODE_SWITCH)
    ));
    
    flush_command_queue(.DIRECT, *fence_holder); // XXX
}

shader_init :: () {

    PATH :: #run tprint("%/ld3d.shader", #filepath);
    packed_shaders: string;
    if !File_Utilities.file_exists(PATH) {
        packed_shaders = compile_and_pack_shaders(PATH);
    } else packed_shaders = File.read_entire_file(PATH);
    
    offset: [5] s64;
    memcpy(offset.data, packed_shaders.data, size_of(s64)*5);
    
    advance(*packed_shaders, size_of(s64)*5);
    
    color_bytecode:         [2] string;
    text_bytecode:          [2] string;
    text_subpixel_bytecode: [2] string;
    
    color_bytecode[0] = String.slice(packed_shaders, 0, offset[0]);
    color_bytecode[1] = String.slice(packed_shaders, offset[0], offset[1] - offset[0]);
    text_bytecode[0] = String.slice(packed_shaders, offset[1], offset[2] - offset[1]);
    text_bytecode[1] = String.slice(packed_shaders, offset[2], offset[3] - offset[2]);
    text_subpixel_bytecode[0] = String.slice(packed_shaders, offset[3], offset[4] - offset[3]);
    text_subpixel_bytecode[1] = String.slice(packed_shaders, offset[4], packed_shaders.count - offset[4]);

    // common root signature

    root_params: [1] D3D12_ROOT_PARAMETER1;

    // b0: frame properties
    frame_properties: D3D12_ROOT_CONSTANTS;
    frame_properties.ShaderRegister = 0;
    frame_properties.RegisterSpace = 0;
    frame_properties.Num32BitValues = size_of(Frame_Properties)/4;

    root_params[0].ParameterType = ._32BIT_CONSTANTS;
    root_params[0].Constants = frame_properties;
    root_params[0].ShaderVisibility = .ALL;

    // s0: static sampler
    sampler_desc: D3D12_STATIC_SAMPLER_DESC;
    sampler_desc.Filter = .MIN_MAG_MIP_POINT;
    sampler_desc.AddressU = .WRAP;
    sampler_desc.AddressV = .WRAP;
    sampler_desc.AddressW = .WRAP;
    sampler_desc.MipLODBias = 0;
    sampler_desc.MaxAnisotropy = 1;
    sampler_desc.ComparisonFunc = .ALWAYS;
    sampler_desc.BorderColor = .TRANSPARENT_BLACK;
    sampler_desc.MinLOD = 0;
    sampler_desc.MaxLOD = FLOAT32_MAX;
    sampler_desc.ShaderRegister = 0;
    sampler_desc.RegisterSpace = 0;
    sampler_desc.ShaderVisibility = .ALL;

    root_sig_desc: D3D12_ROOT_SIGNATURE_DESC1;
    root_sig_desc.NumParameters = root_params.count;
    root_sig_desc.pParameters = root_params.data;
    root_sig_desc.NumStaticSamplers = 1;
    root_sig_desc.pStaticSamplers = *sampler_desc;
    root_sig_desc.Flags = .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT |
        .DENY_HULL_SHADER_ROOT_ACCESS |
        .DENY_DOMAIN_SHADER_ROOT_ACCESS |
        .DENY_GEOMETRY_SHADER_ROOT_ACCESS |
        .CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED;
	// .DENY_PIXEL_SHADER_ROOT_ACCESS;

    common_rs = create_root_signature(root_sig_desc);

    // common pipeline state stream

    // float3 position
    // float4 color
    // float2 texcoord

    vertex_desc: [3] D3D12_INPUT_ELEMENT_DESC;
    vertex_desc[0].SemanticName = "POSITION";
    vertex_desc[0].SemanticIndex = 0;
    vertex_desc[0].Format = .R32G32B32_FLOAT;
    vertex_desc[0].InputSlot = 0;
    vertex_desc[0].AlignedByteOffset = 0;
    vertex_desc[0].InputSlotClass = .PER_VERTEX_DATA;
    vertex_desc[0].InstanceDataStepRate = 0;

    vertex_desc[1].SemanticName = "COLOR";
    vertex_desc[1].SemanticIndex = 0;
    vertex_desc[1].Format = .R32G32B32A32_FLOAT;
    vertex_desc[1].InputSlot = 0;
    vertex_desc[1].AlignedByteOffset = D3D12_APPEND_ALIGNED_ELEMENT;
    vertex_desc[1].InputSlotClass = .PER_VERTEX_DATA;
    vertex_desc[1].InstanceDataStepRate = 0;

    vertex_desc[2].SemanticName = "TEXCOORD";
    vertex_desc[2].SemanticIndex = 0;
    vertex_desc[2].Format = .R32G32_FLOAT;
    vertex_desc[2].InputSlot = 0;
    vertex_desc[2].AlignedByteOffset = D3D12_APPEND_ALIGNED_ELEMENT;
    vertex_desc[2].InputSlotClass = .PER_VERTEX_DATA;
    vertex_desc[2].InstanceDataStepRate = 0;

    {
        using pss: Pipeline_State_Stream;

        root_sig = common_rs;

        input_layout.pInputElementDescs = vertex_desc.data;
        input_layout.NumElements = vertex_desc.count;

        primitive_topology = .TRIANGLE;

        ds_format = .UNKNOWN;
        rt_formats.NumRenderTargets = 1;
        rt_formats.RTFormats[0] = BACK_BUFFER_FORMAT;

        sample_desc.Count = 1;
        sample_desc.Quality = 0;

        blend_desc.AlphaToCoverageEnable = 0;
        blend_desc.IndependentBlendEnable = 0;
        blend_desc.RenderTarget[0].BlendEnable = 1;
        blend_desc.RenderTarget[0].LogicOpEnable = 0;
        blend_desc.RenderTarget[0].SrcBlend = .SRC_ALPHA;
        blend_desc.RenderTarget[0].DestBlend = .INV_SRC_ALPHA;
        blend_desc.RenderTarget[0].BlendOp = .ADD;
        blend_desc.RenderTarget[0].SrcBlendAlpha = .ONE;
        blend_desc.RenderTarget[0].DestBlendAlpha = .ZERO;
        blend_desc.RenderTarget[0].BlendOpAlpha = .ADD;
        blend_desc.RenderTarget[0].RenderTargetWriteMask = xx D3D12_COLOR_WRITE_ENABLE.ALL;

        depth_stencil.DepthEnable = 1;
        depth_stencil.DepthWriteMask = .ZERO;
        depth_stencil.DepthFunc = .ALWAYS;
        depth_stencil.StencilEnable = 0;

        rasterizer.FillMode = .SOLID;
        rasterizer.CullMode = .NONE;
        rasterizer.FrontCounterClockwise = 0;
        rasterizer.DepthBias = 0;
        rasterizer.DepthBiasClamp = 0;
        rasterizer.SlopeScaledDepthBias = 0;
        rasterizer.DepthClipEnable = 1;
        rasterizer.MultisampleEnable = 0;
        rasterizer.AntialiasedLineEnable = 0;
        rasterizer.ForcedSampleCount = 0;
        rasterizer.ConservativeRaster = .OFF;

        vs = {
            color_bytecode[0].data,
            color_bytecode[0].count.(u64)
        };

        ps = {
            color_bytecode[1].data,
            color_bytecode[1].count.(u64)
        };

        color_ps = create_pipeline_state(*pss, "EDITOR_COLOR");

        vs = {
            text_bytecode[0].data,
            text_bytecode[0].count.(u64)
        };

        ps = {
            text_bytecode[1].data,
            text_bytecode[1].count.(u64)
        };

        text_ps = create_pipeline_state(*pss, "EDITOR_TEXT");

        vs = {
            text_subpixel_bytecode[0].data,
            text_subpixel_bytecode[0].count.(u64)
        };

        ps = {
            text_subpixel_bytecode[1].data,
            text_subpixel_bytecode[1].count.(u64)
        };

        blend_desc.RenderTarget[0].SrcBlend = .SRC1_COLOR;
        blend_desc.RenderTarget[0].DestBlend = .INV_SRC1_COLOR;
        blend_desc.RenderTarget[0].BlendOp = .ADD;

        text_subpixel_ps = create_pipeline_state(*pss, "EDITOR_TEXT_SUBPIXEL");
    }
}

renderer_update :: (wt: Window_Type) {
    
    _, _, new_window_width, new_window_height := get_dimensions(wt, false);
    if new_window_width != window_width || new_window_height != window_height {
        resize_swapchain();
    }
}

create_texture :: (texture_id: Editor.Texture_ID, data: [] u8, width: s32, height: s32, filter: Editor.Texture_Filter, format: DXGI_FORMAT) {
    texture: Texture;

    texture.width = width;
    texture.height = height;
    texture.format = format;

    alloc:, texture.upload_key = alloc_default_texture(
        cmd_list,
        width.(u32),
        height.(u32),
        data.data,
        format,
        persistent_map=true
    );

    srv_desc: D3D12_SHADER_RESOURCE_VIEW_DESC;
    srv_desc.Format = format;
    srv_desc.ViewDimension = .TEXTURE2D;
    srv_desc.Shader4ComponentMapping = xx D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING();
    srv_desc.Texture2D.MostDetailedMip = 0;
    srv_desc.Texture2D.MipLevels = 1;
    srv_desc.Texture2D.ResourceMinLODClamp = 0;

    texture.srv = create_shader_resource_view(*srv_descriptors, alloc, *srv_desc);

    textures[texture_id] = texture;
}

renderer_create_texture_r8unorm :: (texture_id: Editor.Texture_ID, data: [] u8, width: s32, height: s32, filter: Editor.Texture_Filter) {
    create_texture(texture_id, data, width, height, filter, .R8_UNORM);
}

renderer_create_texture_rgba8unorm :: (texture_id: Editor.Texture_ID, data: [] u8, width: s32, height: s32, filter: Editor.Texture_Filter) {
    create_texture(texture_id, data, width, height, filter, .R8G8B8A8_UNORM);
}

update_texture :: (texture_id: Editor.Texture_ID, data: [] u8, update_rect: IRect) {
    
    update_xoffset := update_rect.x0;
    update_yoffset := update_rect.y0;
    update_width   := update_rect.x1 - update_rect.x0;
    update_height  := update_rect.y1 - update_rect.y0;

    if update_width == 0 || update_height == 0 then return;

    using texture := textures[texture_id];
    copy_into_default_texture(cmd_list, xx width, xx height, data.data, format, srv.alloc, upload_key);
}

renderer_update_texture_r8unorm :: (texture_id: Editor.Texture_ID, data: [] u8, update_rect: IRect) {
    ProfileZone("renderer_update_texture_rgba8unorm");    
    update_texture(texture_id, data, update_rect);
}

renderer_update_texture_rgba8unorm :: (texture_id: Editor.Texture_ID, data: [] u8, update_rect: IRect) {
    ProfileZone("renderer_update_texture_rgba8unorm");    
    update_texture(texture_id, data, update_rect);
}

renderer_begin_frame :: (clear_color: Vector4) {
    ProfileZone("renderer_begin_frame");

    if at_init {
        close_and_execute_command_list(*command_lists[0]);
        flush_command_queue(.DIRECT, *fence_holder);
        at_init = false;
    }


    cmd_list = *command_lists[FFI];
    assert_closed(cmd_list);
    reset_and_open_command_list(cmd_list);

    scissor_rect := D3D12_RECT.{0, 0, S32_MAX, S32_MAX};
    ID3D12GraphicsCommandList_RSSetScissorRects(cmd_list, 1, *scissor_rect);
    ID3D12GraphicsCommandList_RSSetViewports(cmd_list, 1, *viewport);

    ID3D12GraphicsCommandList_ClearRenderTargetView(cmd_list, render_targets[FFI].CPU_DESCR_HANDLE, xx *clear_color, 0, null);
    ID3D12GraphicsCommandList_OMSetRenderTargets(cmd_list, 1, *render_targets[FFI].CPU_DESCR_HANDLE, .FALSE, null);

    ID3D12GraphicsCommandList_SetDescriptorHeaps(cmd_list, 1, xx *srv_descriptors);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(cmd_list, common_rs);
}

renderer_draw :: (render_commands: [] Editor.Render_Command) {
    ProfileZone("renderer_draw");

    set_projection(window_width, window_height);

    for render_commands {
        if #complete it.type == {
            case .DRAW_COLOR_RECT; {
                if pipeline != .COLOR {
                    if pipeline immediate_flush(cmd_list);
                    set_pipeline(cmd_list, {null, color_ps, .TRIANGLELIST});
				    pipeline = .COLOR;
                }

                immediate_quad(
                    cmd_list,
                    { it.rect.x0, it.rect.y0 },
                    { it.rect.x0, it.rect.y1 },
                    { it.rect.x1, it.rect.y1 },
                    { it.rect.x1, it.rect.y0 },
                    it.color,
                );
            }

            case .DRAW_TEXT; {
                if !it.texture_id return;
                texture := textures[it.texture_id];

                if pipeline != .TEXT {
                    if pipeline immediate_flush(cmd_list);
                    set_pipeline(cmd_list, {null, text_ps, .TRIANGLELIST});
                    pipeline = .TEXT;
                }

                immediate_quad(
                    cmd_list,
                    { it.rect.x0, it.rect.y0 },
                    { it.rect.x0, it.rect.y1 },
                    { it.rect.x1, it.rect.y1 },
                    { it.rect.x1, it.rect.y0 },
                    it.color,
                    { it.texture_rect.x0, it.texture_rect.y0 },
                    { it.texture_rect.x0, it.texture_rect.y1 },
                    { it.texture_rect.x1, it.texture_rect.y1 },
                    { it.texture_rect.x1, it.texture_rect.y0 },
                );
            }

            case .DRAW_TEXT_SUBPIXEL; {
                if !it.texture_id return;
                texture := textures[it.texture_id];

                if pipeline != .TEXT_SUBPIXEL {
                    if pipeline immediate_flush(cmd_list);
					set_pipeline(cmd_list, {null, text_subpixel_ps, .TRIANGLELIST});
                    pipeline = .TEXT_SUBPIXEL;
                }

                immediate_quad(
                    cmd_list,
                    { it.rect.x0, it.rect.y0 },
                    { it.rect.x0, it.rect.y1 },
                    { it.rect.x1, it.rect.y1 },
                    { it.rect.x1, it.rect.y0 },
                    it.color,
                    { it.texture_rect.x0, it.texture_rect.y0 },
                    { it.texture_rect.x0, it.texture_rect.y1 },
                    { it.texture_rect.x1, it.texture_rect.y1 },
                    { it.texture_rect.x1, it.texture_rect.y0 },
                );
            }

            case .SET_SCISSOR; {
                immediate_flush(cmd_list);
                rect := Editor.rect_fixup(it.rect);
                scissor_rect := D3D12_RECT.{xx rect.x0, xx rect.y0, xx rect.x1, xx rect.y1};
                ID3D12GraphicsCommandList_RSSetScissorRects(cmd_list, 1, *scissor_rect);
            }
        }
    }
    
    immediate_flush(cmd_list);
}

renderer_submit_frame :: () {
    ProfileZone("renderer_submit_frame");

    close_and_execute_command_list(cmd_list);
    cmd_list = null;

    PRESENT_PARAMS :: DXGI_PRESENT_PARAMETERS.{0, null, null, null};
    hrcheck(IDXGISwapChain1_Present1(xx ld3d_context().swapchain, 0, 0, *PRESENT_PARAMS));

    fence_holder.value[FFI] += 1;
    ID3D12CommandQueue_Signal(ld3d_context().direct_command_queue, fence_holder.fence[FFI], fence_holder.value[FFI]); // @TODO wrap

    // increment FFI
    FFI = IDXGISwapChain3_GetCurrentBackBufferIndex(ld3d_context().swapchain);

    if ID3D12Fence_GetCompletedValue(fence_holder.fence[FFI]) < fence_holder.value[FFI] {
        ID3D12Fence_SetEventOnCompletion(fence_holder.fence[FFI], fence_holder.value[FFI], fence_holder.event);
        WaitForSingleObject(fence_holder.event, 0xFFFFFFFF);
    }
    
    pipeline = .NONE;

    // assert(false);

    // :WindowVSync
    //
    // @Hack wglSwapInterval unfortunately does nothing (at least on my computer/drivers).
    // This seems to help and I noticed no bad side effects yet. However, some people
    // experienced stutter with DwmFlush, so we need to watch this closely.
    //
    // More discussion here: https://github.com/glfw/glfw/issues/2733
    // #if OS == .WINDOWS {
    //     hresult := DwmFlush();
    //     if hresult != S_OK {
    //         log_error("Call to DwmFlush failed: %", hresult);
    //     }
    // }
}

// ------------------------------------------------------------
#scope_file

LUTILS_LOG_MSGR :: "renderer";

DEBUG_MODE :: false;
MAX_FRAMES_IN_FLIGHT :: 3;
MAX_TEXTURES :: 4;
MAX_SHADER_RESOURCES :: MAX_TEXTURES;

BACK_BUFFER_FORMAT   :: DXGI_FORMAT.R8G8B8A8_UNORM;
DEPTH_STENCIL_FORMAT :: DXGI_FORMAT.D24_UNORM_S8_UINT;

#if OS == .WINDOWS {
    Dwmapi :: #library,system "Dwmapi";
    DwmFlush :: () -> HRESULT #foreign Dwmapi;
}

Texture :: struct {

    width:  s32;
    height: s32;
    format: DXGI_FORMAT;

    upload_key: Upload_Key;
    srv: *Resource_View(.SHADER_RESOURCE);
}

Renderer_State :: struct {
    
    at_init: bool;
    
    window: Window_Type;
    window_width:  s32;
    window_height: s32;

    common_rs:        *ID3D12RootSignature;
    color_ps:         *ID3D12PipelineState;
    text_ps:          *ID3D12PipelineState;
    text_subpixel_ps: *ID3D12PipelineState;

    cmd_list: *Command_List(.DIRECT);
    command_lists: [MAX_FRAMES_IN_FLIGHT] Command_List(.DIRECT);
    fence_holder: Fence_Holder(MAX_FRAMES_IN_FLIGHT);

    rtv_descriptors: Descriptor_Heap(MAX_FRAMES_IN_FLIGHT);
    srv_descriptors: Descriptor_Heap(MAX_SHADER_RESOURCES);

    render_targets: [MAX_FRAMES_IN_FLIGHT] *Resource_View(.RENDER_TARGET);

    viewport: D3D12_VIEWPORT;

    FFI: s64;

    Pipeline :: enum {
        NONE;
        COLOR;
        TEXT;
        TEXT_SUBPIXEL;

    } pipeline: Pipeline = .NONE; // To prevent immediate_flush when pipeline is the same.

    textures: [MAX_TEXTURES] Texture;
    frame_props: Frame_Properties;
    
    Immediate_Vertices :: struct { array: [MAX_VERTICES] Immediate_Vertex; }
    immediate_vertices: GPU_Ring(Immediate_Vertices, 32);
    
    MAX_VERTICES :: 4800;
    vertices: [MAX_VERTICES] Immediate_Vertex;
    num_vertices: s64;

} using renderer_state: Renderer_State;

Frame_Properties :: struct {
    proj: Matrix4;
    texture_srv_index: u32;
}

// TODO(payl): standardize packed dxil
compile_and_pack_shaders :: (path: string) -> string {
    
    msg(.DOC, "Compiling shaders...");
    
    VERTEX_ENTRY   :: Slang_Entrypoint.{.VERTEX, "vs_main"};
    FRAGMENT_ENTRY :: Slang_Entrypoint.{.FRAGMENT, "ps_main"};

    begin_slang_context();

    color_binaries := slang_compile("editor_color", COLOR_SHADER, VERTEX_ENTRY, FRAGMENT_ENTRY);
    text_binaries := slang_compile("editor_text", TEXT_SHADER, VERTEX_ENTRY, FRAGMENT_ENTRY);
    text_subpixel_binaries := slang_compile("editor_text_subpixel", TEXT_SHADER_SUBPIXEL, VERTEX_ENTRY, FRAGMENT_ENTRY);
    
    offset: [5] s64;
    offset[0] = color_binaries[0].bytecode.count;
    offset[1] = offset[0] + color_binaries[1].bytecode.count;
    offset[2] = offset[1] + text_binaries[0].bytecode.count;
    offset[3] = offset[2] + text_binaries[1].bytecode.count;
    offset[4] = offset[3] + text_subpixel_binaries[0].bytecode.count;
    
    builder: String_Builder;
    for offset append_by_pointer(*builder, *it);
    append(*builder, color_binaries[0].bytecode);
    append(*builder, color_binaries[1].bytecode);
    append(*builder, text_binaries[0].bytecode);
    append(*builder, text_binaries[1].bytecode);
    append(*builder, text_subpixel_binaries[0].bytecode);
    append(*builder, text_subpixel_binaries[1].bytecode);
    
    File.write_entire_file(path, *builder, do_reset=false);
    return builder_to_string(*builder);
}

// Simp/immediate.jai copypasta

Immediate_Vertex :: struct {
    position:    Vector3;
    color_scale: Vector4;
    uv0:         Vector2;
}

set_projection :: (target_width: s32, target_height: s32) {
    m := orthographic_projection_matrix(0, target_width.(float), target_height.(float), 0, -1.0, 1.0);
    m._33 = m._33 * 0.5 + 0.5;
    m._34 = m._34 * 0.5 + 0.5;
    frame_props.proj = m;
}

immediate_quad :: (
    cmd_list: *Command_List(.DIRECT),
    p0: Vector2,
    p1: Vector2,
    p2: Vector2,
    p3: Vector2,
    color := Vector4.{1,1,1,1},
    uv0 := Vector2.{0,0},
    uv1 := Vector2.{1,0},
    uv2 := Vector2.{1,1}, 
    uv3 := Vector2.{0, 1}
) {
    
    CheckSpace(cmd_list, 6);

    put_vertex(*v[0], p0, color,  uv0.x, uv0.y);
    put_vertex(*v[1], p1, color,  uv1.x, uv1.y);
    put_vertex(*v[2], p2, color,  uv2.x, uv2.y);

    put_vertex(*v[3], p0, color,  uv0.x, uv0.y);
    put_vertex(*v[4], p2, color,  uv2.x, uv2.y);
    put_vertex(*v[5], p3, color,  uv3.x, uv3.y);
}

immediate_flush :: (cmd_list: *Command_List(.DIRECT)) {
    if !num_vertices return;
    
    // immediate vertex buffer
    new_block(*immediate_vertices);
    immediate_vertices.array = vertices;
    copy_to_gpu(*immediate_vertices);
    
    vbv := vertex_buffer_view(immediate_vertices.alloc, Immediate_Vertex, immediate_vertices.array.count);
    
    ID3D12GraphicsCommandList_IASetVertexBuffers(cmd_list, 0, 1, *vbv);
    ID3D12GraphicsCommandList_IASetIndexBuffer(cmd_list, null);

    ID3D12GraphicsCommandList_SetGraphicsRoot32BitConstants(cmd_list, 0, size_of(Frame_Properties)/4, *frame_props, 0);

    ID3D12GraphicsCommandList_DrawInstanced(cmd_list, num_vertices.(u32), 1, 0, 0);

    num_vertices = 0;
}

immediate_vertex_pointer :: inline (index: s32) -> *Immediate_Vertex { return vertices.data + index; }

CheckSpace :: (cmd_list: *Command_List(.DIRECT), n: s32) #expand {
    if num_vertices >= vertices.count-(n-1)  immediate_flush(cmd_list);
    `v := immediate_vertex_pointer(num_vertices.(s32));
    num_vertices += n;
}

put_vertex :: inline (using vertex: *Immediate_Vertex, p: Vector2, color: Vector4, u: float, v: float) {
    position.xy  = p;
    position.z   = 0;
    color_scale  = color;
    uv0.x        = u;
    uv0.y        = v;
}


COLOR_SHADER :: #string DONE
cbuffer Frame_Properties : register(b0) {
 matrix proj;
 };

struct Vertex_In {
    float3 pos : POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD;
};

struct Vertex_Out {
    float4 pos : SV_POSITION;
    float4 color : COLOR;
};

[shader("vertex")]
Vertex_Out vs_main(Vertex_In input) {
    Vertex_Out output;

    output.pos = mul(proj, float4(input.pos.xy, 0, 1));
    output.color = input.color;

    return output;
}

[shader("fragment")]
float4 ps_main(Vertex_Out input) : SV_TARGET {

    return input.color;
}
DONE

TEXT_SHADER :: #string END
cbuffer Frame_Properties : register(b0) {
    matrix proj;
    uint texture_srv_index;
};

struct Vertex_In {
    float3 pos : POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD;
};

struct Vertex_Out {
    float4 pos : SV_POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD;
};

[shader("vertex")]
Vertex_Out vs_main(Vertex_In input) {
    Vertex_Out output;
    output.pos = mul(proj, float4(input.pos.xy, 0, 1));
    output.texcoord = input.texcoord;
    output.color = input.color;
    return output;
}

SamplerState samps : register(s0);

[shader("fragment")]
float4 ps_main(Vertex_Out input) : SV_TARGET {
    Texture2D texture = Texture2D.Handle((uint)texture_srv_index);
    float a = texture.Sample(samps, input.texcoord).r;
    return input.color * float4(1, 1, 1, a);
}
END

TEXT_SHADER_SUBPIXEL :: #string END
cbuffer Frame_Properties : register(b0) {
    matrix proj;
    uint texture_srv_index;
};

struct Vertex_In {
    float3 pos : POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD;
};

struct Vertex_Out {
    float4 pos : SV_POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD;
};

[shader("vertex")]
Vertex_Out vs_main(Vertex_In input) {
    Vertex_Out output;
    output.pos = mul(proj, float4(input.pos.xy, 0, 1));
    output.texcoord = input.texcoord;
    output.color = input.color;
    return output;
}

SamplerState samps : register(s0);

#define COVERAGE_ADJUSTMENT 0.1

struct Pixel_Out {
    float4 color: SV_TARGET0;
    float4 blend: SV_TARGET1;
};

[shader("fragment")]
Pixel_Out ps_main(Vertex_Out input) {
    Texture2D texture = Texture2D.Handle((uint)texture_srv_index);
    float3 coverage = texture.Sample(samps, input.texcoord).rgb;

    // Coverage adjustment taken from:
    // https://arkanis.de/weblog/2023-08-14-simple-good-quality-subpixel-text-rendering-in-opengl-with-stb-truetype-and-dual-source-blending/
    if (COVERAGE_ADJUSTMENT > 0.0) {
        coverage = min(coverage * (1.0 + COVERAGE_ADJUSTMENT), 1.0);
    } else if (COVERAGE_ADJUSTMENT < 0.0) {
        coverage = max((1.0 - (1.0 - coverage) * (1.0 - COVERAGE_ADJUSTMENT)), 0.0);
    }

    Pixel_Out output;
    output.color = input.color;
    output.blend = float4(coverage, 1);
    return output;
}
END


using Window;
using Math;

// #import "d3d12";
#import "d3d12"()(INCLUDE_DEBUG_BINDINGS = true);
#import "dxgi";
#import "ld3d"(AGILITY_SDK = false);
#import "ld3d/lutils";