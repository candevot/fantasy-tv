package android.text;
public class Html {
    public static final int FROM_HTML_MODE_LEGACY = 0;
    public static final int FROM_HTML_MODE_COMPACT = 63;
    public static String fromHtml(String s) { return strip(s); }
    public static String fromHtml(String s, int flags) { return strip(s); }
    public static String escapeHtml(CharSequence s) { return s == null ? null : s.toString(); }
    private static String strip(String s) { return s == null ? "" : s.replaceAll("<[^>]+>", ""); }
}
