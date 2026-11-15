package com.github.catvod.spider.crawler;

/**
 * 另一个包名下的日志出口（FATCAT_API 2026-11-15）。
 *
 * <p>肥猫 jar 里同时存在 `com.github.catvod.crawler.SpiderDebug` 和
 * `com.github.catvod.spider.crawler.SpiderDebug` 两套引用（不同版本源码
 * 混编的产物），少一个就会在打日志时 NoClassDefFoundError。
 * 统一转给 [com.github.catvod.crawler.SpiderDebug]。
 */
public final class SpiderDebug {

    private SpiderDebug() {
    }

    public static void log(String msg) {
        com.github.catvod.crawler.SpiderDebug.log(msg);
    }

    public static void log(String tag, String msg) {
        com.github.catvod.crawler.SpiderDebug.log(tag, msg);
    }

    public static void log(Throwable e) {
        com.github.catvod.crawler.SpiderDebug.log(e);
    }

    public static void error(String msg) {
        com.github.catvod.crawler.SpiderDebug.error(msg);
    }
}
