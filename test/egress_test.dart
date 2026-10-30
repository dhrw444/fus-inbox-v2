// 出口管理的测试。
//
// 这个文件锁的是**安全性质**，不是「功能能用」：
//
//   - 用户选了代理而桥起不来时，`egress()` 必须返回 null，
//     让抓取失败 —— 绝不能退化成 `'DIRECT'`
//   - 直连时桥不关（关掉的话 `findProxy` 还指着旧端口）
//   - 热切换不重建桥（端口不变、在传的连接不断）
library;

import 'dart:io';

import 'package:fus_inbox/data/egress.dart';
import 'package:fus_inbox/data/proxy_config.dart';
import 'package:fus_inbox/data/proxy_probe.dart';
import 'package:test/test.dart';

/// 一条能通的假上游（SOCKS5）。这里只需要「桥能 start 成功」，
/// 不需要真握手 —— 所以直接把桥的 upstream 指向一个**没人监听**的端口
/// 也能 start 成功（`ServerSocket.bind` 是本地监听，不碰上游）。
ProxyConfig _cfg(int port, {String label = ''}) => ProxyConfig(
  scheme: ProxyScheme.socks5,
  host: '127.0.0.1',
  port: port,
  user: 'u',
  password: 'p',
  label: label,
);

void main() {
  test('出口：直连 / 代理 / 起不来', () async {
    final e = Egress();
    addTearDown(() => e.dispose());

    // ── ① 默认是直连 ──
    expect(e.choice, ProxyChoice.direct, reason: '默认直连');
    expect(e.egress(), 'DIRECT', reason: '直连给 DIRECT');
    expect(e.port, 0, reason: '桥没起，端口是 0');

    // ── ② 选一条出口 → 桥起来，指令指向本地端口 ──
    final target = _cfg(9, label: '测试出口');
    final ok = await e.useProxy(target);
    expect(ok, isTrue, reason: '桥能起来');
    expect(e.choice, ProxyChoice.proxy, reason: '形态是 proxy');
    expect(e.port > 0, isTrue, reason: '端口分出来了');
    expect(e.egress(), 'PROXY 127.0.0.1:${e.port}', reason: '指令指向桥的端口');
    expect(e.current?.label, '测试出口', reason: '记下了当前出口');
    expect(e.summary.contains('测试出口'), isTrue, reason: '摘要说得出是哪条');
    expect(e.summary.contains('带认证'), isTrue, reason: '摘要说得出要认证');

    // ── ③ 热切换：端口不变 ──
    final portBefore = e.port;
    final second = _cfg(10, label: '第二条');
    e.switchTo(second);
    expect(e.port, portBefore, reason: '热切换不重建桥，端口不变');
    expect(e.current?.label, '第二条', reason: '当前出口换成第二条');
    expect(e.choice, ProxyChoice.proxy, reason: '还是 proxy');

    // ── ④ 切直连：桥**不关**，只是上游置空 ──
    e.direct();
    expect(e.choice, ProxyChoice.direct, reason: '形态变直连');
    expect(e.egress(), 'DIRECT', reason: '指令变 DIRECT');
    expect(e.port, portBefore, reason: '桥没关，端口还在');

    // ── ⑤ 最要紧的一条：要代理但桥起不来 → egress 必须是 null ──
    //
    // 造真实的「起不来」：先占一个端口，再让桥去绑**同一个**端口。
    // 这就是 `useProxy` 里那条 catch 分支，是真实存在的代码。
    final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => squatter.close());
    final taken = squatter.port;

    final b = Egress();
    addTearDown(() => b.dispose());
    final started = await b.useProxy(_cfg(9), port: taken);
    expect(started, isFalse, reason: '端口被占，桥起不来');
    expect(b.choice, ProxyChoice.unavailable, reason: '形态是 unavailable');
    expect(b.egress(), isNull, reason: '起不来时必须给 null —— 抓取失败，绝不偷偷直连');
    expect(b.summary.contains('起不来'), isTrue, reason: '摘要说得出原因');
    expect(
      b.choice,
      isNot(ProxyChoice.direct),
      reason: '用户选了代理，绝不能悄悄退回直连（那是静默的 IP 泄漏）',
    );

    // ── ⑤b 端口在、状态也自洽：proxy → 指向真端口 ──
    final c = Egress();
    addTearDown(() => c.dispose());
    expect(await c.useProxy(_cfg(9)), isTrue, reason: '系统分配端口能起来');
    expect(
      c.egress(),
      'PROXY 127.0.0.1:${c.port}',
      reason: 'proxy 形态必须指向真端口，不是 0',
    );
    expect(c.port > 0, isTrue, reason: '说是 proxy 就必须真有端口');
  });

  test('出口：清单解析与排序', () async {
    final e = Egress();
    addTearDown(() => e.dispose());

    // ── 清单加载 ──
    e.loadManifest(
      '# 注释行不算\n'
      'socks5://a:b@1.2.3.4:1080\n'
      'http://5.6.7.8:8080\n'
      '1.2.3.4:1080\n' // 重复（同 id），应被去重
      '\n'
      'garbage-line\n',
    );
    final list = e.manifest;
    expect(list.length, 2, reason: '去重后两条');
    expect(list.map((c) => c.id).toSet(), {
      'socks5://1.2.3.4:1080',
      'http://5.6.7.8:8080',
    }, reason: 'id 不含密码，且去重按它');

    // ── 排序：通了的在前，按耗时；没测过的在后 ──
    final a = _cfg(1080, label: 'a');
    final bb = _cfg(1081, label: 'b');
    final c = _cfg(1082, label: 'c');
    final d = _cfg(1083, label: 'd');
    final probes = <String, ProxyProbe>{
      a.id: const ProxyProbe(ok: true, millis: 800),
      bb.id: const ProxyProbe(ok: true, millis: 200),
      c.id: const ProxyProbe(ok: false, millis: 50, detail: '被拒'),
      // d 没测过
    };
    final ranked = rankByProbe([a, bb, c, d], (p) => probes[p.id]);
    expect(ranked.map((p) => p.label).toList(), [
      'b',
      'a',
      'c',
      'd',
    ], reason: '通的按快慢，失败的后，没测过的最后');

    // ── 同分稳定：同毫秒时按 id 排，不随机跳 ──
    final x = _cfg(2000, label: 'x');
    final y = _cfg(2001, label: 'y');
    final same = <String, ProxyProbe>{
      x.id: const ProxyProbe(ok: true, millis: 300),
      y.id: const ProxyProbe(ok: true, millis: 300),
    };
    final r1 = rankByProbe([x, y], (p) => same[p.id]).map((p) => p.id).toList();
    final r2 = rankByProbe([y, x], (p) => same[p.id]).map((p) => p.id).toList();
    expect(r1, r2, reason: '同分时顺序与入参顺序无关（按 id 稳定）');
  });
}
