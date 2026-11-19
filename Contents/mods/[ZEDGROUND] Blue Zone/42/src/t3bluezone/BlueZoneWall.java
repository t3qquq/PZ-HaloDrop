package t3bluezone;

import java.lang.reflect.Method;
import viewpoint.api.render.FrameView;
import viewpoint.api.view.Vec3;

import static org.lwjgl.opengl.GL33.*;

/**
 * ZEDGROUND Blue Zone: the blue zone wall in Viewpoint 1st/3rd person.
 *
 * Isometric view keeps the Lua ground line (BlueZoneDisplay.lua). In Viewpoint the vanilla isoToScreen projection does
 * not match the 3D camera, so the wall is drawn in Viewpoint's own pass with the frame's view and projection matrices.
 *
 * Loading (0.3.0, 11-19): ZombieBuddy loads this jar at server join (mod.info javaJarFile) and PatchVpWall calls
 * afterTranslucent() at the end of viewpoint.render.AddonDraws.afterTranslucent. 0.1/0.2 were a Viewpoint addon
 * (media/viewpoint/addons): Viewpoint only discovers addons among the mods enabled at the main menu, so a server mod
 * that is turned on by joining never loaded (run 11-18: "Viewpoint.Addons[t3bluezone] missing" the whole session).
 *
 * Drawing (0.4.0, 11-19): plain OpenGL 3.3 calls, the same way the PongDu Viewpoint effects draw (seen working in game).
 * 0.3.x drew through Viewpoint's addon GPU wrapper (AddonGpu): that wrapper only hands out GPU objects to registered
 * addons with a declared budget (addon.properties draw.gpuMiB), and this jar is not one, so the very first buffer was
 * refused ("the draw object is refused: the addon holds 0 KiB of the 0 MiB it asked for") and the wall switched itself
 * off after 3 errors, one frame after the edge came into range (run 11-19 long). Now only two Viewpoint internals are
 * reached by reflection: AddonDraws.view(FrameContext) -> FrameView (matrices, scene origin) and
 * WorldRenderer.bindTarget(). Every GL state that is changed is saved and put back.
 *
 * Geometry: only the arc of the current blue circle near the player (ARC_HALF tiles each side, at most MAX_QUADS quads),
 * a vertical band from camera height - BELOW to + ABOVE. There is no vertex buffer: the vertex shader builds the arc
 * from gl_VertexID and a few uniforms (nearest wall point, radius, angle step), relative to the nearest wall point so
 * 32-bit floats stay exact for circles thousands of tiles wide.
 * Look: sandbox BlueZone.Style (read by ZoneState, the server's value reaches every client).
 *   1 field (0.2.0): PUBG-style curtain - a deep blue shimmering haze with flickering vertical lightning streaks.
 *   2 gas (0.6.0): contaminated zone - a bank of rolling gas that hugs the ground (GAS_TALL high, GAS_LAYERS * GAS_GAP
 *     tiles deep). 0.5.0 drew three flat sheets as tall as the field wall with a slow 2D pattern: on video (run 11-19
 *     Gas) it read as green paint on glass - no depth, sky high, nearly still, one flat colour. Now GAS_LAYERS shells
 *     each stand for the slice of gas behind them and read a 3D world-space noise along the view ray (see FS), so the
 *     cloud has parallax, a billowing top, a dark base and lit tops, and things in the gas fade with distance.
 *     Still no scene depth: gas closer than one shell gap is not drawn (the Lua screen tint covers being inside it),
 *     and from straight above (parachute) the shells are edge-on and nearly invisible.
 *
 * Axes (0.3.1, 11-19): FrameView.view() is relative to FrameView.sceneOrigin(), and sceneOrigin is in PZ world
 * coordinates (x tile, y tile, floor level). Render (x, z) = +-(world x - origin.x), +-(world y - origin.y), height is
 * render y. The default signs are both negative; run 11-19 long confirmed it ("axes calibrated: x=-dx,z=-dy score 1.0").
 * The mapping is still checked against the camera heading Lua publishes (BlueZone.VP) in case Viewpoint changes it.
 */
public final class BlueZoneWall {
    static final String TAG = "[BlueZone][VP] ";

    static final float ARC_HALF = 400f;      // tiles of arc each side of the player
    static final float SEG = 3f;             // tiles per quad (wider when MAX_QUADS caps it)
    static final int MAX_QUADS = 256;
    static final float SHOW_RANGE = 450f;    // draw only when the player is this close to the edge
    static final float BELOW = 60f;          // wall bottom: camera height - BELOW (render units)
    static final float ABOVE = 140f;         // wall top: camera height + ABOVE
    static final int DEFAULT_MAP = 6;        // render x = -(world dx), render z = -(world dy)
    static final int CAL_SAMPLES = 40;       // frames of camera heading used to check the axis mapping
    static final long YAW_MAX_AGE_MS = 150L; // Lua's camera yaw older than this is not used
    static final float[] COLOR = { 0.12f, 0.38f, 1.00f, 0.42f };   // field: rgb = haze tint, a = base opacity
    static final float[] GAS_COLOR = { 0.56f, 0.74f, 0.20f, 0.16f }; // gas: rgb = lit part of the cloud, a = absorption per tile of full density
    static final int GAS_LAYERS = 8;         // shells; GAS_LAYERS * GAS_GAP = how deep the gas bank is (tiles)
    static final float GAS_GAP = 5f;         // tiles between gas shells (outward from the circle)
    static final float GAS_TALL = 28f;       // cloud height above the ground (render units); the rolling top reaches 1.45x
    static final float GAS_BELOW = 25f;      // shells reach this far below the ground level (fills dips)
    static final float GAS_GROUND = 0f;      // ground in render y: the scene origin is the player's floor
    // Distance fade, both styles (0.6.1). Viewpoint hazes far terrain and trees toward the sky colour, the wall was drawn
    // at full strength: on video (run 11-19 Gas, 9:46) far forest in front of the wall hid its foot and looked like sky,
    // so the wall seemed to float, and its far end was cut by a straight vertical edge (far plane 400 / ARC_HALF).
    static final float FADE_NEAR = 170f;     // tiles from the camera where the wall starts to fade
    static final float FADE_FAR = 330f;      // gone from here on (before the far plane and the end of the arc)

