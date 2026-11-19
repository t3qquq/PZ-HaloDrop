package halodropclient;

import me.zed_0xff.zombie_buddy.Patch;

/**
 * Viewpoint turns the neck, the head and everything below them (the arms hang from the neck) toward the camera in
 * viewpoint.input.HeadLook.posed(AnimationPlayer) (javap names only). Skipped while Halo Drop poses the character: see VpPose.
 */
@Patch(className = "viewpoint.input.HeadLook", methodName = "posed")
public class PatchVpHeadLook {
    @Patch.OnEnter(skipOn = true)
    public static boolean enter(@Patch.Argument(0) Object animationPlayer) {
        return VpPose.skip(animationPlayer, 0);
    }
}
