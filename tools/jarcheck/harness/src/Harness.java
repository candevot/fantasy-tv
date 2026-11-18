import android.content.Context;
import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * JVM 实测台：按 FongMi（壳）的调用协议直接跑 spider.jar 里的源。
 *
 * 用法：
 *   java Harness <jar> <csp_Xxx> <ext 文件或字面量> <关键词> [quick]
 *
 * 做的事严格照壳（SiteApi / SearchTask / SiteViewModel）：
 *   1. Init$Loader.a.c = Application（壳里是 App.get()）
 *   2. spider.siteKey = key
 *   3. spider.init(context, ext)  —— ext 是 **String**（壳 Site.ext 就是 String）
 *   4. searchContent(key, quick)  —— 两参（壳在 page == 1 时走这个）
 *      searchContent(key, quick, "1") —— 三参（壳只在翻页时走）
 *   5. detailContent(Arrays.asList(id))
 *   6. playerContent(flag, 第一条地址, vipFlags)
 */
public final class Harness {

    public static void main(String[] args) throws Exception {
        File jar = new File(args[0]);
        String name = args[1];
        String extArg = args.length > 2 ? args[2] : "";
        String ext = extArg.startsWith("@") ? read(new File(extArg.substring(1))) : extArg;
        String keyword = args.length > 3 ? args[3] : "济公传";
        boolean quick = args.length > 4 && Boolean.parseBoolean(args[4]);

        // 父加载器 = 宿主的类加载器（api.jar 里的 Spider 基类在这里）；
        // jar 自己带一份 Spider 也会被子加载器忽略，和 Android 上 DexClassLoader 一致。
        URLClassLoader cl = new URLClassLoader(new URL[]{jar.toURI().toURL()}, Harness.class.getClassLoader());
        java.security.Security.insertProviderAt(new fx.Pkcs7Provider(), 1);
        Context ctx = new android.app.Application();

        injectInit(cl, ctx);

        String clsName = name.startsWith("csp_") ? name.substring(4) : name; // 壳：api.split("csp_")[1]
        Class<?> clz = Class.forName("com.github.catvod.spider." + clsName, true, cl);
        Object spider = clz.getDeclaredConstructor().newInstance();
        setField(spider, "siteKey", name);

        long t0 = System.currentTimeMillis();
        String initErr = "";
        try {
            Method init = clz.getMethod("init", Context.class, String.class);
            init.invoke(spider, ctx, ext);
        } catch (Throwable e) {
            initErr = shortMsg(e);
        }
        long initMs = System.currentTimeMillis() - t0;

        JSONObject out = new JSONObject();
        out.put("class", name);
        out.put("extLen", ext.length());
        out.put("initMs", initMs);
        out.put("initError", initErr);

        // 可选：先 homeContent(true) 预热（-Dfx.warm=1），用来验证「壳有没有这一步」
        if ("1".equals(System.getProperty("fx.warm"))) {
            long w0 = System.currentTimeMillis();
            JSONObject warm = new JSONObject();
            try {
                Method m = clz.getMethod("homeContent", boolean.class);
                Object r = m.invoke(spider, true);
                String text = r == null ? "" : r.toString();
                warm.put("bytes", text.length());
                warm.put("count", listOf(text).size());
                warm.put("raw", clip(text));
            } catch (Throwable e) {
                warm.put("error", shortMsg(e));
            }
            warm.put("ms", System.currentTimeMillis() - w0);
            out.put("home", warm);
        }

        // ---- 搜索：两参（壳协议）
        JSONObject s2 = callSearch(spider, clz, keyword, quick, false);
        // ---- 搜索：三参（我们客户端现在先走的）
        JSONObject s3 = callSearch(spider, clz, keyword, quick, true);
        out.put("search2", s2);
        out.put("search3", s3);

        // ---- 详情：用两参搜索的第一条
        String vodId = s2.optString("firstId", "");
        if (vodId.isEmpty()) vodId = s3.optString("firstId", "");
        JSONObject detail = new JSONObject();
        if (vodId.isEmpty()) {
            detail.put("ok", false);
            detail.put("error", "搜索没有返回任何 vod_id");
        } else {
            detail = callDetail(spider, clz, vodId);
        }
        out.put("detail", detail);

        System.out.println(out.toString(2));
    }

