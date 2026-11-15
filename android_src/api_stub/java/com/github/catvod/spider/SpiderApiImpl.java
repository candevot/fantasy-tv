package com.github.catvod.spider;

import android.content.Context;

import com.github.catvod.crawler.SpiderApi;
import com.github.catvod.crawler.SpiderDebug;
import com.google.gson.JsonArray;

/**
 * 宿主给 jar 的最小 [SpiderApi] 实现（FATCAT_API 2026-11-15）。
 *
 * <p>官方 App 里这些能力背后是本地代理 + WebView 嗅探；我们只做「有实现、
 * 不崩、能打日志」的版本：
 *   · [getAddress] / [getPort]：没有本地代理，返回空串（源会自己走直连）；
 *   · [multiReq]：顺序把每个 URL GET 一遍，拼成 JSON 数组；
 *   · [webParse]：没有 WebView 嗅探，返回空串。
 */
public class SpiderApiImpl implements SpiderApi {

    private final Context context;

    public SpiderApiImpl(Context context) {
        this.context = context == null ? null : context.getApplicationContext();
    }

    @Override
    public String getAddress(boolean local) {
        return "";
    }

    @Override
    public String getPort() {
        return "";
    }

    @Override
    public void log(String msg) {
        SpiderDebug.log(msg);
    }

    @Override
    public String multiReq(JsonArray array) {
        if (array == null) return "[]";
        JsonArray out = new JsonArray();
        for (int i = 0; i < array.size(); i++) {
            String url = "";
            try {
                url = array.get(i).getAsString();
            } catch (Throwable ignored) {
                continue;
            }
            out.add(com.github.catvod.net.Net.get(url));
        }
        return out.toString();
    }

    @Override
    public String webParse(String url, String html) {
        return "";
    }
}
