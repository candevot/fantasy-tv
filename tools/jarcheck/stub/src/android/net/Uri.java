package android.net;
public class Uri {
    private final String raw;
    private Uri(String s) { raw = s; }
    public static Uri parse(String s) { return new Uri(s); }
    public static Uri fromFile(java.io.File f) { return new Uri(f.getAbsolutePath()); }
    public String toString() { return raw == null ? "" : raw; }
    public String getScheme() { int i = raw == null ? -1 : raw.indexOf(':'); return i < 0 ? null : raw.substring(0, i); }
    public String getPath() { try { return new java.net.URI(raw).getPath(); } catch (Exception e) { return raw; } }
    public String getHost() { try { return new java.net.URI(raw).getHost(); } catch (Exception e) { return null; } }
    public String getQuery() { try { return new java.net.URI(raw).getQuery(); } catch (Exception e) { return null; } }
    public String getLastPathSegment() { String p = getPath(); if (p == null) return null; int i = p.lastIndexOf('/'); return i < 0 ? p : p.substring(i + 1); }
    public Builder buildUpon() { return new Builder(raw); }
    public static class Builder {
        private String s;
        Builder(String s) { this.s = s; }
        public Builder appendQueryParameter(String k, String v) { s = s + (s.contains("?") ? "&" : "?") + k + "=" + java.net.URLEncoder.encode(v == null ? "" : v); return this; }
        public Uri build() { return new Uri(s); }
    }
}
