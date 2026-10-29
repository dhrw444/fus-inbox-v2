/// 收件箱的协调器：收帧 → 改状态 → 通知。
///
/// ## 和旧代码的区别
///
/// 旧代码的 `InboxStore` 里，状态是**十几个散字段**，每个 `_ingestXxx`
/// 分支各自拼一个新状态。于是「哪些字段该一起变」这条规则被抄了七八遍，
/// 每遍都可能漏 —— 而漏了不报错，只是行为不对（失败原因被抹掉、hold
/// 卡片永久挂着、转圈不停）。
///
/// 新版只有两条路径能改状态：
///   1. [applyFrame] —— 帧驱动
///   2. [note] / [fail] / [reset] —— 应用自己驱动
///
/// 判断逻辑全在 `frame.dart` / `merge_frame.dart` / `inbox_state.dart`
/// 里（都是纯函数、有单测），这里只负责**接线**。
library;

import 'frame.dart';
import 'inbox_state.dart';
import 'merge_frame.dart';

/// 收件箱状态容器。
///
/// 不继承 Riverpod 的 Notifier —— 那样就没法在 `tool/` 下单测了。
/// 用组合：这个类是纯 Dart，外面包一层 provider 把它接到界面。
class InboxStore() {
  InboxState _state = InboxState.empty;
  Set<String> _seen = const {};
  bool _firstFrameDone = false;

  /// 状态变化时的回调。为空 = 没人听（页面已销毁）。
  void Function()? onChanged;

  InboxState get state => _state;

  /// 收一帧。畸形帧丢掉，不抛。
  void ingest(String raw) {
    final frame = parseFrame(raw);
    if (frame == null) return;
    switch (frame) {
      case MessagesFrame():
        _applyMessages(frame);
      case StatusFrame():
        _emit(_state.copyWith(status: frame.text));
      case HoldFrame():
        _applyHold(frame);
      case MoreDoneFrame():
        _emit(
          _state.copyWith(
            loadingMore: false,
            // `empty` 表示「到底了」，不再有更早的。
            hasMore: !frame.empty,
          ),
        );
      case MoreFailFrame():
        // 失败不等于没有更多：保留 hasMore，用户还能再试。
        _emit(_state.copyWith(loadingMore: false));
    }
  }

  void _applyMessages(MessagesFrame frame) {
    final merged = mergeFrame(
      current: _state.messages,
      incoming: frame.items,
      seenIds: _seen,
      firstFrameDone: _firstFrameDone,
    );
    _seen = merged.seenIds;
    // **只有这一帧真的产出消息时才算首帧结束。**
    //
    // 早期 DOM 扫描可能一条有效消息都没有（页面还没渲染、抓到的全是
    // 受保护行），那一帧被当成首帧的话，之后接口帧里每条都会被标「新」。
    if (merged.messages.isNotEmpty) _firstFrameDone = true;

    _emit(
      _state.applyFrame(
        merged: merged,
        status: _statusLine(merged, frame),
        hits: frame.hits,
        source: frame.source,
      ),
    );
  }

  void _applyHold(HoldFrame frame) {
    if (frame.isClear) {
      // 站点又开始给了 → 清 hold。
      // **但不动 error**：那是我们这边的失败原因（代理不可用之类），
      // 站点说一句「解除」不该把它抹掉 —— 旧代码无条件清，于是失败面板
      // 变成「说不出原因的失败」。
      _emit(_state.copyWith(clearHold: true));
      return;
    }
    final kind = switch (frame.kind) {
      'pause' => HoldKind.quota,
      'challenge' => HoldKind.challenge,
      _ => HoldKind.temporary,
    };
    _emit(
      _state.copyWith(
        hold: SiteHold(
          kind: kind,
          title: frame.title,
          message: frame.message,
          retrySeconds: frame.retrySeconds,
        ),
        phase: InboxPhase.waiting,
        clearError: true,
      ),
    );
  }

  /// 状态栏那一行。
  ///
  /// 空列表时给「在等」的文案；有消息时给条数。不做花哨判断 ——
  /// 用户只需要知道「现在什么情况」。
  String _statusLine(MergeResult merged, MessagesFrame frame) {
    if (merged.messages.isEmpty) {
      // hits == 0 说明挂钩还没截获到接口，多半卡在验证。
      // 这条提示是给「一直不出消息」用的，所以要说清两种可能。
      return frame.hits == 0 ? '还没截获到接口响应' : '截获到了接口，但里面没有消息';
    }
    return '已收到 ${merged.messages.length} 条';
  }

  /// 应用自己写一句提示。
  void note(String text) => _emit(_state.copyWith(status: text));

  /// 报一个失败。
  ///
  /// **必须连 `loadingMore` 一起清** —— 否则翻页途中出错，
  /// `loadingMore` 永远为真，列表底部一直转圈，而之后所有翻页入口都会被
  /// 「正在加载」挡住，功能永久失效。
  void fail(String message) => _emit(
    _state.copyWith(
      phase: InboxPhase.failed,
      error: message,
      status: message,
      loadingMore: false,
    ),
  );

  /// 页面作废（换身份 / 换出口 / 重载）：回到初始状态。
  ///
  /// 换出口时**必须**清 `hold` —— 否则上一轮的拒绝信号还在，状态一变就
  /// 又触发一次自动轮换，形成死循环（旧代码踩过）。
  void reset() {
    _seen = const {};
    _firstFrameDone = false;
    _emit(InboxState.empty);
  }

  /// 翻页开始。
  void markLoadingMore() => _emit(_state.copyWith(loadingMore: true));

  /// 结束翻页。[done] 为真时表示失败/超时（也要清标志）。
  void endLoadingMore() => _emit(_state.copyWith(loadingMore: false));

  /// 多显示几条（「显示更多」按钮）。
  void revealMore() => _emit(_state.copyWith(visible: _state.visible + 5));

  void _emit(InboxState next) {
    _state = next;
    onChanged?.call();
  }
}
