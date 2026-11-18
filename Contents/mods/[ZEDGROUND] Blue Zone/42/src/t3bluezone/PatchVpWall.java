package t3bluezone;

import me.zed_0xff.zombie_buddy.Patch;

/**
 * Viewpoint draws addon callbacks for DrawPoint.AFTER_TRANSLUCENT in viewpoint.render.AddonDraws.afterTranslucent(FrameContext)
 * (javap, Viewpoint jar of 11-19). Addons are only found among the mods enabled at the main menu, so a server mod
 * never gets there; this patch draws the wall at the same point instead, after Viewpoint's own addon draws.
 * ZombieBuddy inlines this advice into AddonDraws: everything it calls must be public.
 */
@Patch(className = "viewpoint.render.AddonDraws", methodName = "afterTranslucent")
public class PatchVpWall {
    @Patch.OnExit
    public static void exit(@Patch.Argument(0) Object frame) {
        BlueZoneWall.afterTranslucent(frame);
    }
}
