# 影视壳（FongMi 5.16 / OK影视）搜索页与分类导航 —— 组件结构说明

对照源码：
- `okys/fm-516/app/src/mobile/java/com/fongmi/android/tv/ui/**`（FongMi 5.16 手机端）
- `okys/fm-516/app/src/main/java/com/fongmi/android/tv/{model,bean,api}/**`（两边共用）
- `okys/ok-src/sources/{S3,p107p2,R6}/**`（OK影视反编译）

结论先写：**壳的搜索页是「顶部搜索框 + 左侧固定源列表 + 右侧结果网格」三段式**，
源列表不随结果滚动；分类页是「顶部横向分类 tab + ViewPager 分页」。
我们现在的「一排横向胶囊 + 一条长列表」在结构上和壳不是一回事。

---

## 一、搜索页：三个 Activity/Fragment 套娃

```
SearchActivity                       ← 只有一个 FrameLayout 容器
└─ SearchFragment                   ← 搜索输入态（输入框 + 热词/联想 + 历史）
   └─ CollectFragment（add 到同一容器，SearchFragment 被 hide）
      ← 结果态（左：源列表；右：结果网格）
```

### 1. `SearchActivity`（`ui/activity/SearchActivity.java`）

- 布局 `activity_search.xml`：**只有一个 `FragmentContainerView id=container`**，没有搜索框。
- `initView` 里 `replace(R.id.container, SearchFragment.newInstance(keyword))`。
- 返回键：有 backstack 就 `popBackStack()`，否则退出。

### 2. `SearchFragment`（`ui/fragment/SearchFragment.java` + `fragment_search.xml`）

```
MaterialToolbar id=toolbar
└─ AppCompatEditText id=keyword      imeOptions=actionSearch，输入框就在 toolbar 里
NestedScrollView
└─ LinearLayout
   ├─ TextView id=record             「搜索记录」
   ├─ RecyclerView id=recordRecycler  FlexboxLayoutManager(ROW) —— 历史是**流式换行的标签云**
   ├─ TextView id=word               「热门搜索 / 搜索建议」
   └─ RecyclerView id=wordRecycler    FlexboxLayoutManager(ROW) —— 热词/联想同样是标签云
```

- 回车（`IME_ACTION_SEARCH`）→ `search()`：写历史 → 收键盘 → `collect(keyword)`。
- `collect()` 才是关键：**把 `CollectFragment` add 到 Activity 的 `R.id.container`，
  同时把 `SearchFragment` `hide()`**（不是 replace，输入框状态留着，点 toolbar 能回来）。
- 输入框内容变化 → 调 `https://suggest.video.iqiyi.com/?if=mobile&key=…` 拿联想词；
  空输入 → `https://api.web.360kan.com/v1/rank?cat=1` 拿热词（并落盘缓存）。
- 右上角菜单 `menu_search`：`action_reset`（清空）、`action_site`（**源开关弹窗** `SiteDialog.search()`）。

### 3. `CollectFragment`（`ui/fragment/CollectFragment.java` + `fragment_collect.xml`）★ 核心

```xml
LinearLayout(vertical)
├─ MaterialToolbar id=toolbar          标题 = 搜索关键词；点击 → 回搜索输入态（带 edit=true）
└─ LinearLayout(horizontal)            ← 整页唯一的内容区
   ├─ CustomRecyclerView id=collect    LinearLayoutManager，**左侧竖向源列表**
   │     width = clamp(最长源名宽度+48dp, 120dp, screenWidth/(列数+1)-40dp)
   └─ RecyclerView id=recycler         GridLayoutManager，右侧结果区
         spanCount = getCount()
```

代码要点：

