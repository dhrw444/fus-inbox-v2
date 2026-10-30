/// 出口测速。
///
/// ## 测的是「真实那条路」，不是近似
///
/// 这里不起一条临时的 SOCKS5 握手去连目标，而是**起一条临时桥**，
/// 然后以 WebView 的身份敲桥的门发 `CONNECT`。理由：
///
///   - 走的字节和用户实际走的完全一样（HTTP 代理协议 → 桥 → 带认证
///     SOCKS5 → 目标），测出「通」就是真通
///   - 不复制第二份握手实现。复制出来的那份迟早和真实现漂开，
///     而漂开之后的测速结果会**说谎**：它说这条出口好，实际用的时候不通
///
/// 临时桥是独立实例，不碰生产桥 —— 否则测速会热切换出口，
/// 把正在加载的页面换到另一条线上。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_config.dart';
import 'socks_bridge.dart';

/// 一次测速的结果。
///
/// [millis] 无论成败都填 —— 失败也想知道「它多久才失败」。
/// 一秒内失败的出口和十秒超时的出口是两种坏法。
class const ProxyProbe({
  required this.ok,
  required this.millis,
  this.detail = '',
}) {
  final bool ok;

  /// 从开始到拿到结果（或拿到错误）花了多少毫秒。
  final int millis;

  /// 失败原因；成功时是「到哪通了」。界面原样显示。
  final String detail;
}

/// 默认测速目标：站点自己。
///
/// 不用 `1.1.1.1:443` 之类 —— 那测的是「能不能上网」，而用户关心的是
/// 「这条出口能不能打开这个站点」。上游对目标的白名单、出口所在地区
/// 的封锁，都只有打真目标才看得出来。
const kProbeHost = 'freeussms.com';
const kProbePort = 443;

/// 测一条出口。
Future<ProxyProbe> probeProxy(
  ProxyConfig target, {
  String host = kProbeHost,
  int port = kProbePort,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final watch = Stopwatch()..start();
  final bridge = SocksBridge()
    ..handshakeTimeout = timeout
    ..headTimeout = timeout;
  Socket? socket;
  try {
    final local = await bridge.start(upstream: target);
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      local,
      timeout: timeout,
    );
    socket.write('CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n\r\n');
    await socket.flush();

    final head = await _readHead(socket, timeout);
    watch.stop();
    if (!head.startsWith('HTTP/1.1 200')) {
      final reason = _reasonOf(head);
      return ProxyProbe(
        ok: false,
        millis: watch.elapsedMilliseconds,
        detail: reason.isEmpty ? '桥回了 ${head.split('\r\n').first}' : reason,
      );
    }
    return ProxyProbe(
      ok: true,
      millis: watch.elapsedMilliseconds,
      detail: '到 $host:$port 通了',
    );
  } catch (e) {
    watch.stop();
    // `SocketException: Connection refused (OS Error: ...)` 里的 OS Error
    // 段对用户没意义，但对排查有意义 —— 保留原文，界面按需截断。
    return ProxyProbe(
      ok: false,
      millis: watch.elapsedMilliseconds,
      detail: '$e',
    );
  } finally {
    try {
      socket?.destroy();
    } catch (_) {
      // 已经关了。
    }
    await bridge.stop();
  }
}

/// 批量测速，最多 [concurrency] 条同时在飞。
///
/// 返回的列表**和入参一一对应**（下标相同），不是「测成功的那些」——
/// 界面要按行显示结果，顺序错位会让用户把好出口当成坏的。
Future<List<ProxyProbe>> probeMany(
  List<ProxyConfig> targets, {
  int concurrency = 6,
  String host = kProbeHost,
  int port = kProbePort,
  Duration timeout = const Duration(seconds: 10),
  void Function(int index, ProxyProbe result)? onEach,
}) async {
  if (targets.isEmpty) return const [];
  final out = List<ProxyProbe>.filled(
    targets.length,
    const ProxyProbe(ok: false, millis: 0, detail: '没轮到'),
  );

  // `next` 的自增和判空必须在同一个同步片段里 —— 中间插一个 await，
  // 两个 worker 就可能拿到同一个下标，把同一条出口测两遍。
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (next >= targets.length) return;
      final i = next++;
      final r = await probeProxy(
        targets[i],
        host: host,
        port: port,
        timeout: timeout,
      );
      out[i] = r;
      onEach?.call(i, r);
    }
  }

  final n = concurrency < 1 ? 1 : concurrency;
  await Future.wait([
    for (var i = 0; i < n && i < targets.length; i++) worker(),
  ]);
  return out;
}

/// 读到 `\r\n\r\n` 为止。
///
/// 不能用 `take(n)` 那种「精确 n 字节」的写法：响应头长度不固定。
/// 也不能 `socket.first`：那拿到的是第一块数据，可能只有半行。
Future<String> _readHead(Socket socket, Duration timeout) {
  final buf = <int>[];
  final done = Completer<String>();
  late StreamSubscription<List<int>> sub;

  void finish() {
    if (done.isCompleted) return;
    for (var i = 0; i + 3 < buf.length; i++) {
      if (buf[i] == 13 &&
          buf[i + 1] == 10 &&
          buf[i + 2] == 13 &&
          buf[i + 3] == 10) {
        done.complete(utf8.decode(buf.sublist(0, i), allowMalformed: true));
        unawaited(sub.cancel());
        return;
      }
    }
  }

  sub = socket.listen(
    (d) {
      buf.addAll(d);
      finish();
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(StateError('桥在读响应头之前就断开了'));
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    },
    cancelOnError: true,
  );
  // 进来就试一次：数据可能已经在 `listen` 之前到达。
  finish();

  return done.future.timeout(
    timeout,
    onTimeout: () {
      unawaited(sub.cancel());
      throw StateError('${timeout.inSeconds} 秒内桥没回响应头');
    },
  );
}

/// 桥的失败响应是 `HTTP/1.1 502 <原因>`。取第三个字段开始的那段。
String _reasonOf(String head) {
  final line = head.split('\r\n').first;
  final parts = line.split(' ');
  if (parts.length < 3) return '';
  return parts.sublist(2).join(' ').trim();
}
