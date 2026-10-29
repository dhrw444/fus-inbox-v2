/// 一个代理出口。
///
/// ## 为什么是值对象
///
/// 旧代码把它做成可变的 class，于是「改了一个字段忘了同步另一个」成了
/// 常见 bug —— 比如把 host 改了、port 还是旧的。这里全部 final，
/// 改动一律走 [copyWith]，编译器保证不漏字段。
///
/// 账号密码也在这里：本仓内置的代理**全部带账号密码**，而
/// `HttpClient.findProxy` 的指令串**不能带凭据**，所以认证必须由
/// 本地桥在 CONNECT 阶段补上（见 `proxy_egress`）。
library;

/// 代理协议。
///
/// 只有这三种：站点只放行能被当普通 HTTP 代理用的出口。
enum ProxyScheme(this.wire) {
  socks5('socks5'),
  http('http'),
  https('https');

  /// 拼 URL 时用的名字。
  ///
  /// 主构造器语法：参数写在 `enum` 名后面就是字段，**不在体内再写
  /// `const ProxyScheme(this.wire);`** —— 那样是重复声明，编译器报
  /// 「already declared」。
  final String wire;

  /// SOCKS5 要走本地桥（`findProxy` 只支持 HTTP 代理）。
  bool get needsBridge => this == ProxyScheme.socks5;
}

/// 一个出口的完整描述。
class const ProxyConfig({
  required this.scheme,
  required this.host,
  required this.port,
  this.user = '',
  this.password = '',
  this.label = '',
}) {
  final ProxyScheme scheme;
  final String host;
  final int port;

  /// 认证用。空串表示这条出口不要认证。
  final String user;
  final String password;

  /// 界面上显示的名字。空的话用 `host:port`。
  final String label;

  /// 稳定标识。绑身份、存盘、去重都用它。
  ///
  /// **不含密码** —— 它会被写进账本、日志、界面，别把凭据漏出去。
  String get id => '${scheme.wire}://$host:$port';

  /// 界面显示名。
  String get displayName => label.isNotEmpty ? label : '$host:$port';

  bool get hasAuth => user.isNotEmpty;

  /// 值相等。用于去重和「有没有变」的判断。
  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.scheme == scheme &&
      other.host == host &&
      other.port == port &&
      other.user == user &&
      other.password == password;

  @override
  int get hashCode => Object.hash(scheme, host, port, user, password);

  @override
  String toString() => displayName;
}

/// 从一行文本解析一个出口。
///
/// 支持的形式：
///
/// ```
/// socks5://1.2.3.4:1080
/// http://user:pass@1.2.3.4:8080
/// 1.2.3.4:1080                    ← 缺协议时默认 socks5
/// user:pass@1.2.3.4:1080
/// ```
///
/// 解析不出来返回 null —— **不抛**。调用方通常在一批上百行里跑，
/// 一行写错不该让整批失败。
ProxyConfig? parseProxyLine(String line) {
  final raw = line.trim();
  if (raw.isEmpty || raw.startsWith('#')) return null;

  // 先把协议拆出来。`scheme://rest` 或者没有协议。
  var scheme = ProxyScheme.socks5; // 缺省：本仓清单以 socks5 为主
  var rest = raw;
  final sep = raw.indexOf('://');
  if (sep > 0) {
    final name = raw.substring(0, sep).toLowerCase();
    rest = raw.substring(sep + 3);
    // switch **表达式**里不能写 `return` —— 那是语句。要判「认不出来
    // 就退出」只能先用可空变量接住、再在外面判。
    final matched = switch (name) {
      'socks5' || 'socks' => ProxyScheme.socks5,
      'http' => ProxyScheme.http,
      'https' => ProxyScheme.https,
      _ => null,
    };
    if (matched == null) return null;
    scheme = matched;
  }

  // 再拆凭据。注意 `@` 在密码里也可能出现，所以取**最后一个** ——
  // 取第一个的话 `p@ss@host:port` 会把 host 切成 `ss@host:port`。
  var user = '';
  var pass = '';
  final at = rest.lastIndexOf('@');
  if (at > 0) {
    final cred = rest.substring(0, at);
    rest = rest.substring(at + 1);
    final colon = cred.indexOf(':');
    if (colon < 0) {
      user = cred;
    } else {
      user = cred.substring(0, colon);
      pass = cred.substring(colon + 1);
    }
  }

  // 最后拆 host:port。从**最后**一个冒号切：IPv6 字面量里有冒号。
  final colon = rest.lastIndexOf(':');
  if (colon <= 0) return null;
  final host = rest.substring(0, colon);
  final port = int.tryParse(rest.substring(colon + 1));
  if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;

  return ProxyConfig(
    scheme: scheme,
    host: host,
    port: port,
    user: user,
    password: pass,
  );
}

/// 解析一整份清单，逐行。
///
/// 去重按 [ProxyConfig.id]（不含密码）—— 同一条出口在清单里出现两次
/// 不该被当成两条，否则额度会按两条算。
List<ProxyConfig> parseProxyList(String text) {
  final seen = <String>{};
  final out = <ProxyConfig>[];
  for (final line in text.split('\n')) {
    final c = parseProxyLine(line);
    if (c == null) continue;
    if (!seen.add(c.id)) continue;
    out.add(c);
  }
  return out;
}
