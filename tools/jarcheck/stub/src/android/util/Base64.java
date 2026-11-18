package android.util;
public class Base64 {
    public static final int DEFAULT = 0, NO_WRAP = 2, NO_PADDING = 1, URL_SAFE = 8, CRLF = 4;
    public static String encodeToString(byte[] b, int flags) { return java.util.Base64.getEncoder().encodeToString(b); }
    public static byte[] decode(String s, int flags) { return java.util.Base64.getDecoder().decode(s); }
    public static byte[] encode(byte[] b, int flags) { return java.util.Base64.getEncoder().encode(b); }
    public static String encodeToString(byte[] b, int o, int l, int f) { return java.util.Base64.getEncoder().encodeToString(java.util.Arrays.copyOfRange(b, o, o + l)); }
    public static byte[] decode(byte[] b, int f) { return java.util.Base64.getDecoder().decode(b); }
}
