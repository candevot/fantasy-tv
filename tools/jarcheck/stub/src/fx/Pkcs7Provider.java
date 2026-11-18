package fx;

import java.security.Provider;

/** 把 Android 的 AES/ECB/PKCS7Padding 补进 OpenJDK。 */
public class Pkcs7Provider extends Provider {
    public Pkcs7Provider() {
        super("FxAndroidCompat", "1.0", "PKCS7Padding 兼容层");
        put("Cipher.AES/ECB/PKCS7Padding", fx.Pkcs7Cipher.class.getName());
        put("Cipher.AES/CBC/PKCS7Padding", fx.Pkcs7Cipher.class.getName());
        put("Cipher.AES/CTR/PKCS7Padding", fx.Pkcs7Cipher.class.getName());
        put("Cipher.AES/GCM/PKCS7Padding", fx.Pkcs7Cipher.class.getName());
    }
}
