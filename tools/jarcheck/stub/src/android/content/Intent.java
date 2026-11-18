package android.content;
public class Intent {
    public Intent() {}
    public Intent(String action) {}
    public Intent(Context c, Class<?> cls) {}
    public Intent setAction(String a) { return this; }
    public Intent putExtra(String k, String v) { return this; }
    public Intent setFlags(int f) { return this; }
    public Intent addFlags(int f) { return this; }
    public String getStringExtra(String k) { return null; }
    public String getAction() { return null; }
    public android.net.Uri getData() { return null; }
}
