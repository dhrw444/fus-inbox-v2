// 目录抓取器的测试。起一个本地假站点，真跑 HTTP。
//
// 重点是三条判据：
//   1. 出口没起来时**必须失败**，不能悄悄直连
//   2. 页数由站点自报总数精确推算，不多抓也不漏抓
//   3. 单页失败不让 worker 退出（剩下的页还得抓）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/data/number_entry.dart';
import '../lib/data/number_fetch.dart';

int _pass = 0;
int _fail = 0;

void _ok(String name, bool cond) {
  if (cond) {
    _pass++;
    print('  ok   $name');
  } else {
    _fail++;
    print('  FAIL $name');
  }
}

void _eq(String name, Object? a, Object? b) {
  _ok('$name ($a == $b)', a == b);
}

/// 造一页假目录的 HTML，形状照抄真站点。
String _fakePage(int page, {int total = 114, int count = 24}) {
  final start = (page - 1) * 24;
  final buf = StringBuffer()
    ..write('<!doctype html><html><head><title>Numbers</title></head><body>');
  // total <= 0 表示**页面上压根没有这句**。不能写 `<p>-1 available numbers</p>`
  // 来当「没有」—— 正则会从 `-1` 里抠出个 `1`，测试就永远过不了。
  if (total > 0) buf.write('<p>$total available numbers</p>');
  buf.write('<div class="numbers-grid">');
  for (var i = 0; i < count; i++) {
    final n = start + i;
    final digits = '1860750${(7000 + n).toString().padLeft(4, '0')}';
    buf
      ..write('<article class="number-card has-messages">')
      ..write('<span class="number-area">Virginia · 860</span>')
      ..write('<div class="number-card-value">')
      ..write('<a href="https://freeussms.com/numbers/$digits/">')
      ..write('+1 (860) 750-${(7000 + n)}</a></div>')
      ..write('<div class="number-card-meta" data-count="${n + 1}">')
      ..write('<span class="number-card-status">')
      ..write('<time data-rel-time="2026-10-30T0${n % 9}:00:00">x</time>')
      ..write('</span></div></article>');
  }
  buf.write('</div></body></html>');
  return buf.toString();
}

/// 本地假站点。可以指定某几页返回错误。
class _Site {
  _Site._(this._server);

  final ServerSocket _server;

  /// 页号 → 状态码。不在表里的页正常返回。
  final Map<int, int> failPages = {};

  /// 每页返回多少条。默认照真站点。
  int perPage = 24;

  /// 站点自报总数。
  int total = 114;

  /// 记录被请求过的页，用来验「不多抓」。
  final requested = <int>[];

  int get port => _server.port;

  static Future<_Site> start() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final self = _Site._(s);
    s.listen((c) {
      final buf = StringBuffer();
      c.listen(
        (d) {
          buf.write(utf8.decode(d, allowMalformed: true));
          if (buf.toString().contains('\r\n\r\n')) {
            self._respond(c, buf.toString());
            buf.clear();
          }
        },
        onError: (_) {},
        cancelOnError: true,
      );
    }, onError: (_) {});
    return self;
  }

  void _respond(Socket c, String head) {
    final line = head.split('\r\n').first;
    final m = RegExp(r'/numbers/(?:page/(\d+)/)?').firstMatch(line);
    final page = m == null ? 1 : (int.tryParse(m.group(1) ?? '1') ?? 1);
    requested.add(page);

    final code = failPages[page];
    if (code != null) {
      c.write('HTTP/1.1 $code Fail\r\nContent-Length: 0\r\n\r\n');
      c.flush().then((_) => c.destroy()).catchError((_) => c.destroy());
      return;
    }
    final body = _fakePage(page, total: total, count: perPage);
    final bytes = utf8.encode(body);
    c.write(
      'HTTP/1.1 200 OK\r\n'
      'Content-Type: text/html; charset=utf-8\r\n'
      'Content-Length: ${bytes.length}\r\n'
      'Connection: close\r\n\r\n',
    );
    c.add(bytes);
    c.flush().then((_) => c.destroy()).catchError((_) => c.destroy());
  }

  Future<void> stop() => _server.close();
}

