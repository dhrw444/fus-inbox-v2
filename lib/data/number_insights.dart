/// 号码的活动快照 —— 含**收录时间**。
///
/// ## 数据在哪
///
/// 号码详情页 `/numbers/<11 位>/` 的 HTML 里有一块 JSON island：
///
/// ```html
/// <script id="fus-number-insights" type="application/json">{...}</script>
/// ```
///
/// 站点自己的 `number-insights.js` 就是读它 —— `load()` 里用正则抠
/// `id=["']fus-number-insights["']` + `type=["']application/json["']`
/// 的那个 `<script>`，然后 `validate()` 校验、`render()` 显示。**不是**
/// 另开一个 API。
///
/// 目录页 `/numbers/` **没有**这份数据。那边的 `number-insights` 只是
/// `<template data-live-view-template>` 里的空壳（`data-insights-phone=""`、
/// 每个 `<dd>` 都是 `—`），要收录时间必须进号码页。
///
/// ## 真实样本（`/tmp/inbox.html` 实测抓取，2026-10-30）
///
/// ```json
/// {"version":1,"number":"+14044225634",
///  "generated_at":"2026-10-30T11:48:03+00:00",
///  "expires_at":"2026-10-30T12:03:03+00:00",
///  "retained_count":32,"arrivals_24h":32,"arrivals_7d":32,
///  "active_days_7utc":2,
///  "first_retained_at":"2026-10-29T13:33:16+00:00",
///  "last_retained_at":"2026-10-30T11:47:39+00:00",
///  "directory_first_seen_at":"2026-10-29T13:23:06+00:00",
///  "daily":[{"date":"2026-10-24","count":0},…]}
/// ```
///
/// `directory_first_seen_at` 比 `first_retained_at` 早 10 分钟 —— 号码先进
/// 目录，之后才收到第一条短信。这就证明它是**收录时间**，不是短信时间。
///
/// ## 为什么要校验
///
/// 这份 JSON 是从网页里抠出来的。网页可以出错、站点可以改版、中间人可以
/// 改内容。一个没校验的值直接显示成「收录于 2026-13-45」比不显示更糟。
/// 下面的判据全部对应 `number-insights.js` 的 `validate()` 函数体。
library;

import 'dart:convert';

/// 一天的活动量。
class const DayCount({required this.date, required this.count}) {
  /// `YYYY-MM-DD`（UTC）。
  final String date;

  /// 那天新增多少条。
  final int count;
}

/// 一个号码的活动快照。
class const NumberInsights({
  required this.phone,
  required this.generatedAt,
  required this.expiresAt,
  required this.retainedCount,
  required this.arrivals24h,
  required this.arrivals7d,
  required this.activeDays7,
  required this.firstRetainedAt,
  required this.lastRetainedAt,
  required this.directoryFirstSeenAt,
  required this.daily,
}) {
  /// 站点自报的号码，带 `+1`（`+14044225634`）。
  final String phone;

  /// 这份快照什么时候生成的。
  final DateTime generatedAt;

  /// 什么时候过期。过了就该重新抓。
  final DateTime expiresAt;

  /// 站点当前列出的短信条数。
  final int retainedCount;

  /// 24 小时内新增。
  final int arrivals24h;

  /// 7 天内新增。
  final int arrivals7d;

  /// 7 天里有几天有新增（0-7）。
  final int activeDays7;

  /// 最早一条被保留的短信。没有短信时 null。
  final DateTime? firstRetainedAt;

  /// 最近一条被保留的短信。没有短信时 null。
  final DateTime? lastRetainedAt;

  /// **这个号码进目录的时间。** 站点没记录时 null。
  ///
  /// 这就是「收录时间」。它和短信无关 —— 一个号可以收录很久却一条短信
  /// 都没有，那时 [firstRetainedAt] 是 null 而这个有值。
  final DateTime? directoryFirstSeenAt;

  /// 最近 7 天逐日新增，从旧到新，恰好 7 条。
  final List<DayCount> daily;

  /// 还有效吗。
  bool liveAt(DateTime now) => expiresAt.isAfter(now);
}

/// 解析一块 HTML 里的活动快照。找不到或不合法返回 null。
///
/// [wantDigits] 是期望的号码，10 位（`4044225634`）或 11 位都行。
/// 站点给的是 `+14044225634`，这里归一化再比 —— **不比的话，把 A 号码的
/// 快照显示到 B 号码上是可能的**（两个页面同构，抓错页就串了）。
NumberInsights? parseNumberInsights(
  String html, {
  required String wantDigits,
  DateTime? now,
}) {
  final body = _extractIsland(html);
  if (body == null) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;

  return _validate(decoded, wantDigits, now ?? DateTime.now());
}

/// 从 HTML 里抠出 JSON island 的正文。
///
/// 用两条 lookahead 各自要求 `id` 和 `type` 存在，而不是写死
/// `<script id="..." type="...">` 这个属性顺序 —— 站点调换一下属性顺序
/// 就会让写死的正则整条失效，而失效时不报错，只是「没有数据」。
String? _extractIsland(String html) {
  final m = RegExp(
    '<script\\b'
    '(?=[^>]*\\bid=["\']fus-number-insights["\'])'
    '(?=[^>]*\\btype=["\']application/json["\'])'
    '[^>]*>([\\s\\S]*?)</script\\s*>',
    caseSensitive: false,
  ).firstMatch(html);
  final body = m?.group(1)?.trim();
  if (body == null) return null;
  // 站点自己限 12000 字符。超过说明抠错了地方，宁可不要。
  return body.length > 12000 ? null : body;
}

