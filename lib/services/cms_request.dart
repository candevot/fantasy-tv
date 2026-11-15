/// 外部 CMS 源的**请求协议层**（纯逻辑，PROTOCOL_FACE 2026-11-15）。
///
/// 壳的 `SiteViewModel.call()`（`model/SiteViewModel.java:233-240`）里有两件
/// 我们原来完全没有的协议细节：
///
/// 1. **`ac=` 不是随便写**：`SiteViewModel` 里三处调用统一是
///    `ac = (site.type == 0 ? "videolist" : "detail")`；搜索是 `wd + quick +
///    extend（+ pg）`，详情是 `ids`，分类是 `t + pg`（+ 过滤 `f`）。
///    我们原来是「自己定一套参数」（`ac=list` / `ac=detail` 混着写），
///    碰上只认 TVBox 那套的源就直接空列表。
///
/// 2. **`ext` 长度决定 GET / POST**：`site.getExt().length() <= 1000 ? get : post`。
///    长 `ext`（大段 base64 的 jar 站点配置）塞进 query 会撞 414 / 被后端
///    截断 —— 这正是「有些源配了 ext 就永远空」的原因。
///
/// 这个文件不联网，只回答「这次请求该用 GET 还是 POST、参数放哪、带哪些头」，
/// 好处是单测能直接钉住（`test/cms_request_test.dart`），不用起 HTTP 服务。
library;

/// 这次请求在壳协议里叫什么动作。
enum CmsCall {
  /// 分类列表（`t` + `pg`）。
  categoryList,

  /// 搜索（`wd` + `quick` + `pg`）。
  search,

  /// 详情（`ids`）。
  detail,

  /// 站点自己的栏目表（`ac=list`，返回里带 `class` 数组）。
  classes,
}

/// GET 装得下的 `ext` 上限（壳里是 1000 个字面量）。
const int kMaxExtForGet = 1000;

/// HTTP 方法。
enum CmsHttpMethod {
  get,
  post;

  String get label => this == CmsHttpMethod.get ? 'GET' : 'POST';
}

/// 一个站点发请求时的画像：壳 `Site` 的 `header` / `ext` / `timeout`（本阶段
/// 用到的那几个字段）。
///
/// 默认值就是壳的默认值：空 header、空 ext、没有站点级 timeout（走全局）。
class CmsSiteProfile {
  const CmsSiteProfile({
    this.key = '',
    this.header = const <String, String>{},
    this.ext = '',
    this.timeout,
    this.playUrl = '',
    this.click = '',
    this.directKind = false,
    this.quickSearch = true,
  });

  /// 没有任何站点级配置时的画像（行为与改造前一致）。
  static const CmsSiteProfile empty = CmsSiteProfile();

  /// 站点 key（日志 / 失败记账用）。
  final String key;

  /// 站点级请求头。之前只从 `ext` 里抠 Referer / Cookie，配置里写
  /// `header:{"Referer":…}` 的源一律 403。
  final Map<String, String> header;

  /// 站点级 ext（作为 `extend` 参数发给 CMS；> [kMaxExtForGet] 走 POST）。
  final String ext;

  /// 站点级超时；null = 没配，用调用方的全局默认。
  final Duration? timeout;

  /// 站点级解析头（`parse:名字` / `json:地址`），交给 `ParseRegistry`。
  final String playUrl;

  /// 站点级点击脚本（WebView 嗅探阶段才执行，先透传）。
  final String click;

  /// 站点是不是 `type: 0`（直接地址形态）—— 决定 `ac=videolist` 还是 `detail`。
  final bool directKind;

  /// 站点允不允许快搜（壳 `Site.isQuickSearch()`，默认允许）。
  ///
  /// 壳在 `SearchTask` 里 `quick && !site.isQuickSearch()` → 直接空结果，
  /// 我们这边则是「搜索时带上 `quick=true`」—— 同一份配置在两边语义一致。
  final bool quickSearch;

