/// 号码目录里的一条。
///
/// ## 为什么把「显示」和「数据」分开
///
/// 站点给的是一串数字（`18607507091`），而界面上要显示成
/// `(860) 750-7091`。旧代码把格式化散在好几个地方，于是同一条号码在
/// 列表里和标题栏上显示的格式不一样。
///
/// 这里只有一个入口：[formatted]。
library;

/// 目录里的一条号码。
class const NumberEntry({
  required this.digits,

  /// 站点给的城市/州（可能为空）。
  this.region = '',

  /// 这条号码多久前有过短信（站点给的相对时间，可能为空）。
  this.lastSeen = '',
}) {
  /// 纯数字的号码（不含 `+`、空格、连字符）。
  ///
  /// 存这个而不是显示串：它是**标识**，用来拼 URL、去重、绑身份。
  /// 显示串可以随时重算，标识不能。
  final String digits;

  /// 归属地。
  final String region;

  /// 最近一次收到短信的相对时间（站点原文）。
  final String lastSeen;

  /// 显示用的格式。
  ///
  /// 美国号码固定 11 位（`1` + 10 位）。**不是 11 位就原样返回** ——
  /// 猜格式比不格式化更糟：`(860) 750-7091` 这种分组只对 10 位有效，
  /// 硬套会把别的长度的号码切得看不出原样。
  String get formatted {
    if (digits.length != 11) return digits;
    final area = digits.substring(1, 4);
    final mid = digits.substring(4, 7);
    final last = digits.substring(7);
    return '($area) $mid-$last';
  }

  /// 收件页的地址。
  String get inboxUrl => 'https://freeussms.com/numbers/$digits/';

  @override
  bool operator ==(Object other) =>
      other is NumberEntry && other.digits == digits;

  @override
  int get hashCode => digits.hashCode;

  @override
  String toString() => formatted;
}

/// 从目录页的 HTML 里提取号码。
///
/// 站点的目录是**服务端渲染的 HTML**，一条号码对应一个
/// `<a href="/numbers/<数字>/">`。所以标题里那段数字就是唯一的锚点。
///
/// ## 为什么不解析 DOM
///
/// 用正则找 `href` 看着粗糙，但它对「站点改版把某个 div 的类名换了」
/// 免疫 —— 而 `document.querySelector('.number-card__title')` 那种写法
/// 一改版就全空。类名是站点的实现细节，URL 形状才是它的契约。
///
/// 去重按数字：同一号码在页面里出现两次（列表 + 侧栏「最近查看」）
/// 只该算一条。
List<NumberEntry> parseNumberList(String html) {
  // `href="/numbers/18607507091/"` —— 引号可能是单/双，可能带绝对域名。
  final pattern = RegExp(
    r'''href=["'](?:https?://[^"']*?)?/numbers/(\d{6,15})/?["']''',
    caseSensitive: false,
  );
  final seen = <String>{};
  final out = <NumberEntry>[];
  for (final m in pattern.allMatches(html)) {
    final digits = m.group(1)!;
    if (!seen.add(digits)) continue;
    out.add(NumberEntry(digits: digits));
  }
  return out;
}
