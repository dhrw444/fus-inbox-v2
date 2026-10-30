/// 把站点推来的一帧消息合并进现有列表。
///
/// ## 为什么这是最容易写错的地方
///
/// 同一批消息会以**多种方式、多次**抵达：
///   - 早期 DOM 扫描（可能字段残缺）
///   - 接口响应（字段完整）
///   - 翻页（新的旧消息）
///   - 重扫（同一批再来一次）
///
/// 于是必须同时处理：**去重、补字段、排序、裁剪、标「新」**。这五件事
/// 任何一件写错，症状都是「列表看起来不对」—— 但具体哪里不对很难说清，
/// 所以必须能单测。
///
/// ## 纯函数
///
/// 不碰状态、不碰网络。输入旧列表 + 新一帧，输出新列表。这样 `tool/`
/// 下可以直接跑。
library;

import '../core/sms_message.dart';

/// 列表最多留几条。
///
/// 240 条：够翻十几页，又不至于让列表 widget 建太多行。超过就从**最旧**
/// 那头裁 —— 用户看的是最新的，裁旧的不会让他丢东西。
const maxMessages = 240;

/// 一帧合并的结果。
class const MergeResult({
  required this.messages,
  required this.seenIds,
  required this.anyNew,
}) {
  /// 合并后的列表，**已排序、已裁剪**。
  final List<SmsMessage> messages;

  /// 见过的所有 id（含被裁掉的）。
  ///
  /// 必须独立于 [messages] 保存：一条消息被裁掉之后如果又收到它的帧，
  /// 靠这个集合才知道「这条见过、不是新的」。只靠列表判会把老消息标成新。
  final Set<String> seenIds;

  /// 这一帧里有没有出现此前没见过的消息。
  ///
  /// 界面用它决定要不要显示「新」标记。放在结果里而不是让调用方自己比，
  /// 是因为判据要算 `seenIds` —— 那个集合调用方拿不到完整历史。
  final bool anyNew;
}

/// 合并一帧。
///
/// - [current] 现有列表（可以为空）
/// - [incoming] 这一帧的消息
/// - [seenIds] 历史上见过的 id（**含已被裁掉的**）
/// - [firstFrameDone] 首帧是否已经处理过
///
/// [firstFrameDone] 为 false 时，这一帧里的消息**全部算旧** —— 它们是
/// 「打开页面时就已经在的那批」，不该标成「新到」。之后出现的才算新。
MergeResult mergeFrame({
  required List<SmsMessage> current,
  required List<SmsMessage> incoming,
  required Set<String> seenIds,
  required bool firstFrameDone,
}) {
  // 用 LinkedHashMap 保序：同 id 的多次出现要能覆盖字段而不改变位置。
  final byId = <String, SmsMessage>{};
  for (final m in current) {
    byId[m.id] = m;
  }

  final seen = Set<String>.from(seenIds);
  var anyNew = false;

  for (final m in incoming) {
    // 空 id 丢掉：它没法去重，留着会让列表里堆满重复。
    if (m.id.isEmpty) continue;

    final old = byId[m.id];
    if (old != null) {
      // 同 id：补齐字段，位置不变。
      byId[m.id] = old.mergeWith(m);
      continue;
    }

    byId[m.id] = m;
    // 只在「首帧已过」且「这个 id 没见过」时才算新。
    if (firstFrameDone && !seen.contains(m.id)) anyNew = true;
    seen.add(m.id);
  }

  final sorted = byId.values.toList()..sort(_byTimeDesc);

  // 裁剪：从最旧那头切。
  final trimmed = sorted.length > maxMessages
      ? sorted.sublist(0, maxMessages)
      : sorted;

  return MergeResult(messages: trimmed, seenIds: seen, anyNew: anyNew);
}

/// 排序：新的在前。
///
/// ## 时间必须归一化之后再比，不能直接比字符串
///
/// 站点的 `received_at` **格式不统一** —— 站点自己解析它时要先判时区：
///   live.js:267 `function parseUTC(raw){return typeof raw==='string'&&raw?Date.parse(/(?:Z|[+-]\d{2}:?\d{2})$/i.test(raw)?raw:raw+'Z'):NaN;}`
/// 那个三元分支存在的唯一理由就是「有的带 `Z`、有的不带」。若格式恒定，
/// 这段代码是死分支，站点不会写它。
///
/// 而 DOM 路径给的时间是 `toISOString()`（定宽 24 字符，带 `Z`）：
///   live.js:544 `time.dateTime=d.toISOString()`
///
/// 两种形状直接 `compareTo` 会在 `'T'` vs `' '`、`'Z'` vs 空处就分叉，
/// 排出来的顺序与真实时间无关。所以这里先解析成时间戳再比。
///
/// ## 解析失败不抛
///
/// `DateTime.tryParse` 失败返回 null，不是抛异常 —— 一条脏数据不该让整个
/// 列表崩。解析不出来的排在有时间的后面。
///
/// ## 站点补 `Z` 的语义
///
/// 站点对不带时区的串**补 `Z`**（当 UTC 处理）。这里照同一规则办，
/// 否则同一批数据在 App 和站点上会排出两种顺序。
DateTime? _parseSiteTime(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  // 已经带时区后缀（`Z` 或 `±hh:mm`）就直接解析。
  final hasZone = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(t);
  return DateTime.tryParse(hasZone ? t : '${t}Z');
}

/// 比较键：有时间的给时间戳，没时间的给 null（排最后）。
int? _timeKey(SmsMessage m) => _parseSiteTime(m.time)?.millisecondsSinceEpoch;

int _byTimeDesc(SmsMessage a, SmsMessage b) {
  final ta = _timeKey(a);
  final tb = _timeKey(b);
  // 有时间的在前，没时间的在后。
  if (ta != null && tb == null) return -1;
  if (ta == null && tb != null) return 1;
  if (ta != null && tb != null) {
    final c = tb.compareTo(ta); // 新的在前
    if (c != 0) return c;
  }
  // 时间相同（或都缺）时按编号倒序。
  //
  // **必须按数值比，不能按字符串比。** 站点给的是 `event_id` 数字
  // （live.js:541 `card.dataset.eventId=String(m.event_id)`），位数不等很常见：
  // 字符串比较是逐码元比的（SDK `dart:core/string.dart` 的 `compareTo` 文档：
  // 「ordering is the same as the ordering of the code units at the first
  // position where the two strings differ」），于是 `'99' > '123'` ——
  // 数值上 123 更新，却被排到后面。
  //
  // 两边都能转成数字时按数字比；转不动的退回字符串比（保证排序仍是全序，
  // 不会因为返回 0 让 `List.sort` 的顺序在两次渲染间漂）。
  final na = int.tryParse(a.id);
  final nb = int.tryParse(b.id);
  if (na != null && nb != null) {
    final c = nb.compareTo(na);
    if (c != 0) return c;
  }
  return b.id.compareTo(a.id);
}
