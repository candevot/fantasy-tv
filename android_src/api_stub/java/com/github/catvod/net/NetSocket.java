package com.github.catvod.net;

/**
 * jar 源里的 WebSocket 出口（FATCAT_API 2026-11-15）。
 *
 * <p>只有少数源（弹幕 / 直播）用它，宿主没注入实现时 `send` 返回 false，
 * 源会走自己的降级分支 —— 比 NoClassDefFoundError 直接崩掉好。
 */
public class NetSocket {

    public interface Listener {
        void onOpen();

        void onMessage(byte[] bytes);

        void onFailure(Throwable e);

        void onClosed();
    }

    public static class Event {
    }

    public NetSocket() {
    }

    public boolean send(byte[] bytes) {
        return false;
    }

    public void close() {
    }
}
