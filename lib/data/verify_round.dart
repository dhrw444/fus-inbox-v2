/// 「等站点验证通过」这一轮的状态机。
///
/// ## 为什么这块单独抽出来重写
///
/// 旧代码里这套判断埋在 900ms 的 Timer 回调里，症状是：
///   - 验证完还会再弹（闸门被重开）
///   - 一直弹（闸门没关上）
///   - 用户过完验证回来，App 已经不看了（超时把它判死）
///   - 轮询取消后没重启（状态机死了）
///
/// 每一个都是「状态没管好」，而不是「逻辑算错」。所以重写时把状态全部
/// 收进这一个对象，**并且把所有会改变它的操作做成显式方法** —— 调用方
/// 只能通过这些方法来改。
///
/// ## 纯逻辑
///
/// 不碰 Timer、不碰 WebView、不碰 UI。时间由外部注入，所以可以单测
/// 「等 5 秒后该不该弹」而不用真的等 5 秒。
library;

/// 一轮验证的状态。**不可变** —— 改动一律返回新对象。
class const VerifyRoundVal({
  required this.elapsed,
  required this.popped,
  required this.visible,
  required this.auto,
  required this.readySeen,
}) {
  /// 这一轮已经等了多久。
  final Duration elapsed;

  /// 这一轮**已经自动弹过**了吗。
  ///
  /// 关键闸门：弹过之后就不再弹，否则用户一收起，几秒后又弹回来，
  /// 等于没给他选。只有「真的拿到消息」才该把它解开。
  final bool popped;

  /// 验证界面现在是否显示。
  final bool visible;

  /// 这次是**自动弹**的还是用户自己点的。
  ///
  /// 和 [visible] 必须一起变 —— 旧代码里它们是两个独立字段，能写出
  /// 「没显示却是自动弹的」这种无意义组合，消费点为此写过好几处三连判
  /// （`!mounted || !_showChallenge || !_challengeAuto`）。
  final bool auto;

  /// 这一轮见过站点报 `ready` 了吗。只认第一次 —— 用来「ready 后补一次重扫」。
  final bool readySeen;

  /// 初始状态：没等、没弹、没 ready。
  static const fresh = VerifyRoundVal(
    elapsed: Duration.zero,
    popped: false,
    visible: false,
    auto: false,
    readySeen: false,
  );

  /// 只有这种情况才需要盯着 `cf_clearance` 自动收层。
  ///
  /// 用户自己点开的那个不自动收：他可能只是想顺便看看网页。
  bool get watchingForAutoPass => visible && auto;

  /// 该不该自动弹出。
  ///
  /// 三个条件缺一不可：
  ///   1. 这一轮还没弹过（[popped] 为假）
  ///   2. 已经等够了（[elapsed] 超过阈值）
  ///   3. 当前没在显示（[visible] 为假）
  ///
  /// 第 3 条放在这里而不是让调用方判 —— 旧代码是调用方各判一次，
  /// 结果有一处漏了，弹层开着的时候又弹一次。
  bool shouldAutoPop({required Duration after}) =>
      !popped && !visible && elapsed >= after;

  /// 该不该判超时。
  ///
  /// **弹层开着时永不算超时。** 用户在站点页面上点复选框、等 Cloudflare
  /// 转圈，很容易超过窗口时长 —— 那时候把轮询停掉，等于「你正在过验证，
  /// 但 App 已经不看了」。
  bool timedOut({required Duration window}) => !visible && elapsed > window;

  /// 落起算点。每 tick 注入当前时间。
  VerifyRoundVal tick(Duration elapsed) => _copy(elapsed: elapsed);

  /// 记下「已经弹过」。
  ///
  /// [auto] 决定是哪种弹：自动弹才盯着 cf_clearance。
  VerifyRoundVal pop({required bool auto}) =>
      _copy(popped: true, visible: true, auto: auto);

  /// 收起验证界面。
  ///
  /// 全应用只有这一个「收起」入口 —— 旧代码里「收起」写了两处，一处漏清
  /// `_challengeAuto`，于是「用户自己点开的弹层」被后续逻辑当成自动弹层，
  /// 自动收层逻辑对着一个手动弹层跑。
  VerifyRoundVal close() => _copy(visible: false, auto: false);

  /// 见站点报 `ready`。返回 `(新状态, 是不是第一次)`。
  ///
  /// 调用方靠「是不是第一次」决定要不要补一次重扫 —— 每次 ready 都重扫
  /// 会白白多发请求，而完全不管又会漏掉「站点 ready 了但没推消息」那种情况。
  (VerifyRoundVal, bool) markReady() {
    if (readySeen) return (this, false);
    return (_copy(readySeen: true), true);
  }

  /// 开新一轮。
  ///
  /// [rearm] 决定要不要把「已经弹过」的闸门也解开。
  ///
  /// **拿到消息时传 true**（下一轮该允许再弹 —— 因为消息来了代表站点
  /// 放过我们了，下次被拒是新的一回事）。
  /// **用户点「收起」时传 false** —— 他刚说了不想过，过几秒又弹回来
  /// 等于没给他选。
  VerifyRoundVal restart({bool rearm = true}) => VerifyRoundVal(
    elapsed: Duration.zero,
    // 起算点归零时必须连 readySeen 一起清：新一轮的 ready 是新的一次，
    // 不清的话「ready 后补一次重扫」永远不会再触发。
    popped: rearm ? false : popped,
    visible: false,
    auto: false,
    readySeen: false,
  );

  VerifyRoundVal _copy({
    Duration? elapsed,
    bool? popped,
    bool? visible,
    bool? auto,
    bool? readySeen,
  }) => VerifyRoundVal(
    elapsed: elapsed ?? this.elapsed,
    popped: popped ?? this.popped,
    visible: visible ?? this.visible,
    auto: auto ?? this.auto,
    readySeen: readySeen ?? this.readySeen,
  );
}
