
RendererState :: struct {
	window: Window_Type;

	instanceVbo: GLuint;
	vao: GLuint;
	standardProgram: GLuint;
	textProgram: GLuint;
	resolutionUniformLocation: GLint;
	whiteDefaultTex: GLuint;

    instances: [..] Instance;
	numInstances: s32;

	MAX_GROUPS :: 256;
	groups: [MAX_GROUPS]Group;
	numGroups: s32;

	setScissor:bool;
	scissor: Rect;

	testBitmap: Bitmap;
}
renderState: RendererState;

Shader :: enum {
	RECTS;
	TEXT;
}

Group :: struct {
	instanceStart: s32;
	instanceEnd: s32;
	texture: *Bitmap;
	shader: GLuint;
	scissorRect: Rect;
}

Instance :: struct {
	dstRect: Rect = .{0.0, 0.0, 1.0, 1.0};
	srcRect: Rect = .{0.0, 0.0, 1.0, 1.0};
	color: Vector4 = .{1.0, 1.0, 1.0, 1.0};
	cornerRadii: Vector4 = .{0.0, 0.0, 0.0, 0.0};
	edgeSoftness: float = 0.0; // negative will result in inverse rounded corners
	borderThickness: float = 0.0;
	angle: float = 0.0;
	texture: *Bitmap = null;
	shader: Shader;
}

Bitmap :: struct {
	width: s32;
	height: s32;

	dirty: bool;
	data: []u8;
	texHandle: GLuint;
	format: BitmapFormat;
}

BitmapFormat :: enum {
	RGBA8;
	R8;
}

init_renderer :: (_window: Window_Type) {
	using renderState;
	window = _window;

	// all initialization
	gl_create_context(window, 4, 2);

	gl_load(*gl);
	gl_enable_debug_output(break_on_error = true);

	glViewport(0, 0, xx windowWidth, xx windowHeight);

	clear_scissor();
	numInstances = 0;
	numGroups = 0;

	// make shader programs
	{
		standardProgram = get_shader_program(VERTEX_SHADER, FRAGMENT_SHADER, .[]);
		textProgram = get_shader_program(VERTEX_SHADER, FRAGMENT_SHADER_TEXT, .[]);
	}
	// setup the VAO
	{
		glGenVertexArrays(1, *vao);
		glGenBuffers(1, *instanceVbo);

		glBindVertexArray(vao);
		glBindBuffer(GL_ARRAY_BUFFER, instanceVbo);

		T :: Instance;
		stride : u32 = size_of(T);
		offset: *T: null;

		// dstRect
		glEnableVertexAttribArray(0);
		glVertexAttribPointer(0, 4, GL_FLOAT, xx false, stride, xx *offset.dstRect);
		glVertexAttribDivisor(0, 1); // update the attribute once per instance

		// srcRect
		glEnableVertexAttribArray(1);
		glVertexAttribPointer(1, 4, GL_FLOAT, xx false, stride, xx *offset.srcRect);
		glVertexAttribDivisor(1, 1);

		// color
		glEnableVertexAttribArray(2);
		glVertexAttribPointer(2, 4, GL_FLOAT, xx false, stride, xx *offset.color);
		glVertexAttribDivisor(2, 1);

		// cornerRadii
		glEnableVertexAttribArray(3);
		glVertexAttribPointer(3, 4, GL_FLOAT, xx false, stride, xx *offset.cornerRadii);
		glVertexAttribDivisor(3, 1);

		// edgeSoftness
		glEnableVertexAttribArray(4);
		glVertexAttribPointer(4, 1, GL_FLOAT, xx false, stride, xx *offset.edgeSoftness);
		glVertexAttribDivisor(4, 1);

		// borderThickness
		glEnableVertexAttribArray(5);
		glVertexAttribPointer(5, 1, GL_FLOAT, xx false, stride, xx *offset.borderThickness);
		glVertexAttribDivisor(5, 1);

		// angle
		glEnableVertexAttribArray(6);
		glVertexAttribPointer(6, 1, GL_FLOAT, xx false, stride, xx *offset.angle);
		glVertexAttribDivisor(6, 1);

		DumpGLErrors("vao");
	}

	// create default white texture
	{
		glGenTextures(1, *whiteDefaultTex);
		glBindTexture(GL_TEXTURE_2D, whiteDefaultTex);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S,     GL_REPEAT);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T,     GL_REPEAT);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		whiteData: []u8 = .[0xFF, 0xFF, 0xFF, 0xFF];
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, whiteData.data);
		glGenerateMipmap(GL_TEXTURE_2D);
		glBindTexture(GL_TEXTURE_2D, 0);
	}

	// blending setup
	{
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);  
	}

    glEnable(GL_SCISSOR_TEST);
}

