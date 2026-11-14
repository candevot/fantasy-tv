package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * TVBox 的解析器基类（JAR_SPIDER，2026-11-14）。
 *
 * <p>官方的 api.jar（FongMi/TV、CatVodTVOfficial/TVBoxOSC 的 catvod 模块）
 * 拿不到时，本文件就是它的「接口等价替身」：包名、类名、方法名、参数类型、
 * 返回类型与官方完全一致，所以现成的 csp_XXX.jar 里的子类可以照常继承、
 * 照常被 DexClassLoader 加载运行。
 *
 * <p>关键约定 —— **所有方法都必须有默认实现**：
 * <ul>
 *   <li>jar 里的子类往往只 override 其中几个（比如只写 searchContent + detailContent），
 *       剩下的交给基类默认实现；</li>
 *   <li>有些子类会写 {@code super.homeContent(filter)} 或者
 *       {@code super.init(context, extend)}，基类方法若是 abstract 就会
 *       AbstractMethodError / InvokeSuper 失败；</li>
 *   <li>默认返回空串而不是 null：TVBox 的调用方（我们这边是 JarSpiderLoader）
 *       统一按 JSON 解析返回值，返回 null 会让一半的源在第一次调用就报空指针。</li>
 * </ul>
 *
 * <p>签名注意：{@code categoryContent} 的第二参 {@code pg} 是 **String**
 * （页码），不是 boolean —— 老 TVBox 时代确实出现过 boolean 的写法，但
 * 现在线上 jar 全按 String 编译，写错类型会在反射查找时直接缺失方法。
 *
 * <p>本文件只依赖 android.content.Context 与 JDK 集合类型，不依赖 okhttp /
 * gson，改它不会牵连别的库。
 */
public abstract class Spider {

    /* ------------------------------------------------------------ 生命周期 */

    /** 老接口：只有 context，没有 ext。子类可能 override 它。 */
    public void init(Context context) throws Exception {
    }

    /** 主入口：构造完 Spider 后由加载器调用，ext 是站点配置（JSON / 地址 / 空串）。 */
    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    /** 释放资源（子类可选）。 */
    public void destroy() {
    }

    /* ------------------------------------------------------------ 内容接口 */

    /** 首页分类 + 首页推荐。`filter` 为 true 时请求带筛选条件。 */
    public String homeContent(boolean filter) throws Exception {
        return "";
    }

    /** 首页视频墙（部分源单独给一个「最近更新」列表）。 */
    public String homeVideoContent() throws Exception {
        return "";
    }

    /** 分类列表。tid = 分类 id，pg = 页码（字符串），extend = 筛选条件。 */
    public String categoryContent(String tid, String pg, boolean filter,
                                  HashMap<String, String> extend) throws Exception {
        return "";
    }

    /** 详情。ids 是 vod_id 列表（TVBox 支持多 id 一起查）。 */
    public String detailContent(List<String> ids) throws Exception {
        return "";
    }

    /** 搜索（旧签名，没有页码）。 */
    public String searchContent(String key, boolean quick) throws Exception {
        return "";
    }

    /** 搜索（带页码）。 */
    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return "";
    }

    /** 取播放地址。flag = 线路名，id = 该集的地址 / 编号，vipFlags = VIP 解析标记。 */
    public String playerContent(String flag, String id, List<String> vipFlags)
            throws Exception {
        return "";
    }

    /** 直播列表 / 直播播放地址。 */
    public String liveContent(String url) throws Exception {
        return "";
    }

    /* ------------------------------------------------------------ 辅助判定 */

    /** 是否需要 App 侧再校验一次「能不能播」。 */
    public boolean manualVideoCheck() {
        return false;
    }

    /** 这个地址是不是视频（给嗅探用）。 */
    public boolean isVideoFormat(String url) {
        return false;
    }

    /* ------------------------------------------------------------ 本地代理 / 动作 */

    /**
     * 本地代理（m3u8 改写、解密等）。返回
     * {@code {code, header, content}} 三个元素的 Object[]，不支持时返回 null。
     */
    public Object[] proxyLocal(Map<String, String> params) throws Exception {
        return null;
    }

    /** 新版本代理入口，语义同 {@link #proxyLocal(Map)}。 */
    public Object[] proxy(Map<String, String> params) throws Exception {
        return null;
    }

    /** 自定义动作（收藏同步、播放记录等），不支持时返回空串。 */
    public String action(String action) throws Exception {
        return "";
    }
}
