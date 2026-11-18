package t3bluezone;

import viewpoint.api.Addon;
import viewpoint.api.AddonContext;
import viewpoint.api.Registration;
import viewpoint.api.render.DrawContext;
import viewpoint.api.render.DrawPoint;
import viewpoint.api.render.FrameView;
import viewpoint.api.render.Gpu;
import viewpoint.api.render.GpuBuffer;
import viewpoint.api.render.GpuMesh;
import viewpoint.api.render.GpuProgram;
import viewpoint.api.render.Primitive;
import viewpoint.api.view.Vec3;

/**
 * ZEDGROUND Blue Zone: the blue zone wall in Viewpoint 1st/3rd person (Viewpoint addon API 1.0.0, no ZombieBuddy).
 *
 * Isometric view keeps the Lua ground line (BlueZoneDisplay.lua). In Viewpoint the vanilla isoToScreen projection does
 * not match the 3D camera, so the wall is drawn here in Viewpoint's own pass (DrawPoint.AFTER_TRANSLUCENT) with the
 * frame's view and projection matrices.
 *
 * Geometry: only the arc of the current blue circle near the player (ARC_HALF tiles each side, at most MAX_QUADS quads),
 * a vertical band from camera height - BELOW to + ABOVE. Rebuilt and uploaded every frame.
 * Look (0.2.0, 11-19): PUBG-style curtain - a deep blue shimmering haze with flickering vertical lightning streaks,
 * strong enough to read as a wall from far away (0.1.0 was a faint striped film).
 *
 * Axes: how PZ world tiles (x, y) map to Viewpoint's render space is not documented. It is found at run time:
 * the camera position is read back from the view matrix, then each candidate mapping (x/y swapped or not, depth axis
 * flipped or not, scene origin subtracted or not) is tried against the player position Lua sends (Zone.player).
 * The first one that puts the player within MATCH_TILES of the camera wins and is logged. Height is the Y axis.
 * If none matches, nothing is drawn and the numbers are logged every 5 s.
 */
public final class BlueZoneWall implements Addon {
    static final String TAG = "[BlueZone][VP] ";

    static final float ARC_HALF = 400f;      // tiles of arc each side of the player
    static final float SEG = 3f;             // tiles per quad (wider when MAX_QUADS caps it)
    static final int MAX_QUADS = 256;
    static final float SHOW_RANGE = 450f;    // draw only when the player is this close to the edge
    static final float BELOW = 60f;          // wall bottom: camera height - BELOW (render units)
    static final float ABOVE = 140f;         // wall top: camera height + ABOVE
    static final float MATCH_TILES = 14f;    // camera-to-player distance allowed while matching axes (3rd person boom)
    static final float RECHECK_TILES = 40f;  // re-match axes when the player drifts this far from the camera
    static final float[] COLOR = { 0.12f, 0.38f, 1.00f, 0.42f };   // rgb = haze tint, a = base opacity

    static final int FLOATS_PER_VERT = 5;    // x y z u v
    static final int VERTS_PER_QUAD = 6;

    static final String VS =
            "layout(location = 0) in vec3 aPos;\n" +
            "layout(location = 1) in vec2 aUV;\n" +
            "uniform mat4 uView;\n" +
            "uniform mat4 uProj;\n" +
            "out vec2 vUV;\n" +
            "void main() {\n" +
            "    vUV = aUV;\n" +
            "    gl_Position = uProj * uView * vec4(aPos, 1.0);\n" +
            "}\n";
    // vUV.x = tiles along the arc, vUV.y = 0 (bottom) .. 1 (top)
    static final String FS =
            "in vec2 vUV;\n" +
            "uniform vec4 uColor;\n" +
            "uniform float uTime;\n" +
            "out vec4 fragColor;\n" +
            "float hash(float n) { return fract(sin(n) * 43758.5453); }\n" +
            "float noise(vec2 p) {\n" +
            "    vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);\n" +
            "    float n = i.x + i.y * 57.0;\n" +
            "    return mix(mix(hash(n), hash(n + 1.0), f.x), mix(hash(n + 57.0), hash(n + 58.0), f.x), f.y);\n" +
            "}\n" +
            "void main() {\n" +
            "    float u = vUV.x; float v = vUV.y;\n" +
            "    float fade = smoothstep(0.0, 0.04, v) * (1.0 - smoothstep(0.80, 1.0, v));\n" +
            "    float haze = noise(vec2(u * 0.12, v * 5.0 - uTime * 0.5)) * 0.6\n" +
            "               + noise(vec2(u * 0.45, v * 18.0 - uTime * 1.4)) * 0.4;\n" +
            "    float col = floor(u * 0.5);\n" +
            "    float wob = noise(vec2(col * 3.7, v * 26.0 + uTime * 9.0)) - 0.5;\n" +
            "    float x = fract(u * 0.5) + wob * 0.35;\n" +
            "    float lit = step(0.80, hash(col * 1.37 + floor(uTime * 7.0) * 11.0));\n" +
            "    float len = step(hash(col * 2.11 + floor(uTime * 7.0) * 5.0) * 0.7, v);\n" +
            "    float bolt = smoothstep(0.07, 0.0, abs(x - 0.5)) * lit * len;\n" +
            "    vec3 c = uColor.rgb * (0.55 + 0.9 * haze) + vec3(0.75, 0.92, 1.0) * bolt * 1.6;\n" +
            "    float a = (uColor.a + 0.30 * haze + 0.55 * bolt) * fade;\n" +
            "    fragColor = vec4(c, clamp(a, 0.0, 0.92));\n" +
            "}\n";

