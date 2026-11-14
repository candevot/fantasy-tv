package com.github.catvod.net;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import okhttp3.Call;
import okhttp3.FormBody;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;

/**
 * jar 源最常用的网络入口（JAR_SPIDER）。
 *
 * <p>绝大多数 csp_XXX.jar 的网络请求都长这样：
 * <pre>
 *   String body = OkHttp.string(url);
 *   String body = OkHttp.string(url, headers);
 *   String body = OkHttp.post(url, "a=1&amp;b=2", headers);
 * </pre>
 * 少了这个类，jar 一进网络就 NoClassDefFoundError。这里用 okhttp3 3.12.13
 * 实现同一组静态方法（jar 里常见的是同步调用，异步回调走 {@link #newCall}）。
 *
 * <p>关于 okhttp 版本：Android 上 3.12.x 是最后一条纯 Java、无 Kotlin 运行时
 * 依赖的分支，dex 体积也小。少数新 jar 用了 4.x 的 Kotlin 扩展
 * （{@code toRequestBody} / {@code toMediaType}），那种源需要把 okhttp 换成
 * 4.x（Gradle 依赖，见 tools/patch_jar_spider.py 的注释），本类只做 3.x 兼容层。
 */
public class OkHttp {

    /** TVBox 社区通用的 UA：不少站点按 UA 拦请求，用 okhttp 默认 UA 会被 403。 */
    public static final String UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

    private static volatile OkHttpClient client;

    public static OkHttpClient client() {
        if (client == null) {
            synchronized (OkHttp.class) {
                if (client == null) {
                    client = new OkHttpClient.Builder()
                            .connectTimeout(15, TimeUnit.SECONDS)
                            .readTimeout(20, TimeUnit.SECONDS)
                            .writeTimeout(20, TimeUnit.SECONDS)
                            .followRedirects(true)
                            .followSslRedirects(true)
                            .retryOnConnectionFailure(true)
                            .build();
                }
            }
        }
        return client;
    }

    /** 允许外部（比如我们自己的插件）注入一个 client，统一连接池 / 证书策略。 */
    public static void setClient(OkHttpClient c) {
        client = c;
    }

    /* ------------------------------------------------------------ 构造请求 */

    public static Request build(String url, Map<String, String> headers) {
        Request.Builder b = new Request.Builder().url(url).header("User-Agent", UA);
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                if (e.getKey() == null) continue;
                try {
                    b.header(e.getKey(), e.getValue() == null ? "" : e.getValue());
                } catch (IllegalArgumentException ignored) {
                    // 非法 header（含空格 / 换行）会让 Builder 抛异常，跳过即可。
                }
            }
        }
        return b.build();
    }

    public static Call newCall(String url, Map<String, String> headers) {
        return client().newCall(build(url, headers));
    }

    public static Call newCall(Request request) {
        return client().newCall(request);
    }

    public static Response newCall(String url, Map<String, String> headers, boolean raw)
            throws IOException {
        return client().newCall(build(url, headers)).execute();
    }

    /* ------------------------------------------------------------ 同步 GET */

    public static String string(String url) {
        return string(url, null);
    }

    public static String string(String url, Map<String, String> headers) {
        try (Response response = client().newCall(build(url, headers)).execute()) {
            ResponseBody body = response.body();
            return body == null ? "" : body.string();
        } catch (Exception e) {
            return "";
        }
    }

    /**
     * 带查询参数：参数会拼到 ?a=1&amp;b=2（值做 URL 编码的工作交给 okhttp 的
     * HttpUrl，避免手拼 encode 出错）。
     */
    public static String string(String url, Map<String, String> headers,
                                Map<String, String> params) {
        return string(withParams(url, params), headers);
    }

    /** 字节流（图片 / 需要自己解压的响应）。 */
    public static byte[] bytes(String url, Map<String, String> headers,
                               Map<String, String> params) {
        try (Response response = client().newCall(build(withParams(url, params), headers))
                .execute()) {
            ResponseBody body = response.body();
            return body == null ? new byte[0] : body.bytes();
        } catch (Exception e) {
            return new byte[0];
        }
    }

    /* ------------------------------------------------------------ 同步 POST */

    public static String post(String url, String body, Map<String, String> headers) {
        try {
            Request.Builder b = new Request.Builder()
                    .url(url)
                    .header("User-Agent", UA)
                    .post(RequestBody.create(null, body == null ? "" : body));
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    if (e.getKey() == null) continue;
                    try {
                        b.header(e.getKey(), e.getValue() == null ? "" : e.getValue());
                    } catch (IllegalArgumentException ignored) {
                    }
                }
            }
            try (Response response = client().newCall(b.build()).execute()) {
                ResponseBody rb = response.body();
                return rb == null ? "" : rb.string();
            }
        } catch (Exception e) {
            return "";
        }
    }

    /** 表单 POST（`application/x-www-form-urlencoded`）。 */
    public static String post(String url, Map<String, String> headers,
                              Map<String, String> params) {
        FormBody.Builder form = new FormBody.Builder();
        if (params != null) {
            for (Map.Entry<String, String> e : params.entrySet()) {
                if (e.getKey() == null) continue;
                form.add(e.getKey(), e.getValue() == null ? "" : e.getValue());
            }
        }
        try {
            Request.Builder b = new Request.Builder()
                    .url(url)
                    .header("User-Agent", UA)
                    .post(form.build());
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    if (e.getKey() == null) continue;
                    try {
                        b.header(e.getKey(), e.getValue() == null ? "" : e.getValue());
                    } catch (IllegalArgumentException ignored) {
                    }
                }
            }
            try (Response response = client().newCall(b.build()).execute()) {
                ResponseBody rb = response.body();
                return rb == null ? "" : rb.string();
            }
        } catch (Exception e) {
            return "";
        }
    }

    /* ------------------------------------------------------------ 工具 */

    static String withParams(String url, Map<String, String> params) {
        if (url == null) return "";
        if (params == null || params.isEmpty()) return url;
        StringBuilder sb = new StringBuilder(url);
        sb.append(url.contains("?") ? '&' : '?');
        boolean first = true;
        for (Map.Entry<String, String> e : params.entrySet()) {
            if (e.getKey() == null) continue;
            if (!first) sb.append('&');
            first = false;
            sb.append(e.getKey()).append('=').append(e.getValue() == null ? "" : e.getValue());
        }
        return sb.toString();
    }
}
