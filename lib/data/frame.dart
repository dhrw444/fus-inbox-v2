/// 解析注入脚本发来的帧。
///
/// ## 边界在这
///
/// JS 和 Dart 之间的协议是**字符串**（`JSON.stringify` 之后经
/// `callHandler` 过来）。这里是唯一解析它的地方，所以：
///
///   - 所有「字段名 / 类型」的判据集中在这里，不会散落到状态层
///   - 任何畸形帧在这里被丢掉，不会往下污染
///   - 纯函数，可直接单测（喂一段 JSON 字符串，看解析出什么）
///
/// ## 为什么不用 `json.decode` 直接转模型
///
/// 因为**帧的形状不统一**：`messages` 帧带 `items` 数组，`holdup` 帧带
/// `kind`，`status` 帧带 `text`。用一个「万能模型」会把它们揉成一大堆
/// 可空字段，每个消费点都要自己判「这个字段在这个帧里有没有意义」。
///
/// 改成解析成**密封类型**（[Frame] 的子类）：每个帧只带自己的字段，
/// 消费点用 `switch` 分派时编译器会检查有没有漏。
library;

import 'dart:convert';

import '../core/sms_message.dart';

/// 站点发来的一帧。密封类：只有下面这些形状。
sealed class const Frame();

/// 消息列表（DOM 扫描或接口响应）。
class const MessagesFrame({
  required this.items,
  required this.hits,
  required this.source,
}) extends Frame {
  final List<SmsMessage> items;

  /// 截获到几次接口响应。0 说明挂钩还没生效。
  final int hits;

  /// `dom` / `api`。
  final String source;
}

/// 状态栏文案。
class const StatusFrame({required this.text}) extends Frame {
  final String text;
}

/// 站点拒绝（或解除拒绝）。
class const HoldFrame({
  required this.kind,
  required this.title,
  required this.message,
  required this.retrySeconds,
}) extends Frame {
  /// 空串 = **解除**（站点又开始给了）。
  final String kind;
  final String title;
  final String message;
  final int retrySeconds;

  bool get isClear => kind.isEmpty;
}

/// 翻页结束。
class const MoreDoneFrame({required this.empty}) extends Frame {
  /// true = 到底了，没有更早的消息。
  final bool empty;
}

/// 翻页失败。
class const MoreFailFrame({required this.reason}) extends Frame {
  final String reason;
}

/// 解析一帧。返回 null = 畸形帧，丢掉。
///
/// ## 为什么宁可丢也不猜
///
/// 猜（比如「没有 type 就当成 messages」）会把畸形帧塞进状态层，而那里
/// 已经假定「进来的都是合法帧」。一个畸形帧能造成的问题远大于「这一帧
/// 没处理」——后者只是慢一拍，前者可能让整个列表错乱。
Frame? parseFrame(String raw) {
  if (raw.isEmpty) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;

  final type = decoded['type'];
  if (type is! String) return null;

  return switch (type) {
    'messages' => _parseMessages(decoded),
    'status' => StatusFrame(text: _str(decoded['text'])),
    'holdup' => _parseHold(decoded),
    'moreDone' => MoreDoneFrame(empty: decoded['empty'] == true),
    'moreFail' => MoreFailFrame(reason: _str(decoded['reason'])),
    _ => null,
  };
}

Frame? _parseMessages(Map<dynamic, dynamic> m) {
  final raw = m['items'];
  if (raw is! List) return null;

  final items = <SmsMessage>[];
  for (final e in raw) {
    final msg = _parseMessage(e);
    // 空 id 的消息在下游会被丢掉（没法去重），这里直接过滤掉，
    // 少传一层垃圾。
    if (msg != null) items.add(msg);
  }

  return MessagesFrame(
    items: items,
    hits: _int(m['hits']),
    source: _str(m['src']),
  );
}

/// 解析一条消息。字段缺失就用空串/默认值 —— 站点的 DOM 扫描拿到的条目
/// 经常只有一半字段，那是正常的（后续帧会补齐）。
SmsMessage? _parseMessage(Object? raw) {
  if (raw is! Map) return null;
  final id = _str(raw['id']);
  if (id.isEmpty) return null;
  return SmsMessage(
    id: id,
    text: _str(raw['text']),
    code: _str(raw['code']),
    sender: _str(raw['sender']),
    time: _str(raw['time']),
    phone: _str(raw['phone']),
    isProtected: raw['protected'] == true,
  );
}

Frame? _parseHold(Map<dynamic, dynamic> m) => HoldFrame(
  kind: _str(m['kind']),
  title: _str(m['title']),
  message: _str(m['message']),
  retrySeconds: _int(m['retry']),
);

/// 取字符串。非字符串一律给空串 —— 不做 `toString()`。
///
/// `toString()` 会把 `null` 变成 `"null"`、把数字变成 `"123"`，
/// 那些假字符串会被下游当成真实内容（比如显示「发送方：null」）。
String _str(Object? v) => v is String ? v : '';

/// 取整数。兼容字符串形式（JS 的 `JSON.stringify` 对数字是安全的，
/// 但站点自己塞进 DOM 的属性都是字符串，注入脚本可能原样传过来）。
int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
