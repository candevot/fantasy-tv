package android.os;
import java.io.File;
public class Environment {
    public static String getExternalStorageDirectory() { return System.getProperty("java.io.tmpdir", "/tmp"); }
    public static File getExternalStoragePublicDirectory(String t) { return new File(System.getProperty("java.io.tmpdir", "/tmp"), t); }
    public static class MediaStore { public static final String DIR_MOVIES = "Movies"; public static final String DIR_MUSIC = "Music"; }
}
