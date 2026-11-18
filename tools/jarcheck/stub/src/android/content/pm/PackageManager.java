package android.content.pm;
import java.util.*;
public class PackageManager {
    public static class NameNotFoundException extends Exception {}
    public PackageInfo getPackageInfo(String p, int f) throws NameNotFoundException {
        PackageInfo i = new PackageInfo();
        i.packageName = p;
        i.versionName = "1.0.0";
        i.signatures = new Signature[]{ new Signature("0000000000000000000000000000000000000000") };
        return i;
    }
    public List<PackageInfo> getInstalledPackages(int f) { return new ArrayList<>(); }
}