  CmsSiteProfile copyWith({
    String? key,
    Map<String, String>? header,
    String? ext,
    Duration? timeout,
    String? playUrl,
    String? click,
    bool? directKind,
    bool? quickSearch,
  }) =>
      CmsSiteProfile(
        key: key ?? this.key,
        header: header ?? this.header,
        ext: ext ?? this.ext,
        timeout: timeout ?? this.timeout,
        playUrl: playUrl ?? this.playUrl,
        click: click ?? this.click,
        directKind: directKind ?? this.directKind,
        quickSearch: quickSearch ?? this.quickSearch,
      );
}

/// 一次准备好的请求。
class CmsRequest {
  const CmsRequest({
    required this.uri,
    required this.method,
    required this.header,
    this.body = '',
  });

  final Uri uri;
  final CmsHttpMethod method;

  /// 除 accept 之外的请求头（站点级 header 已合进来）。
  final Map<String, String> header;

  /// POST 时的表单体（`a=1&b=2`）；GET 时为空串。
  final String body;

  bool get isPost => method == CmsHttpMethod.post;

  /// 壳的 `ac` 取值：`type 0` 用 `videolist`，其余用 `detail`。
  ///
  /// 只有「站点栏目表」固定 `ac=list` —— 壳那边栏目是从首页响应里拿的，
  /// 我们是单独拉一次，`list` 是苹果 CMS 里带 `class` 数组的那个动作。
  static String acFor(CmsCall call, {required bool directKind}) {
    switch (call) {
      case CmsCall.classes:
        return 'list';
      case CmsCall.search:
        // 搜索不带 ac（壳只发 wd / quick / extend / pg），苹果 CMS 默认走
        // detail 语义。这里显式写 detail，避免有的源把无 ac 当 list。
        return 'detail';
      case CmsCall.categoryList:
      case CmsCall.detail:
        return directKind ? 'videolist' : 'detail';
    }
  }

  /// 组装请求。
  ///
  /// [params] 是已经拼好的业务参数（含 `ac` / `t` / `pg` / `wd` / `ids`）；
  /// 站点 ext 在这里统一补成 `extend`（壳 `call()` 的第一句）。
  static CmsRequest build({
    required String api,
    required Map<String, String> params,
    CmsSiteProfile profile = CmsSiteProfile.empty,
  }) {
    final merged = <String, String>{...params};
    final ext = profile.ext;
    // 壳：`if (!site.getExt().isEmpty()) params.put("extend", site.getExt())`。
    // 搜索那边也显式给一个空 extend（部分源靠这个键判断走不走 TVBox 分支）。
    if (ext.isNotEmpty) {
      merged['extend'] = ext;
    } else if (merged['ac'] == 'detail' && merged.containsKey('wd')) {
      merged['extend'] = '';
    }
    final base = _baseUri(api);
    final usePost = ext.length > kMaxExtForGet;
    final header = <String, String>{
      'accept': '*/*',
      ...profile.header,
    };
    if (usePost) {
      return CmsRequest(
        uri: base,
        method: CmsHttpMethod.post,
        header: <String, String>{
          ...header,
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: merged.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}='
                '${Uri.encodeQueryComponent(e.value)}')
            .join('&'),
      );
    }
    return CmsRequest(
      uri: base.replace(
        queryParameters: <String, String>{
          ...base.queryParameters,
          ...merged,
        },
      ),
      method: CmsHttpMethod.get,
      header: header,
    );
  }

  /// 地址归一：没有 query 时补尾斜杠（`http://a.com/api.php/provide/vod` →
  /// 加 `/`），有 query 就原样（`…/vod/?key=x` 再加斜杠会变成 404）。
  static Uri _baseUri(String api) {
    var text = api.trim();
    if (text.isEmpty) return Uri.parse('');
    if (!text.contains('?')) {
      if (!text.endsWith('/')) text = '$text/';
    }
    return Uri.parse(text);
  }
}
