package com.huanxiang.fantasy_tv

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheKeyFactory

/**
 * 分片磁盘缓存的 cacheKey 规则（**播放器和预取器必须共用这一个**）。
 *
 * 服务端的播放列表里，分片都是 `/api/seg?u=<真实地址>&i=<序号>&s=<线路>&ln=<线路>`
 * 这样的同一路径、只有 query 不同的地址。所以不能只按路径算 key（所有分片会撞成
 * 一条），也不能完全信任 URL 原样（不同线路 / 会话可能给同一片带上不同的附加参数）。
 *
 * 规则：`stripQuery(url) + "||" + url`
 *   · 前半段 `stripQuery(url)` 是稳定前缀（同一片在多条线路上前缀一致），
 *   · 后半段整条 url 保唯一（`u` 才是真正的片地址）。
 *
 * 一致性怎么保证：播放器的 `CacheDataSource.Factory`、
 * [SegmentPreloader] 的工厂、以及首页续播预取 [ExoPlayerPlugin] 的
 * `prefetchSegment` 全都 `.setCacheKeyFactory(FxCacheKeyFactory)` ——
 * 只有一份实现，谁都不能自己拼 key。少任何一处，预取写进去的片
 * 播放器都查不到（等于白下）。
 */
@OptIn(UnstableApi::class)
object FxCacheKeyFactory : CacheKeyFactory {

    override fun buildCacheKey(dataSpec: DataSpec): String = cacheKeyOf(dataSpec.uri.toString())

    /** 去掉 query 的地址 + `||` + 完整地址。 */
    fun cacheKeyOf(url: String): String {
        val mark = url.indexOf('?')
        val head = if (mark < 0) url else url.substring(0, mark)
        return head + "||" + url
    }
}
