package android.os;
import java.util.*;
public class Bundle {
    private final Map<String, Object> m = new HashMap<>();
    public void putString(String k, String v) { m.put(k, v); }
    public String getString(String k) { Object v = m.get(k); return v == null ? null : v.toString(); }
    public void putInt(String k, int v) { m.put(k, v); }
    public int getInt(String k) { Object v = m.get(k); return v == null ? 0 : ((Number) v).intValue(); }
    public void putSerializable(String k, Object v) { m.put(k, v); }
    public Object get(String k) { return m.get(k); }
    public Set<String> keySet() { return m.keySet(); }
}
