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
 */
final class SkyLight {
    static final String TAG = "[HaloDrop][SkyLight] ";
    static final String VAR = "HaloDropPose";

    private static boolean resolved, broken;
    private static Field fInstChar, fInstPlayerData, fPdAmbient;
    private static Field fSlotChar, fSlotR, fSlotG, fSlotB;
    private static Method mGetVar, mVecSet, mRsInstance, mRsAmbient;
    private static int errors;
    private static long nextStateLog;
    private static int applied;

    private SkyLight() {}

    static void log(String s) { System.out.println(TAG + s); }

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

    static void onInstanceLights(Object inst) {
        if (!ready(inst)) return;
        try {
            if (!inAir(fInstChar.get(inst))) return;
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

    static void onSlotInit(Object slot) {
        if (!ready(slot)) return;
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
}