    static final int VERTS_PER_QUAD = 6;

    // world offset from the scene origin = uNear + uR * (rotation of the arc angle around uPhi); render xz = uMap * offset
    static final String VS =
            "#version 330 core\n" +
            "uniform mat4 uView;\n" +
            "uniform mat4 uProj;\n" +
            "uniform vec4 uNear;\n" + // xy = nearest wall point, world tiles relative to the scene origin
            "uniform vec4 uPhi;\n" + // xy = cos, sin of the angle from the circle centre to that point
            "uniform float uR;\n" + // circle radius (tiles)
            "uniform float uDa;\n" + // angle per quad (radians)
            "uniform float uQuads;\n" +
            "uniform vec4 uMap;\n" + // render x = uMap.x * wx + uMap.y * wy, render z = uMap.z * wx + uMap.w * wy
            "uniform vec4 uY;\n" + // x = wall bottom, y = top (render y)
            "uniform float uU0;\n" + // tiles along the circle at the nearest point (keeps the field pattern fixed in the world)
            "uniform float uOff;\n" + // tiles this sheet sits outside the circle (gas shells)
            "out vec2 vUV;\n" +
            "out vec3 vW;\n" + // xy = world tiles relative to the scene origin, z = render height
            "const vec2 CORNER[6] = vec2[6](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0));\n" +
            "void main() {\n" +
            "    int quad = gl_VertexID / 6;\n" +
            "    vec2 c = CORNER[gl_VertexID - quad * 6];\n" +
            "    float d = (float(quad) + c.x - uQuads * 0.5) * uDa;\n" +
            "    float s = sin(d);\n" +
            "    float h = sin(d * 0.5);\n" +
            "    float cm1 = -2.0 * h * h;\n" + // cos(d) - 1 without cancellation
            "    vec2 w = uNear.xy + uR * vec2(uPhi.x * cm1 - uPhi.y * s, uPhi.y * cm1 + uPhi.x * s);\n" +
            "    w += uOff * vec2(uPhi.x * (1.0 + cm1) - uPhi.y * s, uPhi.y * (1.0 + cm1) + uPhi.x * s);\n" +
            "    vec3 p = vec3(uMap.x * w.x + uMap.y * w.y, mix(uY.x, uY.y, c.y), uMap.z * w.x + uMap.w * w.y);\n" +
            "    vUV = vec2(uU0 + uR * d, c.y);\n" +
            "    vW = vec3(w, p.y);\n" +
            "    gl_Position = uProj * uView * vec4(p, 1.0);\n" +
            "}\n";
    // vUV.x = tiles along the circle, vUV.y = 0 (bottom) .. 1 (top)
    // Gas: every shell stands for the slice of gas behind it. The fragment walks the view ray into that slice, reads a 3D
    // noise density there (world position, so the cloud has parallax and does not slide with the shell) and turns it into
    // absorption. Shells are depth tested one by one, so things standing in the gas fade with distance.
    static final String FS =
            "#version 330 core\n" +
            "in vec2 vUV;\n" +
            "in vec3 vW;\n" +
            "uniform vec4 uColor;\n" +
            "uniform float uTime;\n" +
            "uniform float uStyle;\n" + // 1 field, 2 gas
            "uniform float uSeed;\n" + // gas shell number (unused by the shader, kept for diagnostics)
            "uniform vec4 uNear;\n" +
            "uniform vec4 uPhi;\n" +
            "uniform float uR;\n" +
            "uniform vec4 uCam;\n" + // camera, xy = world tiles relative to the scene origin, z = render height
            "uniform vec4 uOrg;\n" + // xy = scene origin mod 1024 (keeps the gas noise fixed in the world), zw = distance fade start / end
            "uniform vec4 uGas;\n" + // gas: x = shell spacing, y = slab thickness, z = cloud height, w = ground (render y)
            "out vec4 fragColor;\n" +
            "float hash(float n) { return fract(sin(n) * 43758.5453); }\n" +
            "float noise(vec2 p) {\n" +
            "    vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);\n" +
            "    float n = i.x + i.y * 57.0;\n" +
            "    return mix(mix(hash(n), hash(n + 1.0), f.x), mix(hash(n + 57.0), hash(n + 58.0), f.x), f.y);\n" +
            "}\n" +
            "float noise3(vec3 p) {\n" +
            "    vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);\n" +
            "    float n = i.x + i.y * 57.0 + i.z * 113.0;\n" +
            "    return mix(mix(mix(hash(n), hash(n + 1.0), f.x), mix(hash(n + 57.0), hash(n + 58.0), f.x), f.y),\n" +
            "               mix(mix(hash(n + 113.0), hash(n + 114.0), f.x), mix(hash(n + 170.0), hash(n + 171.0), f.x), f.y), f.z);\n" +
            "}\n" +
            "void main() {\n" +
            "    float u = vUV.x; float v = vUV.y;\n" +
            "    float haze = 1.0 - smoothstep(uOrg.z, uOrg.w, length(vW - uCam.xyz));\n" + // distance fade (both styles), see FADE_NEAR
            "    if (haze <= 0.0) discard;\n" +
            "    if (uStyle > 1.5) {\n" +
            "        float gap = uGas.x; float thick = uGas.y; float tall = uGas.z; float ground = uGas.w;\n" +
            "        vec3 d = normalize(vW - uCam.xyz);\n" + // view ray through this shell point
            "        vec2 rv = uPhi.xy * uR + (vW.xy - uNear.xy);\n" +
            "        vec2 rd = rv / max(length(rv), 0.001);\n" +
            "        float len = min(gap / max(abs(dot(d.xy, rd)), 0.22), gap * 4.0);\n" + // length of the ray inside this shell's slice
            "        vec3 q = vW + d * len * 0.5;\n" + // sample in the middle of the slice (behind the shell, seen from the camera)
            "        vec2 qn = q.xy - uNear.xy;\n" +
            "        float rr = dot(uPhi.xy, qn);\n" +
            "        float s = (2.0 * uR * rr + dot(qn, qn)) / (sqrt(max(uR * uR + 2.0 * uR * rr + dot(qn, qn), 0.0)) + uR);\n" + // tiles outside the circle, exact for big radii
            "        float hgt = q.z - ground;\n" +
            "        if (hgt > tall * 1.5) discard;\n" +
            "        vec3 P = vec3(q.xy + uOrg.xy, q.z);\n" +
            "        vec3 wind = vec3(0.50, 0.31, 0.0) * uTime;\n" +
            "        float top = tall * (0.50 + 0.95 * noise(P.xy * 0.030 + wind.xy * 0.030));\n" + // rolling cloud top
            "        float hf = 1.0 - smoothstep(top * 0.25, top, hgt);\n" +
            "        if (hf <= 0.0) discard;\n" +
            "        float n = noise3(P * vec3(0.060, 0.060, 0.100) + wind * 0.060 + vec3(0.0, 0.0, uTime * 0.020)) * 0.55\n" +
            "                + noise3(P * vec3(0.150, 0.150, 0.230) + wind * 0.150 + vec3(7.3, 1.9, -uTime * 0.050)) * 0.30\n" +
            "                + noise3(P * vec3(0.410, 0.410, 0.560) + wind * 0.410 + vec3(3.1, 5.7, -uTime * 0.110)) * 0.15;\n" +
            "        float front = smoothstep(-2.0, 6.0, s + (n - 0.5) * 14.0);\n" + // billowing edge at the circle
            "        float back = 1.0 - smoothstep(thick * 0.70, thick, s);\n" + // thins out at the far side of the slab
            "        float puff = clamp((n - 0.32) * 2.9, 0.0, 1.0);\n" +
            "        float dens = (0.10 + 1.70 * puff * puff) * hf * front * back;\n" +
            "        float a = (1.0 - exp(-uColor.a * dens * len)) * smoothstep(-0.3, 1.4, vW.z - ground);\n" + // absorption along the slice; fades at the ground so shells leave no lines on it
            "        float lit = clamp(0.15 + 0.85 * hgt / max(top, 0.01), 0.0, 1.0) * (0.35 + 0.65 * puff);\n" +
            "        vec3 c = mix(uColor.rgb * vec3(0.20, 0.30, 0.34), uColor.rgb * 1.10 + vec3(0.16, 0.13, 0.02), lit);\n" +
            "        fragColor = vec4(c, clamp(a, 0.0, 0.92) * haze);\n" +
            "        return;\n" +
            "    }\n" +
            "    float fade = smoothstep(0.0, 0.04, v) * (1.0 - smoothstep(0.80, 1.0, v));\n" +
            "    float shim = noise(vec2(u * 0.12, v * 5.0 - uTime * 0.5)) * 0.6\n" +
            "               + noise(vec2(u * 0.45, v * 18.0 - uTime * 1.4)) * 0.4;\n" +
            "    float col = floor(u * 0.5);\n" +
            "    float wob = noise(vec2(col * 3.7, v * 26.0 + uTime * 9.0)) - 0.5;\n" +
            "    float x = fract(u * 0.5) + wob * 0.35;\n" +
            "    float lit = step(0.80, hash(col * 1.37 + floor(uTime * 7.0) * 11.0));\n" +
            "    float len = step(hash(col * 2.11 + floor(uTime * 7.0) * 5.0) * 0.7, v);\n" +
            "    float bolt = smoothstep(0.07, 0.0, abs(x - 0.5)) * lit * len;\n" +
            "    vec3 c = uColor.rgb * (0.55 + 0.9 * shim) + vec3(0.75, 0.92, 1.0) * bolt * 1.6;\n" +
            "    float a = (uColor.a + 0.30 * shim + 0.55 * bolt) * fade;\n" +
            "    fragColor = vec4(c, clamp(a, 0.0, 0.92) * haze);\n" +
            "}\n";

