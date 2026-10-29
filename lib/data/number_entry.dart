/// 号码目录里的一条。
///
/// ## 字段来自站点真实的 DOM，不是我猜的
///
/// 站点 `/numbers/` 的每一条长这样（实测抓下来的原文）：
///
/// ```html
/// <article class="number-card is-fresh has-messages" data-live-card="c3ce…">
///   <span class="number-area">Virginia · 757</span>
///   <a href="https://freeussms.com/numbers/17573596469/">…</a>
///   <span class="fresh-text">Last text
///     <time data-rel-time="2026-10-29T21:00:21">41 sec ago</time></span>
///   <div class="number-card-meta" data-count="23" data-empty="false">
/// ```
///
/// 注意那个 `<time>`：它同时给了**绝对时间**（`data-rel-time`）和相对
/// 文字（`41 sec ago`）。**只能取绝对的那个** —— 相对文字是抓取那一刻
/// 的快照，列表在手上放五分钟它就成了假话，而我们没法重算它。
library;

/// 目录里的一条号码。
class const NumberEntry({
  required this.digits,

  /// 归属州，例如 `Virginia`。站点没给就是空串。
  this.state = '',

  /// 区号，例如 `757`。站点没给就是空串。
  this.areaCode = '',

  /// 最近一次收到短信的**绝对**时间。
  ///
  /// 站点给的是不带时区的 ISO（`2026-10-29T21:00:21`），实测与 UTC
  /// 一致 —— 抓取时页面写「41 sec ago」，而那一刻的 UTC 正是这个值。
  /// 解析失败时为 null（**不是** `DateTime.now()`：编一个当前时间出来，
  /// 界面上会显示成「刚刚」，而实际可能已经过去很久）。
  this.lastTextAt,

  /// 已有的短信条数。站点没给就是 0。
  this.messageCount = 0,
}) {
  /// 纯数字的号码。
  ///
  /// 存这个而不是显示串：它是**标识**，用来拼 URL、去重、绑身份。
  /// 显示串随时可以重算，标识不能。
  final String digits;

  final String state;
  final String areaCode;
  final DateTime? lastTextAt;
  final int messageCount;

  /// 这个号码现在有没有短信。
  ///
  /// 用来把「空号」排到后面 —— 用户点进去看到「暂无短信」是白跑一趟。
  bool get hasMessages => messageCount > 0;

  /// 显示用的号码。
  ///
  /// **只有 11 位才分组**。`(860) 750-7091` 那种切法只对 10 位有效，
  /// 硬套别的长度会把它切得看不出原样 —— 猜格式比不格式化更糟。
  String get formatted {
    if (digits.length != 11) return digits;
    return '(${digits.substring(1, 4)}) '
        '${digits.substring(4, 7)}-${digits.substring(7)}';
  }

  /// 归属地一行文字。两个字段都可能缺，缺就少显示一段。
  String get regionLabel {
    if (state.isEmpty && areaCode.isEmpty) return '';
    if (state.isEmpty) return areaCode;
    if (areaCode.isEmpty) return state;
    return '$state · $areaCode';
  }

  /// 收件页地址。
  String get inboxUrl => 'https://freeussms.com/numbers/$digits/';

  /// 描述这个号码「新不新」。
  ///
  /// 用绝对时间算，不用站点那句相对文字 —— 那条一分钟前抓的
  /// `1 min ago` 现在可能是 `8 min ago`，而重算需要用绝对时间。
  String describeAge(DateTime now) {
    final t = lastTextAt;
    if (t == null) return hasMessages ? '$messageCount 条' : '暂无短信';
    final d = now.difference(t);
    final rel = d.isNegative
        ? '刚刚'
        : d.inMinutes < 1
        ? '${d.inSeconds} 秒前'
        : d.inHours < 1
        ? '${d.inMinutes} 分钟前'
        : d.inDays < 1
        ? '${d.inHours} 小时前'
        : '${d.inDays} 天前';
    return hasMessages ? '$rel · $messageCount 条' : rel;
  }

  NumberEntry copyWith({int? messageCount}) => NumberEntry(
    digits: digits,
    state: state,
    areaCode: areaCode,
    lastTextAt: lastTextAt,
    messageCount: messageCount ?? this.messageCount,
  );

  /// 相等只看号码 —— 它是标识。
  ///
  /// 目录刷新时同一条号码的时间/条数会变，但那是**同一条**，用在
  /// `Set`/`where` 里应该算命中，否则每次刷新界面整列都会重建。
  @override
  bool operator ==(Object other) =>
      other is NumberEntry && other.digits == digits;

  @override
  int get hashCode => digits.hashCode;

  @override
  String toString() => formatted;
}

/// 从目录页 HTML 里提取号码。
///
/// ## 两条路，优先走结构化那条
///
/// 站点在同一页里给了两份信息：
///
///   1. 正文的 `<article class="number-card">` —— 有归属州、绝对时间、
///      条数。**首选**。
///   2. `<head>` 里的 JSON-LD `ItemList` —— 只有号码和地址。
///
/// 所以先按 `<article>` 切块；一块都没切到时，退回「按 href 找号码」。
/// 退回那条路拿不到归属地和条数，但**至少列表不是空的** —— 站点改版
/// 时用户看到的是「信息少了」，而不是「什么都没有」。
List<NumberEntry> parseNumberList(String html) {
  final cards = _parseCards(html);
  if (cards.isNotEmpty) return cards;
  return _parseBareLinks(html);
}

