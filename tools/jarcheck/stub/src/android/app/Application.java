package android.app;
import android.content.Context;
public class Application extends Context {
    public Application() {}
    public void onCreate() {}
    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks cb) {}
    public ActivityLifecycleCallbacks aa() { return null; }
    public interface ActivityLifecycleCallbacks {}
}
