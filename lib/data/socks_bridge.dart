/// 本地代理桥。
///
/// ## 为什么必须有这一层
///
/// 两边的协议对不上：
///
///   - **上游**：内置清单的 588 条出口**全是带账号密码的 SOCKS5**。
///   - **客户端**：安卓 WebView 只会说 HTTP 代理（`CONNECT`），
///     而且 `HttpClient.findProxy` 的指令串**不能带凭据** ——
///     它只能写 `PROXY host:port`，没地方塞用户名密码。
///
/// 所以中间要有个人把 HTTP 代理请求翻译成带认证的 SOCKS5，凭据补在
/// 握手阶段。桥监听 `127.0.0.1` 的一个随机端口，WebView 指着它。
///
/// ## 只绑回环地址
///
/// **不能绑 `anyIPv4`**。绑了就成了一个敞开在局域网里的代理，同一个
/// wifi 下任何人都能拿它当跳板，流量记在我们账上。
///
/// ## 为什么放在数据层
///
/// 只依赖 `dart:io`，一行 Flutter 都没有 —— 能在本机单测，不需要真机。
/// 这个项目里凡是「不碰框架」的东西都放这一层，就是为了用测试锁住行为。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_config.dart';

/// 一条隧道：已建好的上游连接 + 它的读取器。
///
/// 读取器是必需的，不是多此一举 —— 握手期间已经从 socket 上读掉了
/// 几个字节（版本、认证结果、应答），而 `Socket` 的流只能被订阅一次。
/// 不把它包起来的话，握手读完就再也拿不到后续数据了 —— 表现是
/// 「代理连上了，但页面永远转圈」。
class const _Tunnel({
  required this.socket,
  required this.reader,
  required this.hop,
}) {
  final Socket socket;
  final _SockReader reader;
  final String hop;
}

/// HTTP → SOCKS5 的本地桥。
///
/// 每次换出口都要重新 `start` —— 上游是启动时固定进去的，不提供运行中
/// 换出口的接口（那会引入「一半连接走旧出口」的状态）。
class SocksBridge() {
  ServerSocket? _server;

  /// 当前出口。`null` = **直连**。
  ///
  /// 可空是有意的，不是「还没配」：用户完全可能一条代理都不配（或者
  /// 清单全试挂了），那时桥必须自己直连出去，而不是拒绝服务。
  /// 这条桥的语义是「按当前出口转发」，不是「一条 SOCKS5 隧道」。
  ProxyConfig? _upstream;

  /// 出口被换过几次。只用于排查。
  int upstreamSwitches = 0;

  ProxyConfig? get upstream => _upstream;

  /// 当前有没有在跑。
  bool get isRunning => _server != null;

  /// 本地端口。
  ///
  /// 没启动时是 0 —— **不要拿 0 当「随便一个端口」**，那会让 WebView
  /// 去连一个不存在的代理，表现为所有请求都失败，而错误只有
  /// `ERR_PROXY_CONNECTION_FAILED`，看不出是桥没起来。
  int get port => _server?.port ?? 0;

  /// 桥转过的连接数。用来确认「WebView 真的走过来了」——
  /// 界面空白时第一个该看的就是它是不是 0。
  int connections = 0;

  /// 最近一次失败原因，给界面显示用。
  String lastError = '';

