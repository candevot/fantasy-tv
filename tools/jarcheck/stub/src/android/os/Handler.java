package android.os;
public class Handler {
    public Handler() {}
    public Handler(Looper l) {}
    public boolean post(Runnable r) { r.run(); return true; }
    public boolean postDelayed(Runnable r, long d) { return true; }
    public void removeCallbacks(Runnable r) {}
    public void sendEmptyMessage(int what) {}
    public Message obtainMessage(int what) { return new Message(); }
    public static class Message { public int what; public Object obj; }
}
