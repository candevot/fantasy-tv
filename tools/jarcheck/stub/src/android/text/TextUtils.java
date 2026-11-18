package android.text;
public class TextUtils {
    public static boolean isEmpty(CharSequence s) { return s == null || s.length() == 0; }
    public static String join(CharSequence d, Iterable<?> items) {
        if (items == null) return "";
        StringBuilder sb = new StringBuilder();
        for (Object o : items) { if (sb.length() > 0) sb.append(d); sb.append(o); }
        return sb.toString();
    }
    public static String join(CharSequence d, Object[] items) {
        if (items == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.length; i++) { if (i > 0) sb.append(d); sb.append(items[i]); }
        return sb.toString();
    }
    public static boolean equals(CharSequence a, CharSequence b) { return a == null ? b == null : a.equals(b); }
    public static CharSequence concat(CharSequence... t) { StringBuilder sb = new StringBuilder(); for (CharSequence c : t) sb.append(c); return sb.toString(); }
    public static boolean isDigitsOnly(CharSequence s) { return s != null && s.toString().matches("\\d+"); }
    public static String[] split(String t, String d) { return t.split(d); }
}