render_frame :: () {
	using renderState;

	glClearColor(style.backgroundDark.x, style.backgroundDark.y, style.backgroundDark.z, 1.0);
	glClear(GL_COLOR_BUFFER_BIT);

	if numGroups == 0 then return;

	// end the final group
	groups[numGroups-1].instanceEnd = numInstances;

	glBindVertexArray(vao);
	glBindBuffer(GL_ARRAY_BUFFER, instanceVbo);
	glBufferData(GL_ARRAY_BUFFER, size_of(Instance) * numInstances, instances.data, GL_STREAM_DRAW);

	for 0..numGroups-1 {
		instance := *groups[it];
		glUseProgram(instance.shader);

		scissor := groups[it].scissorRect;

		glScissor(xx scissor.x, xx (windowHeight - (scissor.h+scissor.y)), xx scissor.w, xx scissor.h);

		// per component blending for subpixel text rendering
		if instance.shader == textProgram {
			glBlendFunc(GL_SRC1_COLOR, GL_ONE_MINUS_SRC1_COLOR);  
		}
		else {
			glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);  
		}

		resolutionUniformLocation = glGetUniformLocation(standardProgram, "resolution");
		glUniform2f(resolutionUniformLocation, xx windowWidth, xx windowHeight);

		if instance.texture == null {
			glBindTexture(GL_TEXTURE_2D, whiteDefaultTex);
		}
		else {
			if instance.texture.dirty {
				load_bitmap_to_gpu(instance.texture);
				instance.texture.dirty = false;
			}
			glBindTexture(GL_TEXTURE_2D, instance.texture.texHandle);
		}

		count := instance.instanceEnd - instance.instanceStart;
		glDrawArraysInstancedBaseInstance(GL_TRIANGLES, 0, 6, xx count, xx instance.instanceStart);
	}

	platform_swap_buffers(window);

	array_reset_keeping_memory(*instances);
	numInstances = 0;
	numGroups = 0;
}

set_scissor :: (rect: Rect) {
	using renderState;
	setScissor = true;
	scissor = rect;
}

clear_scissor :: () {
	using renderState;
	setScissor = true;
	scissor = .{0, 0, xx windowWidth, xx windowHeight};
}

submit_instance :: (instance: Instance) {
	using renderState;
	if numInstances == 0 {
		// start a new group
		shaderHandle := standardProgram;
		if instance.shader == .TEXT then shaderHandle = textProgram;
		groups[numGroups] = .{numInstances, 0, instance.texture, shaderHandle, scissor};
		numGroups += 1;
	}
	if numInstances && (
		// conditions to start new group
		setScissor ||
		instance.texture != instances[numInstances-1].texture ||
		instance.shader != instances[numInstances-1].shader) {

		// end previous group
		groups[numGroups-1].instanceEnd = numInstances;
		// start new group
		shaderHandle := standardProgram;
		if instance.shader == .TEXT then shaderHandle = textProgram;
		groups[numGroups] = .{numInstances, 0, instance.texture, shaderHandle, scissor};
		numGroups += 1;
		setScissor = false;
	}
	array_add(*instances, instance);
	numInstances += 1;
}

resize_backbuffer :: () {
	glViewport(0, 0, xx windowWidth, xx windowHeight);
	clear_scissor();
}

make_bitmap_from_file :: (path: string) -> Bitmap {
	bitmap: Bitmap;
	w, h, channels: s32;
	stbi_set_flip_vertically_on_load(1);
	bitmap.data.data = stbi_load(temp_c_string(path), *w, *h, *channels, 0); 
	bitmap.data.count = channels * w * h; 
	bitmap.width = w;
	bitmap.height = h;
	bitmap.format = .RGBA8;

	return bitmap;
}