| 行为 | 实现 |
|---|---|
| 参与搜索的源 | `VodConfig.get().getSites().stream().filter(Site::isSearchable)` —— 配置里 `searchable:0` 的源**不进列表也不发请求** |
| 首项 | `Collect.all()` —— 名字是「全部」，`activated=true`，把所有源的结果**合并**进这一项 |
| 每个源一项 | 源返回非空结果时 `mCollectAdapter.add(Collect.create(list))`（`Collect` = site + list + page + activated） |
| 点源 | `mSearchAdapter.setItems(item.getList(), () -> recycler.scrollToPosition(0))` + `setActivated` + `mScroller.setPage(item.getPage())` |
| 结果卡片 | `adapter_search.xml`：**128dp 高的一行** = 96dp 海报 + 片名（3 行）+ 集数文案 + 右上角**来源角标**（`item.getSiteName()`） |
| 翻页 | `CustomScroller` 绑在右侧 `recycler` 上；滚到底 → `searchContent(activated.getSite(), keyword, false, nextPage)`，**只翻当前选中的那个源**（「全部」不翻页） |
| 增量 | `SiteViewModel.searchContent(List<Site>, keyword, quick)` 对每个源 `App.submitSearch(SearchTask.create(...).run())`，**每回来一个源就 `postValue` 一次**，页面边收边显示 |

`CollectAdapter` 只做一件事：把 `Collect` 渲染成一个**文本按钮**（`adapter_collect.xml` =
`MaterialTextView` + `shape_item` 圆角背景 + `setActivated` 选中态），点一下切换右侧列表。

**这就是「分类导航」在搜索页的形态**：不是横向胶囊，而是一条**固定不滚动的左栏**，
里面是「全部 + 每个出了结果的源」。

### 4. 多源调度（`model/SiteViewModel` + `model/SearchTask`）

```java
public void searchContent(List<Site> sites, String keyword, boolean quick) {
    stopSearch();
    sites.forEach(site -> searchFuture.add(App.submitSearch(SearchTask.create(this, site, keyword, quick).run())));
}
```

- **每个源一个独立任务，全部并发提交**（`App.searchExecutor`），谁先回来谁先上屏；
- `SearchTask.call()`：`type==3` → `site.spider().searchContent(keyword, quick)`；
  翻页时走三参版本 `searchContent(keyword, quick, page)`；
- `quick=true` 且 `site.isQuickSearch()==false` 的源直接返回空（配置里 37 个源 `quickSearch:0`）；
- 关键词先过 `Trans.t2s()`（繁转简）—— 我们没做这一步，繁体关键词会漏源；
- 结果 `vod.setSite(site)`，卡片上的来源角标就是这里来的；
- 单次调用超时 `Constant.TIMEOUT_VOD = 30s`，**没有全局锁**，慢源只拖慢它自己。

---

## 二、分类导航（首页 / 分类页）

### `VodFragment`（`ui/fragment/VodFragment.java` + `fragment_vod.xml`）

```xml
CoordinatorLayout
├─ AppBarLayout id=appBar
│  ├─ MaterialToolbar id=toolbar       logo + 标题 + menu(search / keep / history)
│  └─ RecyclerView id=type             **横向分类 tab 条**（TypeAdapter，selector_item_round 选中态）
├─ CustomViewPager id=pager            每个分类一个 FolderFragment（懒加载）
├─ ProgressLayout id=progress
└─ FloatingActionButton id=filter      分类筛选（filter 按钮，有 filters 才显示）
```

- `TypeAdapter.addAll(result)`：`result.getTypes()`（来自 `homeContent` 的 `class` 数组）
  + 如果首页还有 `list`，**在最前面插一个「首页」tab**（`typeId="home"`）；
- tab 与 pager 双向联动：`addOnPageChangeListener` → `type.smoothScrollToPosition(position)`；
  点 tab → `pager.setCurrentItem(position)`；
- `TypeFragment` 负责单个分类的内容：`categoryContent(tid, page, true, extend)`，
  布局是 `SwipeRefreshLayout + ProgressLayout + CustomRecyclerView`，
  `style.isList() ? LinearLayoutManager : GridLayoutManager(Product.getColumn(...))`。

### 列数规则（`Product.java`）

