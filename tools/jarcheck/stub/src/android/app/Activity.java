package android.app;
import android.content.Context;
import android.os.Bundle;
public class Activity extends Context {
    public Activity() {}
    protected void onCreate(Bundle b) {}
    public void runOnUiThread(Runnable r) { r.run(); }
    public android.content.Intent getIntent() { return new android.content.Intent(); }
    public void finish() {}
    public void setContentView(int id) {}
    public void setContentView(Object v) {}
    public void requestPermissions(String[] p, int c) {}
    public boolean shouldShowRequestPermissionRationale(String p) { return false; }
}
