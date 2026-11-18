package halodrop;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.security.ProtectionDomain;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaCallFrame;

/**
 * Halo Drop dedicated-server agent.
 *
 * Adds two functions to the Lua global table HaloDropNative (created by HaloDropPreload.lua):
 *   HaloDropNative.state(x, y)   -> -2 error, -1 outside map, 0 not requested, 1 loaded, 2 loading
 *   HaloDropNative.preload(x, y) -> asks the server to load (or keep) the 64x64 server cell that holds tile (x, y),
 *                                   then returns the same codes as state()
 * Both run on the server main thread because server Lua calls them.
 *
 * No game class is modified. The agent thread only replaces the values of keys that Lua already created
 * (no structural change to the Lua table), and it never forces LuaManager to initialise early.
 */
public final class Agent {
    static final String TAG = "[HaloDropAgent] ";
    static final double VERSION = 1.0;
    static volatile boolean luaManagerLoaded;

    public static void premain(String args, Instrumentation inst) {
        log("premain, java " + System.getProperty("java.version"));
        try {
            inst.addTransformer(new ClassFileTransformer() {
                @Override
                public byte[] transform(ClassLoader loader, String name, Class<?> cls, ProtectionDomain pd, byte[] bytes) {
                    if ("zombie/Lua/LuaManager".equals(name)) luaManagerLoaded = true;
                    return null; // observe only, never change a class
                }
            });
        } catch (Throwable t) {
            log("addTransformer failed: " + t);
        }
        Thread th = new Thread(Agent::run, "HaloDropAgent");
        th.setDaemon(true);
        th.start();
    }

    static void log(String s) {
        System.out.println(TAG + s);
    }

    static void run() {
        Field envField = null;
        int registered = 0;
        boolean waitingLogged = false;
        while (true) {
            try {
                Thread.sleep(2000L);
                if (!luaManagerLoaded) continue;
                if (envField == null) {
                    // the main thread has already loaded the class; reading the field only waits for its own init
                    Class<?> lm = Class.forName("zombie.Lua.LuaManager", false, ClassLoader.getSystemClassLoader());
                    envField = lm.getField("env");
                }
                Object env = envField.get(null);
                if (!(env instanceof KahluaTable)) continue;
                Object slot = ((KahluaTable) env).rawget("HaloDropNative");
                if (!(slot instanceof KahluaTable)) {
                    if (!waitingLogged) {
                        waitingLogged = true;
                        log("waiting for Lua global HaloDropNative (HaloDropPreload.lua)");
                    }
                    continue;
                }
                KahluaTable t = (KahluaTable) slot;
                // Lua creates the keys with the value false; replacing an existing value does not restructure the table
                if (Boolean.FALSE.equals(t.rawget("preload")) && Boolean.FALSE.equals(t.rawget("state"))
                        && Boolean.FALSE.equals(t.rawget("version"))) {
                    t.rawset("state", new CellFn(false));
                    t.rawset("preload", new CellFn(true));
                    t.rawset("version", Double.valueOf(VERSION));
                    registered++;
                    log("registered HaloDropNative.state/preload (count " + registered + ")");
                }
            } catch (InterruptedException e) {
                return;
            } catch (Throwable t) {
                log("agent loop error: " + t);
                try { Thread.sleep(10000L); } catch (InterruptedException e) { return; }
            }
        }
    }

    /** state(x, y) / preload(x, y). x, y are world tile coordinates. */
    static final class CellFn implements JavaFunction {
        private final boolean load;
        private static boolean resolved;
        private static boolean broken;
        private static Field fInstance, fIsLoaded;
        private static Method mMinX, mMinY, mInvalid, mLoad, mGetCell;
        private static int errors;

        CellFn(boolean load) {
            this.load = load;
        }

        private static void resolve() throws Exception {
            Class<?> sm = Class.forName("zombie.network.ServerMap");
            fInstance = sm.getField("instance");
            mMinX = sm.getMethod("getMinX");
            mMinY = sm.getMethod("getMinY");
            mInvalid = sm.getMethod("isInvalidCell", int.class, int.class);
            mLoad = sm.getMethod("loadOrKeepRelevent", int.class, int.class);
            mGetCell = sm.getMethod("getCell", int.class, int.class);
            Class<?> sc = Class.forName("zombie.network.ServerMap$ServerCell");
            fIsLoaded = sc.getField("isLoaded");
            resolved = true;
            log("ServerMap members resolved");
        }

        @Override
        public int call(LuaCallFrame frame, int nArguments) {
            double code = -2.0;
            try {
                if (!broken && nArguments >= 2 && frame.get(0) instanceof Double && frame.get(1) instanceof Double) {
                    if (!resolved) resolve();
                    int x = (int) Math.floor(((Double) frame.get(0)).doubleValue());
                    int y = (int) Math.floor(((Double) frame.get(1)).doubleValue());
                    Object sm = fInstance.get(null);
                    int cx = Math.floorDiv(x, 64) - ((Integer) mMinX.invoke(sm)).intValue();
                    int cy = Math.floorDiv(y, 64) - ((Integer) mMinY.invoke(sm)).intValue();
                    if (((Boolean) mInvalid.invoke(sm, cx, cy)).booleanValue()) {
                        code = -1.0;
                    } else {
                        if (load) mLoad.invoke(sm, cx, cy);
                        Object cell = mGetCell.invoke(sm, cx, cy);
                        if (cell == null) code = 0.0;
                        else code = fIsLoaded.getBoolean(cell) ? 1.0 : 2.0;
                    }
                }
            } catch (Throwable t) {
                errors++;
                if (errors <= 5) log("cell call failed (" + errors + "): " + t + (t.getCause() != null ? " cause=" + t.getCause() : ""));
                if (!resolved) broken = true; // member names changed: stop trying, Lua sees -2
            }
            frame.push(Double.valueOf(code));
            return 1;
        }
    }
}
