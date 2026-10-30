// HTTP 上游的端到端测试。
//
// 内置清单全是 socks5，但用户手填的出口可能是 `http://`。桥必须按
// 协议分派 —— 对 HTTP 代理发 SOCKS5 问候字节，得到的是「版本号 72」
// （72 是字母 'H'），报错完全指不到真正的原因。
//
// 这个文件起一个**假的 HTTP 代理**，验 CONNECT 转发、Basic 认证头、
// 407 拒绝这三条路径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fus_inbox/data/proxy_config.dart';
import 'package:fus_inbox/data/socks_bridge.dart';
import 'package:test/test.dart';

/// 一个足够像样的 HTTP 代理。
///
/// 收到 `CONNECT host:port` 就回 200 然后进隧道模式（回声）；
/// 配了 [expectUser] 时检查 `Proxy-Authorization`，不对就回 407。
class _FakeHttpProxy({
  this.expectUser = '',
  this.expectPass = '',
  this.replyStatus = 200,
}) {
  final String expectUser;
  final String expectPass;
  final int replyStatus;

  /// 最近一次收到的请求头，测试直接读它。
  String seenHead = '';
  String seenAuth = '';
  int connections = 0;

  ServerSocket? _server;
  int get port => _server!.port;

  Future<void> start() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handle(Socket c) async {
    connections++;
    final buf = <int>[];
    var tunnel = false;
    final headReady = Completer<void>();

    // **只订阅一次。** 第一版是「先 listen 一下再 cancel，再 listen 真的
    // 那个」—— `Socket` 的流只能被订阅一次，第二次直接抛
    // `Bad state: Stream has already been listened to`。
    // 所以状态机必须写在一个监听器里，靠 `tunnel` 这个开关切阶段。
    c.listen(
      (d) {
        if (tunnel) {
          // 隧道模式：原样回声，模拟一个服务器。
          try {
            c.add(d);
          } catch (_) {}
          return;
        }
        buf.addAll(d);
        if (headReady.isCompleted) return;
        // 先判「这是不是 HTTP 请求」。SOCKS5 问候只有 3 个字节
        // （`\x05\x01\x02`）且**永远不会有 `\r\n\r\n`**，只等结尾标记的话
        // 这里会一直等到桥超时，测出来的原因就变成「没收到应答」而不是
        // 「对面不是 SOCKS5」—— 后者才是这条要锁的东西。
        if (buf.isNotEmpty && buf[0] != 0x43) {
          seenHead = 'NOT-HTTP';
          headReady.complete();
          return;
        }
        final end = _headEnd(buf);
        if (end < 0) return;
        seenHead = utf8.decode(buf.sublist(0, end), allowMalformed: true);
        buf.removeRange(0, end + 4);
        headReady.complete();
      },
      onError: (_) {
        if (!headReady.isCompleted) headReady.completeError(StateError('连接出错'));
      },
      cancelOnError: false,
    );

    try {
      await headReady.future;
    } catch (_) {
      return;
    }

    final lines = seenHead.split('\r\n');
    for (final l in lines) {
      if (l.toLowerCase().startsWith('proxy-authorization:')) {
        seenAuth = l.substring(l.indexOf(':') + 1).trim();
      }
    }

    // 有期望凭据就校验。Basic 的载荷是 base64(user:pass)。
    if (expectUser.isNotEmpty) {
      final want =
          'Basic ${base64.encode(utf8.encode('$expectUser:$expectPass'))}';
      if (seenAuth != want) {
        c.write('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');
        await c.flush();
        await c.close();
        return;
      }
    }

    if (replyStatus != 200) {
      c.write('HTTP/1.1 $replyStatus Nope\r\n\r\n');
      await c.flush();
      await c.close();
      return;
    }

    c.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    await c.flush();
    tunnel = true;

    // 握手期间可能已经收到隧道数据，补回声。
    if (buf.isNotEmpty) {
      c.add(List<int>.from(buf));
      buf.clear();
    }
  }
}

