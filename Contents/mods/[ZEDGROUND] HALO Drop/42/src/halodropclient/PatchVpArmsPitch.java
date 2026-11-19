package halodropclient;

import me.zed_0xff.zombie_buddy.Patch;

/** Same as PatchVpHeadLook for the arm chains: viewpoint.input.ArmsPitch.posed(AnimationPlayer). See VpPose. */
@Patch(className = "viewpoint.input.ArmsPitch", methodName = "posed")
public class PatchVpArmsPitch {
    @Patch.OnEnter(skipOn = true)
    public static boolean enter(@Patch.Argument(0) Object animationPlayer) {
        return VpPose.skip(animationPlayer, 1);
    }
}
