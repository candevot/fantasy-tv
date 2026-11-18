package fx;
import android.content.SharedPreferences;
import java.util.*;

/** 内存版 SharedPreferences（实测台用，不落盘）。 */
public class Prefs implements SharedPreferences {
    private static final Map<String, Prefs> CACHE = new HashMap<>();
    public static synchronized Prefs get(String name) { return CACHE.computeIfAbsent(name == null ? "default" : name, k -> new Prefs()); }
    private final Map<String, Object> map = new HashMap<>();
    public Map<String, ?> getAll() { return map; }
    public String getString(String k, String d) { Object v = map.get(k); return v == null ? d : String.valueOf(v); }
    public Set<String> getStringSet(String k, Set<String> d) { Object v = map.get(k); return v == null ? d : (Set<String>) v; }
    public int getInt(String k, int d) { Object v = map.get(k); return v == null ? d : ((Number) v).intValue(); }
    public long getLong(String k, long d) { Object v = map.get(k); return v == null ? d : ((Number) v).longValue(); }
    public float getFloat(String k, float d) { Object v = map.get(k); return v == null ? d : ((Number) v).floatValue(); }
    public boolean getBoolean(String k, boolean d) { Object v = map.get(k); return v == null ? d : (Boolean) v; }
    public boolean contains(String k) { return map.containsKey(k); }
    public SharedPreferences.Editor edit() { return new Ed(); }
    private class Ed implements SharedPreferences.Editor {
        public SharedPreferences.Editor putString(String k, String v) { map.put(k, v); return this; }
        public SharedPreferences.Editor putStringSet(String k, Set<String> v) { map.put(k, v); return this; }
        public SharedPreferences.Editor putInt(String k, int v) { map.put(k, v); return this; }
        public SharedPreferences.Editor putLong(String k, long v) { map.put(k, v); return this; }
        public SharedPreferences.Editor putFloat(String k, float v) { map.put(k, v); return this; }
        public SharedPreferences.Editor putBoolean(String k, boolean v) { map.put(k, v); return this; }
        public SharedPreferences.Editor remove(String k) { map.remove(k); return this; }
        public SharedPreferences.Editor clear() { map.clear(); return this; }
        public boolean commit() { return true; }
        public void apply() {}
    }
}

// 同名不同槽：按文件名缓存