int _headEnd(List<int> b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// 以 WebView 的身份敲桥的门。
class _Peer(this.socket) {
  final Socket socket;
  final _buf = <int>[];
  bool _closed = false;
  Completer<void>? _pending;

  Future<void> listen() async {
    socket.listen(
      (d) {
        _buf.addAll(d);
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      onError: (_) {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  void _wake() {
    final c = _pending;
    _pending = null;
    c?.complete();
  }

  Future<void> _more() {
    if (_closed) return Future<void>.value();
    final c = Completer<void>();
    _pending = c;
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  Future<String> readHead() async {
    while (true) {
      final end = _headEnd(_buf);
      if (end >= 0) {
        final s = utf8.decode(_buf.sublist(0, end), allowMalformed: true);
        _buf.removeRange(0, end + 4);
        return s;
      }
      if (_closed) throw StateError('还没收到完整响应头连接就断了');
      await _more();
    }
  }

  Future<String> takeText(int n) async {
    while (_buf.length < n && !_closed) {
      await _more();
    }
    if (_buf.length < n) throw StateError('少收到字节');
    final out = utf8.decode(_buf.sublist(0, n), allowMalformed: true);
    _buf.removeRange(0, n);
    return out;
  }

  void send(String s) => socket.add(utf8.encode(s));
}

Future<_Peer> _open(int port) async {
  final p = _Peer(await Socket.connect('127.0.0.1', port));
  await p.listen();
  return p;
}

ProxyConfig _httpCfg(int port, {String user = '', String pass = ''}) =>
    ProxyConfig(
      scheme: ProxyScheme.http,
      host: '127.0.0.1',
      port: port,
      user: user,
      password: pass,
    );

void main() {
  test('http 上游', () async {
    // ── ① 无认证：CONNECT 转发 + 隧道 ──
    {
      final up = _FakeHttpProxy();
      await up.start();
      final bridge = SocksBridge();
      final port = await bridge.start(upstream: _httpCfg(up.port));

      final peer = await _open(port);
      peer.send(
        'CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n',
      );
      expect(
        (await peer.readHead()).startsWith('HTTP/1.1 200'),
        isTrue,
        reason: '桥应当回 200',
      );
      expect(
        up.seenHead.startsWith('CONNECT example.com:443 HTTP/1.1'),
        isTrue,
        reason: '上游收到的是 CONNECT，不是 SOCKS5 问候',
      );
      expect(bridge.connections, 1, reason: '计了一条');

      const msg = 'hello-through-http';
      peer.send(msg);
      expect(await peer.takeText(msg.length), msg, reason: '隧道双向通');

      peer.socket.destroy();
      await bridge.stop();
      await up.stop();
    }

    // ── ② 带认证：Basic 头必须被补上 ──
    //
    // 这是桥存在的核心理由：`findProxy` 的指令串塞不进凭据，
    // 所以认证只能在桥这里补。
    {
      final up = _FakeHttpProxy(expectUser: 'alice', expectPass: 'secret');
      await up.start();
      final bridge = SocksBridge();
      final port = await bridge.start(
        upstream: _httpCfg(up.port, user: 'alice', pass: 'secret'),
      );

      final peer = await _open(port);
      peer.send('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
      expect(
        (await peer.readHead()).startsWith('HTTP/1.1 200'),
        isTrue,
        reason: '凭据对，桥回 200',
      );
      expect(
        up.seenAuth.startsWith('Basic '),
        isTrue,
        reason: '上游收到了 Proxy-Authorization: Basic',
      );
      expect(
        up.seenAuth,
        'Basic ${base64.encode(utf8.encode('alice:secret'))}',
        reason: '载荷是 base64(user:pass)',
      );

      peer.socket.destroy();
      await bridge.stop();
      await up.stop();
    }

    // ── ③ 凭据错 → 407 → 桥回 502，且原因指向「认证」 ──
    //
    // 必须能分清「认证错」和「连不上」：前者用户要改密码，后者要换出口。
    {
      final up = _FakeHttpProxy(expectUser: 'alice', expectPass: 'secret');
      await up.start();
      final bridge = SocksBridge();
      final port = await bridge.start(
        upstream: _httpCfg(up.port, user: 'alice', pass: '错'),
      );

      final peer = await _open(port);
      peer.send('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
      expect(
        (await peer.readHead()).startsWith('HTTP/1.1 502'),
        isTrue,
        reason: '桥把 407 翻成 502',
      );
      expect(
        bridge.lastError.contains('认证'),
        isTrue,
        reason: '原因说得出是认证，实际是：${bridge.lastError}',
      );

      peer.socket.destroy();
      await bridge.stop();
      await up.stop();
    }

    // ── ④ 上游回别的状态码（比如 403）→ 502，原因带状态码 ──
    {
      final up = _FakeHttpProxy(replyStatus: 403);
      await up.start();
      final bridge = SocksBridge();
      final port = await bridge.start(upstream: _httpCfg(up.port));

      final peer = await _open(port);
      peer.send('CONNECT blocked.example:443 HTTP/1.1\r\n\r\n');
      expect(
        (await peer.readHead()).startsWith('HTTP/1.1 502'),
        isTrue,
        reason: '桥回 502',
      );
      expect(
        bridge.lastError.contains('403'),
        isTrue,
        reason: '原因带上游状态码，实际是：${bridge.lastError}',
      );

      peer.socket.destroy();
      await bridge.stop();
      await up.stop();
    }

    // ── ⑤ 同一份配置，改成 socks5 协议 → 走 SOCKS5 握手，不该被当成 HTTP ──
    //
    // 这条锁住「按 scheme 分派」这件事本身。只测 http 的话，
    // 一律走 socks5 的实现也能全过。
    {
      // 一个只接受 HTTP 的上游，对它发 SOCKS5 问候应该被拒。
      final up = _FakeHttpProxy();
      await up.start();
      final bridge = SocksBridge();
      // 故意把 scheme 标成 socks5，但实际端口上是 HTTP 服务。
      final port = await bridge.start(
        upstream: ProxyConfig(
          scheme: ProxyScheme.socks5,
          host: '127.0.0.1',
          port: up.port,
        ),
      );

      final peer = await _open(port);
      peer.send('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
      final head = await peer.readHead();
      expect(
        head.startsWith('HTTP/1.1 502'),
        isTrue,
        reason: '协议对不上时必须失败，不能假装成功',
      );
      expect(
        bridge.lastError.contains('不是 SOCKS5'),
        isTrue,
        reason: '原因指得出「对面不是 SOCKS5」，实际是：${bridge.lastError}',
      );

      peer.socket.destroy();
      await bridge.stop();
      await up.stop();
    }

    // ── ⑥ 上游连上却不说话 → 握手超时，不是永久挂着 ──
    //
    // 这是实测里最常见的坏出口：三次握手完成，然后一个字节都不回。
    // `Socket.connect` 的超时只覆盖到「连上」，握手字节的读取完全没有
    // 期限 —— 不设超时就是永久占一条连接和两个 fd。
    {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      silent.listen((c) {
        held.add(c);
        // 什么都不发，也不关。
      });

      final bridge = SocksBridge()
        ..handshakeTimeout = const Duration(milliseconds: 300);
      final port = await bridge.start(upstream: _httpCfg(silent.port));

      final peer = await _open(port);
      final watch = Stopwatch()..start();
      peer.send('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
      final head = await peer.readHead();
      watch.stop();

      expect(head.startsWith('HTTP/1.1 502'), isTrue, reason: '沉默的上游必须失败');
      expect(
        bridge.lastError.contains('没收到'),
        isTrue,
        reason: '原因说得出是「没收到应答」，实际是：${bridge.lastError}',
      );
      expect(
        watch.elapsedMilliseconds < 3000,
        isTrue,
        reason: '不能等满 8 秒默认值，实测 ${watch.elapsedMilliseconds}ms',
      );

      peer.socket.destroy();
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
      await bridge.stop();
    }
  });
}