    private static final BlueZoneWall INSTANCE = new BlueZoneWall();

    private int program, vao;
    private int uView, uProj, uNear, uPhi, uR, uDa, uQuads, uMap, uY, uU0, uOff, uColor, uTime, uStyle, uSeed, uCam, uOrg, uGas;
    private final int[] gasOrder = new int[GAS_LAYERS];
    private int lastStyle = -1;
    private boolean broken;
    private int errors;

    // Viewpoint internals (reflection, resolved on the first frame)
    private boolean vpResolved;
    private Method mView, mBind;
    private boolean firstDrawLogged;

    // arc of this frame (filled by buildArc, read by the draw)
    private final float[] arcNear = new float[2];
    private final float[] arcPhi = new float[2];
    private float arcR, arcDa, arcU0;

    // axis mapping (render thread only)
    private int mapping = DEFAULT_MAP; // bit0 swap world x/y, bit1 negate render x, bit2 negate render z
    private boolean calibrated, defaultLogged;
    private final double[] calScore = new double[8];
    private int calSamples, calRounds, fwdVotes;
    private double lastFwdDot = Double.NaN;
    private String lastNdc = "?";
    private long nextDiag;
    private long nextStat;
    private int drawnFrames, skippedFar;

    // how many pixels of the wall reached the screen (occlusion query, about once a second; diagnostics only)
    private int query;
    private boolean queryOff, queryPending;
    private long nextQuery;
    private String lastSamples = "?";

