package com.example.spider;

import android.content.Context;

import com.github.catvod.crawler.Spider;

import java.util.HashMap;
import java.util.List;

/**
 * jar 源自检用的示例解析器（JAR_SPIDER，2026-11-14）。
 *
 * <p>它什么都不联网，只按 TVBox 的标准 JSON 形状返回一份固定数据，
 * 用来验证「DexClassLoader 加载 → 反射调 Spider → Flutter 转模型」这条链路
 * 是通的。真正的三方 jar（肥猫 / 饭太硬 / 二小那些 csp_Xxx）与它的区别只有
 * 数据来源，接口完全一致。
 *
 * <p>编译：`python3 tools/build_sample_jar.py`（产物
 * `tools/spider_sample/spider-demo.jar`）。
 * 真机安装（设置 → 片源管理 → jar 插件 → 安装 jar，填这个地址）：
 * <pre>file:///sdcard/Download/spider-demo.jar</pre>
 * 然后加一个片源：类型 `jar 插件 (3)`，api `csp_Demo`，ext 留空。
 *
 * <p>注意：这里**故意只 override 一部分方法**（`homeVideoContent` /
 * `liveContent` / `manualVideoCheck` 没写），用来验证基类的默认实现
 * 不会导致 AbstractMethodError —— 现实中的 jar 也经常这样写。
 */
public class CspDemo extends Spider {

    /** 详情里用到的两条线路（flag 就是 `vod_play_from` 里的那一段）。 */
    // 注意：线路名不要用「A / A2」这种前缀关系 —— models.dart 的 mergeLines
    // 会把「同源同名前缀」的线路合并成一条（CMS 的「高清线路 / 高清线路2」
    // 就是这么处理的），演示数据故意用两个不相干的名字，自检时能看到两条线。
    private static final String LINE_A = "演示A";
    private static final String LINE_B = "演示B";

    private String ext = "";

    @Override
    public void init(Context context, String extend) {
        // 真源这里通常解析 extend（JSON / 地址 / 空串），示例只记一笔。
        this.ext = extend == null ? "" : extend;
    }

    private String vod(String id, String name, String remarks, String typeName) {
        return "{"
                + "\"vod_id\":\"" + id + "\","
                + "\"vod_name\":\"" + name + "\","
                + "\"vod_pic\":\"\","
                + "\"vod_remarks\":\"" + remarks + "\","
                + "\"vod_year\":\"2026\","
                + "\"vod_area\":\"内地\","
                + "\"vod_score\":\"8.8\","
                + "\"type_name\":\"" + typeName + "\","
                + "\"vod_director\":\"幻想影视\","
                + "\"vod_actor\":\"Little Code Sauce\","
                + "\"vod_content\":\"jar 源自检数据（api=csp_Demo，ext=" + ext + "）\""
                + "}";
    }

    @Override
    public String homeContent(boolean filter) {
        return "{"
                + "\"class\":["
                + "{\"type_id\":\"1\",\"type_name\":\"电影\"},"
                + "{\"type_id\":\"2\",\"type_name\":\"电视剧\"}"
                + "],"
                + "\"list\":[" + vod("demo-1", "幻想起点 · 自检片", "正片", "电影") + "]"
                + "}";
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter,
                                  HashMap<String, String> extend) {
        String typeName = "2".equals(tid) ? "电视剧" : "电影";
        return "{"
                + "\"page\":" + (pg == null ? 1 : Integer.parseInt(pg)) + ","
                + "\"pagecount\":1,"
                + "\"limit\":20,"
                + "\"total\":1,"
                + "\"list\":[" + vod("demo-1", "幻想起点 · 自检片", "正片", typeName) + "]"
                + "}";
    }

    @Override
    public String detailContent(List<String> ids) {
        String id = (ids == null || ids.isEmpty()) ? "demo-1" : ids.get(0);
        String playUrl = "正片$https://example.com/demo.m3u8"
                + "$$$"
                + "正片$https://example.com/demo2.m3u8";
        String detail = "{"
                + "\"vod_id\":\"" + id + "\","
                + "\"vod_name\":\"幻想起点 · 自检片\","
                + "\"vod_pic\":\"\","
                + "\"vod_remarks\":\"正片\","
                + "\"vod_year\":\"2026\","
                + "\"vod_area\":\"内地\","
                + "\"vod_score\":\"8.8\","
                + "\"type_name\":\"电影\","
                + "\"vod_director\":\"幻想影视\","
                + "\"vod_actor\":\"Little Code Sauce\","
                + "\"vod_content\":\"jar 源自检数据：能看到两条线路（" + LINE_A
                + " / " + LINE_B + "）说明详情转换正常。\","
                + "\"vod_play_from\":\"" + LINE_A + "$$$" + LINE_B + "\","
                + "\"vod_play_url\":\"" + playUrl + "\""
                + "}";
        return "{\"list\":[" + detail + "]}";
    }

    @Override
    public String searchContent(String key, boolean quick) {
        return searchContent(key, quick, "1");
    }

    @Override
    public String searchContent(String key, boolean quick, String pg) {
        if (key == null || !key.contains("自检")) {
            return "{\"list\":[]}";
        }
        return "{\"list\":[" + vod("demo-1", "幻想起点 · 自检片", "正片", "电影") + "]}";
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        // parse=0 表示 url 就是能直接播的地址；真源里常见 parse=1（要嗅探）。
        String url = LINE_B.equals(flag)
                ? "https://example.com/demo2.m3u8"
                : "https://example.com/demo.m3u8";
        return "{"
                + "\"parse\":0,"
                + "\"url\":\"" + url + "\","
                + "\"header\":{\"User-Agent\":\"fx-jar-spider-selftest\"}"
                + "}";
    }
}