    /* ------------------------------------------------------------------ */

    private static JSONObject callSearch(Object spider, Class<?> clz, String keyword, boolean quick, boolean three) {
        JSONObject out = new JSONObject();
        String method = "searchContent";
        long t0 = System.currentTimeMillis();
        Object raw;
        try {
            if (three) {
                Method m = clz.getMethod(method, String.class, boolean.class, String.class);
                raw = m.invoke(spider, keyword, quick, "1");
            } else {
                Method m = clz.getMethod(method, String.class, boolean.class);
                raw = m.invoke(spider, keyword, quick);
            }
        } catch (Throwable e) {
            out.put("ok", false);
            out.put("error", shortMsg(e));
            out.put("ms", System.currentTimeMillis() - t0);
            return out;
        }
        out.put("ms", System.currentTimeMillis() - t0);
        String text = raw == null ? "" : raw.toString();
        out.put("bytes", text.length());
        out.put("isEmpty", text.trim().isEmpty());
        out.put("raw", clip(text));
        List<JSONObject> items = listOf(text);
        out.put("count", items.size());
        if (!items.isEmpty()) {
            JSONObject first = items.get(0);
            out.put("firstId", first.optString("vod_id", ""));
            out.put("firstName", first.optString("vod_name", ""));
            JSONArray names = new JSONArray();
            for (int i = 0; i < Math.min(items.size(), 8); i++) names.put(items.get(i).optString("vod_name", ""));
            out.put("names", names);
        }
        return out;
    }

    private static JSONObject callDetail(Object spider, Class<?> clz, String vodId) {
        JSONObject out = new JSONObject();
        long t0 = System.currentTimeMillis();
        Object raw;
        try {
            Method m = clz.getMethod("detailContent", List.class);
            raw = m.invoke(spider, new ArrayList<>(Arrays.asList(vodId)));
        } catch (Throwable e) {
            out.put("ok", false);
            out.put("error", shortMsg(e));
            out.put("ms", System.currentTimeMillis() - t0);
            return out;
        }
        out.put("ms", System.currentTimeMillis() - t0);
        String text = raw == null ? "" : raw.toString();
        out.put("bytes", text.length());
        List<JSONObject> items = listOf(text);
        if (items.isEmpty()) {
            out.put("ok", false);
            out.put("error", "detailContent 没有 list: " + clip(text));
            return out;
        }
        JSONObject vod = items.get(0);
        String from = vod.optString("vod_play_from", "");
        String url = vod.optString("vod_play_url", "");
        out.put("ok", true);
        out.put("vodName", vod.optString("vod_name", ""));
        out.put("playFrom", from);
        out.put("playUrlLen", url.length());

        String[] lines = from.contains("$$$") ? from.split("\\$\\$\\$") : new String[]{from};
        String[] blocks = url.contains("$$$") ? url.split("\\$\\$\\$") : new String[]{url};
        out.put("lineCount", Math.max(lines.length, blocks.length));
        JSONArray lineInfo = new JSONArray();
        int totalEp = 0;
        String firstFlag = null, firstUrl = null;
        for (int i = 0; i < Math.max(lines.length, blocks.length); i++) {
            String lineName = i < lines.length ? lines[i].trim() : "";
            String block = i < blocks.length ? blocks[i].trim() : "";
            List<String[]> eps = episodes(block);
            totalEp += eps.size();
            if (firstFlag == null && !lineName.isEmpty() && !eps.isEmpty()) {
                firstFlag = lineName;
                firstUrl = eps.get(0)[1];
            }
            JSONObject line = new JSONObject();
            line.put("name", lineName);
            line.put("episodes", eps.size());
            line.put("firstEpName", eps.isEmpty() ? "" : eps.get(0)[0]);
            line.put("firstEpUrl", eps.isEmpty() ? "" : clip(eps.get(0)[1]));
            lineInfo.put(line);
        }
        out.put("lines", lineInfo);
        out.put("totalEpisodes", totalEp);

        // ---- 播放：壳用「线路名 + 该集地址 + 配置的 vipFlags」
        if (firstFlag != null) {
            long p0 = System.currentTimeMillis();
            try {
                Method m = clz.getMethod("playerContent", String.class, String.class, List.class);
                Object rawP = m.invoke(spider, firstFlag, firstUrl, new ArrayList<String>());
                String ptext = rawP == null ? "" : rawP.toString();
                JSONObject p = new JSONObject();
                p.put("ms", System.currentTimeMillis() - p0);
                p.put("bytes", ptext.length());
                p.put("raw", clip(ptext));
                try {
                    JSONObject pj = new JSONObject(ptext);
                    p.put("url", clip(pj.optString("url", "")));
                    p.put("parse", pj.optInt("parse", 0));
                } catch (Exception ignored) {
                }
                out.put("player", p);
            } catch (Throwable e) {
                out.put("playerError", shortMsg(e));
            }
        }
        return out;
    }

