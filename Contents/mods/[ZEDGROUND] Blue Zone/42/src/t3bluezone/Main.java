package t3bluezone;

/**
 * ZombieBuddy entry point of the Blue Zone wall (runs once when ZombieBuddy loads the jar at server join).
 * ZombieBuddy also applies the @Patch classes of this package (PatchVpWall).
 * The wall only draws when Viewpoint is installed; without it the patched class never loads and nothing happens.
 */
public class Main {
    public static final String VERSION = "0.4.0";

    public static void main(String[] args) {
        BlueZoneWall.log("loaded v" + VERSION + " (ZombieBuddy, draws after Viewpoint's translucent pass)");
    }
}