alloc_bitmap :: (bitmap: *Bitmap, w: s32, h: s32, format: BitmapFormat) {
	bytesPerPixel := 1;
	if format == .RGBA8 {
		bytesPerPixel = 4;
	}
	
	size := bytesPerPixel * w * h;
	bitmap.data = NewArray(size, u8);
	bitmap.format = format;
	bitmap.width = w;
	bitmap.height = h;
}

load_bitmap_to_gpu :: (bitmap: *Bitmap) {
	glGenTextures(1, *bitmap.texHandle);
	glBindTexture(GL_TEXTURE_2D, bitmap.texHandle);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S,     GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T,     GL_CLAMP_TO_EDGE);
	// @todo: probably want to allow this to be customized?
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

	glformat := GL_RGBA;
	if bitmap.format == .R8 {
		glformat = GL_RED;
	}
	glTexImage2D(GL_TEXTURE_2D, 0, xx glformat, xx bitmap.width, xx bitmap.height, 0, xx glformat, GL_UNSIGNED_BYTE, bitmap.data.data);
	glBindTexture(GL_TEXTURE_2D, 0);
}

#import "GL"(DUMP_GL_ERRORS=true);
#import "stb_image";

#scope_file

get_shader_program :: (vertShader: string, fragShader: string, defines: []string) -> GLuint {
    LOG_BUFFER_SIZE :: 512;

    make_shader_object :: (shader: string, defines: []string, type : GLenum) -> GLuint {
        shaderHandle := glCreateShader(type);

		builder : String_Builder;
		builder.allocator = temp;
		init_string_builder(*builder);
		append(*builder, "#version 330 core\n");
		for defines {
			print_to_builder(*builder, "#define %\n", it);
		}
		prefix := builder_to_string(*builder,,temp);

        shaders: [2] *u8;
        lengths: [2] s32;
        shaders[0] = prefix.data;
        shaders[1] = shader.data;
        lengths[0] = xx prefix.count;
        lengths[1] = xx shader.count;

        glShaderSource(shaderHandle, 2, shaders.data, lengths.data);

        glCompileShader(shaderHandle);

        success : GLint;
        glGetShaderiv(shaderHandle, GL_COMPILE_STATUS, *success);

        if !success then {
            logData: [LOG_BUFFER_SIZE] u8;
            glGetShaderInfoLog(shaderHandle, logData.count, null, logData.data);
            print("%", to_string(logData.data));
            return 0;
        }

        return shaderHandle;
    }

    vertexShader := make_shader_object(vertShader, defines, GL_VERTEX_SHADER);
    fragmentShader := make_shader_object(fragShader, defines, GL_FRAGMENT_SHADER);
    program := glCreateProgram();

    glAttachShader(program, vertexShader);
    glAttachShader(program, fragmentShader);
    glLinkProgram(program);

    success : GLint = 0;
    glGetProgramiv(program, GL_LINK_STATUS, *success);

    if !success then {
        logData: [LOG_BUFFER_SIZE] u8;
        glGetProgramInfoLog(program, logData.count, null, logData.data);
        print("%", to_string(logData.data));
        return 0;
    }

    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);

    return program;
}


VERTEX_SHADER :: #string END
layout (location = 0) in vec4 dstRect;
layout (location = 1) in vec4 srcRect;
layout (location = 2) in vec4 inColor;
layout (location = 3) in vec4 inCornerRadii;
layout (location = 4) in float inEdgeSoftness;
layout (location = 5) in float inBorderThickness;
layout (location = 6) in float angle;

uniform vec2 resolution;
uniform sampler2D bitmap;

out vec2 dstSize;
out vec2 uv;
out vec4 color;
out vec4 cornerRadii;
out float edgeSoftness;
out float borderThickness;