  /// 启动，返回本地端口。
  ///
  /// [upstream] 为 null 表示直连。
  ///
  /// [port] 默认 0（系统分配）。需要固定端口时传具体端口 ——
  /// 端口一变，客户端那边的代理设置就失效了，所以「能不变就不变」。
  /// 端口被占用会抛，由调用方决定退到哪个端口。
  Future<int> start({ProxyConfig? upstream, int port = 0}) async {
    await stop();
    _upstream = upstream;
    connections = 0;
    upstreamSwitches = 0;
    lastError = '';
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_handle, onError: (_) {});
    return server.port;
  }

  /// 换出口。**只影响之后建立的连接**。
  ///
  /// 不杀在传的隧道 —— 中途掐掉会把正在收的东西截断，而用户看到的
  /// 只是「刷新一下少了几条」。同一条出口（id 相同）重复设不算切换。
  void setUpstream(ProxyConfig? next) {
    if (identical(next, _upstream) || next?.id == _upstream?.id) return;
    _upstream = next;
    upstreamSwitches++;
  }

  /// 停止。多次调用安全。
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _upstream = null;
    try {
      await s?.close();
    } catch (_) {
      // 关不掉就算了。端口随进程回收，不该让调用方因此失败。
    }
  }

  /// 读请求头的上限。
  ///
  /// 二十秒够慢网络发完一行请求头，再久就是对面连上不说话。做成可调
  /// 字段而不是常量，是为了测试能把它调到几百毫秒 —— 不然这条判据
  /// 要跑二十秒，久了就没人跑。
  Duration headTimeout = const Duration(seconds: 20);

  /// 上游 SOCKS5 握手的每一步最多等多久。
  ///
  /// 三条出口实测里最常见的一种「坏出口」不是连不上，而是**连上之后
  /// 不说话**（或是认证过了但 CONNECT 迟迟不回）。`Socket.connect` 的
  /// 超时只覆盖「三次握手完成」那一步，握手字节的读取完全没有期限 ——
  /// 一条这样的出口会把一条连接和两个 fd 永久占住。
  Duration handshakeTimeout = const Duration(seconds: 8);

  /// 处理一条来自 WebView 的连接。
  Future<void> _handle(Socket client) async {
    // Nagle 会把小包攒起来再发，对隧道就是平白加一层延迟。
    client.setOption(SocketOption.tcpNoDelay, true);
    final cr = _SockReader(client);

    String head;
    try {
      head = await cr.takeHead(timeout: headTimeout);
    } catch (e) {
      // 超时/灌垃圾都要**显式收掉这条连接**，不能直接 return ——
      // 那样 reader 的订阅还挂着，客户端之后发什么都进缓冲没人消费，
      // fd 不释放、内存无上限涨。实测过：五个「连上就不发请求」的
      // 客户端，二十秒后 fd 仍是 +10，客户端断开后还进 CLOSE_WAIT。
      lastError = '读请求头失败: $e';
      _fail(client, 408, lastError);
      return;
    }

    final parts = head.split('\r\n').first.split(' ');
    if (parts.length < 3) {
      lastError = '请求行不完整（不是 CONNECT，也不是绝对地址的 GET/POST）';
      _fail(client, 400, lastError);
      return;
    }
    final method = parts[0].toUpperCase();
    final target = parts[1];

    // CONNECT 给的是 `host:port`；绝对地址给的是完整 URL。
    final hp = method == 'CONNECT' ? _splitHostPort(target) : _splitUrl(target);
    if (hp == null) {
      lastError = '听不懂的目标地址: $target';
      _fail(client, 400, lastError);
      return;
    }
    final (host, port) = hp;

    _Tunnel tunnel;
    try {
      final up = _upstream;
      tunnel = up == null
          ? await _connectDirect(host, port)
          // 按协议分派。**不能一律当 SOCKS5** —— 用户手填 `http://` 的
          // 出口很常见（本机 mihomo 之类），对它发 `\x05\x01\x02` 会得到
          // 「上游不是 SOCKS5（版本号 72）」，而 72 是字母 'H'。
          : up.scheme.needsBridge
          ? await _connectViaSocks(up, host, port, handshakeTimeout)
          : await _connectViaHttp(up, host, port, handshakeTimeout, method);
    } catch (e) {
      lastError = '$e';
      _fail(client, 502, '$e');
      return;
    }
    connections++;

    if (method == 'CONNECT') {
      // 隧道通了才回 200 —— 先回 200 再连上游的话，连不上时客户端
      // 已经以为通了，会一直等数据，界面上就是「永远转圈」。
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await client.flush();
    } else {
      // 把请求行改写成 origin 形式。原样转发会 400 —— 源站不认
      // `GET http://host/path HTTP/1.1` 这种绝对形式。
      final rest = head.substring(head.indexOf('\r\n'));
      tunnel.socket.write('$method ${_originForm(target)} HTTP/1.1$rest');
      await tunnel.socket.flush();
    }

    _pump(cr, tunnel);
  }
}

