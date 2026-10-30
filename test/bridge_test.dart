// 桥的端到端测试。
//
// 起一个**假的 SOCKS5 上游**（在本地），让桥去连它，然后我们以
// WebView 的身份连桥。这样能验到真东西：握手字节、认证、隧道、错误码。
//
// 跑：dart run tool/bridge_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fus_inbox/data/proxy_config.dart';
import 'package:fus_inbox/data/socks_bridge.dart';

import 'package:test/test.dart';

void _ok(String what, bool cond) {
  expect(cond, isTrue, reason: what);
}

/// 假上游记下来的请求。
class _Seen() {
  String host = '';
  int port = 0;
  String user = '';
  String pass = '';
}

/// 一个足够像样的 SOCKS5 上游。
///
/// [authOk] 为 false 时故意回「认证失败」；[connectRep] 非 0 时故意回
/// 一个失败应答码。这两个是用来测桥的错误路径的。
class _FakeSocks({
    this.expectUser = 'u',
    this.expectPass = 'p',
    this.authOk = true,
    this.connectRep = 0,
  }) {
  final String expectUser;
  final String expectPass;
  final bool authOk;
  final int connectRep;
  final seen = _Seen();

  ServerSocket? _server;
  int get port => _server!.port;

  Future<void> start() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen((c) => _Conn(this, c), onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

/// 处理一条上游连接。
///
/// 必须写成**显式状态机**。第一版是按「每来一块数据就把整个流程从头跑
/// 一遍」写的，结果进了认证阶段后首字节是 `0x01` 而不是 `0x05`，被开头
/// 那句「不是 SOCKS5 就返回」挡住 —— 流程永远推进不下去，测试直接卡死。
/// 状态机的阶段必须跟着流程走，不能靠数据长什么样去猜走到哪了。
class _Conn(this.fake, this.socket) {
  this {
    socket.listen(_onData, onDone: () {}, onError: (_) {}, cancelOnError: true);
  }

  final _FakeSocks fake;
  final Socket socket;
  final _buf = <int>[];

  /// 0=等问候 1=等认证 2=等 CONNECT 3=已进隧道
  int _phase = 0;

  /// 防重入：`_advance` 里有 await，同一阶段不能被跑第二遍，
  /// 否则会把同一段缓冲消费两次。
  bool _busy = false;

  void _onData(List<int> d) {
    if (_phase == 3) {
      // 隧道通了之后原样回声，模拟一个「服务器」。
      try {
        socket.add(d);
      } catch (_) {}
      return;
    }
    _buf.addAll(d);
    unawaited(_advance());
  }

  Future<void> _advance() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        switch (_phase) {
          case 0:
            if (!await _greeting()) return;
          case 1:
            if (!await _auth()) return;
          case 2:
            if (!await _connect()) return;
          default:
            return;
        }
      }
    } catch (_) {
      // 假上游崩了不该影响测试结论。
    } finally {
      _busy = false;
    }
  }

  /// 返回 true 表示这一步走完了，可以进下一步。
  Future<bool> _greeting() async {
    if (_buf.length < 2) return false;
    if (_buf[0] != 0x05) return false;
    final methods = _buf[1];
    if (_buf.length < 2 + methods) return false;
    final offered = _buf.sublist(2, 2 + methods);
    _buf.removeRange(0, 2 + methods);
    if (!offered.contains(0x02)) {
      // 客户端没报「用户名密码」，只能拒。
      socket.add(<int>[0x05, 0xFF]);
      await socket.flush();
      return false;
    }
    socket.add(<int>[0x05, 0x02]);
    await socket.flush();
    _phase = 1;
    return true;
  }

  Future<bool> _auth() async {
    if (_buf.length < 2) return false;
    if (_buf[0] != 0x01) return false;
    final ulen = _buf[1];
    if (_buf.length < 3 + ulen) return false;
    final user = utf8.decode(_buf.sublist(2, 2 + ulen));
    final plen = _buf[2 + ulen];
    if (_buf.length < 3 + ulen + plen) return false;
    final pass = utf8.decode(_buf.sublist(3 + ulen, 3 + ulen + plen));
    _buf.removeRange(0, 3 + ulen + plen);
    fake.seen
      ..user = user
      ..pass = pass;
    if (!fake.authOk || user != fake.expectUser || pass != fake.expectPass) {
      socket.add(<int>[0x01, 0x01]);
      await socket.flush();
      return false;
    }
    socket.add(<int>[0x01, 0x00]);
    await socket.flush();
    _phase = 2;
    return true;
  }

  Future<bool> _connect() async {
    if (_buf.length < 5) return false;
    if (_buf[0] != 0x05) return false;
    final atyp = _buf[3];
    if (atyp != 0x03) {
      socket.add(<int>[0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await socket.flush();
      return false;
    }
    final hlen = _buf[4];
    if (_buf.length < 7 + hlen) return false;
    final host = utf8.decode(_buf.sublist(5, 5 + hlen));
    final p = (_buf[5 + hlen] << 8) | _buf[6 + hlen];
    _buf.removeRange(0, 7 + hlen);
    fake.seen
      ..host = host
      ..port = p;

    if (fake.connectRep != 0) {
      socket.add(<int>[0x05, fake.connectRep, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await socket.flush();
      return false;
    }
    // 成功应答，绑一个全零的 IPv4 地址 —— 客户端必须把这段读干净。
    socket.add(<int>[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    await socket.flush();
    _phase = 3;

    // 握手期间可能已经顺手收到了隧道数据，补回声出去。
    if (_buf.isNotEmpty) {
      socket.add(List<int>.from(_buf));
      _buf.clear();
    }
    return true;
  }
}

/// 客户端一侧的读取器，模拟 WebView 的行为。
class _Peer(this.socket) {
  this {
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

  final Socket socket;
  final _buf = <int>[];
  bool _closed = false;
  Completer<void>? _pending;

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
      for (var i = 0; i + 3 < _buf.length; i++) {
        if (_buf[i] == 13 &&
            _buf[i + 1] == 10 &&
            _buf[i + 2] == 13 &&
            _buf[i + 3] == 10) {
          final s = utf8.decode(_buf.sublist(0, i), allowMalformed: true);
          _buf.removeRange(0, i + 4);
          return s;
        }
      }
      if (_closed) throw StateError('还没收到完整响应头连接就断了');
      await _more();
    }
  }

  Future<List<int>> take(int n) async {
    while (_buf.length < n && !_closed) {
      await _more();
    }
    if (_buf.length < n) throw StateError('少收到字节');
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  void send(String s) => socket.add(utf8.encode(s));
}

/// 以 WebView 的身份敲桥的门。
Future<_Peer> _connectBridge(int port) async {
  final s = await Socket.connect('127.0.0.1', port);
  return _Peer(s);
}

void main() {
  test('bridge', () async {

  // ── ① 端到端：握手 → 认证 → CONNECT → 隧道 ──
  {
    final up = _FakeSocks();
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'u',
        password: 'p',
      ),
    );

    final peer = await _connectBridge(port);
    peer.send('CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n');
    final head = await peer.readHead();
    _ok('CONNECT 回 200', head.startsWith('HTTP/1.1 200'));
    _ok('上游收到的目标对', up.seen.host == 'example.com' && up.seen.port == 443);
    _ok('上游收到凭据', up.seen.user == 'u' && up.seen.pass == 'p');
    _ok('桥计了连接数', bridge.connections == 1);

    // 隧道数据：发什么回来什么。
    const msg = 'tunnel-hello';
    peer.send(msg);
    _ok('隧道双向通', utf8.decode(await peer.take(msg.length)) == msg);

    // 大一点的数据，确认跨多个包也不截断。
    final big = 'x' * 20000;
    peer.send(big);
    _ok('20KB 不截断', utf8.decode(await peer.take(20000)) == big);

    peer.socket.destroy();
    await bridge.stop();
    await up.stop();
  }

  // ── ② 凭据不对 → 502，不是挂起 ──
  //
  // 上游期望 `u` / `p`，桥配的是 `u` / `错`。显式传期望值而不是靠默认 ——
  // 默认值一旦改动，这条测试就会静默失效（lint 的 `unused_element_parameter`
  // 就是在提醒这件事：这两个参数从没被任何测试用过）。
  {
    final up = _FakeSocks(expectUser: 'alice', expectPass: 'secret');
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'alice',
        password: '错',
      ),
    );
    final peer = await _connectBridge(port);
    peer.send('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
    _ok('认证失败回 502', (await peer.readHead()).startsWith('HTTP/1.1 502'));
    _ok('记下了失败原因', bridge.lastError.contains('认证'));
    peer.socket.destroy();
    await bridge.stop();
    await up.stop();
  }

  // ── ③ 上游拒绝 CONNECT → 502，原因说得清 ──
  {
    final up = _FakeSocks(connectRep: 0x05);
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'u',
        password: 'p',
      ),
    );
    final peer = await _connectBridge(port);
    peer.send('CONNECT blocked.example:443 HTTP/1.1\r\n\r\n');
    _ok('上游拒绝回 502', (await peer.readHead()).startsWith('HTTP/1.1 502'));
    _ok('原因含「连接被拒」', bridge.lastError.contains('连接被拒'));
    peer.socket.destroy();
    await bridge.stop();
    await up.stop();
  }

  // ── ③b 上游拒绝**认证**（不是 CONNECT）→ 502，原因不能跟「连接被拒」混 ──
  //
  // 这条是 lint 帮我发现的缺口：假上游有 `authOk` 这个开关，但从来没被
  // 传过值 —— 也就是「认证被拒」这条路径压根没测。用户配错账号密码时
  // 走的就是这条，报错信息必须能指向「凭据」而不是「连不上」。
  {
    final up = _FakeSocks(authOk: false);
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'u',
        password: 'p',
      ),
    );
    final peer = await _connectBridge(port);
    peer.send('CONNECT blocked.example:443 HTTP/1.1\r\n\r\n');
    _ok('上游拒绝认证也回 502', (await peer.readHead()).startsWith('HTTP/1.1 502'));
    _ok(
      '原因说的是认证，不是连接被拒',
      bridge.lastError.contains('认证') && !bridge.lastError.contains('连接被拒'),
    );
    peer.socket.destroy();
    await bridge.stop();
    await up.stop();
  }

  // ── ④ 请求行不完整 → 400，不是静默挂断 ──
  {
    final up = _FakeSocks();
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'u',
        password: 'p',
      ),
    );
    final peer = await _connectBridge(port);
    peer.send('GARBAGE\r\n\r\n');
    _ok('坏请求回 400', (await peer.readHead()).startsWith('HTTP/1.1 400'));
    peer.socket.destroy();
    await bridge.stop();
    await up.stop();
  }

  // ── ⑤ 只绑回环；stop 之后真的关掉 ──
  {
    final up = _FakeSocks();
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'u',
        password: 'p',
      ),
    );
    _ok('端口不为 0', port > 0);

    final p1 = await _connectBridge(port);
    p1.send('CONNECT a.example:443 HTTP/1.1\r\n\r\n');
    _ok('回环连得上', (await p1.readHead()).startsWith('HTTP/1.1 200'));
    p1.socket.destroy();

    // 真正的断言：拿本机的**非回环**地址去连，必须连不上。
    // 连得上就说明桥绑成了 0.0.0.0 —— 那就成了一个敞在局域网里的
    // 开放代理，同一个 wifi 下谁都能拿它当跳板。
    final external = <String>[];
    for (final ni in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in ni.addresses) {
        external.add(a.address);
      }
    }
    if (external.isEmpty) {
      markTestSkipped('没有非回环地址，这条判不了');
    } else {
      var reachable = false;
      for (final ip in external) {
        try {
          final s = await Socket.connect(
            ip,
            port,
            timeout: const Duration(seconds: 2),
          );
          s.destroy();
          reachable = true;
        } catch (_) {
          // 连不上 = 正确。
        }
      }
      _ok('外部地址连不上（没绑 0.0.0.0）', !reachable);
    }

    await bridge.stop();
    _ok('stop 后 isRunning 为假', !bridge.isRunning);
    _ok('stop 后 port 归 0', bridge.port == 0);

    var refused = false;
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 2),
      );
      s.destroy();
    } catch (_) {
      refused = true;
    }
    _ok('stop 后连不上', refused);

    await up.stop();
  }

  // ── ⑥ 两条并发连接互不干扰 ──
  {
    final up = _FakeSocks();
    await up.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: up.port,
        user: 'u',
        password: 'p',
      ),
    );
    final a = await _connectBridge(port);
    final b = await _connectBridge(port);
    a.send('CONNECT a.example:443 HTTP/1.1\r\n\r\n');
    b.send('CONNECT b.example:443 HTTP/1.1\r\n\r\n');
    _ok('A 拿到 200', (await a.readHead()).startsWith('HTTP/1.1 200'));
    _ok('B 拿到 200', (await b.readHead()).startsWith('HTTP/1.1 200'));
    a.send('AAA');
    b.send('BBB');
    _ok('A 的数据是 A 的', utf8.decode(await a.take(3)) == 'AAA');
    _ok('B 的数据是 B 的', utf8.decode(await b.take(3)) == 'BBB');
    _ok('计了两条', bridge.connections == 2);
    a.socket.destroy();
    b.socket.destroy();
    await bridge.stop();
    await up.stop();
  }

  // ── ⑦ 没有出口时走直连，而不是拒绝服务 ──
  {
    final echo = await _EchoServer.start();
    final bridge = SocksBridge();
    final port = await bridge.start(); // upstream 缺省 null
    final peer = await _connectBridge(port);
    peer.send('CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\n\r\n');
    _ok('直连也回 200', (await peer.readHead()).startsWith('HTTP/1.1 200'));
    peer.send('direct');
    _ok('直连隧道通', utf8.decode(await peer.take(6)) == 'direct');
    _ok('直连确实到了目标', echo.connections == 1);
    peer.socket.destroy();
    await bridge.stop();
    await echo.stop();
  }

  // ── ⑧ 换出口只影响新连接，不掐断在传的 ──
  {
    final a = _FakeSocks();
    await a.start();
    final echo = await _EchoServer.start();
    final bridge = SocksBridge();
    final port = await bridge.start(
      upstream: ProxyConfig(
        scheme: ProxyScheme.socks5,
        host: '127.0.0.1',
        port: a.port,
        user: 'u',
        password: 'p',
      ),
    );

    final old = await _connectBridge(port);
    old.send('CONNECT 1.example:443 HTTP/1.1\r\n\r\n');
    _ok('换之前走上游', (await old.readHead()).startsWith('HTTP/1.1 200'));
    old.send('still');
    _ok('换之前数据通', utf8.decode(await old.take(5)) == 'still');

    // 热切换成直连。
    bridge.setUpstream(null);
    _ok('记了一次切换', bridge.upstreamSwitches == 1);
    bridge.setUpstream(null);
    _ok('同一条出口重复设不算切换', bridge.upstreamSwitches == 1);

    // 老连接还在，数据照样能走 —— 这是「不掐断在传的」的判据。
    old.send('alive');
    _ok('老连接没被掐断', utf8.decode(await old.take(5)) == 'alive');

    // 新连接走直连。
    final fresh = await _connectBridge(port);
    fresh.send('CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\n\r\n');
    _ok('新连接回 200', (await fresh.readHead()).startsWith('HTTP/1.1 200'));
    fresh.send('newgo');
    _ok('新连接走直连', utf8.decode(await fresh.take(5)) == 'newgo');

    old.socket.destroy();
    fresh.socket.destroy();
    await bridge.stop();
    await a.stop();
    await echo.stop();
  }

  // ── ⑨ 连上不发请求 → 超时回 408，不是挂在那里占 fd ──
  {
    final bridge = SocksBridge();
    bridge.headTimeout = const Duration(milliseconds: 400);
    final port = await bridge.start();
    final peer = await _connectBridge(port);
    // 故意什么都不发。
    final head = await peer.readHead();
    _ok('沉默的客户端回 408', head.startsWith('HTTP/1.1 408'));
    _ok('原因说得出是超时', bridge.lastError.contains('秒内没收到'));
    peer.socket.destroy();
    await bridge.stop();
  }

  });
}


/// 一个只会把收到的字节原样送回的 TCP 服务，用来验直连。
///
/// 直连路径没有 SOCKS5 握手，所以不能用 `_FakeSocks` 顶替 —— 需要的是
/// 一个「连上就是隧道」的裸服务端。
class _EchoServer._(this._server) {
  final ServerSocket _server;
  int connections = 0;

  int get port => _server.port;

  static Future<_EchoServer> start() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final self = _EchoServer._(s);
    s.listen((c) {
      self.connections++;
      c.listen(
        (d) {
          try {
            c.add(d);
          } catch (_) {}
        },
        onError: (_) {},
        cancelOnError: true,
      );
    }, onError: (_) {});
    return self;
  }

  Future<void> stop() => _server.close();
}
