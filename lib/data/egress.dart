/// 出口（代理）的选择与保存。
///
/// ## 为什么单独一层
///
/// 「当前用哪条出口」这件事被三处读：目录抓取的 `findProxy`、桥的上游、
/// 界面上的显示。三处各读各的字段，必然漂 —— 旧代码就是这样：界面显示
/// 出口 A，实际请求走出口 B，因为界面读的是「刚选的那条」，而桥读的是
/// 「最后一次 start 时传的那条」。
///
/// 所以出口只有一个来源：这个类的 [_current]。谁要用就调 [egress] /
/// [current] 拿，不许自己存副本。
///
/// ## 三种出口状态，界面上必须能分清
///
///   - **直连**（[ProxyChoice.direct]）—— 用户明确选的
///   - **走某条代理**（[ProxyChoice.proxy]）—— 桥已经起来了
///   - **要代理但桥没起来**（[ProxyChoice.unavailable]）—— 抓取必须失败，
///     绝不偷偷直连
///
/// 第三种是最容易写错的一种：写成「桥没起来就直连」，界面上一片祥和，
/// 而真实 IP 已经交出去了。`findProxy` 那边靠抛异常守住（见
/// `number_fetch.dart`），这里负责把状态**说出来**。
library;

import 'dart:async';

import 'proxy_config.dart';
import 'proxy_probe.dart';
import 'socks_bridge.dart';

/// 当前出口的形态。
enum ProxyChoice() {
  /// 用户明确选了直连。`findProxy` 给 `'DIRECT'`。
  direct,

  /// 走某条代理。`findProxy` 给 `'PROXY 127.0.0.1:<端口>'`。
  proxy,

  /// 用户要代理，但桥没起来。`findProxy` **抛异常**，抓取失败。
  unavailable,
}

/// 出口管理。
///
/// 不继承任何框架的东西 —— 能在 `test/` 下用假上游跑。
class Egress() {
  /// 生产用的桥。**整个应用只有这一条** —— 桥每条连接都会现读上游，
  /// 所以换出口不需要重建桥，端口也就不会变。
  final _bridge = SocksBridge();

  /// 当前选中的出口。`null` = 直连。
  ProxyConfig? _current;

  /// 用户选的模式。
  ProxyChoice _choice = ProxyChoice.direct;

  /// 桥为什么起不来。空串 = 没出错。
  String _error = '';

  /// 最近一次测速结果，按出口 id 存。
  final _probes = <String, ProxyProbe>{};

  /// 内置清单（原始文本）。空 = 还没加载。
  String _manifest = '';

  /// 出口变了（界面据此刷新）。
  void Function()? onChanged;

  /// 桥的端口。桥没起来是 0。
  int get port => _bridge.port;

  /// 桥转过的连接数。界面空白时第一个该看的就是它。
  int get connections => _bridge.connections;

  /// 桥最近一次失败原因。
  String get bridgeError => _bridge.lastError;

  /// 当前出口。
  ProxyConfig? get current => _current;

  /// 当前形态。
  ProxyChoice get choice => _choice;

  /// 起桥失败的原因。空串 = 没出错。
  String get error => _error;

  /// 内置清单里有多少条。
  List<ProxyConfig> get manifest => parseProxyList(_manifest);

  /// 换一份清单（从 assets 读来的文本）。
  ///
  /// 不自动选出口 —— 清单里 588 条全是陌生人的代理，默认挑一条等于
  /// 把用户流量交给一个随机节点。必须他自己点。
  void loadManifest(String text) {
    _manifest = text;
    onChanged?.call();
  }

  /// 最近一次测速的结果。没测过返回 null。
  ProxyProbe? probeOf(ProxyConfig p) => _probes[p.id];

  /// 记一条测速结果。
  void noteProbe(ProxyConfig p, ProxyProbe r) {
    _probes[p.id] = r;
    onChanged?.call();
  }

  /// 选一条出口并起桥。
  ///
  /// 返回是否成功。失败时 [choice] 变成 [ProxyChoice.unavailable]，
  /// 界面必须显示 [error] —— 不能沉默地留在「直连」。
  ///
  /// [port] 默认 0（系统分配）。生产不该传具体端口 —— 端口变了，
  /// WebView 那边存的代理设置就失效。参数存在的理由是**能测**
  /// 「端口被占时怎么办」这条路径，而那条路径是真实存在的代码。
  Future<bool> useProxy(ProxyConfig target, {int port = 0}) async {
    _current = target;
    try {
      await _bridge.start(upstream: target, port: port);
      _choice = ProxyChoice.proxy;
      _error = '';
      onChanged?.call();
      return true;
    } catch (e) {
      // 端口占用之类。**不退回直连** —— 用户选了代理，这里悄悄改成直连
      // 就是一次静默的 IP 泄漏。
      _choice = ProxyChoice.unavailable;
      _error = '$e';
      onChanged?.call();
      return false;
    }
  }