/// 交接之后双向搬字节。
///
/// ### 为什么不用 `pipe`
///
/// `Socket.pipe` 会**顺手把源关掉**，而这条链上两个方向要各自独立地
/// 决定什么时候收摊。用它的话，客户端一读完请求就把上游也关了。
///
/// ### 背压
///
/// 这里**没有做背压** —— 目的地写得慢时数据会堆在内存里。对文本页面
/// （这个应用只会用它看短信）够用；如果哪天要下大文件，得换成会暂停
/// 源订阅的写法。写在这里是为了别让它变成「没人知道的隐患」。
void _pump(_SockReader client, _Tunnel up) {
  // 先补发交接前已经读进缓冲、还没转出去的字节。少了这一步，
  // 数据会在隧道刚通的那一刻丢一小截 —— 表现为页面加载到一半停住。
  final cLeft = client.drain();
  if (cLeft.isNotEmpty) _safeAdd(up.socket, cLeft);
  final uLeft = up.reader.drain();
  if (uLeft.isNotEmpty) _safeAdd(client.socket, uLeft);

  // 移交：之后两边收到的数据直接对写。
  client.attach(up.socket);
  up.reader.attach(client.socket);

  // 任一侧关闭就关掉另一侧。不这么做的话，对端已经走了而这边的
  // 订阅还活着，连接和内存都不释放。
  //
  // 收 `Future<Object?>` 而不是 `Future<Socket>`：`Socket.done` 的静态
  // 类型是 `Future`（它是从 `IOSink` 继承来的），写成 `Future<Socket>`
  // 编译器直接拒收 —— 这条是查了 SDK 源码才确定的，别凭印象改回去。
  void closeOther(Future<Object?> done, Socket other) {
    unawaited(
      done.then<void>((_) => _shut(other), onError: (_, _) => _shut(other)),
    );
  }

  closeOther(up.socket.done, client.socket);
  closeOther(client.socket.done, up.socket);
}

/// 带「可移交」的 socket 读取器。
///
/// socket 的流只能订阅一次，而握手期间必须先同步读几个字节。这个类
/// 把订阅收在自己手里：交接前收到的数据进缓冲、由 [take] 取；调用
/// [attach] 之后，收到的数据直接写给对端，不再经过缓冲。
class _SockReader(this.socket) {
  /// 主构造器在头上声明的参数**不会自动成为字段**（与直觉相反，
  /// 但编译器这么定的）—— 字段仍要在体内声明，两处靠名字对上。
  /// 少了这一行，体内所有 `socket.xxx` 都解析不到。
  final Socket socket;

  /// 订阅。**不能放构造函数里** —— 用主构造器写法之后构造函数没有体，
  /// 而且字段存了订阅会被判「赋了从不读」。改成第一次用时再挂。
  bool _hooked = false;
  void _hook() {
    if (_hooked) return;
    _hooked = true;
    socket.listen(
      _onData,
      onDone: _onDone,
      onError: (_) => _onDone(),
      cancelOnError: true,
    );
  }

  final _buf = <int>[];
  Socket? _forwardTo;
  bool _closed = false;
  Completer<void>? _pending;

  void _onData(List<int> d) {
    final to = _forwardTo;
    if (to != null) {
      _safeAdd(to, d);
      return;
    }
    _buf.addAll(d);
    _wake();
  }

  void _onDone() {
    _closed = true;
    _wake();
  }

  void _wake() {
    final c = _pending;
    _pending = null;
    c?.complete();
  }

  /// 移交：之后收到的数据直接写给 [to]。
  ///
  /// **顺手挂钩**。直连路径下没有任何 `take()` 调用，不在这儿挂的话
  /// 订阅永远不建立 —— 表现为「隧道通了，但一个字节都不往回走」。
  void attach(Socket to) {
    _hook();
    _forwardTo = to;
  }

  /// 取走缓冲里现有的全部字节，清空缓冲。
  List<int> drain() {
    final out = List<int>.from(_buf);
    _buf.clear();
    return out;
  }

