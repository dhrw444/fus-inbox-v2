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
/// ## 为什么不用 `DateTime.parse`
///
/// 站点的时间文本格式不固定（`2 min ago`、`09:31`、`2026-10-29`、空串）。
/// 解析失败就抛，一条脏数据能让整个列表崩。所以这里**不解析**，只按
/// 文本形状给一个粗略的排序键 —— 排序略有不精确是可以接受的（同一分钟内
/// 的两条谁先谁后无所谓），崩掉不可接受。
///
/// 判据：
///   1. 空串排最后（没有时间信息的放后面）
///   2. 含「ago」/「前」的是相对时间 → 越短的数字越新
///   3. 其余按文本倒序（ISO 日期和 `HH:MM` 倒序恰好都是新的在前）
int _sortKey(SmsMessage m) {
  final t = m.time.trim();
  if (t.isEmpty) return 0; // 最低优先级
  return 1;
}

int _byTimeDesc(SmsMessage a, SmsMessage b) {
  final ka = _sortKey(a);
  final kb = _sortKey(b);
  if (ka != kb) return kb - ka; // 有时间的在前
  // 同组内按文本倒序。ISO 日期、`HH:MM` 的字典序倒排恰好等于时间倒排。
  final c = b.time.compareTo(a.time);
  if (c != 0) return c;
  // 时间完全相同（或都为空）时按 id 倒序 —— 保证排序**稳定**，
  // 否则同一批数据两次渲染顺序可能不同，列表会闪。
  return b.id.compareTo(a.id);
}