void main()
{
	vec2 quadVerts[6] = vec2[](
        vec2( 0.0,  0.0),
        vec2( 1.0,  0.0),
        vec2( 1.0,  1.0),
        vec2( 0.0,  0.0),
        vec2( 1.0,  1.0),
        vec2( 0.0,  1.0)
    );

	vec2 pivotShift = vec2(0.5, 0.5);
	mat2 rotate = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
	vec2 vert = rotate * (quadVerts[gl_VertexID] - pivotShift);
	vert = vert + pivotShift;

	vec2 screenPos = dstRect.xy + (vert) * dstRect.zw;

	vec2 pos;
	pos.x = (screenPos.x / resolution.x) * 2.0 - 1.0;
	pos.y = 1.0 - (screenPos.y / resolution.y) * 2.0;

    gl_Position = vec4(pos, 0.0, 1.0);

	vec2 texSize = textureSize(bitmap, 0);
	uv = srcRect.xy + quadVerts[gl_VertexID] * srcRect.zw;
	uv.y = texSize.y - uv.y;

	color = inColor; 
	cornerRadii = inCornerRadii;
	edgeSoftness = inEdgeSoftness;
	borderThickness = inBorderThickness;
	dstSize = dstRect.zw;
}
END

FRAGMENT_SHADER :: #string END
layout(location = 0, index = 0) out vec4 fragmentColor;

uniform sampler2D bitmap;

in vec2 dstSize;
in vec2 uv;
in vec4 color;
in vec4 cornerRadii;
in float edgeSoftness;
in float borderThickness;

float sdfRoundedBox(vec2 pt, vec2 halfDimensions, vec4 radii)
{
    radii.xy = (pt.x > 0.0) ? radii.zw : radii.yx;
    radii.x = (pt.y > 0.0) ? radii.x : radii.y;
    vec2 q = abs(pt) - halfDimensions + radii.x;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radii.x;
}

void main()
{
    fragmentColor = color * texture(bitmap, uv);

	vec2 softnessPadding = vec2(max(0, edgeSoftness-1), max(0, edgeSoftness-1));
	vec2 pt = (uv - vec2(0.5, 0.5)) * dstSize; 
	vec2 halfSize = (dstSize/2) - softnessPadding;

	float borderFactor = 1.0;
	if (borderThickness != 0.0) {

		vec2 interiorHalfSize = (dstSize/2) - softnessPadding - borderThickness;
		float interiorRadiusReduce = min(interiorHalfSize.x/halfSize.x, interiorHalfSize.y/halfSize.y);
		vec4 interiorRadii = cornerRadii * (interiorRadiusReduce*interiorRadiusReduce);
		float dist = sdfRoundedBox(pt, interiorHalfSize, interiorRadii);
		borderFactor = smoothstep(-edgeSoftness, 0, dist);
	}

	float dist = sdfRoundedBox(pt, halfSize, cornerRadii);
	float mainSDFfactor = 1 - smoothstep(-edgeSoftness, 0, dist);

	fragmentColor.a *= mainSDFfactor * borderFactor;
} 
END

FRAGMENT_SHADER_TEXT :: #string END
layout(location = 0, index = 0) out vec4 fragmentColor;
layout(location = 0, index = 1) out vec4 blendWeights;

uniform sampler2D bitmap;

in vec2 dstSize;
in vec2 uv;
in vec4 color;
in vec4 cornerRadii;
in float edgeSoftness;
in float borderThickness;

void main()
{
	ivec2 iuv = ivec2(uv);
	float left   = texelFetchOffset(bitmap, iuv, 0, ivec2(-1, 0)).r;
    float center = texelFetch(bitmap, iuv, 0).r;
    float right  = texelFetchOffset(bitmap, iuv, 0, ivec2( 1, 0)).r;
	vec3 pixelCoverages = vec3(left, center, right);

	// makes the glyphs slightly bolder, might want to make this configurable?
	float coverageAdjustment = +0.2;
	if (coverageAdjustment >= 0) {
		pixelCoverages = min(pixelCoverages * (1 + coverageAdjustment), 1);
	} else {
		pixelCoverages = max((1 - (1 - pixelCoverages) * (1 + -coverageAdjustment)), 0);
	}

	fragmentColor = color;
	blendWeights = vec4(pixelCoverages * color.a, color.a);

} 
END
