/// 号码目录的筛选、排序、分组。
///
/// ## 纯逻辑，不碰界面
///
/// 目录页要同时支持「搜索 + 页签 + 排序」，三个维度会互相影响
/// （「最新活跃」页签下按条数排，和「按州」页签下按州分组是两回事）。
/// 这些组合放进界面里会变成一堆 `if`，所以单独抽一层：
/// 输入号码列表 + 一组条件，输出**可直接渲染的行列表**。
///
/// ## 每个比较器最后一步必须兜到号码
///
/// Dart 的 `List.sort` **不保证稳定** —— `dart:core` 的 `List.sort` 文档
/// 原话是「The sort is not guaranteed to be stable」。目录是分页并发抓
/// 回来的，时间戳/条数并列的项很多。比较器对并列项返回 0，两次刷新之间
/// 列表顺序就会跳，用户滑到一半行换了位置。
///
/// 所以每条排序链的最后一环都是号码比较：号码唯一，永远分得出先后，
/// 比较器因此变成全序。
library;

import 'number_entry.dart';

/// 排序方式。
enum NumberSort(this.label) {
  /// 最近有短信的在前。没有短信时间的排后面。
  recent('最新活跃'),

  /// **最近被收录的在前。** 没有收录时间的排后面。
  ///
  /// 这是用户要的那个维度：先看到「刚进目录的号」。收录时间来自站点
  /// 的 `directory_first_seen_at`（见 `number_insights.dart`），不是
  /// 「最后一条短信时间」。
  newest('最近收录'),

  /// 短信条数多的在前。
  busiest('条数最多'),

  /// 号码升序。站点按号码递增收录，所以这等价于「按收录顺序」的近似。
  digits('号码'),

  /// 有短信的在前，其余保持号码序。
  hasMessages('有短信优先');

  final String label;
}

/// 页签。
enum NumberTab(this.label) {
  all('全部'),
  live('最新活跃'),
  byState('按州');

  final String label;
}

/// 目录筛选条件。不可变。
class const DirectoryFilter({
  this.query = '',
  this.tab = NumberTab.all,
  this.sort = NumberSort.recent,
  this.starredOnly = false,
}) {
  /// 搜索词。号码片段、区号、州名都能匹配。
  final String query;
  final NumberTab tab;
  final NumberSort sort;
  final bool starredOnly;

  bool get isDefault =>
      query.trim().isEmpty &&
      tab == NumberTab.all &&
      sort == NumberSort.recent &&
      !starredOnly;

  DirectoryFilter copyWith({
    String? query,
    NumberTab? tab,
    NumberSort? sort,
    bool? starredOnly,
  }) => DirectoryFilter(
    query: query ?? this.query,
    tab: tab ?? this.tab,
    sort: sort ?? this.sort,
    starredOnly: starredOnly ?? this.starredOnly,
  );
}

/// 「最近活跃」页签的时间窗。
///
/// 10 分钟：站点自己的 `fresh` 标记就在这个量级（页面上写 `41 sec ago`
/// 的号码带 `is-fresh` 类）。太短会让页签经常空着，太长就没有「最新」的意思。
const kLiveWindow = Duration(minutes: 10);

/// 一行渲染数据：要么一个号码，要么一个分组标题。
///
/// 界面直接按这个列表建行，不用自己判「这行是标题还是号码」。
sealed class const DirectoryRow();

/// 一个号码行。
class const NumberRow({
  required this.entry,
  required this.starred,
}) extends DirectoryRow {
  final NumberEntry entry;
  final bool starred;
}

/// 一个分组标题（按州页签用）。
class const GroupRow({required this.title, required this.count})
    extends DirectoryRow {
  final String title;
  final int count;
}

/// 一个号码的收录时间。没查到就是「未记录」。
///
/// 单独一个值对象而不是 `DateTime?`：`null` 分不清「还没查」和「站点没有」，
/// 而这两种情况界面上该说的话不一样。
class const FirstSeenInfo({
  /// 站点记录的收录时间。null = 站点没给。
  this.at,

  /// 我们尝试查过但站点没给（不是「还没查」）。
  this.probed = false,
}) {
  final DateTime? at;
  final bool probed;

  static const unknown = FirstSeenInfo();

  /// 查过、但站点确实没记录。
  static const absent = FirstSeenInfo(probed: true);

  bool get known => at != null;
}