  /// 精确取 [n] 个字节，不够就等。
  ///
  /// [timeout] 是**必须给**的（除了测试里的假上游）：上游连上却不说话时
  /// 这个 await 会永久挂着。`Socket.connect` 的超时只管到「连上」为止，
  /// 握手这几步读字节全是无期限等 —— 表现是桥不动、fd 不释放，
  /// 而界面只看到「一直转圈」。
  Future<List<int>> take(int n, {Duration? timeout}) async {
    _hook();
    while (_buf.length < n && !_closed) {
      final wait = _sleep();
      if (timeout == null) {
        await wait;
      } else {
        try {
          await wait.timeout(timeout);
        } on TimeoutException {
          // 把 `TimeoutException after 0:00:08.000000: Future not completed`
          // 换成人话 —— 那句话会原样出现在界面的失败面板上。
          throw StateError(
            '${timeout.inMilliseconds < 1000 ? '${timeout.inMilliseconds} 毫秒' : '${timeout.inSeconds} 秒'}'
            '内没收到对端应答',
          );
        }
      }
    }
    if (_buf.length < n) {
      throw StateError('连接在收够 $n 字节之前就断了');
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  /// 读到空行为止（HTTP 请求头）。
  Future<String> takeHead({Duration? timeout}) {
    final inner = _takeHeadInner();
    if (timeout == null) return inner;
    return inner.timeout(
      timeout,
      // 子秒超时要单独说，否则会印出「0 秒内没收到」这种看不懂的话。
      onTimeout: () => throw StateError(
        '${timeout.inMilliseconds < 1000 ? '${timeout.inMilliseconds} 毫秒' : '${timeout.inSeconds} 秒'}'
        '内没收到完整请求头',
      ),
    );
  }

  Future<String> _takeHeadInner() async {
    _hook();
    const cap = 64 * 1024;
    while (true) {
      final end = _headEnd(_buf);
      if (end >= 0) {
        // 头部按 UTF-8 解，坏字节不抛 —— 请求行和头字段都是 ASCII，
        // 但客户端可能塞别的东西，不值得为此整条连接失败。
        final head = utf8.decode(_buf.sublist(0, end), allowMalformed: true);
        _buf.removeRange(0, end + 4);
        return head;
      }
      if (_closed) throw StateError('请求头没读完连接就断了');
      if (_buf.length > cap) throw StateError('请求头超过 ${cap ~/ 1024}KB，拒绝');
      await _sleep();
    }
  }

  Future<void> _sleep() {
    final c = Completer<void>();
    _pending = c;
    return c.future;
  }
}

/// 按**当前**出口连到 [host]:[port]。
///
/// 每次连接都现读一次 `_upstream`，不是启动时抓的快照 —— 换出口是
/// 热切换，抓快照就等于永远停在第一条出口上。
Future<_Tunnel> _connectDirect(String host, int port) async {
  // 直连也要超时：DNS 卡住或对端黑洞时，不设超时就是永久占一条客户端
  // 连接 + 一个 fd。
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 12),
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  return _Tunnel(socket: socket, reader: _SockReader(socket), hop: host);
}

/// 连上上游，并让它替我们连到 [host]:[port]。
///
/// RFC 1928 的四步，一步都不能省：
///
///   ① 问候：报出我们支持的认证方式
///   ② 认证：上游挑了用户名密码就走这一步
///   ③ 请求：让它 CONNECT 到目标
///   ④ 应答：读掉它回的绑定地址（**必须读干净**，否则那几个字节会被
///      当成隧道里的数据吐给客户端，网页第一个字符就乱了）
Future<_Tunnel> _connectViaSocks(
  ProxyConfig p,
  String host,
  int port,
  Duration step,
) async {
  final socket = await Socket.connect(
    p.host,
    p.port,
    timeout: const Duration(seconds: 12),
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  final reader = _SockReader(socket);
  try {
    // ── ① 问候 ──
    socket.add(<int>[0x05, 0x01, p.hasAuth ? 0x02 : 0x00]);
    await socket.flush();
    final greet = await reader.take(2, timeout: step);
    if (greet[0] != 0x05) {
      throw StateError('上游不是 SOCKS5（版本号 ${greet[0]}）');
    }
    if (greet[1] == 0xFF) {
      throw StateError('上游不接受我们支持的认证方式');
    }

    // ── ② 认证 ──
    // 上游选 0x02 就得给凭据。**上游越过它自己选 0x00 也是合法的**
    // （RFC 允许它挑「无认证」），那种情况下不发凭据——发了会被当成
    // 下一条命令的开头，整个会话就错位了。
    if (greet[1] == 0x02) {
      final u = utf8.encode(p.user);
      final pw = utf8.encode(p.password);
      if (u.isEmpty) throw StateError('上游要求认证，但这条出口没有用户名');
      if (u.length > 255 || pw.length > 255) throw StateError('代理凭据过长');
      socket.add(<int>[0x01, u.length, ...u, pw.length, ...pw]);
      await socket.flush();
      final ok = await reader.take(2, timeout: step);
      if (ok[1] != 0x00) throw StateError('上游拒绝认证（用户名或密码不对）');
    }

    // ── ③ CONNECT ──
    // ATYP 一律用域名（0x03）：让上游去解析。用 IPv4 的话，万一目标是
    // 个只在 CDN 那边能解析的名字，本地解析出来的地址可能连不上。
    final hb = utf8.encode(host);
    if (hb.isEmpty || hb.length > 255) throw StateError('目标主机名长度不合法');
    socket.add(<int>[
      0x05,
      0x01,
      0x00,
      0x03,
      hb.length,
      ...hb,
      port >> 8,
      port & 0xFF,
    ]);
    await socket.flush();

    // ── ④ 应答 ──
    final rep = await reader.take(4, timeout: step);
    if (rep[1] != 0x00) throw StateError(_socksError(rep[1]));
    var skip = 0;
    if (rep[3] == 0x01) {
      skip = 4; // IPv4
    } else if (rep[3] == 0x04) {
      skip = 16; // IPv6
    } else if (rep[3] == 0x03) {
      skip = (await reader.take(1, timeout: step))[0]; // 域名，长度在前一字节
    } else {
      throw StateError('上游回了看不懂的地址类型 ${rep[3]}');
    }
    await reader.take(skip + 2, timeout: step); // 地址本体 + 端口

    return _Tunnel(socket: socket, reader: reader, hop: '$host:$port');
  } catch (e) {
    _shut(socket);
    rethrow;
  }
}

/// 连上 HTTP 代理，让它替我们连到 [host]:[port]。
///
/// ## 和 SOCKS5 的区别
///
/// SOCKS5 是「先握手，再隧道」——`CONNECT` 成功之后双方就只传裸字节。
/// HTTP 代理没有握手阶段：**`CONNECT` 请求本身就是握手**，代理回
/// `200 Connection Established` 之后才开始隧道。
///
/// ## 凭据放在哪
///
/// HTTP 代理的认证是**请求头**（`Proxy-Authorization: Basic ...`），
/// 不是握手字节 —— 这正是桥存在的理由之一：`findProxy` 的指令串里
/// 塞不进这个头，只能在这里补。
///
/// ## 只在 CONNECT 上加认证
///
/// 绝对地址的 `GET`（也就是「非 CONNECT」分支）已经带上了客户端自己
/// 的 `Proxy-Authorization`（如果客户端会发的话），这里再补一个会变成
/// 两个头。所以只在 CONNECT 这条路径上补，绝对地址路径原样转发。
Future<_Tunnel> _connectViaHttp(
  ProxyConfig p,
  String host,
  int port,
  Duration step,
  String method,
) async {
  final socket = await Socket.connect(
    p.host,
    p.port,
    timeout: const Duration(seconds: 12),
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  final reader = _SockReader(socket);
  try {
    // 认证头：`Basic base64(user:pass)`。RFC 7617。
    final auth = p.hasAuth
        ? 'Proxy-Authorization: Basic '
              '${base64.encode(utf8.encode('${p.user}:${p.password}'))}\r\n'
        : '';
    socket.write(
      'CONNECT $host:$port HTTP/1.1\r\n'
      'Host: $host:$port\r\n'
      '$auth'
      // 有些代理（Squid 老版本）不认没有 UA 的 CONNECT。
      'User-Agent: fus-inbox\r\n\r\n',
    );
    await socket.flush();

    final head = await reader.takeHead(timeout: step);
    final status = _statusOf(head);
    if (status == 407) {
      throw StateError('上游要求代理认证（407），这条出口的账号密码不对或没填');
    }
    if (status != 200) {
      throw StateError('上游拒绝 CONNECT（HTTP $status）');
    }
    return _Tunnel(socket: socket, reader: reader, hop: '$host:$port');
  } catch (e) {
    _shut(socket);
    rethrow;
  }
}

/// 从响应头里取状态码。取不到返回 0。
int _statusOf(String head) {
  final line = head.split('\r\n').first;
  final parts = line.split(' ');
  if (parts.length < 2) return 0;
  return int.tryParse(parts[1]) ?? 0;
}

/// SOCKS5 应答码 → 人话。
///
/// 主要是给自己看：界面空白时，「主机不可达」和「连接被拒」要做的
/// 事完全不同——前者换出口，后者目标本身不通。
String _socksError(int rep) => switch (rep) {
  0x01 => '上游：通用失败',
  0x02 => '上游：规则不允许连接',
  0x03 => '上游：网络不可达',
  0x04 => '上游：主机不可达',
  0x05 => '上游：连接被拒',
  0x06 => '上游：TTL 超时',
  0x07 => '上游：不支持的命令',
  0x08 => '上游：不支持的地址类型',
  _ => '上游：未知错误 0x${rep.toRadixString(16)}',
};

/// `host:443` 或 `[::1]:443`。切不了返回 null。
(String, int)? _splitHostPort(String s) {
  final i = s.lastIndexOf(':');
  if (i <= 0) return null;
  // IPv6 字面量在 CONNECT 里带方括号，上游的域名模式装不下，
  // 去掉括号让它当主机名走（多数上游会拒绝，但至少格式是对的）。
  final host = s.substring(0, i).replaceAll('[', '').replaceAll(']', '');
  final port = int.tryParse(s.substring(i + 1));
  if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
  return (host, port);
}

/// `http://host:port/path` → 主机和端口。
(String, int)? _splitUrl(String s) {
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return null;
  final port = u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);
  return (u.host, port);
}

/// `http://host/path?q` → `/path?q`。
///
/// 源站不认绝对形式的请求行，转发前必须改写成这样。
String _originForm(String s) {
  final u = Uri.tryParse(s);
  if (u == null) return '/';
  final path = u.path.isEmpty ? '/' : u.path;
  return u.hasQuery ? '$path?${u.query}' : path;
}

/// 找 `\r\n\r\n` 的起点，没有返回 -1。
int _headEnd(List<int> b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// 写数据，写不进去不抛。
///
/// 对端已经关了是**常态**（浏览器拿到页面就断），不该冒泡成未捕获异常
/// 把整个桥带下去。
void _safeAdd(Socket s, List<int> data) {
  try {
    s.add(data);
  } catch (_) {
    // 忽略。
  }
}

/// 关 socket，失败不抛。
void _shut(Socket s) {
  try {
    s.destroy();
  } catch (_) {
    // 忽略。
  }
}

/// 回一个 HTTP 错误再挂断。
///
/// 比直接断开好：WebView 会把状态码显示出来，比
/// `ERR_EMPTY_RESPONSE` 有用得多。
void _fail(Socket client, int code, String reason) {
  try {
    client.write(
      'HTTP/1.1 $code $reason\r\n'
      'Content-Length: 0\r\n'
      'Connection: close\r\n\r\n',
    );
  } catch (_) {
    // 忽略。
  }
  _hangUp(client);
}

/// 礼貌地断开。
void _hangUp(Socket client) {
  try {
    client.flush().then((_) => _shut(client)).catchError((_) => _shut(client));
  } catch (_) {
    _shut(client);
  }
}
