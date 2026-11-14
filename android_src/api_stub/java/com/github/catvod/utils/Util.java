package com.github.catvod.utils;

import android.util.Base64;

import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.security.MessageDigest;

/**
 * jar 源常用的小工具（JAR_SPIDER）：md5 / base64 / URL 编解码 / 取域名。
 *
 * <p>这些在官方 api.jar 里也能找到同名方法，缺失时的表现是
 * NoSuchMethodError —— 而这类调用大多发生在签名计算、解密入口，
 * 一崩就是整个源不可用，所以这里按常用签名补上。
 *
 * <p>Base64 用 android.util.Base64（不是 java.util.Base64：后者要 API 26，
 * 本项目 minSdk 23，在旧机上会 NoClassDefFoundError）。
 */
public class Util {

    /** Java 的 Base64 在 Android 上不可靠，统一走 android.util.Base64。 */
    public static String base64(String s) {
        return encode(s);
    }

    public static String encode(String s) {
        try {
            return Base64.encodeToString(s.getBytes("UTF-8"), Base64.NO_WRAP);
        } catch (Exception e) {
            return "";
        }
    }

    public static String decode(String s) {
        try {
            return new String(Base64.decode(s, Base64.NO_WRAP), "UTF-8");
        } catch (Exception e) {
            return "";
        }
    }

    public static String md5(String s) {
        return hash("MD5", s);
    }

    public static String sha1(String s) {
        return hash("SHA-1", s);
    }

    public static String sha256(String s) {
        return hash("SHA-256", s);
    }

    static String hash(String algorithm, String s) {
        if (s == null) return "";
        try {
            MessageDigest md = MessageDigest.getInstance(algorithm);
            byte[] out = md.digest(s.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(out.length * 2);
            for (byte b : out) {
                int v = b & 0xFF;
                if (v < 16) sb.append('0');
                sb.append(Integer.toHexString(v));
            }
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    public static String urlEncode(String s) {
        try {
            return URLEncoder.encode(s == null ? "" : s, "UTF-8");
        } catch (UnsupportedEncodingException e) {
            return s == null ? "" : s;
        }
    }

    public static String urlDecode(String s) {
        try {
            return URLDecoder.decode(s == null ? "" : s, "UTF-8");
        } catch (Exception e) {
            return s == null ? "" : s;
        }
    }

    public static String getHost(String url) {
        try {
            java.net.URI uri = new java.net.URI(url);
            String host = uri.getHost();
            return host == null ? "" : host;
        } catch (Exception e) {
            return "";
        }
    }

    /** 只留 ascii / 数字以外的字符替换成空（很多 jar 用它清洗片名）。 */
    public static String clean(String s) {
        if (s == null) return "";
        return s.replaceAll("[\\p{Cntrl}]", "").trim();
    }
}
