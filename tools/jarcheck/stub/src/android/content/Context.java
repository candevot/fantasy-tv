package android.content;

import android.content.pm.PackageManager;
import android.content.res.Resources;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;

/** 最小 Context：JVM 实测用（只实现 jar 源真正会调的方法）。 */
public class Context {
    private static File base;
    static {
        base = new File(System.getProperty("fx.data", "/tmp/fxharness"));
        base.mkdirs();
    }
    public Context() {}
    public Context getApplicationContext() { return this; }
    public String getPackageName() { return "com.huanxiang.fantasy_tv"; }
    public File getFilesDir() { File f = new File(base, "files"); f.mkdirs(); return f; }
    public File getCacheDir() { File f = new File(base, "cache"); f.mkdirs(); return f; }
    public File getExternalFilesDir(String t) { File f = new File(base, "ext/" + t); f.mkdirs(); return f; }
    public File getDir(String n, int m) { File f = new File(base, n); f.mkdirs(); return f; }
    public FileOutputStream openFileOutput(String n, int m) throws Exception { return new FileOutputStream(new File(getFilesDir(), n)); }
    public boolean deleteFile(String n) { return new File(getFilesDir(), n).delete(); }
    public InputStream openFileInput(String n) throws Exception { return new java.io.FileInputStream(new File(getFilesDir(), n)); }
    public String[] fileList() { return getFilesDir().list(); }
    public ClassLoader getClassLoader() { return Context.class.getClassLoader(); }
    public Object getSystemService(String name) { return null; }
    public Resources getResources() { return new Resources(); }
    public PackageManager getPackageManager() { return new PackageManager(); }
    public android.os.Looper getMainLooper() { return null; }
    public Object getApplicationInfo() { return null; }
    public String getString(int id) { return ""; }
    public CharSequence getText(int id) { return ""; }
    public void startActivity(Intent i) {}
    public int checkSelfPermission(String p) { return 0; }
    public SharedPreferences getSharedPreferences(String n, int m) { return fx.Prefs.get(n); }
    public ContentResolver getContentResolver() { return new ContentResolver(); }
    public android.content.res.AssetManager getAssets() { return new android.content.res.AssetManager(); }
    public Object getPackageCodePath() { return ""; }
    public File getDatabasePath(String n) { return new File(getFilesDir(), n); }
}