/// 按 `<article>` 切块解析（首选路径）。
List<NumberEntry> _parseCards(String html) {
  final blocks = RegExp(
    r'<article[^>]*>(.*?)</article>',
    dotAll: true,
    caseSensitive: false,
  ).allMatches(html);

  // 一个号码在页面上可能出现多次（列表里一次、侧栏「最近查看」再一次），
  // 按数字去重 —— 不去重的话用户会看到重复行。
  final seen = <String>{};
  final out = <NumberEntry>[];
  for (final b in blocks) {
    final block = b.group(1)!;
    final digits = _firstGroup(
      RegExp(r'/numbers/(\d{6,15})/').firstMatch(block),
    );
    if (digits == null || !seen.add(digits)) continue;

    // `Virginia · 757` —— 州名和区号用中点分隔。缺一半是正常的
    // （站点对某些号码只给区号），所以两边都允许空。
    final area = _firstGroup(
      RegExp(r'class="number-area"[^>]*>([^<]*)<').firstMatch(block),
    );
    final parts = (area ?? '').split('·');
    final state = parts.isNotEmpty ? parts[0].trim() : '';
    final code = parts.length > 1 ? parts[1].trim() : '';

    out.add(
      NumberEntry(
        digits: digits,
        state: state,
        areaCode: code,
        lastTextAt: _parseRelTime(block),
        // `data-count="23"`。解析不出来按 0 —— 0 会被
        // `hasMessages` 当成「空号」，把没有条数的号码排到后面，
        // 这是可接受的降级：宁可排后面，也不假装它有很多条。
        messageCount:
            int.tryParse(
              _firstGroup(RegExp(r'data-count="(\d+)"').firstMatch(block)) ??
                  '',
            ) ??
            0,
      ),
    );
  }
  return out;
}

/// 退回路径：只认地址里的号码。
///
/// 结构信息全丢，但列表还在。用在 `<article>` 结构被站点改掉时。
List<NumberEntry> _parseBareLinks(String html) {
  // 引号可能是单/双，可能带绝对域名。
  final pattern = RegExp(
    r'''href=["'](?:https?://[^"']*?)?/numbers/(\d{6,15})/?["']''',
    caseSensitive: false,
  );
  final seen = <String>{};
  final out = <NumberEntry>[];
  for (final m in pattern.allMatches(html)) {
    final digits = m.group(1)!;
    if (seen.add(digits)) out.add(NumberEntry(digits: digits));
  }
  return out;
}

/// 取第一个捕获组，没有匹配返回 null。
String? _firstGroup(RegExpMatch? m) => m?.group(1);

/// 从 `data-rel-time="2026-10-29T21:00:21"` 取绝对时间。
///
/// **只认这个属性**，不认它包着的 `41 sec ago` —— 相对文字一离开抓取
/// 那一刻就是错的，而且没法反推。解析失败返回 null，不编时间。
DateTime? _parseRelTime(String block) {
  final raw = _firstGroup(RegExp(r'data-rel-time="([^"]+)"').firstMatch(block));
  if (raw == null) return null;
  // 站点给的是不带时区的 ISO。补上 `Z` 再解析 —— 否则 Dart 会按
  // **设备本地时区**解释，在中国的手机上会差 8 小时，界面显示
  // 「8 小时前」而实际是「刚刚」。
  return DateTime.tryParse('${raw}Z')?.toUtc();
}

/// 一页目录：号码 + 站点自报的总数。
///
/// ## 为什么要带 `total`
///
/// 站点自己在页面上写「114 available numbers」。有它就**能精确算出有几页**
/// （`ceil(114 / 24) = 5`），不用一页页试到 404 为止。
///
/// 实测对过：第 1/2/5 页都自报 114，第 5 页正好 18 条（114 = 24×4 + 18），
/// 第 6 页 HTTP 404。所以这个数可信，这个算法成立。
///
/// `null` 表示页面上找不到这个数 —— 那时只能靠「不足一页就当到底了」。
class const NumberPage({required this.entries, this.total}) {
  /// 本页的号码，已按号码去重。
  final List<NumberEntry> entries;

  /// 站点自报的目录总条数。找不到时为 null。
  final int? total;

  /// 按 [pageSize] 推算一共几页。
  ///
  /// 自报总数缺失时返回 null —— **不猜**。猜错了要么少抓（用户以为
  /// 只有 5 个号），要么多抓（打一堆 404 给站点）。
  int? pageCount(int pageSize) {
    final t = total;
    if (t == null || t <= 0 || pageSize <= 0) return null;
    return (t / pageSize).ceil();
  }
}

/// 站点目录每页的条数。实测：1、2 页各 24 条。
const kNumberPageSize = 24;

/// 从一页 HTML 解析出 [NumberPage]。
///
/// 比 [parseNumberList] 多一件事：把站点自报的总数也抠出来。
/// 目录抓取用这个；只关心号码列表的地方用那个就够了。
NumberPage parseNumberPage(String html) {
  final entries = parseNumberList(html);
  final m = RegExp(r'(\d+)\s+available numbers').firstMatch(html);
  final total = m == null ? null : int.tryParse(m.group(1)!);
  return NumberPage(entries: entries, total: total);
}
