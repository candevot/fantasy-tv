package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 空解析器：`api` 填不到类、或者站点配置里写了 `csp_None` 时用它兜底。
 *
 * <p>存在的意义是「不让 App 崩」：加载器拿不到类时返回它，调用方照常拿到
 * 空串，UI 只显示「这个源没有内容」，而不是整条搜索链路挂掉。
 */
public class SpiderNull extends Spider {

    public static final String TAG = "SpiderNull";

    @Override
    public void init(Context context, String extend) {
    }

    @Override
    public String homeContent(boolean filter) {
        return "";
    }

    @Override
    public String homeVideoContent() {
        return "";
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter,
                                 HashMap<String, String> extend) {
        return "";
    }

    @Override
    public String detailContent(List<String> ids) {
        return "";
    }

    @Override
    public String searchContent(String key, boolean quick) {
        return "";
    }

    @Override
    public String searchContent(String key, boolean quick, String pg) {
        return "";
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return "";
    }

    @Override
    public String liveContent(String url) {
        return "";
    }

    @Override
    public Object[] proxyLocal(Map<String, String> params) {
        return null;
    }

    @Override
    public String action(String action) {
        return "";
    }
}
