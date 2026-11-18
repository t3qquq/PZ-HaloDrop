package halodropclient;

import me.zed_0xff.zombie_buddy.Patch;

/**
 * Viewpoint (1st/3rd person) lights character models from its own light grid, not from the vanilla ambient:
 * viewpoint.models.ModelCapture reads viewpoint.light.OwnedLight.modelSky(x, y, z, flag) and modelLightAt(x, y, z)
 * at the character's square (member names checked with javap only). The empty air squares a jumper falls through
 * come back dark there. For squares a Halo Drop jumper occupies, use the values of the ground below instead.
 * If Viewpoint is not installed the target class never loads and this patch does nothing.
 */
@Patch(className = "viewpoint.light.OwnedLight", methodName = "modelSky")
public class PatchVpSky {
    @Patch.OnExit
    public static void exit(@Patch.Argument(0) int x, @Patch.Argument(1) int y, @Patch.Argument(2) int z,
                            @Patch.Argument(3) boolean flag, @Patch.Return(readOnly = false) float ret) {
        ret = SkyLight.vpSky(x, y, z, flag, ret);
    }
}
