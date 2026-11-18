package t3bluezone.lua;

import t3bluezone.ZoneState;
import viewpoint.api.lua.LuaExport;

/**
 * Lua -> Java bridge (Viewpoint addon exports). Called from BlueZoneViewpoint.lua on the game thread.
 * Lua reaches it as Viewpoint.Addons["t3bluezone"].Zone.<name> (the Lua side also tries other nestings and logs what it found).
 * Only numbers and booleans cross the bridge; the render thread reads the copy in ZoneState.
 */
@LuaExport(name = "Zone")
public final class Zone {
    private Zone() {}

    /**
     * One Blue Zone snapshot (BlueZone.C on the Lua side).
     * f* = blue circle at the start of the current segment, w* = white circle (wr < 0: none),
     * durMs / remainMs = current segment, shrinking = seg "shrink", paused = admin pause.
     */
    @LuaExport(name = "set")
    public static void set(double fx, double fy, double fr, double wx, double wy, double wr,
                           double durMs, double remainMs, boolean shrinking, boolean paused) {
        ZoneState.set(fx, fy, fr, wx, wy, wr, durMs, remainMs, shrinking, paused);
    }

    @LuaExport(name = "clear")
    public static void clear() {
        ZoneState.clear();
    }

    /** Local player position in PZ world tiles: used to find how Viewpoint scene axes map to the world. */
    @LuaExport(name = "player")
    public static void player(double x, double y, double z) {
        ZoneState.player(x, y, z);
    }

    @LuaExport(name = "version")
    public static String version() {
        return ZoneState.VERSION;
    }
}
