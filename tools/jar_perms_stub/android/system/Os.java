package android.system;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.attribute.PosixFilePermission;
import java.util.EnumSet;
import java.util.Set;

/**
 * `android.system.Os` 的替身（**只给 tools/check_jar_perms.sh 的 JVM 单测用**，
 * 不会进 APK：它不在 android_src/kotlin 下，CI 的拷贝步骤只认 .kt/.java…
 * 注意 patch_exoplayer.py 会拷 android_src 下所有 .java，所以这里刻意放在
 * tools/ 而不是 android_src/）。
 *
 * 意义：JarPermissions 里对 Os.chmod / Os.stat 的调用是**反射**的 ——
 * 方法名、静态性、参数类型、StructStat.st_mode 字段名全都编译期不检查。
 * 这个替身让单测在「假装是 Android」的 classpath 上真跑一遍，等于验证了
 * 那两处反射签名和 ART 上一致。
 */
public final class Os {

    /** 和真机一致：`Os.chmod(String path, int mode)`，失败抛 ErrnoException。 */
    public static void chmod(String path, int mode) throws ErrnoException {
        try {
            Files.setPosixFilePermissions(Paths.get(path), permsOf(mode));
        } catch (Exception e) {
            throw new ErrnoException(String.valueOf(e.getMessage()));
        }
    }

    /** 和真机一致：`Os.stat(String path) → StructStat`（st_mode 低 9 位是权限）。 */
    public static StructStat stat(String path) throws ErrnoException {
        try {
            return new StructStat(modeOf(Files.getPosixFilePermissions(Paths.get(path))));
        } catch (Exception e) {
            throw new ErrnoException(String.valueOf(e.getMessage()));
        }
    }

    private static Set<PosixFilePermission> permsOf(int mode) {
        Set<PosixFilePermission> out = EnumSet.noneOf(PosixFilePermission.class);
        if ((mode & 0400) != 0) out.add(PosixFilePermission.OWNER_READ);
        if ((mode & 0200) != 0) out.add(PosixFilePermission.OWNER_WRITE);
        if ((mode & 0100) != 0) out.add(PosixFilePermission.OWNER_EXECUTE);
        if ((mode & 0040) != 0) out.add(PosixFilePermission.GROUP_READ);
        if ((mode & 0020) != 0) out.add(PosixFilePermission.GROUP_WRITE);
        if ((mode & 0010) != 0) out.add(PosixFilePermission.GROUP_EXECUTE);
        if ((mode & 0004) != 0) out.add(PosixFilePermission.OTHERS_READ);
        if ((mode & 0002) != 0) out.add(PosixFilePermission.OTHERS_WRITE);
        if ((mode & 0001) != 0) out.add(PosixFilePermission.OTHERS_EXECUTE);
        return out;
    }

    private static int modeOf(Set<PosixFilePermission> perms) {
        int mode = 0;
        if (perms.contains(PosixFilePermission.OWNER_READ)) mode |= 0400;
        if (perms.contains(PosixFilePermission.OWNER_WRITE)) mode |= 0200;
        if (perms.contains(PosixFilePermission.OWNER_EXECUTE)) mode |= 0100;
        if (perms.contains(PosixFilePermission.GROUP_READ)) mode |= 0040;
        if (perms.contains(PosixFilePermission.GROUP_WRITE)) mode |= 0020;
        if (perms.contains(PosixFilePermission.GROUP_EXECUTE)) mode |= 0010;
        if (perms.contains(PosixFilePermission.OTHERS_READ)) mode |= 0004;
        if (perms.contains(PosixFilePermission.OTHERS_WRITE)) mode |= 0002;
        if (perms.contains(PosixFilePermission.OTHERS_EXECUTE)) mode |= 0001;
        return mode;
    }
}
