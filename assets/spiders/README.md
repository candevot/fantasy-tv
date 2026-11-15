# assets/spiders —— 可选的内置 jar 插件

把肥猫那份 `spider.jar` 放到这里（文件名必须是 `spider.jar`），CI 的
`tools/patch_jar_spider.py` 会把它拷进 `android/app/src/main/assets/spiders/`，
App 首次启动时由原生 `installBundled()` 解到 `filesDir/spiders/bundled.jar`，
**不联网也能用**。

- 文件大小：服务器上那份实测 **1,929,492 B（1.9 MB）**，dex 包
  （`classes.dex` 4.9 MB + META-INF），体积完全可以内置。
- 默认策略：先试内置；没有内置就走「设置 → jar 插件」里的下载地址
  （默认 `http://125.94.244.87/spider.jar`，md5
  `cbe016eb3cb002ae62058604843f5106`），下载完强校验 md5。
- 这个目录默认是空的：内置会把 APK 撑大 1.9 MB，且服务器地址已经可用，
  需要离线兜底时再放文件进来。
