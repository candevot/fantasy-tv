package com.github.catvod.utils;

import java.net.URI;

/** URL 拼接工具（FATCAT_API 2026-11-15）：jar 里大量 `UriUtil.resolve(base, href)`。 */
public final class UriUtil {

    private UriUtil() {
    }

    public static String resolve(String base, String url) {
        if (url == null) return "";
        String href = url.trim();
        if (href.isEmpty()) return "";
        String lower = href.toLowerCase();
        if (lower.startsWith("http://") || lower.startsWith("https://")
                || lower.startsWith("data:") || lower.startsWith("magnet:")) {
            return href;
        }
        try {
            URI b = URI.create(base.trim());
            return b.resolve(href).toString();
        } catch (Throwable ignored) {
            return href;
        }
    }
}
