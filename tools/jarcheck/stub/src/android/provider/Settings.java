package android.provider;
public class Settings {
    public static class Secure {
        public static String getString(android.content.ContentResolver r, String n) { return null; }
        public static boolean putString(android.content.ContentResolver r, String n, String v) { return true; }
    }
    public static class System {
        public static String getString(android.content.ContentResolver r, String n) { return null; }
        public static int getInt(android.content.ContentResolver r, String n, int d) { return d; }
    }
    public static class Global {
        public static String getString(android.content.ContentResolver r, String n) { return null; }
        public static int getInt(android.content.ContentResolver r, String n, int d) { return d; }
    }
}
