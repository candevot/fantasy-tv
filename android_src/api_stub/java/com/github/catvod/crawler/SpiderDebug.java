package com.github.catvod.crawler;

import android.util.Log;

/**
 * jar 源的日志出口（JAR_SPIDER）。
 *
 * <p>很多 csp_XXX.jar 里带 {@code SpiderDebug.log(...)}，少了这个类会在
 * 第一次打印日志时抛 NoClassDefFoundError —— 而这类日志往往在 catch 里，
 * 结果就是一个本来能跑的源莫名其妙地一直返回空。
 *
 * <p>统一走 Log.d，tag 前缀 `spider/`，真机上看
 * {@code adb logcat -s FXSpider} 就能过滤。
 */
public class SpiderDebug {

    private static final String TAG = "FXSpider";

    /** 打开 / 关闭（子类可能改这个静态字段）。 */
    public static boolean debug = false;

    public static void log(String msg) {
        if (!debug) return;
        Log.d(TAG, "spider/" + (msg == null ? "null" : msg));
    }

    public static void log(String tag, String msg) {
        if (!debug) return;
        Log.d(TAG, "spider/" + (tag == null ? "" : tag) + " " + (msg == null ? "" : msg));
    }

    public static void log(Throwable e) {
        if (!debug || e == null) return;
        Log.d(TAG, "spider/throwable", e);
    }

    public static void log(String msg, Throwable e) {
        if (!debug) return;
        Log.d(TAG, "spider/" + (msg == null ? "" : msg), e);
    }

    public static void error(String msg) {
        Log.w(TAG, "spider/" + (msg == null ? "null" : msg));
    }
}