    private Registration reg;
    private GpuProgram program;
    private GpuBuffer buffer;
    private GpuMesh mesh;
    private boolean broken;
    private int errors;
    private final float[] verts = new float[MAX_QUADS * VERTS_PER_QUAD * FLOATS_PER_VERT];

    // axis mapping (render thread only)
    private int mapping = -1;          // bit0 swap x/y, bit1 flip depth, bit2 subtract scene origin
    private long nextDiag;
    private long nextStat;
    private int drawnFrames, skippedFar;

    public static void log(String s) { System.out.println(TAG + s); }

    @Override
    public void enable(AddonContext ctx) {
        log("enable v" + ZoneState.VERSION + " id=" + ctx.id());
        reg = ctx.render().draw(DrawPoint.AFTER_TRANSLUCENT, this::draw);
        log("draw registered at AFTER_TRANSLUCENT");
    }

    @Override
    public void disable() {
        log("disable");
        if (reg != null) reg.close();
        reg = null;
        closeGpu();
    }

    private void closeGpu() {
        try { if (mesh != null) mesh.close(); } catch (Throwable ignored) { }
        try { if (buffer != null) buffer.close(); } catch (Throwable ignored) { }
        try { if (program != null) program.close(); } catch (Throwable ignored) { }
        mesh = null; buffer = null; program = null;
    }

    private void fail(String where, Throwable t) {
        errors++;
        log(where + " failed (" + errors + "): " + t);
        if (errors >= 3) {
            broken = true;
            log("wall off after " + errors + " errors");
            closeGpu();
        }
    }

    private boolean gpuReady(Gpu gpu) {
        if (program != null) return true;
        try {
            program = compile(gpu);
            buffer = gpu.buffer(verts.length * 4);
            mesh = gpu.mesh(buffer, 3, 2);
            log("gpu ready: buffer " + (verts.length * 4) + " bytes, mesh attributes 3+2");
            return true;
        } catch (Throwable t) {
            closeGpu();
            fail("gpu setup", t);
            return false;
        }
    }

