package halodropclient;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Halo Drop: jumpers drawn pitch black while high in the air.
 *
 * Why: vanilla lights a character model from the square it stands on
 *   (ModelInstance.PlayerData.updateLights -> square.interpolateLight -> currentAmbient,
 *    then ModelSlotRenderData.initModel copies currentAmbient to ambientR/G/B).
 *   The empty air squares Halo Drop creates above the map (air fill, up to z 31) never get light data,
 *   so the ambient is 0 and the jumper and the parachute render as a black silhouette.
 * What: while the character has the anim variable HaloDropPose (set by HaloDropPose.lua from the jump until
 *   the engine fall takes over), replace that ambient with the player's sky ambient
 *   (RenderSettings.getAmbientForPlayer, the value vanilla uses for a vehicle with no square).
 *   Every other character is left untouched. Works for remote jumpers too (they get the variable from the relay).
 * Everything is reached by reflection so the jar needs no game jar to build.
 * Viewpoint does not use that ambient for its 1st/3rd person view (run 11-17: override active, still black):
 * it reads its own light grid at the character's square. PatchVpSky/PatchVpLight swap those lookups for the
 * ground values below while a jumper is on that square. This class remembers where jumpers are (jumperAt).
 * The jump plane (HaloDropC17, z 31) has the same problem: viewpoint.models.VehicleCapture reads the same two
 * lookups (javap names only), so it came out as a black silhouette right before the jump (run 11-18, 6:42).
 * scanPlanes() finds those vehicles in the cell every PLANE_SCAN_MS and planeAt() covers a box around each.
 * The class and the hook methods must be public: ZombieBuddy inlines the @Patch advice into the game class
 * (zombie.core.skinnedmodel.model.ModelInstance), which is in another package (0.1.0 was package-private ->
 * IllegalAccessError on every character render).
 */
public final class SkyLight {
    static final String TAG = "[HaloDrop][SkyLight] ";
    static final String VAR = "HaloDropPose";

    private static boolean resolved, broken;
    private static Field fInstChar, fInstPlayerData, fPdAmbient;
    private static Field fSlotChar, fSlotR, fSlotG, fSlotB;
    private static Method mGetVar, mVecSet, mRsInstance, mRsAmbient;
    private static int errors;
    private static long nextStateLog;
    private static int applied;

    // where airborne jumpers were drawn recently (game thread writes, Viewpoint threads read)
    private static final int SLOTS = 8;
    private static final long KEEP_MS = 1500L;
    private static final int[] jx = new int[SLOTS], jy = new int[SLOTS], jz = new int[SLOTS];
    private static final long[] jt = new long[SLOTS];
    private static Method mGetX, mGetY, mGetZ;
    // Viewpoint lookups called again for the ground square (z 0)
    private static Method mVpSky, mVpLight;
    private static boolean vpResolved, vpBroken;
    private static final ThreadLocal<boolean[]> inVp = ThreadLocal.withInitial(() -> new boolean[1]);
    private static int vpLogged, vpPlaneLogged;
    private static long vpNextLog;
    private static int vpSkySwaps, vpLightSwaps, vpPlaneSwaps;

    // Halo Drop jump planes in the loaded cell (game thread scans, Viewpoint threads read)
    static final String PLANE_SUFFIX = "HaloDropC17";
    // the jump plane flies 200 tiles/s: 200 ms between scans left it 40 tiles past a 32-tile box (run 11-18 d27c7e2: plane swaps 0)
    private static final long PLANE_SCAN_MS = 50L;
    private static final int PLANE_REACH = 48;      // tiles around the vehicle origin (C-17 is about 53 tiles long)
    private static final int PLANE_Z_REACH = 2;
    // the vehicle's own z stays 0 while the client moves it with setWorldTransform (run 11-18 fix1:
    // "tracked ... at (5889,10123,0)", plane swaps 0, C-17 still black up close) -> use the flight level
    private static final int PLANE_LEVEL = 31;
    private static final int PLANE_MIN_Z = 20;
    private static final int PLANE_SLOTS = 4;
    private static final int[] px = new int[PLANE_SLOTS], py = new int[PLANE_SLOTS], pz = new int[PLANE_SLOTS];
    private static volatile int planeCount;
    private static long nextPlaneScan;
    private static boolean planeResolved, planeBroken;
    private static Field fWorldInstance, fWorldCell;
    private static Method mCellVehicles, mVehScript, mVehX, mVehY, mVehZ;
    private static int lastPlaneCount;

