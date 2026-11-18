package android.os;
public class SystemClock {
    public static long elapsedRealtime() { return System.nanoTime() / 1000000L; }
    public static long currentThreadTimeMillis() { return System.currentTimeMillis(); }
    public static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) {} }
}