    public static void log(String s) { System.out.println(TAG + s); }

    /** called by PatchVpWall at the end of AddonDraws.afterTranslucent (Viewpoint render thread) */
    public static void afterTranslucent(Object frame) {
        INSTANCE.draw(frame);
    }

    private boolean resolveVp(Object frame) {
        if (vpResolved) return true;
        try {
            ClassLoader cl = frame.getClass().getClassLoader();
            Class<?> ad = Class.forName("viewpoint.render.AddonDraws", false, cl);
            mView = ad.getDeclaredMethod("view", frame.getClass());
            mView.setAccessible(true);
            mBind = Class.forName("viewpoint.render.WorldRenderer", false, cl).getMethod("bindTarget");
            vpResolved = true;
            log("viewpoint hooks resolved (AddonDraws.view, WorldRenderer.bindTarget)");
            return true;
        } catch (Throwable t) {
            broken = true;
            log("viewpoint hooks FAILED, wall off (Viewpoint changed?): " + t);
            return false;
        }
    }

    private void closeGl() {
        try { if (program != 0) glDeleteProgram(program); } catch (Throwable ignored) { }
        program = 0;   // the vertex array is kept: it holds no data
    }

    private void fail(String where, Throwable t) {
        errors++;
        log(where + " failed (" + errors + "): " + t);
        if (errors >= 3) {
            broken = true;
            log("wall off after " + errors + " errors");
            closeGl();
        }
    }

    private static int shader(int type, String src) {
        int s = glCreateShader(type);
        glShaderSource(s, src);
        glCompileShader(s);
        if (glGetShaderi(s, GL_COMPILE_STATUS) == 0) {
            String info = glGetShaderInfoLog(s);
            glDeleteShader(s);
            throw new IllegalStateException((type == GL_VERTEX_SHADER ? "vertex" : "fragment") + " shader: " + info);
        }
        return s;
    }

    /** compiles the program and makes the (empty) vertex array; throws when the shader does not build */
    private void initGl() {
        if (program != 0) return;
        int vs = shader(GL_VERTEX_SHADER, VS), fs = shader(GL_FRAGMENT_SHADER, FS);
        int p = glCreateProgram();
        glAttachShader(p, vs);
        glAttachShader(p, fs);
        glLinkProgram(p);
        glDeleteShader(vs);
        glDeleteShader(fs);
        if (glGetProgrami(p, GL_LINK_STATUS) == 0) {
            String info = glGetProgramInfoLog(p);
            glDeleteProgram(p);
            throw new IllegalStateException("program link: " + info);
        }
        uView = glGetUniformLocation(p, "uView");
        uProj = glGetUniformLocation(p, "uProj");
        uNear = glGetUniformLocation(p, "uNear");
        uPhi = glGetUniformLocation(p, "uPhi");
        uR = glGetUniformLocation(p, "uR");
        uDa = glGetUniformLocation(p, "uDa");
        uQuads = glGetUniformLocation(p, "uQuads");
        uMap = glGetUniformLocation(p, "uMap");
        uY = glGetUniformLocation(p, "uY");
        uU0 = glGetUniformLocation(p, "uU0");
        uColor = glGetUniformLocation(p, "uColor");
        uTime = glGetUniformLocation(p, "uTime");
        uOff = glGetUniformLocation(p, "uOff");
        uStyle = glGetUniformLocation(p, "uStyle");
        uSeed = glGetUniformLocation(p, "uSeed");
        uCam = glGetUniformLocation(p, "uCam");
        uOrg = glGetUniformLocation(p, "uOrg");
        uGas = glGetUniformLocation(p, "uGas");
        if (vao == 0) vao = glGenVertexArrays();
        program = p;
        log("gl ready: program " + p + " vao " + vao + " uniforms view=" + uView + " proj=" + uProj + " near=" + uNear + " phi=" + uPhi
                + " r=" + uR + " da=" + uDa + " quads=" + uQuads + " map=" + uMap + " y=" + uY + " u0=" + uU0 + " color=" + uColor + " time=" + uTime
                + " off=" + uOff + " style=" + uStyle + " seed=" + uSeed + " cam=" + uCam + " org=" + uOrg + " gas=" + uGas);
    }