  /// 换出口但**不重建桥**（热切换）。
  ///
  /// 只影响之后建立的连接 —— 正在加载的页面不会被掐断。这是桥
  /// `setUpstream` 的语义，也是旧代码踩过的坑（它用 stop+start，
  /// 端口变了、在传的连接断了）。
  void switchTo(ProxyConfig? next) {
    if (next == null) {
      direct();
      return;
    }
    if (!_bridge.isRunning) {
      // 桥没起来就没有「热切换」可言，只能起一条。
      unawaited(useProxy(next));
      return;
    }
    _current = next;
    _bridge.setUpstream(next);
    _choice = ProxyChoice.proxy;
    _error = '';
    onChanged?.call();
  }

  /// 明确选直连。
  ///
  /// 桥**不关** —— 关掉的话 `findProxy` 那边还在用旧端口，会连一个
  /// 已经死掉的代理。改成把桥的上游设成 null（桥自己直连），
  /// 然后 `findProxy` 给 `'DIRECT'`。
  void direct() {
    _current = null;
    _choice = ProxyChoice.direct;
    _error = '';
    if (_bridge.isRunning) _bridge.setUpstream(null);
    onChanged?.call();
  }

  /// 给 `HttpClient.findProxy` 的指令。
  ///
  /// **返回 null 表示「要代理但起不来」，调用方必须让请求失败。**
  /// 这条约定写在 `number_fetch.dart` 的 `_findProxy` 里，两边必须一致。
  ///
  /// `proxy` 分支还要再查一次端口：状态是 `proxy` 但桥已经没了（`stop`
  /// 被别处调过、或起桥之后崩了），`port` 会是 0，指令就变成
  /// `PROXY 127.0.0.1:0` —— 那不是「直连」，是「连一个不存在的代理」，
  /// 而 WebView 只会报 `ERR_PROXY_CONNECTION_FAILED`。按 unavailable 处理，
  /// 原因说得出。
  String? egress() {
    switch (_choice) {
      case ProxyChoice.direct:
        return 'DIRECT';
      case ProxyChoice.proxy:
        final p = port;
        if (p <= 0) return null;
        return 'PROXY 127.0.0.1:$p';
      case ProxyChoice.unavailable:
        return null;
    }
  }

  /// 状态一句话。界面上那行字。
  String get summary => switch (_choice) {
    ProxyChoice.direct => '直连（本机 IP）',
    ProxyChoice.proxy =>
      '走 ${_current?.displayName ?? '代理'}${_current != null && _current!.hasAuth ? '（带认证）' : ''}',
    ProxyChoice.unavailable => '要代理但桥起不来：$_error',
  };

  /// 测速并记下结果。
  Future<ProxyProbe> probe(ProxyConfig target) async {
    final r = await probeProxy(target);
    noteProbe(target, r);
    return r;
  }

  /// 批量测速。结果按下标一一对应。
  Future<List<ProxyProbe>> probeAll(
    List<ProxyConfig> targets, {
    int concurrency = 6,
    void Function(int index, ProxyProbe result)? onEach,
  }) => probeMany(
    targets,
    concurrency: concurrency,
    onEach: (i, r) {
      noteProbe(targets[i], r);
      onEach?.call(i, r);
    },
  );

  /// 关掉桥。应用退出时调。
  Future<void> dispose() async {
    await _bridge.stop();
    _choice = ProxyChoice.direct;
    _current = null;
    onChanged?.call();
  }
}

/// 按测速结果排序，最快的在前。
///
/// **没测过的排在最后**，不是排在最前 —— 排在前面的话，用户点「最快的
/// 那条」会点到一条从没测过的。同分时按 id 稳定排序，避免每次刷新顺序
/// 乱跳。
List<ProxyConfig> rankByProbe(
  List<ProxyConfig> list,
  ProxyProbe? Function(ProxyConfig) probeOf,
) {
  final copy = List<ProxyConfig>.from(list);
  copy.sort((a, b) {
    final pa = probeOf(a);
    final pb = probeOf(b);
    // 通了的总在没通/没测的前面。
    final oka = pa?.ok == true;
    final okb = pb?.ok == true;
    if (oka != okb) return oka ? -1 : 1;
    if (oka && okb) {
      final c = pa!.millis.compareTo(pb!.millis);
      if (c != 0) return c;
    }
    return a.id.compareTo(b.id);
  });
  return copy;
}