/// 把条件应用到号码列表上，返回可直接渲染的行。
///
/// [starredOf] 判收藏，[firstSeenOf] 取收录时间（可能还没查）。
List<DirectoryRow> applyDirectoryFilter({
  required List<NumberEntry> entries,
  required DirectoryFilter filter,
  required bool Function(String digits) starredOf,
  required FirstSeenInfo Function(String digits) firstSeenOf,
  required DateTime now,
}) {
  var list = entries.toList();

  // ① 只看收藏。
  if (filter.starredOnly) {
    list = list.where((e) => starredOf(e.digits)).toList();
  }

  // ② 页签。
  if (filter.tab == NumberTab.live) {
    final cutoff = now.subtract(kLiveWindow);
    list = list.where((e) {
      final t = e.lastTextAt;
      return t != null && t.isAfter(cutoff);
    }).toList();
  }

  // ③ 搜索。空词不动。
  final q = filter.query.trim().toLowerCase();
  if (q.isNotEmpty) {
    // 号码匹配忽略非数字 —— 用户可能输入 `(757) 555`。
    final qDigits = q.replaceAll(RegExp(r'[^\d]'), '');
    list = list.where((e) {
      if (qDigits.isNotEmpty && e.digits.contains(qDigits)) return true;
      if (e.areaCode.toLowerCase().contains(q)) return true;
      if (e.state.toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  // ④ 排序。
  list.sort(
    (a, b) => _compare(a, b, filter.sort, firstSeenOf),
  );

  // ⑤ 按州页签：同一州聚到一起，前面插标题行。
  if (filter.tab == NumberTab.byState) {
    return _groupByState(list, starredOf, firstSeenOf, filter.sort);
  }

  return [
    for (final e in list)
      NumberRow(entry: e, starred: starredOf(e.digits)),
  ];
}

/// 比较两个号码。**最后一步一定兜到号码**，保证全序。
int _compare(
  NumberEntry a,
  NumberEntry b,
  NumberSort sort,
  FirstSeenInfo Function(String) firstSeenOf,
) {
  switch (sort) {
    case NumberSort.recent:
      final ta = a.lastTextAt;
      final tb = b.lastTextAt;
      if (ta != null && tb == null) return -1;
      if (ta == null && tb != null) return 1;
      if (ta != null && tb != null) {
        final c = tb.compareTo(ta);
        if (c != 0) return c;
      }

    case NumberSort.newest:
      final fa = firstSeenOf(a.digits).at;
      final fb = firstSeenOf(b.digits).at;
      if (fa != null && fb == null) return -1;
      if (fa == null && fb != null) return 1;
      if (fa != null && fb != null) {
        final c = fb.compareTo(fa); // 新的在前
        if (c != 0) return c;
      }

    case NumberSort.busiest:
      final c = b.messageCount.compareTo(a.messageCount);
      if (c != 0) return c;

    case NumberSort.hasMessages:
      final ha = a.messageCount > 0;
      final hb = b.messageCount > 0;
      if (ha != hb) return ha ? -1 : 1;

    case NumberSort.digits:
      break;
  }
  // 兜底：号码升序。**不能省**，否则并列项顺序会在刷新间漂。
  return a.digits.compareTo(b.digits);
}

/// 按州分组：州名升序，组内按 [sort] 排。
List<DirectoryRow> _groupByState(
  List<NumberEntry> list,
  bool Function(String) starredOf,
  FirstSeenInfo Function(String) firstSeenOf,
  NumberSort sort,
) {
  const unknownName = '未知归属';
  final groups = <String, List<NumberEntry>>{};
  for (final e in list) {
    final s = e.state.trim();
    groups.putIfAbsent(s.isEmpty ? unknownName : s, () => []).add(e);
  }

  final names = groups.keys.toList()
    ..sort((a, b) {
      // 「未知归属」永远最后 —— 它是兜底组，不是真州名。
      if (a == unknownName) return 1;
      if (b == unknownName) return -1;
      return a.compareTo(b);
    });

  final out = <DirectoryRow>[];
  for (final name in names) {
    final items = groups[name]!
      ..sort((a, b) => _compare(a, b, sort, firstSeenOf));
    out.add(GroupRow(title: name, count: items.length));
    out.addAll([
      for (final e in items)
        NumberRow(entry: e, starred: starredOf(e.digits)),
    ]);
  }
  return out;
}

/// 把收录时间说成人话。
///
/// [info] 没查到时间时**必须说「未记录」**，不能编「刚收录」——
/// 那是把「不知道」说成「有」。
String describeFirstSeen(FirstSeenInfo info, DateTime now) {
  final at = info.at;
  if (at == null) {
    // 「还没查」和「查过但没有」是两件事：前者等一会儿可能就有了。
    return info.probed ? '收录时间未记录' : '收录时间未查到';
  }

  final d = now.toUtc().difference(at.toUtc());
  // 时钟往回跳（用户改了系统时间）时差值为负。不显示「-3 分钟前」。
  if (d.isNegative || d.inMinutes < 1) return '刚收录';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前收录';
  if (d.inDays < 1) return '${d.inHours} 小时前收录';
  if (d.inDays < 30) return '${d.inDays} 天前收录';
  final months = d.inDays ~/ 30;
  if (months < 12) return '$months 个月前收录';
  return '${d.inDays ~/ 365} 年前收录';
}

/// 精确时刻 `2026-10-29 13:23 UTC`。相对时间好读，绝对时间好核对。
String exactFirstSeen(FirstSeenInfo info) {
  final at = info.at?.toUtc();
  if (at == null) return '';
  final y = at.year.toString().padLeft(4, '0');
  final mo = at.month.toString().padLeft(2, '0');
  final d = at.day.toString().padLeft(2, '0');
  final h = at.hour.toString().padLeft(2, '0');
  final mi = at.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi UTC';
}
