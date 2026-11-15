package android.system;

/**
 * `android.system.StructStat` 的最小替身（只有 JVM 单测用）。
 *
 * 真机上是公开 SDK 类、`st_mode` 是 public int 字段；这里保持同样的形态，
 * 好让 JarPermissions.androidMode() 里那句
 * `stat.javaClass.getField("st_mode").getInt(stat)` 能被真正执行到 ——
 * 反射写错（字段名 / 类型）在编译期是发现不了的，只有跑一遍才知道。
 */
public final class StructStat {
    public final int st_mode;

    public StructStat(int mode) {
        this.st_mode = mode;
    }
}
