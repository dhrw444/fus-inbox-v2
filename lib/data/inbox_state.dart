/// 收件箱的状态。
///
/// ## 为什么状态要单独一个值对象
///
/// 旧代码里「状态」散在十几个字段上（`phase`、`status`、`error`、`hold`、
/// `hits`、`source`、`loadingMore`、`visible`……），于是每个改动点都要
/// 记得「哪些字段该一起变」。漏一个就是「界面卡住」「转圈不停」「失败原因
/// 被抹掉」这类 bug —— 而且每一处漏都不报错，只是行为不对。
///
/// 现在全部收进一个**不可变**对象：任何变化都走 [copyWith]，只有一处
/// 定义「改这个字段要不要连带改别的」。判据集中，漏不了。
library;

import '../core/sms_message.dart';
import 'merge_frame.dart';

/// 收件箱处在什么阶段。
enum InboxPhase {
  /// 正在等站点给消息（页面刚打开 / 验证中 / 被限流）。
  waiting,

  /// 拿到消息了。
  ready,

  /// 出错了（网络、代理、页面加载失败）。
  failed,
}

/// 站点拒绝给消息的原因。
enum HoldKind {
  /// 配额用完（`429 + pause`）。换出口或等。
  quota,

  /// 要过人机验证（`403 + challenge`）。
  challenge,

  /// 服务端临时繁忙（`503`）。等它自己好。
  temporary,
}

/// 站点的一次拒绝。
class const SiteHold({
  required this.kind,
  required this.title,
  required this.message,
  this.retrySeconds = 0,
}) {
  final HoldKind kind;

  /// 站点自己的标题。空串表示用它默认文案。
  final String title;

  /// 站点自己的说明。空串同上。
  final String message;

  /// 站点建议多少秒后再试。0 表示它没说。
  final int retrySeconds;
}

/// 收件箱的完整状态。不可变。
class const InboxState({
  required this.messages,
  required this.phase,
  this.status = '',
  this.error = '',
  this.hold,
  this.hits = 0,
  this.source = '',
  this.visible = 5,
  this.loadingMore = false,
  this.hasMore = true,
}) {
  /// 消息列表。**已排序、已裁剪**（由 `mergeFrame` 保证）。
  final List<SmsMessage> messages;

  final InboxPhase phase;

  /// 状态栏那一行字（「正在打开收件页…」「截获到了接口」之类）。
  final String status;

  /// 失败原因。空串 = 没有失败。
  final String error;

  /// 站点主动拒绝时非空。和 [error] 是两件事：
  /// [error] 是「我们这边出问题了」，[hold] 是「站点说现在不给」。
  final SiteHold? hold;

  /// 截获到几次接口响应。0 说明挂钩还没生效。
  final int hits;

  /// 数据来源（`dom` / `api`），只用于排查。
  final String source;

  /// 当前显示前几条。用户点「显示更多」才增加。
  final int visible;

  /// 正在加载更早的消息。
  final bool loadingMore;

  /// 还有更早的消息可以加载。
  final bool hasMore;

  /// 初始状态。
  static const empty = InboxState(
    messages: [],
    phase: InboxPhase.waiting,
    status: '正在打开收件页…',
  );

  /// 当前该显示的几条。
  ///
  /// 单独一个 getter 而不是让界面自己 `sublist`：界面里写 `sublist(0, n)`
  /// 在列表短于 n 时会抛，那种 bug 只在「消息不足 5 条」时出现。
  List<SmsMessage> get shown =>
      messages.length <= visible ? messages : messages.sublist(0, visible);

  /// 还有没有没显示出来的。
  bool get hasHidden => messages.length > visible;

  /// 改状态。**所有变化都走这里**。
  ///
  /// `clearXxx` 系列参数是刻意的：`copyWith(error: '')` 和「不改 error」
  /// 在 Dart 里无法区分（`''` 是合法值，`null` 又表示「没传」）。所以
  /// 要清空某个可选字段时必须显式说 `clearError: true`。
  ///
  /// 这套约定是本文件最重要的一条：**没有它，每一处「忘记清空」都会变成
  /// 一个独立的 bug**（失败提示不消失、hold 卡片永久挂着）。
  InboxState copyWith({
    List<SmsMessage>? messages,
    InboxPhase? phase,
    String? status,
    String? error,
    SiteHold? hold,
    int? hits,
    String? source,
    int? visible,
    bool? loadingMore,
    bool? hasMore,
    bool clearError = false,
    bool clearHold = false,
  }) => InboxState(
    messages: messages ?? this.messages,
    phase: phase ?? this.phase,
    status: status ?? this.status,
    error: clearError ? '' : (error ?? this.error),
    hold: clearHold ? null : (hold ?? this.hold),
    hits: hits ?? this.hits,
    source: source ?? this.source,
    visible: visible ?? this.visible,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
  );

  /// 应用一帧消息。
  ///
  /// 这是唯一把 [messages] 换掉的地方 —— 合并、排序、裁剪全在
  /// `mergeFrame` 里，这里只负责把结果装进状态。
  ///
  /// 三条连带规则（都是旧代码踩过坑的）：
  ///   1. 有消息 → `phase` 必须变 `ready`，且**清掉 hold**（站点又开始给了）
  ///   2. 没消息且本来不是 failed → 保持 waiting（不要因为一帧空就报错）
  ///   3. `error` **不清** —— 除非调用方明确说清（见 [copyWith] 的约定）
  InboxState applyFrame({
    required MergeResult merged,
    required String status,
    int? hits,
    String? source,
  }) {
    final hasMessages = merged.messages.isNotEmpty;
    return copyWith(
      messages: merged.messages,
      phase: hasMessages ? InboxPhase.ready : (phase == InboxPhase.failed ? InboxPhase.failed : InboxPhase.waiting),
      status: status,
      hits: hits,
      source: source,
      // 拿到消息 = 站点又开始给了 → hold 必须消失。
      clearHold: hasMessages,
      // 同样地，拿到消息说明「能用了」，失败原因也该清。
      clearError: hasMessages,
    );
  }
}
