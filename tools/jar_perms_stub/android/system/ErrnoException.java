package android.system;

/** `android.system.ErrnoException` 的替身：真机上 chmod/stat 失败会抛它。 */
public class ErrnoException extends Exception {
    public ErrnoException(String message) {
        super(message);
    }
}