    private SkyLight() {}

    public static void log(String s) { System.out.println(TAG + s); }

    private static void fail(String where, Throwable t) {
        errors++;
        if (errors <= 5) log(where + " failed (" + errors + "): " + t + (t.getCause() != null ? " cause=" + t.getCause() : ""));
        if (!resolved) broken = true; // member names changed: stop, vanilla lighting stays
    }

    private static void resolve(ClassLoader cl) throws Exception {
        Class<?> mi = Class.forName("zombie.core.skinnedmodel.model.ModelInstance", false, cl);
        fInstChar = mi.getField("character");
        fInstPlayerData = mi.getField("playerData");
        Class<?> pd = Class.forName("zombie.core.skinnedmodel.model.ModelInstance$PlayerData", false, cl);
        fPdAmbient = pd.getField("currentAmbient");
        mVecSet = fPdAmbient.getType().getMethod("set", float.class, float.class, float.class);
        Class<?> msr = Class.forName("zombie.core.skinnedmodel.model.ModelSlotRenderData", false, cl);
        fSlotChar = msr.getField("character");
        fSlotR = msr.getField("ambientR");
        fSlotG = msr.getField("ambientG");
        fSlotB = msr.getField("ambientB");
        Class<?> rs = Class.forName("zombie.core.opengl.RenderSettings", false, cl);
        mRsInstance = rs.getMethod("getInstance");
        mRsAmbient = rs.getMethod("getAmbientForPlayer", int.class);
        Class<?> chr = Class.forName("zombie.characters.IsoGameCharacter", false, cl);
        mGetVar = chr.getMethod("getVariableString", String.class);
        mGetX = chr.getMethod("getX");
        mGetY = chr.getMethod("getY");
        mGetZ = chr.getMethod("getZ");
        resolved = true;
        log("members resolved");
    }

    private static boolean ready(Object o) {
        if (broken || o == null) return false;
        if (!resolved) {
            try { resolve(o.getClass().getClassLoader()); }
            catch (Throwable t) { fail("resolve", t); return false; }
        }
        return true;
    }

    /** true while Halo Drop drives this character's pose (jump -> release to engine fall). */
    private static boolean inAir(Object character) throws Exception {
        if (character == null) return false;
        Object v = mGetVar.invoke(character, VAR);
        return v instanceof String && !((String) v).isEmpty();
    }

    private static float sky() throws Exception {
        Object rs = mRsInstance.invoke(null);
        float a = rs == null ? 0f : ((Float) mRsAmbient.invoke(rs, 0)).floatValue();
        return a;
    }

    private static void stateLog(float amb) {
        applied++;
        long now = System.currentTimeMillis();
        if (now >= nextStateLog) {
            nextStateLog = now + 5000L;
            log("override active: ambient=" + amb + " calls=" + applied);
            applied = 0;
        }
    }

    public static void onInstanceLights(Object inst) {
        if (!ready(inst)) return;
        scanPlanes(inst.getClass().getClassLoader());
        try {
            Object chr = fInstChar.get(inst);
            if (!inAir(chr)) return;
            remember(chr);
            Object[] pds = (Object[]) fInstPlayerData.get(inst);
            if (pds == null) return;
            float a = sky();
            for (Object pd : pds) {
                if (pd == null) continue;
                Object vec = fPdAmbient.get(pd);
                if (vec != null) mVecSet.invoke(vec, a, a, a);
            }
            stateLog(a);
        } catch (Throwable t) {
            fail("instance lights", t);
        }
    }

    public static void onSlotInit(Object slot) {
        if (!ready(slot)) return;
        // vehicles come through here too (the player is hidden while the jump plane flies past)
        scanPlanes(slot.getClass().getClassLoader());
        try {
            if (!inAir(fSlotChar.get(slot))) return;
            float a = sky();
            fSlotR.setFloat(slot, a);
            fSlotG.setFloat(slot, a);
            fSlotB.setFloat(slot, a);
        } catch (Throwable t) {
            fail("slot ambient", t);
        }
    }