    // ── axis mapping ───────────────────────────────────────────

    /** camera position in render space from a view matrix (column-major or row-major, picked by the zero row) */
    static double[] cameraFromView(float[] m) {
        boolean colMajor = Math.abs(m[3]) + Math.abs(m[7]) + Math.abs(m[11]) < 1e-3f;
        double r00, r01, r02, r10, r11, r12, r20, r21, r22, tx, ty, tz;
        if (colMajor) {
            r00 = m[0]; r01 = m[4]; r02 = m[8];  tx = m[12];
            r10 = m[1]; r11 = m[5]; r12 = m[9];  ty = m[13];
            r20 = m[2]; r21 = m[6]; r22 = m[10]; tz = m[14];
        } else {
            r00 = m[0]; r01 = m[1]; r02 = m[2];  tx = m[3];
            r10 = m[4]; r11 = m[5]; r12 = m[6];  ty = m[7];
            r20 = m[8]; r21 = m[9]; r22 = m[10]; tz = m[11];
        }
        // camera = -R^T t
        return new double[] {
                -(r00 * tx + r10 * ty + r20 * tz),
                -(r01 * tx + r11 * ty + r21 * tz),
                -(r02 * tx + r12 * ty + r22 * tz),
                colMajor ? 1 : 0 };
    }

    /** horizontal forward axis of the camera in render space {x, z, length before normalising} (OpenGL: the camera looks down -Z) */
    static double[] forwardFromView(float[] m, boolean colMajor) {
        double fx, fz;
        if (colMajor) { fx = -m[2]; fz = -m[10]; }
        else          { fx = -m[8]; fz = -m[10]; }
        double len = Math.hypot(fx, fz);
        if (len < 1e-6) return new double[] { 0, 0, 0 };
        return new double[] { fx / len, fz / len, len };
    }

    /** world offset (dx, dy) in tiles -> render (x, z) for a candidate mapping */
    static double[] dir(int map, double dx, double dy) {
        boolean swap = (map & 1) != 0;
        double a = swap ? dy : dx, b = swap ? dx : dy;
        return new double[] { (map & 2) != 0 ? -a : a, (map & 4) != 0 ? -b : b };
    }

    /** the same mapping as a 2x2 matrix {m00, m01, m10, m11}: render x = m00 * dx + m01 * dy, render z = m10 * dx + m11 * dy */
    static float[] mapMatrix(int map) {
        double[] ex = dir(map, 1, 0), ey = dir(map, 0, 1);
        return new float[] { (float) ex[0], (float) ey[0], (float) ex[1], (float) ey[1] };
    }

    /** world tile (wx, wy) -> render (x, z): relative to the scene origin (world x, world y, floor level) */
    static double[] toRender(int map, double wx, double wy, Vec3 origin) {
        return dir(map, wx - origin.x(), wy - origin.y());
    }

    static String mapName(int map) {
        boolean swap = (map & 1) != 0;
        return "x=" + ((map & 2) != 0 ? "-" : "+") + (swap ? "dy" : "dx") + ",z=" + ((map & 4) != 0 ? "-" : "+") + (swap ? "dx" : "dy");
    }

    private void diag(String why, double[] cam, FrameView v) {
        long now = System.currentTimeMillis();
        if (now < nextDiag) return;
        nextDiag = now + 5000L;
        Vec3 e = v.eye(), o = v.sceneOrigin();
        log("axes " + why + ": camera(view)=(" + f1(cam[0]) + "," + f1(cam[1]) + "," + f1(cam[2]) + ") colMajor=" + (cam[3] > 0)
                + " eye=" + vec(e) + " sceneOrigin=" + vec(o)
                + " player=(" + f1(ZoneState.px) + "," + f1(ZoneState.py) + ") camYaw=" + f1(ZoneState.camYaw)
                + " yawAgeMs=" + (now - ZoneState.camYawAt));
    }

