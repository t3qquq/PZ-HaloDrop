package t3bluezone;

/**
 * Blue Zone state shared between the Lua export (game thread) and the draw callback (render thread).
 * The current blue circle is interpolated here from the last snapshot and the local clock,
 * the same way BlueZoneClient.lua does it (remain counts down from the moment the snapshot arrived).
 */
public final class ZoneState {
    public static final String VERSION = "0.1.0";

    private ZoneState() {}

    /** immutable snapshot */
    static final class Snap {
        final double fx, fy, fr, wx, wy, wr, durMs, remainMs;
        final boolean shrinking, paused;
        final long recvAt;

        Snap(double fx, double fy, double fr, double wx, double wy, double wr,
             double durMs, double remainMs, boolean shrinking, boolean paused, long recvAt) {
            this.fx = fx; this.fy = fy; this.fr = fr;
            this.wx = wx; this.wy = wy; this.wr = wr;
            this.durMs = durMs; this.remainMs = remainMs;
            this.shrinking = shrinking; this.paused = paused;
            this.recvAt = recvAt;
        }
    }

    private static volatile Snap snap;
    private static volatile double px, py, pz;
    private static volatile long playerAt;
    private static int setLogged;

    public static void set(double fx, double fy, double fr, double wx, double wy, double wr,
                           double durMs, double remainMs, boolean shrinking, boolean paused) {
        Snap prev = snap;
        snap = new Snap(fx, fy, fr, wx, wy, wr, durMs, remainMs, shrinking, paused, System.currentTimeMillis());
        boolean changed = prev == null || prev.shrinking != shrinking || prev.paused != paused || prev.fr != fr || prev.wr != wr;
        if (changed && setLogged < 40) {
            setLogged++;
            BlueZoneWall.log("zone set: blue=(" + r0(fx) + "," + r0(fy) + " r" + r0(fr) + ") white=(" + r0(wx) + "," + r0(wy) + " r" + r0(wr)
                    + ") dur=" + r0(durMs) + "ms remain=" + r0(remainMs) + "ms shrinking=" + shrinking + " paused=" + paused);
        }
    }

    public static void clear() {
        if (snap != null) BlueZoneWall.log("zone cleared");
        snap = null;
    }

    public static void player(double x, double y, double z) {
        px = x; py = y; pz = z;
        playerAt = System.currentTimeMillis();
    }

    static boolean hasPlayer() {
        return playerAt != 0 && System.currentTimeMillis() - playerAt < 5000L;
    }

    static double playerX() { return px; }
    static double playerY() { return py; }
    static double playerZ() { return pz; }

    /** current blue circle {cx, cy, r} in world tiles, or null when there is no round */
    static double[] currentBlue() {
        Snap s = snap;
        if (s == null) return null;
        if (!s.shrinking || s.wr < 0 || s.durMs <= 0) return new double[] { s.fx, s.fy, s.fr };
        double elapsed = s.paused ? 0 : (System.currentTimeMillis() - s.recvAt);
        double remain = Math.max(0, s.remainMs - elapsed);
        double f = (s.durMs - remain) / s.durMs;
        if (f < 0) f = 0; else if (f > 1) f = 1;
        return new double[] { s.fx + (s.wx - s.fx) * f, s.fy + (s.wy - s.fy) * f, s.fr + (s.wr - s.fr) * f };
    }

    static String r0(double v) { return Long.toString(Math.round(v)); }
}
