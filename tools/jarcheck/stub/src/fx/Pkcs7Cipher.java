package fx;

import javax.crypto.Cipher;
import javax.crypto.CipherSpi;
import javax.crypto.spec.IvParameterSpec;
import java.security.AlgorithmParameters;
import java.security.Key;
import java.security.SecureRandom;
import java.security.spec.AlgorithmParameterSpec;

/**
 * Android 的 "AES/ECB/PKCS7Padding"：OpenJDK 只有 PKCS5Padding。
 * AES 分组 16 字节，PKCS7 与 PKCS5 在这里完全等价 —— 直接转发。
 */
public class Pkcs7Cipher extends CipherSpi {
    private Cipher delegate;
    private String mode = "ECB";
    private String padding = "PKCS5Padding";

    private Cipher make() {
        try {
            return Cipher.getInstance("AES/" + mode + "/" + padding);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    @Override protected void engineSetMode(String s) { mode = s; }
    @Override protected void engineSetPadding(String s) {
        padding = s.toUpperCase().contains("PKCS7") ? "PKCS5Padding" : s;
    }
    @Override protected int engineGetBlockSize() { return 16; }
    @Override protected int engineGetOutputSize(int n) { return (delegate == null ? make() : delegate).getOutputSize(n); }
    @Override protected byte[] engineGetIV() { return delegate == null ? null : delegate.getIV(); }
    @Override protected AlgorithmParameters engineGetParameters() { return delegate == null ? null : delegate.getParameters(); }
    @Override protected void engineInit(int opmode, Key key, SecureRandom random) {
        try { delegate = make(); delegate.init(opmode, key, random); } catch (Exception e) { throw new RuntimeException(e); }
    }
    @Override protected void engineInit(int opmode, Key key, AlgorithmParameterSpec params, SecureRandom random) {
        // Android 的 ECB 实现会忽略 IvParameterSpec，OpenJDK 会抛
        // "ECB mode cannot use IV" —— 这里按 Android 语义把 IV 丢掉。
        if ("ECB".equalsIgnoreCase(mode) && params instanceof IvParameterSpec) {
            engineInit(opmode, key, random);
            return;
        }
        try { delegate = make(); delegate.init(opmode, key, params, random); } catch (Exception e) { throw new RuntimeException(e); }
    }
    @Override protected void engineInit(int opmode, Key key, AlgorithmParameters params, SecureRandom random) {
        try { delegate = make(); delegate.init(opmode, key, params, random); } catch (Exception e) { throw new RuntimeException(e); }
    }
    @Override protected byte[] engineUpdate(byte[] in, int off, int len) {
        return delegate.update(in, off, len);
    }
    @Override protected int engineUpdate(byte[] in, int off, int len, byte[] out, int outOff) {
        try { return delegate.update(in, off, len, out, outOff); } catch (Exception e) { throw new RuntimeException(e); }
    }
    @Override protected byte[] engineDoFinal(byte[] in, int off, int len) {
        try { return delegate.doFinal(in, off, len); } catch (Exception e) { throw new RuntimeException(e); }
    }
    @Override protected int engineDoFinal(byte[] in, int off, int len, byte[] out, int outOff) {
        try { return delegate.doFinal(in, off, len, out, outOff); } catch (Exception e) { throw new RuntimeException(e); }
    }
}