    /**
     * Checks the axis mapping against the camera heading Lua publishes. Every usable frame adds, for each candidate,
     * the dot product between the view matrix's forward axis and the candidate's image of the world heading.
     * The forward sign (-Z or +Z) is voted by the third-person camera: it sits behind the player it looks at.
     */
    private void calibrate(float[] view, double[] cam, FrameView v) {
        if (calibrated) return;
        long now = System.currentTimeMillis();
        double yaw = ZoneState.camYaw;
        long age = now - ZoneState.camYawAt;
        if (Double.isNaN(yaw) || age > YAW_MAX_AGE_MS || age < -1000L) {
            if (!defaultLogged) {
                defaultLogged = true;
                log("axes: using default " + mapName(mapping) + " until Lua sends a camera yaw (BlueZone.VP yaw=" + f1(yaw) + " ageMs=" + age + ")");
            }
            return;
        }
        double[] f = forwardFromView(view, cam[3] > 0);
        if (f[2] < 0.35) return;                       // looking almost straight down or up: no heading
        double camFlat = Math.hypot(cam[0], cam[2]);
        if (camFlat > 1.0) fwdVotes += (f[0] * -cam[0] + f[1] * -cam[2]) >= 0 ? 1 : -1;
        double c = Math.cos(Math.toRadians(yaw)), s = Math.sin(Math.toRadians(yaw));
        for (int map = 0; map < 8; map++) {
            double[] d = dir(map, c, s);
            calScore[map] += d[0] * f[0] + d[1] * f[1];
        }
        if (++calSamples < CAL_SAMPLES) return;
        double sign = fwdVotes < 0 ? -1 : 1;           // camera looks down +Z instead of -Z
        int best = -1, second = -1;
        for (int map = 0; map < 8; map++) {
            double sc = calScore[map] * sign;
            if (best < 0 || sc > calScore[best] * sign) { second = best; best = map; }
            else if (second < 0 || sc > calScore[second] * sign) second = map;
        }
        double bestAvg = calScore[best] * sign / calSamples, secondAvg = calScore[second] * sign / calSamples;
        StringBuilder all = new StringBuilder();
        for (int map = 0; map < 8; map++) all.append(' ').append(mapName(map)).append('=').append(f2(calScore[map] * sign / calSamples));
        calRounds++;
        if (bestAvg > 0.85 && bestAvg - secondAvg > 0.15) {
            calibrated = true;
            log("axes calibrated: " + mapName(best) + " score " + f2(bestAvg) + (best == mapping ? " (same as default)" : " (default " + mapName(mapping) + " was WRONG, switched)")
                    + " forward=" + (sign > 0 ? "-Z" : "+Z") + " votes=" + fwdVotes + " eye=" + vec(v.eye()) + " scores:" + all);
            mapping = best;
        } else {
            if (calRounds <= 5 || calRounds % 20 == 0) {
                log("axes calibration inconclusive (" + calRounds + "), keeping " + mapName(mapping) + ": best " + mapName(best) + " " + f2(bestAvg)
                        + " second " + mapName(second) + " " + f2(secondAvg) + " forward=" + (sign > 0 ? "-Z" : "+Z") + " votes=" + fwdVotes + " scores:" + all);
            }
            java.util.Arrays.fill(calScore, 0);
            calSamples = 0;
            fwdVotes = 0;
        }
    }

    // ── draw ───────────────────────────────────────────────────

    private static void toggle(int cap, boolean on) { if (on) glEnable(cap); else glDisable(cap); }

