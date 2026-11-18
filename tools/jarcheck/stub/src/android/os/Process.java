package android.os;
public class Process {
    public static void killProcess(int pid) { System.err.println("[stub] killProcess(" + pid + ") 被调用（jar 想做签名自毁，已忽略）"); }
    public static int myPid() { return 1; }
    public static int myTid() { return 1; }
    public static int myUid() { return 10000; }
    public static void setThreadPriority(int p) {}
}
