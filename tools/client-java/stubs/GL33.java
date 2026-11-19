package org.lwjgl.opengl;

/**
 * Compile-only stub of LWJGL's GL33 (the game ships the real one). Not shipped.
 * Only what the client Java of this repo calls. Constants are inlined by javac, so the values must be the real ones;
 * method descriptors must match LWJGL 3 exactly (checked against a working addon jar with javap -c).
 */
public final class GL33 {
    private GL33() {}

    public static final int GL_ZERO = 0, GL_ONE = 1, GL_TRIANGLES = 4;
    public static final int GL_LEQUAL = 0x0203, GL_SRC_ALPHA = 0x0302, GL_ONE_MINUS_SRC_ALPHA = 0x0303;
    public static final int GL_CULL_FACE = 0x0B44, GL_DEPTH_TEST = 0x0B71, GL_DEPTH_WRITEMASK = 0x0B72, GL_DEPTH_FUNC = 0x0B74;
    public static final int GL_VIEWPORT = 0x0BA2, GL_BLEND = 0x0BE2, GL_SCISSOR_TEST = 0x0C11;
    public static final int GL_FUNC_ADD = 0x8006, GL_BLEND_EQUATION_RGB = 0x8009, GL_BLEND_EQUATION_ALPHA = 0x883D;
    public static final int GL_BLEND_DST_RGB = 0x80C8, GL_BLEND_SRC_RGB = 0x80C9, GL_BLEND_DST_ALPHA = 0x80CA, GL_BLEND_SRC_ALPHA = 0x80CB;
    public static final int GL_VERTEX_ARRAY_BINDING = 0x85B5;
    public static final int GL_CURRENT_QUERY = 0x8865, GL_QUERY_RESULT = 0x8866, GL_QUERY_RESULT_AVAILABLE = 0x8867, GL_SAMPLES_PASSED = 0x8914;
    public static final int GL_FRAGMENT_SHADER = 0x8B30, GL_VERTEX_SHADER = 0x8B31, GL_COMPILE_STATUS = 0x8B81, GL_LINK_STATUS = 0x8B82;
    public static final int GL_CURRENT_PROGRAM = 0x8B8D;
    public static final int GL_DRAW_FRAMEBUFFER_BINDING = 0x8CA6, GL_READ_FRAMEBUFFER = 0x8CA8, GL_DRAW_FRAMEBUFFER = 0x8CA9, GL_READ_FRAMEBUFFER_BINDING = 0x8CAA;

    public static native void glAttachShader(int program, int shader);
    public static native void glBeginQuery(int target, int id);
    public static native void glBindFramebuffer(int target, int framebuffer);
    public static native void glBindVertexArray(int array);
    public static native void glBlendEquationSeparate(int modeRGB, int modeAlpha);
    public static native void glBlendFuncSeparate(int sfactorRGB, int dfactorRGB, int sfactorAlpha, int dfactorAlpha);
    public static native void glCompileShader(int shader);
    public static native int glCreateProgram();
    public static native int glCreateShader(int type);
    public static native void glDeleteProgram(int program);
    public static native void glDeleteShader(int shader);
    public static native void glDepthFunc(int func);
    public static native void glDepthMask(boolean flag);
    public static native void glDisable(int target);
    public static native void glDrawArrays(int mode, int first, int count);
    public static native void glEnable(int target);
    public static native void glEndQuery(int target);
    public static native int glGenQueries();
    public static native int glGenVertexArrays();
    public static native boolean glGetBoolean(int pname);
    public static native int glGetInteger(int pname);
    public static native void glGetIntegerv(int pname, int[] params);
    public static native String glGetProgramInfoLog(int program);
    public static native int glGetProgrami(int program, int pname);
    public static native int glGetQueryObjecti(int id, int pname);
    public static native int glGetQueryi(int target, int pname);
    public static native String glGetShaderInfoLog(int shader);
    public static native int glGetShaderi(int shader, int pname);
    public static native int glGetUniformLocation(int program, CharSequence name);
    public static native boolean glIsEnabled(int cap);
    public static native void glLinkProgram(int program);
    public static native void glShaderSource(int shader, CharSequence string);
    public static native void glUniform1f(int location, float v0);
    public static native void glUniform4f(int location, float v0, float v1, float v2, float v3);
    public static native void glUniformMatrix4fv(int location, boolean transpose, float[] value);
    public static native void glUseProgram(int program);
    public static native void glViewport(int x, int y, int w, int h);
}