    private static void remember(Object chr) {
        try {
            int x = (int) Math.floor(((Number) mGetX.invoke(chr)).doubleValue());
            int y = (int) Math.floor(((Number) mGetY.invoke(chr)).doubleValue());
            int z = (int) Math.floor(((Number) mGetZ.invoke(chr)).doubleValue());
            long now = System.currentTimeMillis();
            synchronized (jt) {
                int slot = 0;
                for (int i = 0; i < SLOTS; i++) {
                    if (jx[i] == x && jy[i] == y && jz[i] == z) { slot = i; break; }
                    if (jt[i] < jt[slot]) slot = i;
                }
                jx[slot] = x; jy[slot] = y; jz[slot] = z; jt[slot] = now;
            }
        } catch (Throwable t) {
            fail("remember", t);
        }
    }

    private static void planeResolve(ClassLoader cl) throws Exception {
        Class<?> w = Class.forName("zombie.iso.IsoWorld", false, cl);
        fWorldInstance = w.getField("instance");
        fWorldCell = w.getField("currentCell");
        Class<?> cell = Class.forName("zombie.iso.IsoCell", false, cl);
        mCellVehicles = cell.getMethod("getVehicles");
        Class<?> veh = Class.forName("zombie.vehicles.BaseVehicle", false, cl);
        mVehScript = veh.getMethod("getScriptName");
        mVehX = veh.getMethod("getX");
        mVehY = veh.getMethod("getY");
        mVehZ = veh.getMethod("getZ");
        planeResolved = true;
        log("plane members resolved");
    }

    /** every PLANE_SCAN_MS: where the Halo Drop jump planes are (game thread, from the character light hook) */
    private static void scanPlanes(ClassLoader cl) {
        if (planeBroken) return;
        long now = System.currentTimeMillis();
        if (now < nextPlaneScan) return;
        nextPlaneScan = now + PLANE_SCAN_MS;
        try {
            if (!planeResolved) planeResolve(cl);
            Object world = fWorldInstance.get(null);
            Object cell = world == null ? null : fWorldCell.get(world);
            Object set = cell == null ? null : mCellVehicles.invoke(cell);
            int n = 0;
            if (set instanceof Iterable) {
                for (Object v : (Iterable<?>) set) {
                    if (n >= PLANE_SLOTS || v == null) continue;
                    Object name = mVehScript.invoke(v);
                    if (!(name instanceof String) || !((String) name).endsWith(PLANE_SUFFIX)) continue;
                    int x = (int) Math.floor(((Number) mVehX.invoke(v)).doubleValue());
                    int y = (int) Math.floor(((Number) mVehY.invoke(v)).doubleValue());
                    int z = (int) Math.floor(((Number) mVehZ.invoke(v)).doubleValue());
                    synchronized (px) { px[n] = x; py[n] = y; pz[n] = z; }
                    n++;
                }
            }
            planeCount = n;
            if (n != lastPlaneCount) {
                log(n > 0 ? ("jump plane tracked for light swap: count=" + n + " first at (" + px[0] + "," + py[0] + "," + pz[0] + ")")
                          : "jump plane gone, plane light swap idle");
                lastPlaneCount = n;
            }
        } catch (java.util.ConcurrentModificationException e) {
            // the cell vehicle set changed mid-scan; try again next time
        } catch (Throwable t) {
            planeBroken = true;
            log("plane scan failed, plane light swap off: " + t);
        }
    }

    /** true when the square is inside the box around a tracked jump plane */
    static boolean planeAt(int x, int y, int z) {
        int n = planeCount;
        for (int i = 0; i < n; i++) {
            int zc = pz[i] >= PLANE_MIN_Z ? pz[i] : PLANE_LEVEL;
            if (Math.abs(px[i] - x) <= PLANE_REACH && Math.abs(py[i] - y) <= PLANE_REACH && Math.abs(zc - z) <= PLANE_Z_REACH) return true;
        }
        return false;
    }

    /** true when a jumper was drawn on or next to this square in the last KEEP_MS (z within 1 level) */
    static boolean jumperAt(int x, int y, int z) {
        long now = System.currentTimeMillis();
        for (int i = 0; i < SLOTS; i++) {
            if (now - jt[i] > KEEP_MS) continue;
            if (Math.abs(jx[i] - x) <= 1 && Math.abs(jy[i] - y) <= 1 && Math.abs(jz[i] - z) <= 1) return true;
        }
        return false;
    }