```java
public static int getColumn(Context c) {
    int count = ResUtil.isLand(c) ? 7 : 5;          // 竖屏基数 5
    count += ResUtil.isPad() ? 1 : 0;               // 平板 +1
    return Math.abs(Setting.getSize() - count);     // size 默认 2 → 竖屏 |2-5| = 3 列
}
```

→ **分类页 = 3 列海报网格（竖屏）**，横屏 5 列，平板 6 列；`size` 设置项可调。

### OK影视 的差异（`S3/C0278e.java` = CollectFragment，`p107p2/a.java` = Product）

- 搜索页同样是 `fragment_collect.xml`（`collect` + `recycler` + `toolbar` 三件套），
  但**多一个「列表/网格」切换按钮**（`menu action_view`，`viewType` 存 `R6.g`，默认 3 = 网格）；
- 网格 span：`u0(i8)` 里 `iK = a.k() - 1 = |size-5| - 1`，默认 size=2 → **2 列**；
  切到列表模式则 span = 1（平板 2/3）；
- 分类页 `z.java` 仍用 `GridLayoutManager(a.k())` → 3 列，和 FongMi 一致。

> 用户说的「壳是 3 列海报网格」对应的是**分类页**；搜索页壳实际是
> FongMi 1 列（96dp 海报 + 文字）／OK影视 默认 2 列可切。要做 3 列需要我们自己定，
> 不能说是「照壳」。

---

## 三、和我们现在的实现对照

| 维度 | 壳 | 我们（`lib/pages/search_page.dart`） |
|---|---|---|
| 源导航 | 左侧**竖向固定栏**，宽 120dp~屏宽/(列+1)，不随结果滚 | `_sourceFilterBar()` = **横向滚动胶囊**，且**在 sliver 列表里**（跟着结果滚走） |
| 源列表内容 | 「全部」+ 每个有结果的源 | 「全部 N」+ 每个有结果的源（`_sourceCounts`）—— 内容一致，**位置和形态不同** |
| 结果卡片 | `adapter_search`：96dp 海报 + 片名 + 来源角标（OK影视可切网格） | `FxSearchResultTile`：84×112 海报 + 标题 + 元信息，**长条 tile** |
| 结果容器 | `GridLayoutManager(spanCount)` | `SliverList`（单列长列表） |
| 分区 | 无「我们的源 / 外部源」之分，全部混在一个列表里按源聚合 | 分两段：own 一段 + `_externalHeader` 一段 |
| 输入态 | 独立 Fragment（热词/联想/历史标签云），结果态覆盖在上面 | 同一页面内切换（`_resultsView()` / 搜索态） |
| 源开关 | `SiteDialog.search()` 逐个源开关 `searchable` | 无（只能整份配置导入/删除） |
| 繁转简 | `Trans.t2s(keyword)` | 无 |
| 并发 | 每源一个任务，30s 单次超时，无全局锁 | 20 并发闸门 + 12s 源级预算 + 40s 整体收尾（本轮已改） |

---

## 四、按壳改造的落点（待确认后执行，本轮不动 UI）

1. `search_page.dart`：把 `_sourceFilterBar()` 从 sliver 里拿出来，放到
   `Column` 的固定区（搜索框下面、结果区上面），改成**左侧竖向列表**或
   **顶部固定横向条**（二选一，取决于是否保留「我们自己的源」那一段）；
2. `_resultSliver()`：`SliverList` → `SliverGrid`（`SliverGridDelegateWithFixedCrossAxisCount`，
   竖屏 3 列 / 横屏 5 列，与 `Product.getColumn` 同口径）；
3. `FxSearchResultTile` 增加「海报网格」变体（壳的 `adapter_vod_rect`：海报 + 单行片名 +
   右上角来源角标 + 集数），长条 tile 保留给列表模式；
4. 首页/分类页保持现状（我们自己 CMS 的分类），只在 `category_page.dart` 里
   对齐 3 列网格与 `Product.getColumn` 的列数口径；
5. 可选（壳有、我们没有）：`SiteDialog.search()` 那种**逐源搜索开关**，落在
   `source_settings_page.dart`。
