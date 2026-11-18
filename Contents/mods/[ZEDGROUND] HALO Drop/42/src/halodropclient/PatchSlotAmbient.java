package halodropclient;

import me.zed_0xff.zombie_buddy.Patch;

/** After the per-frame render snapshot copies the ambient: same override, for render paths that skip updateLights. */
@Patch(className = "zombie.core.skinnedmodel.model.ModelSlotRenderData", methodName = "initModel")
public class PatchSlotAmbient {
    @Patch.OnExit
    public static void exit(@Patch.This Object slotRenderData) { SkyLight.onSlotInit(slotRenderData); }
}
