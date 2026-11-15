package com.github.catvod;

import android.content.Context;

/**
 * 全局 Context 出口（FATCAT_API 2026-11-15）。
 *
 * <p>jar 里的工具类会调 `Runtime.context()` 拿 App Context（文件目录、缓存）。
 * 官方实现是进程级单例；这里由 [com.github.catvod.spider.SpiderApiImpl]
 * 在加载 jar 时注入，拿不到时返回 null（jar 侧通常有空判断）。
 */
public final class Runtime {

    private static volatile Context appContext;

    private Runtime() {
    }

    public static Context context() {
        return appContext;
    }

    public static void setContext(Context context) {
        if (context == null) return;
        Context app = context.getApplicationContext();
        appContext = app != null ? app : context;
    }
}