/// 校验并转成 [NumberInsights]。规则对应 `validate()`。
NumberInsights? _validate(
  Map<dynamic, dynamic> raw,
  String want,
  DateTime now,
) {
  if (raw['version'] != 1) return null;

  // 号码必须对上。
  final num = raw['number'];
  if (num is! String) return null;
  final want11 = _to11(want);
  if (want11 == null || _to11(num) != want11) return null;

  final generated = _ts(raw['generated_at']);
  final expires = _ts(raw['expires_at']);
  if (generated == null || expires == null) return null;

  // 生成时间不能在未来（留一分钟容差给时钟偏差）。
  if (generated.isAfter(now.add(const Duration(minutes: 1)))) return null;
  // 已过期 = 这份数据不再可信。
  if (!expires.isAfter(now)) return null;
  // 有效期不能早于生成时间，也不能长过 15 分钟（站点自己就这么限的）。
  if (!expires.isAfter(generated)) return null;
  if (expires.difference(generated) > const Duration(minutes: 15)) return null;

  final retained = _count(raw['retained_count']);
  final a24 = _count(raw['arrivals_24h']);
  final a7 = _count(raw['arrivals_7d']);
  final active = _count(raw['active_days_7utc']);
  if (retained == null || a24 == null || a7 == null || active == null) {
    return null;
  }
  // 三个数必须单调：24 小时 ≤ 7 天 ≤ 保留总数。
  if (a24 > a7 || a7 > retained) return null;
  if (active > 7) return null;

  final first = _ts(raw['first_retained_at']);
  final last = _ts(raw['last_retained_at']);
  final seen = _ts(raw['directory_first_seen_at']);

  // 三个可选时间：给了就必须合法，且不能晚于快照生成时间。
  final limit = generated.add(const Duration(minutes: 1));
  for (final t in [first, last, seen]) {
    if (t != null && t.isAfter(limit)) return null;
  }

  // 没有保留短信时首/末必须是空的；有保留短信时两个都得有且首不晚于末。
  if (retained == 0 && (first != null || last != null)) return null;
  if (retained > 0) {
    if (first == null || last == null) return null;
    if (first.isAfter(last)) return null;
  }

  final daily = _daily(raw['daily'], generated);
  if (daily == null) return null;
  // 逐日加起来不能超过 7 天总数，有量的天数必须等于自报活跃天数。
  var sum = 0;
  var days = 0;
  for (final d in daily) {
    sum += d.count;
    if (d.count > 0) days++;
  }
  if (sum > a7) return null;
  if (days != active) return null;

  return NumberInsights(
    phone: num,
    generatedAt: generated,
    expiresAt: expires,
    retainedCount: retained,
    arrivals24h: a24,
    arrivals7d: a7,
    activeDays7: active,
    firstRetainedAt: first,
    lastRetainedAt: last,
    directoryFirstSeenAt: seen,
    daily: daily,
  );
}

/// 校验逐日数组：恰好 7 条、日期连续、以快照当天为最后一天。
List<DayCount>? _daily(Object? raw, DateTime generated) {
  if (raw is! List || raw.length != 7) return null;

  // 快照生成那天的 UTC 零点。站点就是这么算的。
  final g = generated.toUtc();
  final todayUtc = DateTime.utc(g.year, g.month, g.day);

  final out = <DayCount>[];
  for (var i = 0; i < 7; i++) {
    final e = raw[i];
    if (e is! Map) return null;
    final date = e['date'];
    final count = _count(e['count']);
    if (date is! String || count == null) return null;

    // 期望的日期：今天往前推 6-i 天。
    final want = todayUtc.subtract(Duration(days: 6 - i));
    if (date != _isoDate(want)) return null;
    out.add(DayCount(date: date, count: count));
  }
  return out;
}

/// `YYYY-MM-DD`。
String _isoDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// 解析时间戳。
///
/// 站点给的是**带时区**的 ISO（`2026-10-30T11:48:03+00:00`），而且站点
/// 自己的正则要求必须带 `Z` 或 `±hh:mm` —— 不带时区的一律判不合法。
/// 这里照办：不带时区就返回 null，**不猜它是 UTC 还是本地时间**。
/// 猜错会让收录时间差几个小时，而那看起来完全正常。
DateTime? _ts(Object? v) {
  if (v is! String || v.isEmpty) return null;
  if (!RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(v)) return null;
  return DateTime.tryParse(v)?.toUtc();
}

/// 取非负整数，上限 10 亿（站点自己的 `count()` 就这么限）。
int? _count(Object? v) {
  if (v is int && v >= 0 && v <= 1000000000) return v;
  return null;
}

/// 归一化成 11 位：`+14044225634` / `14044225634` / `4044225634` 都认。
String? _to11(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.length == 11) return digits;
  if (digits.length == 10) return '1$digits';
  return null;
}
