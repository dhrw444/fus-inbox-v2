/// 号码目录的抓取。
///
/// ## 为什么不走 WebView
///
/// `/numbers/` 是站点**服务端直出的静态 HTML**（`article.number-card`），
/// 不需要会话签名 —— 站点自己的 `live.js` 里写着
/// "This gate controls SMS bodies only."，签名锁只放在短信正文上。
///
/// 所以目录可以用普通的 `HttpClient` 抓，不用开一个 WebView 等页面渲染。
/// 代价是必须**自己把出口接上**：`dart:io` 的 `HttpClient` 由 Dart VM
/// 直接发 socket，完全不经过 WebView 的代理设置。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'number_entry.dart';
import 'number_insights.dart';

/// 抓目录时出的错。
///
/// 带上 [retryable]：上层靠它决定「重试」还是「直接告诉用户别试了」。
/// 靠解析消息字符串判断太脆。
class const NumberFetchError(this.message, {this.retryable = true})
    implements Exception {
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// 目录抓取器。
///
/// 只做三件事：**走哪条出口**、**连接怎么复用**、**几页怎么并发**。
/// 解析在 [parseNumberPage]，这里不碰 HTML。
class NumberFetcher({
  /// 出口指令，即 `HttpClient.findProxy` 的返回值。
  ///
  /// 三种取值，语义必须明确：
  /// - `'DIRECT'` —— 有意直连（用户没开「目录走代理」）
  /// - `'PROXY host:port'` —— 走当前那条出口
  /// - `null` —— **要代理但出口还没起来**
  ///
  /// 传 null 时请求会**失败**，绝不退化成直连 —— 理由见 [_findProxy]。
  this.egress,
  this.base = 'https://freeussms.com',
}) {
  /// 用户代理。`HttpClient` 不会自己带，站点按 UA 分模板，必须显式设。
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  /// 单页上限。站点自报总数缺失时用它兜底，防止无限翻页。
  static const pageCap = 40;

  final String? Function()? egress;
  final String base;

  late final HttpClient _http = HttpClient()
    ..findProxy = _findProxy
    // 连接复用是这里唯一真正有效的提速手段。
    //
    // 实测单页耗时构成：DNS + TCP + **TLS 握手占六成以上**，而握手只在
    // 新建连接时发生。把 5 页塞进同一条 keep-alive 连接，后 4 页能省掉
    // 4 次握手。比调任何页间隔都管用。
    ..maxConnectionsPerHost = 6
    ..connectionTimeout = const Duration(seconds: 15)
    // idleTimeout 要盖住整个抓取过程，太短会在页与页之间被回收，
    // 等于每次重握手。
    ..idleTimeout = const Duration(seconds: 45)
    ..autoUncompress = true;

  int _fetched = 0;

  /// 已抓的页数。给界面显示进度用。
  int get fetchedPages => _fetched;

  /// `HttpClient.findProxy` 的实现。
  ///
  /// ## 这条是整个抓取里最重要的一段
  ///
  /// 没有注入 [egress] → 直连（测试和纯解析场景走这条）。
  ///
  /// 注入了但回调返回 null → **抛异常让这次请求失败**。
  ///
  /// 为什么不是返回 `'DIRECT'`：那样请求会成功、页面正常显示、一条报错
  /// 都没有，唯一的变化是**真实 IP 被交出去了一次**。这种失败没人能
  /// 发现。抛异常则会一路传到界面上的「目录拉取失败：…」，用户看得见。
  ///
  /// 实测确认过：不挂 `findProxy` 时请求照样成功、SOCKS5 侧连接数为 0
  /// —— 也就是说「以为在走代理」和「真的在走代理」从外面看不出区别。
  String _findProxy(Uri uri) {
    final hook = egress;
    if (hook == null) return 'DIRECT';
    final directive = hook();
    if (directive == null || directive.isEmpty) {
      throw const NumberFetchError('出口没起来，已拒绝直连', retryable: false);
    }
    return directive;
  }

  String _pageUrl(int page) =>
      page <= 1 ? '$base/numbers/' : '$base/numbers/page/$page/';

  /// 抓一页。
  Future<NumberPage> fetchPage(int page) async {
    final uri = Uri.parse(_pageUrl(page));
    late final HttpClientResponse res;
    try {
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      // 站点按 referer 判断来源，缺了会当成外链。
      req.headers.set(HttpHeaders.refererHeader, _pageUrl(page));
      req.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml',
      );
      res = await req.close().timeout(const Duration(seconds: 20));
    } on NumberFetchError {
      rethrow;
    } on Exception catch (e) {
      throw NumberFetchError('网络请求失败：$e');
    }

    if (res.statusCode != HttpStatus.ok) {
      // 响应体不读会占着连接不放。
      unawaited(res.drain<void>().catchError((Object _) {}));
      throw NumberFetchError(
        '目录第 $page 页返回 HTTP ${res.statusCode}',
        // 404 是「没有这一页了」，重试没意义；其余状态码可能是一时的。
        retryable: res.statusCode != HttpStatus.notFound,
      );
    }

    _fetched++;
    final body = await res.transform(utf8.decoder).join();
    return parseNumberPage(body);
  }

  /// 抓完整目录。
  ///
  /// 策略是「先探后并」：
  ///
  ///   1. 先单独抓第 1 页 —— 拿到站点自报总数，就能**精确**算出有几页
  ///      （实测：114 条 ÷ 24 = 5 页，第 5 页正好 18 条，第 6 页 404）
  ///   2. 剩下的页并发抓，最多 3 个在飞
  ///
  /// 为什么并发：单页实测 2~4 秒（站点在 Cloudflare 后面，握手本身慢），
  /// 5 页串行就是 10 秒起。限 3 个是折中 —— 既不像爆破，又能把 10 秒
  /// 压到 4 秒左右。
  ///
  /// [onProgress] 每完成一页回调一次，界面据此显示「已加载 N 个号」。
  Future<List<NumberEntry>> fetchAll({
    int? maxPages,
    void Function(int loaded, int page)? onProgress,
    void Function(List<NumberEntry> soFar)? onPage,
  }) async {
    _fetched = 0;
    var limit = maxPages ?? pageCap;
    if (limit <= 0 || limit > pageCap) limit = pageCap;

    // 第 1 页必须单独先来 —— 要读它自报的总数。
    final first = await _fetchWithRetry(1);
    if (first.entries.isEmpty) {
      throw const NumberFetchError('首页没有解析出任何号码');
    }

    final needed = first.pageCount(kNumberPageSize);
    if (needed != null && needed > 0 && needed < limit) limit = needed;

    final seen = <String>{};
    final out = <NumberEntry>[];
    for (final n in first.entries) {
      if (seen.add(n.digits)) out.add(n);
    }
    onProgress?.call(out.length, 1);
    onPage?.call(List<NumberEntry>.unmodifiable(out));

    // 首页不足一页 = 站点总共就这些。
    if (limit <= 1 || first.entries.length < kNumberPageSize) return out;

    final queue = <int>[for (var p = 2; p <= limit; p++) p];
    var done = 1;
    var failed = 0;

    /// 把一个结果并入主列表。
    ///
    /// 抽成同步函数是有意的：保证「改 out + 回调」是一个不可分割的片段。
    /// 否则两个 worker 在 await 之间交错写入，`onPage` 的快照会出现
    /// 号码忽多忽少的抖动。
    void merge(List<NumberEntry> batch) {
      done++;
      for (final n in batch) {
        if (seen.add(n.digits)) out.add(n);
      }
      onProgress?.call(out.length, done);
      onPage?.call(List<NumberEntry>.unmodifiable(out));
    }

    Future<void> worker() async {
      while (true) {
        // **取值和判空必须在同一个同步片段里，中间不能有 await。**
        // 否则两个 worker 可能在 await 间隙拿到同一页，重复请求。
        if (queue.isEmpty) return;
        final page = queue.removeAt(0);

        final NumberPage batch;
        try {
          batch = await _fetchWithRetry(page);
        } on NumberFetchError catch (e) {
          // 单页失败**不能让 worker 退出** —— 它退出后队列里剩下的页
          // 就没人抓了。记一笔继续取下一页。
          failed++;
          if (!e.retryable) {
            queue.clear();
            return;
          }
          continue;
        }
        if (batch.entries.isEmpty) {
          // 空页 = 站点已经没有更多了，清空队列让所有 worker 收工。
          queue.clear();
          return;
        }
        merge(batch.entries);
      }
    }

    const concurrency = 3;
    await Future.wait([
      for (var i = 0; i < concurrency && i < limit - 1; i++) worker(),
    ]);

    if (out.isEmpty) {
      throw NumberFetchError('目录抓取失败（$failed 页出错）');
    }
    return out;
  }

  /// 抓单页，失败重试两次（1 秒、2 秒退避）。
  ///
  /// 只对 [NumberFetchError.retryable] 的错误重试 —— 出口没起来、404
  /// 这些重试多少次都一样，只会白白打站点。
  Future<NumberPage> _fetchWithRetry(int page) async {
    NumberFetchError? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await fetchPage(page);
      } on NumberFetchError catch (e) {
        last = e;
        if (!e.retryable) rethrow;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    throw last!;
  }

  /// 抓一个号码的活动快照（**含收录时间**）。
  ///
  /// 抓的是号码详情页 `/numbers/<11 位>/` 的 HTML，不是某个接口 ——
  /// 收录时间只在那页的 `<script id="fus-number-insights">` 里，目录页
  /// 没有。理由见 `number_insights.dart` 的文档。
  ///
  /// [digits] 收 10 位（`4044225634`）或 11 位（`14044225634`），
  /// 因为界面和目录两处给的形状不一样。
  ///
  /// 返回 null 表示**站点没给**（页面没这块、快照过期、号码对不上）。
  /// 抛 [NumberFetchError] 表示**我们没抓到**（网络、出口、HTTP 错误）。
  /// 两种失败必须分开：前者是「这号没有数据」，后者是「再试一次可能就有」，
  /// 界面上该说的和该做的都不一样。
  Future<NumberInsights?> fetchInsights(String digits) async {
    final eleven = digits.length == 10 ? '1$digits' : digits;
    if (eleven.length != 11) {
      throw const NumberFetchError('号码位数不对', retryable: false);
    }
    final uri = Uri.parse('$base/numbers/$eleven/');

    late final HttpClientResponse res;
    try {
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      // 从目录点进来时站点就是这么带的 referer。直接开号码页不带的话
      // 站点可能当外链处理（和目录抓取同一套逻辑）。
      req.headers.set(HttpHeaders.refererHeader, '$base/numbers/');
      req.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml',
      );
      res = await req.close().timeout(const Duration(seconds: 20));
    } on NumberFetchError {
      rethrow;
    } on Exception catch (e) {
      throw NumberFetchError('抓号码页失败：$e');
    }

    if (res.statusCode != HttpStatus.ok) {
      unawaited(res.drain<void>().catchError((Object _) {}));
      throw NumberFetchError(
        '号码页返回 HTTP ${res.statusCode}',
        retryable: res.statusCode != HttpStatus.notFound,
      );
    }

    final body = await res.transform(utf8.decoder).join();
    // 解析失败不抛 —— 那是「站点没给/给了坏的」，不是「我们抓失败」。
    return parseNumberInsights(body, wantDigits: eleven);
  }

  /// 释放连接。页面销毁时调用，`force: true` 顺手掐掉还在飞的请求。
  void dispose() => _http.close(force: true);
}
