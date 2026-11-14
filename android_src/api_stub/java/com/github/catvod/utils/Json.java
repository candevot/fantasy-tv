package com.github.catvod.utils;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

/**
 * jar 源常用的 JSON 助手（JAR_SPIDER）。
 *
 * <p>现成的 csp_XXX.jar 里到处是 {@code Json.parse(...)} / {@code Json.toJson(...)}，
 * 官方 api.jar 里就是 gson 的一层薄封装。这里用同一套语义实现：
 * <ul>
 *   <li>{@link #safeParse(String)} 永不抛异常（解析失败返回空对象），
 *       对应官方「坏 JSON 当空处理」的行为；</li>
 *   <li>{@link #toJson(Object)} 关闭 html 转义 —— 站点返回的地址里带
 *       {@code &} 时不会被写成 {@code \u0026}，否则拼出来的 URL 直接 404。</li>
 * </ul>
 */
public class Json {

    private static final Gson GSON =
            new GsonBuilder().disableHtmlEscaping().serializeNulls().create();

    public static Gson gson() {
        return GSON;
    }

    /** 严格解析：不合法时抛异常（老 jar 里有的调用会 catch 它）。 */
    public static JsonObject parse(String json) {
        JsonElement e = JsonParser.parseString(json == null ? "{}" : json);
        return e.isJsonObject() ? e.getAsJsonObject() : new JsonObject();
    }

    /** 宽松解析：任何异常都吃掉，返回空对象。 */
    public static JsonObject safeParse(String json) {
        try {
            return parse(json);
        } catch (Exception e) {
            return new JsonObject();
        }
    }

    /** 数组解析：失败返回空数组。 */
    public static JsonArray parseArray(String json) {
        try {
            JsonElement e = JsonParser.parseString(json == null ? "[]" : json);
            return e.isJsonArray() ? e.getAsJsonArray() : new JsonArray();
        } catch (Exception e) {
            return new JsonArray();
        }
    }

    public static JsonArray safeParseArray(String json) {
        return parseArray(json);
    }

    public static String toJson(Object o) {
        try {
            return GSON.toJson(o);
        } catch (Exception e) {
            return "{}";
        }
    }

    /** 取字符串字段，缺字段 / null 时返回空串（不返回 "null" 文本）。 */
    public static String getString(JsonObject obj, String key) {
        if (obj == null || key == null || !obj.has(key)) return "";
        JsonElement e = obj.get(key);
        if (e == null || e.isJsonNull()) return "";
        return e.isJsonPrimitive() ? e.getAsString() : e.toString();
    }

    public static int getInt(JsonObject obj, String key, int def) {
        try {
            return obj == null || !obj.has(key) ? def : obj.get(key).getAsInt();
        } catch (Exception e) {
            return def;
        }
    }

    public static JsonObject object(String json) {
        return safeParse(json);
    }
}