    private static boolean vpReady() {
        if (vpBroken) return false;
        if (vpResolved) return true;
        try {
            Class<?> ol = Class.forName("viewpoint.light.OwnedLight", false, SkyLight.class.getClassLoader());
            mVpSky = ol.getMethod("modelSky", int.class, int.class, int.class, boolean.class);
            mVpLight = ol.getMethod("modelLightAt", int.class, int.class, int.class);
            vpResolved = true;
            log("viewpoint light lookups resolved");
            return true;
        } catch (Throwable t) {
            vpBroken = true;
            log("viewpoint light lookups not found, ground swap off: " + t);
            return false;
        }
    }

    private static void vpLog(String what, int x, int y, int z, Object orig, Object ground) {
        boolean planeLog = what.startsWith("plane");
        if (planeLog ? vpPlaneLogged < 6 : vpLogged < 12) {
            if (planeLog) vpPlaneLogged++; else vpLogged++;
            log("vp " + what + " swap at (" + x + "," + y + "," + z + ") orig=" + orig + " ground=" + ground);
        }
        long now = System.currentTimeMillis();
        if (now >= vpNextLog) {
            vpNextLog = now + 5000L;
            log("vp ground swap active: sky=" + vpSkySwaps + " light=" + vpLightSwaps + " plane=" + vpPlaneSwaps + " (last 5s)");
            vpSkySwaps = 0;
            vpLightSwaps = 0;
            vpPlaneSwaps = 0;
        }
    }

    // diagnostics: which levels Viewpoint asks about inside the plane box (is the C-17 lit through these lookups at all?)
    private static int diagLow, diagMid, diagHigh;
    private static long diagNext;
    private static void planeDiag(int x, int y, int z) {
        if (planeCount <= 0) return;
        boolean inBox = false;
        for (int i = 0; i < planeCount; i++)
            if (Math.abs(px[i] - x) <= PLANE_REACH && Math.abs(py[i] - y) <= PLANE_REACH) { inBox = true; break; }
        if (!inBox) return;
        if (z <= 0) diagLow++; else if (z < PLANE_MIN_Z) diagMid++; else diagHigh++;
        long now = System.currentTimeMillis();
        if (now >= diagNext) {
            if (diagNext != 0) log("plane box lookups (last 1s): z<=0 " + diagLow + ", z1-" + (PLANE_MIN_Z - 1) + " " + diagMid
                    + ", z>=" + PLANE_MIN_Z + " " + diagHigh + " at plane (" + px[0] + "," + py[0] + "," + pz[0] + ")");
            diagNext = now + 1000L;
            diagLow = diagMid = diagHigh = 0;
        }
    }

    public static float vpSky(int x, int y, int z, boolean flag, float orig) {
        planeDiag(x, y, z);
        if (z <= 0) return orig;
        boolean plane = false;
        if (!jumperAt(x, y, z)) {
            if (!planeAt(x, y, z)) return orig;
            plane = true;
        }
        boolean[] busy = inVp.get();
        if (busy[0] || !vpReady()) return orig;
        busy[0] = true;
        try {
            float g = ((Number) mVpSky.invoke(null, x, y, 0, flag)).floatValue();
            if (plane) vpPlaneSwaps++; else vpSkySwaps++;
            vpLog(plane ? "plane sky" : "sky", x, y, z, orig, g);
            return g;
        } catch (Throwable t) {
            fail("vp sky", t);
            return orig;
        } finally {
            busy[0] = false;
        }
    }

    public static int vpLight(int x, int y, int z, int orig) {
        if (z <= 0) return orig;
        boolean plane = false;
        if (!jumperAt(x, y, z)) {
            if (!planeAt(x, y, z)) return orig;
            plane = true;
        }
        boolean[] busy = inVp.get();
        if (busy[0] || !vpReady()) return orig;
        busy[0] = true;
        try {
            int g = ((Number) mVpLight.invoke(null, x, y, 0)).intValue();
            if (plane) vpPlaneSwaps++; else vpLightSwaps++;
            vpLog(plane ? "plane light" : "light", x, y, z, "0x" + Integer.toHexString(orig), "0x" + Integer.toHexString(g));
            return g;
        } catch (Throwable t) {
            fail("vp light", t);
            return orig;
        } finally {
            busy[0] = false;
        }
    }
}
