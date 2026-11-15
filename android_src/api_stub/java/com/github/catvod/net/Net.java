package com.github.catvod.net;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.TimeUnit;

/**
 * jar 源常用的同步 HTTP 工具（FATCAT_API 2026-11-15）。
 *
 * <p>官方 api.jar 里是 okhttp 封装；这里用 `HttpURLConnection` 实现同样的
 * `get(url)` / `get(url, timeoutSec)` / `sleep(ms)` 三个方法 —— 少一层
 * okhttp 版本差异（jar 是 okhttp 3/4 混着编译的），行为足够。
 */
public final class Net {

    private static final String UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

    private Net() {
    }

    public static String get(String url) {
        return get(url, 15);
    }

    public static String get(String url, int timeoutSeconds) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setConnectTimeout((int) TimeUnit.SECONDS.toMillis(Math.max(1, timeoutSeconds)));
            conn.setReadTimeout((int) TimeUnit.SECONDS.toMillis(Math.max(1, timeoutSeconds)));
            conn.setInstanceFollowRedirects(true);
            conn.setRequestProperty("User-Agent", UA);
            conn.setRequestProperty("Accept", "*/*");
            int code = conn.getResponseCode();
            InputStream input = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            if (input == null) return "";
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[16 * 1024];
            int n;
            while ((n = input.read(buf)) > 0) out.write(buf, 0, n);
            input.close();
            return new String(out.toByteArray(), "UTF-8");
        } catch (Throwable e) {
            return "";
        } finally {
            if (conn != null) {
                try {
                    conn.disconnect();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    public static void sleep(long millis) {
        try {
            Thread.sleep(Math.max(0, millis));
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }
}
