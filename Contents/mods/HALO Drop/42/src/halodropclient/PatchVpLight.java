package halodropclient;

import me.zed_0xff.zombie_buddy.Patch;

/** Same as PatchVpSky for the light-source part (OwnedLight.modelLightAt). */
@Patch(className = "viewpoint.light.OwnedLight", methodName = "modelLightAt")
public class PatchVpLight {
    @Patch.OnExit
    public static void exit(@Patch.Argument(0) int x, @Patch.Argument(1) int y, @Patch.Argument(2) int z,
                            @Patch.Return(readOnly = false) int ret) {
        ret = SkyLight.vpLight(x, y, z, ret);
    }
}
