package com.github.catvod.crawler;

import com.google.gson.JsonArray;

/**
 * 宿主提供给 jar 的回调接口（FATCAT_API 2026-11-15）。
 *
 * <p>线上肥猫那批 jar（`classes.dex` 里带 `com.github.catvod.spider.Init` 的
 * 那一版）里，`Spider` 基类会保存一个 `SpiderApi`：
 * <pre>
 *   public void initApi(SpiderApi api) { this.api = api; }
 * </pre>
 * 源里的「本地代理地址」「日志」「多线程请求合并」「网页解析」都通过它回调宿主。
 * 缺了这个类/接口，jar 自己的 Spider 基类一加载就 NoClassDefFoundError。
 *
 * <p>这里给出与官方一致的签名（方法名 / 参数 / 返回类型），实现放在
 * [com.github.catvod.spider.SpiderApiImpl]（本工程自己用），由加载器注入。
 */
public interface SpiderApi {

    /** 本地代理地址：`http://127.0.0.1:<port>/proxy?...`。 */
    String getAddress(boolean local);

    /** 本地代理端口（字符串）。 */
    String getPort();

    /** 日志（走 SpiderDebug / logcat）。 */
    void log(String msg);

    /** 批量请求（多线程 GET/POST）。 */
    String multiReq(JsonArray array);

    /** 网页嗅探解析（WebView）。没有实现时返回空串。 */
    String webParse(String url, String html);
}