    /** GLSL 330 first; if the host adds its own #version line, retry without ours. */
    private GpuProgram compile(Gpu gpu) {
        try {
            GpuProgram p = gpu.program("#version 330 core\n" + VS, "#version 330 core\n" + FS);
            log("shader compiled with #version 330 core");
            return p;
        } catch (RuntimeException first) {
            log("shader with #version 330 core refused (" + first + "), retrying without a version line");
            GpuProgram p = gpu.program(VS, FS);
            log("shader compiled without a version line");
            return p;
        }
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

    /** world tile (wx, wy) -> render (x, z) for a candidate mapping */
    static double[] toRender(int map, double wx, double wy, Vec3 origin) {
        boolean swap = (map & 1) != 0, flip = (map & 2) != 0, rel = (map & 4) != 0;
        double sx, sz;
        if (swap) { sx = wy; sz = flip ? -wx : wx; }
        else      { sx = wx; sz = flip ? -wy : wy; }
        if (rel && origin != null) { sx -= origin.x(); sz -= origin.z(); }
        return new double[] { sx, sz };
    }

    static String mapName(int map) {
        return ((map & 1) != 0 ? "swap" : "noswap") + "," + ((map & 2) != 0 ? "flip" : "noflip") + "," + ((map & 4) != 0 ? "origin" : "absolute");
    }

    private void diag(String why, double[] cam, FrameView v) {
        long now = System.currentTimeMillis();
        if (now < nextDiag) return;
        nextDiag = now + 5000L;
        Vec3 e = v.eye(), o = v.sceneOrigin();
        log("axes " + why + ": camera(view)=(" + f1(cam[0]) + "," + f1(cam[1]) + "," + f1(cam[2]) + ") colMajor=" + (cam[3] > 0)
                + " eye=" + vec(e) + " sceneOrigin=" + vec(o)
                + " player=(" + f1(ZoneState.playerX()) + "," + f1(ZoneState.playerY()) + "," + f1(ZoneState.playerZ()) + ")");
    }

    private boolean matchAxes(double[] cam, FrameView v) {
        if (!ZoneState.hasPlayer()) { diag("waiting for player position from Lua", cam, v); return false; }
        double px = ZoneState.playerX(), py = ZoneState.playerY();
        if (mapping >= 0) {
            double[] r = toRender(mapping, px, py, v.sceneOrigin());
            if (Math.hypot(r[0] - cam[0], r[1] - cam[2]) <= RECHECK_TILES) return true;
            log("axes drifted (" + mapName(mapping) + "), matching again");
            mapping = -1;
        }
        int best = -1;
        double bestErr = Double.MAX_VALUE;
        for (int map = 0; map < 8; map++) {
            double[] r = toRender(map, px, py, v.sceneOrigin());
            double err = Math.hypot(r[0] - cam[0], r[1] - cam[2]);
            if (err < bestErr) { bestErr = err; best = map; }
        }
        if (bestErr <= MATCH_TILES) {
            mapping = best;
            log("axes matched: " + mapName(best) + " (camera-to-player " + f1(bestErr) + " tiles)");
            return true;
        }
        diag("no mapping within " + MATCH_TILES + " tiles (best " + mapName(best) + " " + f1(bestErr) + ")", cam, v);
        return false;
    }

    // ── draw ───────────────────────────────────────────────────

    private void draw(DrawContext dc) {
        if (broken) return;
        double[] blue = ZoneState.currentBlue();
        if (blue == null || blue[2] < 1) return;
        try {
            FrameView v = dc.view();
            float[] view = v.view(), proj = v.projection();
            double[] cam = cameraFromView(view);
            if (!matchAxes(cam, v)) return;
            int quads = buildArc(blue, cam, v);
            stats(quads);
            if (quads == 0) return;
            if (!gpuReady(dc.gpu())) return;
            buffer.upload(verts);
            program.setMatrix("uView", view)
                   .setMatrix("uProj", proj)
                   .set("uColor", COLOR)
                   .set("uTime", (float) (v.seconds() % 1000.0));
            dc.gpu().draw(program, mesh, Primitive.TRIANGLES, 0, quads * VERTS_PER_QUAD);
        } catch (Throwable t) {
            fail("draw", t);
        }
    }

    /** fills verts with the arc of the blue circle facing the player; returns the quad count */
    private int buildArc(double[] blue, double[] cam, FrameView v) {
        double cx = blue[0], cy = blue[1], r = blue[2];
        double px = ZoneState.playerX(), py = ZoneState.playerY();
        double dx = px - cx, dy = py - cy;
        double dist = Math.sqrt(dx * dx + dy * dy);
        if (Math.abs(dist - r) > SHOW_RANGE) { skippedFar++; return 0; }
        double phi = Math.atan2(dy, dx);
        double span = Math.min(Math.PI, ARC_HALF / r);
        int quads = (int) Math.ceil(2 * span * r / SEG);
        if (quads < 4) quads = 4; else if (quads > MAX_QUADS) quads = MAX_QUADS;
        double a0 = phi - span, da = 2 * span / quads;
        float yLo = (float) (cam[1] - BELOW), yHi = (float) (cam[1] + ABOVE);
        Vec3 origin = v.sceneOrigin();
        int k = 0;
        double[] p1 = toRender(mapping, cx + r * Math.cos(a0), cy + r * Math.sin(a0), origin);
        float u1 = 0f;
        for (int i = 1; i <= quads; i++) {
            double a = a0 + da * i;
            double[] p2 = toRender(mapping, cx + r * Math.cos(a), cy + r * Math.sin(a), origin);
            float u2 = (float) (r * da * i);
            k = vert(k, p1, yLo, u1, 0f);
            k = vert(k, p2, yLo, u2, 0f);
            k = vert(k, p2, yHi, u2, 1f);
            k = vert(k, p1, yLo, u1, 0f);
            k = vert(k, p2, yHi, u2, 1f);
            k = vert(k, p1, yHi, u1, 1f);
            p1 = p2;
            u1 = u2;
        }
        // unused tail stays from earlier frames; only quads * 6 vertices are drawn
        return quads;
    }

    private int vert(int k, double[] p, float y, float u, float vv) {
        verts[k] = (float) p[0];
        verts[k + 1] = y;
        verts[k + 2] = (float) p[1];
        verts[k + 3] = u;
        verts[k + 4] = vv;
        return k + FLOATS_PER_VERT;
    }

    private void stats(int quads) {
        if (quads > 0) drawnFrames++;
        long now = System.currentTimeMillis();
        if (now < nextStat) return;
        if (nextStat != 0) log("wall frames drawn=" + drawnFrames + " skipped(far from edge)=" + skippedFar + " last quads=" + quads + " (last 10s)");
        nextStat = now + 10000L;
        drawnFrames = 0;
        skippedFar = 0;
    }

    static String f1(double d) { return String.valueOf(Math.round(d * 10) / 10.0); }
    static String vec(Vec3 p) { return p == null ? "null" : "(" + f1(p.x()) + "," + f1(p.y()) + "," + f1(p.z()) + ")"; }
}
