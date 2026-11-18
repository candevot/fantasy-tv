package android.content.pm;
public class Signature {
    private final String v;
    public Signature(byte[] b) { v = java.util.Arrays.toString(b); }
    public Signature(String s) { v = s; }
    public byte[] toByteArray() { return v.getBytes(); }
    public int hashCode() { return v.hashCode(); }
    public boolean equals(Object o) { return o instanceof Signature && v.equals(((Signature) o).v); }
}
