package t3bluezone;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Blue Zone state for the wall, read straight from Lua and the game (no Lua -> Java bridge).
 *
 * Lua: the global table BlueZone.C (BlueZoneClient.lua) is the last server snapshot. It is replaced as a whole on every
 * State and set to nil on Stopped, never edited in place, so reading its fields from the render thread sees one snapshot.
 * Fields used: phase, seg, dur, remain, paused, recvAt (getTimestampMs = System.currentTimeMillis), fx fy fr, wx wy wr.
 * The blue circle exists from the phase 1 shrink on (BlueZone.blueActive in BlueZoneConfig.lua): nothing to draw
 * during the phase 1 wait. During "shrink" it moves from f* to w* linearly, as BlueZone.blueAt does.
 * Player: IsoPlayer.getInstance() x / y, used to pick the arc near the player.
 * Camera: BlueZone.VP { yaw, at } (BlueZoneDisplay.lua, Viewpoint's eye yaw in world atan2(dy, dx) degrees and the
 * getTimestampMs it was read at), used by BlueZoneWall to check its axis mapping. NaN when Lua has not sent one.
 * Everything is reached by reflection (Kahlua table / game classes), so the jar needs no game jar to build.
 */
public final class ZoneState {
    private ZoneState() {}

    private static boolean resolved, broken;
    private static Field fEnv;
    private static Method mRawget, mGetInstance, mGetX, mGetY;
    private static int errors;
    private static String lastState = "";

    static double px, py;
    static boolean hasPlayer;
    static double camYaw = Double.NaN;
    static long camYawAt;

    private static void fail(String where, Throwable t) {
        errors++;
        if (errors <= 5) BlueZoneWall.log("state " + where + " failed (" + errors + "): " + t);
        if (errors >= 20) {
            broken = true;
            BlueZoneWall.log("state reading off after " + errors + " errors");
        }
    }

    private static boolean resolve() {
        if (resolved) return true;
        if (broken) return false;
        try {
            ClassLoader cl = ZoneState.class.getClassLoader();
            Class<?> lm = Class.forName("zombie.Lua.LuaManager", false, cl);
            fEnv = lm.getField("env");
            Class<?> kt = Class.forName("se.krka.kahlua.vm.KahluaTable", false, cl);
            mRawget = kt.getMethod("rawget", Object.class);
            Class<?> ip = Class.forName("zombie.characters.IsoPlayer", false, cl);
            mGetInstance = ip.getMethod("getInstance");
            mGetX = ip.getMethod("getX");
            mGetY = ip.getMethod("getY");
            resolved = true;
            BlueZoneWall.log("state lookups resolved (LuaManager.env, KahluaTable.rawget, IsoPlayer.getInstance)");
            return true;
        } catch (Throwable t) {
            broken = true;
            BlueZoneWall.log("state lookups FAILED, wall off: " + t);
            return false;
        }
    }

    private static Object get(Object table, String key) throws Exception {
        return table == null ? null : mRawget.invoke(table, key);
    }

    private static double num(Object table, String key) throws Exception {
        Object v = get(table, key);
        return v instanceof Number ? ((Number) v).doubleValue() : Double.NaN;
    }

    /** current blue circle {cx, cy, r} in world tiles, or null when there is none (no round / phase 1 wait / error) */
    static double[] currentBlue() {
        if (!resolve()) return null;
        try {
            Object p = mGetInstance.invoke(null);
            hasPlayer = p != null;
            if (p != null) {
                px = ((Number) mGetX.invoke(p)).doubleValue();
                py = ((Number) mGetY.invoke(p)).doubleValue();
            }
            Object bz = get(fEnv.get(null), "BlueZone");
            Object vp = get(bz, "VP");
            double yaw = num(vp, "yaw"), at = num(vp, "at");
            camYaw = yaw;
            camYawAt = Double.isNaN(at) ? 0L : (long) at;
            Object c = get(bz, "C");
            if (c == null) { note("no round"); return null; }
            double phase = num(c, "phase");
            Object seg = get(c, "seg");
            if (!(phase >= 1) || (phase == 1 && "wait".equals(seg))) { note("blue inactive (phase " + (long) phase + " " + seg + ")"); return null; }
            double fx = num(c, "fx"), fy = num(c, "fy"), fr = num(c, "fr");
            double wx = num(c, "wx"), wy = num(c, "wy"), wr = num(c, "wr");
            if (!"shrink".equals(seg) || !(wr >= 0)) { note("blue still phase " + (long) phase + " " + seg); return new double[] { fx, fy, fr }; }
            double dur = num(c, "dur"), remain = num(c, "remain"), recvAt = num(c, "recvAt");
            boolean paused = Boolean.TRUE.equals(get(c, "paused"));
            double elapsed = paused ? 0 : System.currentTimeMillis() - recvAt;
            double left = Math.max(0, remain - elapsed);
            double f = dur > 0 ? (dur - left) / dur : 1;
            if (f < 0) f = 0; else if (f > 1) f = 1;
            note("blue shrinking phase " + (long) phase + (paused ? " (paused)" : ""));
            return new double[] { fx + (wx - fx) * f, fy + (wy - fy) * f, fr + (wr - fr) * f };
        } catch (Throwable t) {
            fail("read", t);
            return null;
        }
    }

    private static void note(String s) {
        if (!s.equals(lastState)) {
            lastState = s;
            BlueZoneWall.log("zone: " + s);
        }
    }
}