    /** `集名$地址#集名$地址` → 列表（照壳 Flag.setEpisodes：先按 # 切，再按第一个 $ 切）。 */
    private static List<String[]> episodes(String block) {
        List<String[]> out = new ArrayList<>();
        if (block == null || block.trim().isEmpty()) return out;
        for (String chunk : block.split("#")) {
            String item = chunk.trim();
            if (item.isEmpty()) continue;
            int cut = item.indexOf('$');
            String epName = cut > 0 ? item.substring(0, cut).trim() : "";
            String addr = cut >= 0 ? item.substring(cut + 1).trim() : item;
            if (addr.isEmpty()) continue;
            out.add(new String[]{epName, addr});
        }
        return out;
    }

    private static List<JSONObject> listOf(String text) {
        List<JSONObject> out = new ArrayList<>();
        if (text == null || text.trim().isEmpty()) return out;
        try {
            JSONObject json = new JSONObject(text);
            JSONArray arr = json.optJSONArray("list");
            if (arr == null) return out;
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o != null) out.add(o);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    private static void injectInit(URLClassLoader cl, Context ctx) {
        try {
            Class<?> loaderCls = Class.forName("com.github.catvod.spider.Init$Loader", true, cl);
            Field a = loaderCls.getDeclaredField("a");
            a.setAccessible(true);
            Object init = a.get(null);
            if (init == null) {
                Class<?> initCls = Class.forName("com.github.catvod.spider.Init", true, cl);
                Constructor<?> c = initCls.getDeclaredConstructor();
                c.setAccessible(true);
                init = c.newInstance();
                a.set(null, init);
            }
            Field cc = init.getClass().getDeclaredField("c");
            cc.setAccessible(true);
            cc.set(init, ctx);
            System.err.println("[harness] Init.context 已注入：" + ctx.getPackageName());
        } catch (Throwable e) {
            System.err.println("[harness] Init 注入失败（非 fatcat jar？）：" + e);
        }
    }

    private static void setField(Object target, String name, Object value) {
        Class<?> c = target.getClass();
        while (c != null) {
            try {
                Field f = c.getDeclaredField(name);
                f.setAccessible(true);
                f.set(target, value);
                return;
            } catch (NoSuchFieldException e) {
                c = c.getSuperclass();
            } catch (Throwable ignored) {
                return;
            }
        }
    }

    private static String read(File f) {
        try {
            return new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (Exception e) {
            return "";
        }
    }

    private static String clip(String s) {
        if (s == null) return "";
        String t = s.replace('\n', ' ');
        return t.length() <= 160 ? t : t.substring(0, 160) + "…";
    }

    private static String shortMsg(Throwable e) {
        Throwable inner = e;
        while (inner.getCause() != null && inner.getCause() != inner) inner = inner.getCause();
        String m = inner.getMessage();
        return inner.getClass().getSimpleName() + (m == null ? "" : ": " + clip(m));
    }
}
