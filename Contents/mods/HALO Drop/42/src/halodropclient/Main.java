package halodropclient;

/** ZombieBuddy entry point (runs once when the jar loads). The @Patch classes are applied by ZombieBuddy. */
public class Main {
    public static final String VERSION = "0.1.1";

    public static void main(String[] args) {
        SkyLight.log("loaded v" + VERSION);
    }
}