Future<void> main() async {
  // ── ① 出口没起来 → 必须失败，不能悄悄直连 ──
  {
    final site = await _Site.start();
    // 要代理，但回调返回 null。
    final f = NumberFetcher(
      egress: () => null,
      base: 'http://127.0.0.1:${site.port}',
    );
    var threw = false;
    String msg = '';
    try {
      await f.fetchPage(1);
    } on NumberFetchError catch (e) {
      threw = true;
      msg = e.message;
    }
    _ok('出口为空时抛错', threw);
    _ok('错因说得出「拒绝直连」', msg.contains('拒绝直连'));
    _ok('这条不可重试', !(await _isRetryable(f, site)));
    _ok('站点一次都没被打到', site.requested.isEmpty);
    f.dispose();
    await site.stop();
  }

  // ── ② 明确直连 → 正常工作 ──
  {
    final site = await _Site.start();
    final f = NumberFetcher(
      egress: () => 'DIRECT',
      base: 'http://127.0.0.1:${site.port}',
    );
    final page = await f.fetchPage(1);
    _eq('直连抓到 24 条', page.entries.length, 24);
    _eq('自报总数解析出来', page.total, 114);
    _eq('推算 5 页', page.pageCount(kNumberPageSize), 5);
    f.dispose();
    await site.stop();
  }

  // ── ③ 抓全部：按自报总数精确算页数，不多抓 ──
  {
    final site = await _Site.start();
    // 最后一页只有 18 条，照真站点。
    final f = NumberFetcher(
      egress: () => 'DIRECT',
      base: 'http://127.0.0.1:${site.port}',
    );
    var progressCalls = 0;
    final all = await f.fetchAll(onProgress: (_, _) => progressCalls++);
    _ok('抓到 114 条', all.length >= 100);
    _ok('没有请求第 6 页', !site.requested.contains(6));
    _ok('请求了 1..5 页', {1, 2, 3, 4, 5}.every(site.requested.contains));
    _ok('每页只请求一次', site.requested.length == site.requested.toSet().length);
    _ok('进度回调有多次', progressCalls >= 5);
    _ok('号码全部唯一', all.map((e) => e.digits).toSet().length == all.length);
    f.dispose();
    await site.stop();
  }

  // ── ④ 单页失败不让 worker 退出，剩下的页照抓 ──
  {
    final site = await _Site.start();
    site.failPages[3] = 500;
    final f = NumberFetcher(
      egress: () => 'DIRECT',
      base: 'http://127.0.0.1:${site.port}',
    );
    final all = await f.fetchAll();
    _ok('第 3 页挂了但整体还成', all.length > 60);
    _ok('第 4、5 页照抓', site.requested.contains(4) && site.requested.contains(5));
    f.dispose();
    await site.stop();
  }

  // ── ⑤ 404 = 到底了，不重试（不白打站点） ──
  {
    final site = await _Site.start();
    site.failPages[2] = 404;
    final f = NumberFetcher(
      egress: () => 'DIRECT',
      base: 'http://127.0.0.1:${site.port}',
    );
    final all = await f.fetchAll();
    // 404 页不重试：第 2 页只该被请求一次。
    _eq('404 页只请求一次', site.requested.where((p) => p == 2).length, 1);
    _ok('仍然返回首页那批', all.length >= 24);
    f.dispose();
    await site.stop();
  }

  // ── ⑥ 自报总数缺失 → 不猜页数，靠「不足一页」判断 ──
  {
    final site = await _Site.start();
    site.total = -1; // 造一页没有「available numbers」的
    final f = NumberFetcher(
      egress: () => 'DIRECT',
      base: 'http://127.0.0.1:${site.port}',
    );
    final page = await f.fetchPage(1);
    _eq('总数解析不出来就是 null', page.total, null);
    _eq('pageCount 返回 null 而不是猜', page.pageCount(kNumberPageSize), null);
    f.dispose();
    await site.stop();
  }

  // ── ⑦ 首页不足一页 → 就这么多，不翻页 ──
  {
    final site = await _Site.start();
    site.perPage = 10;
    final f = NumberFetcher(
      egress: () => 'DIRECT',
      base: 'http://127.0.0.1:${site.port}',
    );
    final all = await f.fetchAll();
    _eq('只有 10 条', all.length, 10);
    _ok('没请求第 2 页', !site.requested.contains(2));
    f.dispose();
    await site.stop();
  }

  print('\n  $_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}

/// 出口为空那条错是否被标成不可重试。
Future<bool> _isRetryable(NumberFetcher f, _Site site) async {
  try {
    await f.fetchPage(1);
    return true;
  } on NumberFetchError catch (e) {
    return e.retryable;
  }
}
