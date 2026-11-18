package android.os;
public class Parcel {
    public static Parcel obtain() { return new Parcel(); }
    public void recycle() {}
    public void writeString(String s) {}
    public String readString() { return null; }
    public void writeInt(int i) {}
    public int readInt() { return 0; }
    public void writeValue(Object o) {}
    public Object readValue(ClassLoader cl) { return null; }
    public void setDataPosition(int p) {}
    public byte[] marshall() { return new byte[0]; }
    public void unmarshall(byte[] b, int o, int l) {}
}