    private void draw(Object frame) {
        if (broken) return;
        double[] blue = ZoneState.currentBlue();
        if (blue == null || blue[2] < 1) return;
        if (!resolveVp(frame)) return;
        try {
            FrameView v = (FrameView) mView.invoke(null, frame);
            float[] view = v.view(), proj = v.projection();
            double[] cam = cameraFromView(view);
            if (!ZoneState.hasPlayer || v.sceneOrigin() == null) { diag("waiting (player=" + ZoneState.hasPlayer + ")", cam, v); return; }
            calibrate(view, cam, v);
            int quads = buildArc(blue, cam, v, view, proj);
            lastFwdDot = headingDot(view, cam);
            stats(quads, blue, cam);
            if (quads == 0) return;

            int oldProgram = glGetInteger(GL_CURRENT_PROGRAM), oldVao = glGetInteger(GL_VERTEX_ARRAY_BINDING);
            int fbo = glGetInteger(GL_DRAW_FRAMEBUFFER_BINDING), readFbo = glGetInteger(GL_READ_FRAMEBUFFER_BINDING);
            int[] viewport = new int[4];
            glGetIntegerv(GL_VIEWPORT, viewport);
            boolean blend = glIsEnabled(GL_BLEND), depth = glIsEnabled(GL_DEPTH_TEST), cull = glIsEnabled(GL_CULL_FACE),
                    scissor = glIsEnabled(GL_SCISSOR_TEST), mask = glGetBoolean(GL_DEPTH_WRITEMASK);
            int df = glGetInteger(GL_DEPTH_FUNC), sr = glGetInteger(GL_BLEND_SRC_RGB), dr = glGetInteger(GL_BLEND_DST_RGB),
                    sa = glGetInteger(GL_BLEND_SRC_ALPHA), da = glGetInteger(GL_BLEND_DST_ALPHA),
                    er = glGetInteger(GL_BLEND_EQUATION_RGB), ea = glGetInteger(GL_BLEND_EQUATION_ALPHA);
            try {
                initGl();
                mBind.invoke(null);
                glUseProgram(program);
                glBindVertexArray(vao);
                glEnable(GL_BLEND);
                glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
                glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);   // the target's alpha is left alone
                glEnable(GL_DEPTH_TEST);                  // buildings and hills in front hide the wall
                glDepthFunc(GL_LEQUAL);
                glDepthMask(false);                       // the see-through wall does not hide what is behind it
                glDisable(GL_CULL_FACE);                  // both sides: seen from inside and outside the zone
                glDisable(GL_SCISSOR_TEST);

                boolean colMajor = cam[3] > 0;
                glUniformMatrix4fv(uView, !colMajor, view);
                glUniformMatrix4fv(uProj, !colMajor, proj);
                glUniform4f(uNear, arcNear[0], arcNear[1], 0f, 0f);
                glUniform4f(uPhi, arcPhi[0], arcPhi[1], 0f, 0f);
                glUniform1f(uR, arcR);
                glUniform1f(uDa, arcDa);
                glUniform1f(uQuads, quads);
                float[] mm = mapMatrix(mapping);
                glUniform4f(uMap, mm[0], mm[1], mm[2], mm[3]);
                glUniform1f(uU0, arcU0);
                int style = ZoneState.style;
                boolean gas = style == 2;
                float camS = 0f;
                // camera in world tiles relative to the scene origin (the axis mapping is its own inverse transposed)
                float cwx = (float) (mm[0] * cam[0] + mm[2] * cam[2]), cwy = (float) (mm[1] * cam[0] + mm[3] * cam[2]);
                Vec3 org = v.sceneOrigin();
                glUniform4f(uCam, cwx, cwy, (float) cam[1], 0f);
                glUniform4f(uOrg, (float) (org.x() % 1024.0), (float) (org.y() % 1024.0), FADE_NEAR, FADE_FAR);
                if (gas) {
                    glUniform4f(uY, GAS_GROUND - GAS_BELOW, GAS_GROUND + GAS_TALL * 1.5f, 0f, 0f);
                    glUniform4f(uGas, GAS_GAP, GAS_GAP * GAS_LAYERS, GAS_TALL, GAS_GROUND);
                    // tiles the camera is outside the circle (same formula as the shader)
                    double qx = cwx - arcNear[0], qy = cwy - arcNear[1], rr = arcPhi[0] * qx + arcPhi[1] * qy, q2 = qx * qx + qy * qy;
                    camS = (float) ((2.0 * arcR * rr + q2) / (Math.sqrt(Math.max((double) arcR * arcR + 2.0 * arcR * rr + q2, 0.0)) + arcR));
                } else {
                    glUniform4f(uY, (float) (cam[1] - BELOW), (float) (cam[1] + ABOVE), 0f, 0f);
                }
                float[] col = gas ? GAS_COLOR : COLOR;
                glUniform4f(uColor, col[0], col[1], col[2], col[3]);
                glUniform1f(uTime, (float) (v.seconds() % 1000.0));
                glUniform1f(uStyle, gas ? 2f : 1f);
                if (style != lastStyle) {
                    lastStyle = style;
                    log("wall style " + style + (gas ? " (gas, " + GAS_LAYERS + " shells " + GAS_GAP + " tiles apart, cloud " + GAS_TALL + " high, camera "
                            + f1(camS) + " tiles outside the edge)" : " (field)") + " fade " + FADE_NEAR + "-" + FADE_FAR + " tiles");
                }

                boolean counting = beginSamples();
                if (gas) {
                    // shells farthest from the camera first: the camera can stand inside the zone, in the gas or beyond it
                    for (int i = 0; i < GAS_LAYERS; i++) gasOrder[i] = i;
                    for (int i = 1; i < GAS_LAYERS; i++) {
                        int k = gasOrder[i];
                        float dk = Math.abs(k * GAS_GAP - camS);
                        int j = i - 1;
                        while (j >= 0 && Math.abs(gasOrder[j] * GAS_GAP - camS) < dk) { gasOrder[j + 1] = gasOrder[j]; j--; }
                        gasOrder[j + 1] = k;
                    }
                    for (int i = 0; i < GAS_LAYERS; i++) {
                        glUniform1f(uOff, gasOrder[i] * GAS_GAP);
                        glUniform1f(uSeed, gasOrder[i]);
                        glDrawArrays(GL_TRIANGLES, 0, quads * VERTS_PER_QUAD);
                    }
                } else {
                    glUniform1f(uOff, 0f);
                    glUniform1f(uSeed, 0f);
                    glDrawArrays(GL_TRIANGLES, 0, quads * VERTS_PER_QUAD);
                }
                if (counting) endSamples();
                if (!firstDrawLogged) {
                    firstDrawLogged = true;
                    log("first wall draw: quads=" + quads + " axes=" + mapName(mapping) + " nearestWallNdc=" + lastNdc + " blue=(" + f1(blue[0]) + "," + f1(blue[1]) + " r" + f1(blue[2])
                            + ") colMajor=" + colMajor + " proj[10]=" + proj[10] + " proj[14]=" + proj[14]
                            + " viewport=" + viewport[2] + "x" + viewport[3]
                            + " gl before: blend=" + blend + " depthTest=" + depth + " depthFunc=0x" + Integer.toHexString(df) + " cull=" + cull + " depthWrite=" + mask);
                }
            } finally {
                glUseProgram(oldProgram);
                glBindVertexArray(oldVao);
                glBlendEquationSeparate(er, ea);
                glBlendFuncSeparate(sr, dr, sa, da);
                toggle(GL_BLEND, blend);
                glDepthFunc(df);
                glDepthMask(mask);
                toggle(GL_DEPTH_TEST, depth);
                toggle(GL_CULL_FACE, cull);
                toggle(GL_SCISSOR_TEST, scissor);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, readFbo);
                glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
            }
        } catch (Throwable t) {
            fail("draw", t);
        }
    }

    // ── drawn pixel count (diagnostics only: a failure here never turns the wall off) ──

    /** reads the last count and starts a new one about once a second; false when this frame is not counted */
    private boolean beginSamples() {
        if (queryOff) return false;
        try {
            if (queryPending) {
                if (glGetQueryObjecti(query, GL_QUERY_RESULT_AVAILABLE) == 0) return false;
                lastSamples = String.valueOf(glGetQueryObjecti(query, GL_QUERY_RESULT));
                queryPending = false;
            }
            long now = System.currentTimeMillis();
            if (now < nextQuery) return false;
            if (glGetQueryi(GL_SAMPLES_PASSED, GL_CURRENT_QUERY) != 0) return false;   // Viewpoint is counting: leave it alone
            nextQuery = now + 1000L;
            if (query == 0) query = glGenQueries();
            glBeginQuery(GL_SAMPLES_PASSED, query);
            return true;
        } catch (Throwable t) {
            queryOff = true;
            lastSamples = "off";
            log("pixel count off (wall still draws): " + t);
            return false;
        }
    }

    private void endSamples() {
        try {
            glEndQuery(GL_SAMPLES_PASSED);
            queryPending = true;
        } catch (Throwable t) {
            queryOff = true;
            lastSamples = "off";
            log("pixel count off (wall still draws): " + t);
        }
    }

    /** works out the arc of the blue circle facing the player (arcNear / arcPhi / arcR / arcDa); returns the quad count */
    private int buildArc(double[] blue, double[] cam, FrameView v, float[] view, float[] proj) {
        double cx = blue[0], cy = blue[1], r = blue[2];
        double px = ZoneState.px, py = ZoneState.py;
        double dx = px - cx, dy = py - cy;
        double dist = Math.sqrt(dx * dx + dy * dy);
        if (Math.abs(dist - r) > SHOW_RANGE) { skippedFar++; return 0; }
        double phi = Math.atan2(dy, dx);
        double span = Math.min(Math.PI, ARC_HALF / r);
        int quads = (int) Math.ceil(2 * span * r / SEG);
        if (quads < 4) quads = 4; else if (quads > MAX_QUADS) quads = MAX_QUADS;
        Vec3 origin = v.sceneOrigin();
        double cp = Math.cos(phi), sp = Math.sin(phi);
        double nearX = cx + r * cp, nearY = cy + r * sp;           // wall point straight out from the player
        arcNear[0] = (float) (nearX - origin.x());
        arcNear[1] = (float) (nearY - origin.y());
        arcPhi[0] = (float) cp;
        arcPhi[1] = (float) sp;
        arcR = (float) r;
        arcDa = (float) (2 * span / quads);
        arcU0 = (float) ((r * (phi + Math.PI)) % 4096.0);
        // diagnostics: where that nearest wall point lands on screen at camera height
        double[] near = toRender(mapping, nearX, nearY, origin);
        lastNdc = ndc(view, proj, near[0], cam[1], near[1]);
        return quads;
    }

    /** clip-space position of a render-space point, "(x,y) w=..": |x|,|y| <= 1 and w > 0 means on screen. Column-major matrices. */
    static String ndc(float[] view, float[] proj, double x, double y, double z) {
        double[] e = mul(view, x, y, z, 1), c = mul(proj, e[0], e[1], e[2], e[3]);
        if (Math.abs(c[3]) < 1e-9) return "w=0";
        return "(" + f2(c[0] / c[3]) + "," + f2(c[1] / c[3]) + ") w=" + f1(c[3]);
    }

    static double[] mul(float[] m, double x, double y, double z, double w) {
        return new double[] {
                m[0] * x + m[4] * y + m[8] * z + m[12] * w,
                m[1] * x + m[5] * y + m[9] * z + m[13] * w,
                m[2] * x + m[6] * y + m[10] * z + m[14] * w,
                m[3] * x + m[7] * y + m[11] * z + m[15] * w };
    }

    /** dot between the view's forward axis and the mapped camera yaw from Lua (1 = the mapping agrees with the camera), NaN without a yaw */
    private double headingDot(float[] view, double[] cam) {
        double yaw = ZoneState.camYaw;
        if (Double.isNaN(yaw) || System.currentTimeMillis() - ZoneState.camYawAt > YAW_MAX_AGE_MS) return Double.NaN;
        double[] f = forwardFromView(view, cam[3] > 0);
        if (f[2] < 0.35) return Double.NaN;
        double[] d = dir(mapping, Math.cos(Math.toRadians(yaw)), Math.sin(Math.toRadians(yaw)));
        return d[0] * f[0] + d[1] * f[1];
    }

    private void stats(int quads, double[] blue, double[] cam) {
        if (quads > 0) drawnFrames++;
        long now = System.currentTimeMillis();
        if (now < nextStat) return;
        if (nextStat != 0) {
            double edge = Math.hypot(ZoneState.px - blue[0], ZoneState.py - blue[1]) - blue[2];
            log("wall frames drawn=" + drawnFrames + " skipped(far from edge)=" + skippedFar + " last quads=" + quads + " (last 10s)"
                    + " edgeDist=" + f1(edge) + " pixels=" + lastSamples + " axes=" + mapName(mapping) + (calibrated ? "(calibrated)" : "(default)")
                    + " headingDot=" + f2(lastFwdDot) + " nearestWallNdc=" + lastNdc
                    + " cam=(" + f1(cam[0]) + "," + f1(cam[1]) + "," + f1(cam[2]) + ")");
        }
        nextStat = now + 10000L;
        drawnFrames = 0;
        skippedFar = 0;
    }

    static String f2(double d) { return Double.isNaN(d) ? "nan" : String.valueOf(Math.round(d * 100) / 100.0); }
    static String f1(double d) { return String.valueOf(Math.round(d * 10) / 10.0); }
    static String vec(Vec3 p) { return p == null ? "null" : "(" + f1(p.x()) + "," + f1(p.y()) + "," + f1(p.z()) + ")"; }
}
