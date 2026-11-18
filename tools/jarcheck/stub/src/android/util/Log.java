package android.util;
/** 打到 stderr 的日志（JVM 实测用）。 */
public class Log {
    public static int v(String t, String m) { System.err.println("V/" + t + ": " + m); return 0; }
    public static int d(String t, String m) { System.err.println("D/" + t + ": " + m); return 0; }
    public static int i(String t, String m) { System.err.println("I/" + t + ": " + m); return 0; }
    public static int w(String t, String m) { System.err.println("W/" + t + ": " + m); return 0; }
    public static int e(String t, String m) { System.err.println("E/" + t + ": " + m); return 0; }
    public static int e(String t, String m, Throwable x) { System.err.println("E/" + t + ": " + m + " :: " + x); return 0; }
    public static int w(String t, String m, Throwable x) { System.err.println("W/" + t + ": " + m + " :: " + x); return 0; }
    public static int w(String t, Throwable x) { System.err.println("W/" + t + ": " + x); return 0; }
    public static String getStackTraceString(Throwable x) { return String.valueOf(x); }
    public static int println(int p, String t, String m) { System.err.println(t + ": " + m); return 0; }
}
