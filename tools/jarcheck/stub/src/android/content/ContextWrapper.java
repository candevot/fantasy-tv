package android.content;
public class ContextWrapper extends Context {
    protected Context mBase;
    public ContextWrapper(Context base) { mBase = base; }
    public Context getBaseContext() { return mBase; }
    public Context getApplicationContext() { return mBase == null ? this : mBase.getApplicationContext(); }
}
