package halodropclient;

import me.zed_0xff.zombie_buddy.Patch;

/** After vanilla picks a character model's ambient from its square: keep jumpers lit (air squares have no light data). */
@Patch(className = "zombie.core.skinnedmodel.model.ModelInstance", methodName = "updateLights")
public class PatchInstanceLights {
    @Patch.OnExit
    public static void exit(@Patch.This Object modelInstance) { SkyLight.onInstanceLights(modelInstance); }
}
