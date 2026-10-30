/// 收件页。
///
/// ## 它只做一件事：接线
///
/// 所有判断都在别处：
///   - 收到什么帧、怎么解析 → `data/frame.dart`
///   - 怎么合并去重排序 → `data/merge_frame.dart`
///   - 状态怎么变 → `data/inbox_state.dart`
///   - 验证界面的闸门 → `data/verify_round.dart`
///   - 内核怎么配 → `platform/web_view.dart`
///
/// 这个文件负责的是「把它们串起来，并且在正确的时候调 `setState`」。
/// 旧代码把这些全混在一个 1100 行的文件里，于是「什么时候该做什么」
/// 这件事本身变成了最难查的部分。
///
/// ## 三个 Timer，各有各的职责
///
///   1. `_verifyTick` —— 900ms，推进验证状态机
///   2. `_loadMoreTick` —— 15 秒，翻页超时兜底
///   3. `_watchdog` —— 25 秒，整页卡住的兜底提示
///
/// 旧代码的三个 Timer 之间有隐式耦合（一个取消另一个还在跑），新版
/// 各自独立、各自在 `dispose` 里收尾。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/load_failure.dart';
import '../core/site_grant.dart';
import '../core/user_agent.dart';
import '../data/egress.dart';
import '../data/inbox_state.dart';
import '../data/inbox_store.dart';
import '../data/verify_round.dart';
import '../data/visitor_session.dart';
import '../main.dart'
    show
        egress,
        readRoster,
        readVisitors,
        writeProfile,
        writeRoster,
        writeVisitors;
import '../platform/identity_script.dart';
import '../platform/site_wipe.dart';
import '../platform/web_view.dart';
import 'widgets/message_card.dart';

/// 自动弹出验证的等待时长。
const _autoPopAfter = Duration(seconds: 6);

/// 验证窗口：超过这么久还没结果就放弃等待。
const _verifyWindow = Duration(seconds: 90);

/// 翻页超时。
const _loadMoreTimeout = Duration(seconds: 15);

/// 整页卡住的兜底提示。
const _watchdogAfter = Duration(seconds: 25);

/// 收件页。
class const InboxPage({
  required this.inboxUrl,
  required this.title,
  this.allowedHost = 'freeussms.com',
  super.key,
}) extends StatefulWidget {
  /// 要打开的收件页地址（`https://freeussms.com/numbers/<号码>/`）。
  final String inboxUrl;

  /// 标题栏显示什么（号码）。
  final String title;

  /// 只放行这个域名（含子域）的导航。
  ///
  /// 通道会把页面发来的 JSON 直接交给状态层，任何第三方页面拿到它都是
  /// 不该有的攻击面。做成参数而不是写死常量：站点换域名时只改调用方。
  final String allowedHost;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState() extends State<InboxPage> {
  final _store = InboxStore();
  final _scroll = ScrollController();

  /// 重建标识跟着身份走 —— 理由见 [inboxViewKey]。
  Key get _viewKey => inboxViewKey(currentProfile);

  VerifyRoundVal _round = VerifyRoundVal.fresh;
  String _scannerScript = '';
  bool _ready = false;

  /// 访客（出口 + 身份）已经定好并应用上了。
  ///
  /// **和 [_ready] 分开，两个都成立才建 WebView。** `_ready` 只说「脚本
  /// 读到了」，它和访客决策是两条独立的异步；只等 `_ready` 的话，脚本先
  /// 回来就会**用盘上那个旧身份把页面打出去**，然后才切到新的 —— 站点
  /// 看到的正是一次「设备指纹变了」，比不换更可疑。这个位置本来就是要
  /// 防住这件事（见 `initState` 里那段顺序说明），只是之前没有东西把
  /// 它落实。
  ///
  /// 决策失败也要置起来（见 [_openWithVisitor] 的 `finally`）：那属于
  /// 「沿用当前身份直开」，不能把页面卡死在一个永远不成立的条件上。
  bool _visitorReady = false;

  /// WebView 控制器。视图建好之前是 null。
  InAppWebViewController? _controller;

  /// [_controller] 是哪一代视图给的。key 跟它不一致 = 视图已重建、
  /// 旧控制器已销毁，别再往它身上导航（见 [controllerOwnsView]）。
  Key? _controllerKey;

  Timer? _verifyTick;
  Timer? _loadMoreTick;
  Timer? _watchdog;

  /// 访客会话。打开页面时决定用哪个出口 + 哪个身份。
  ///
  /// 它读「这个号码上次是谁看的」记忆，有可用记忆就切回那个出口 + 身份。
  /// 站点拒绝时它给出「身份和 IP 一起换」的方案。
  late final VisitorSession _session;

  /// 这个号码的纯数字。访客记忆按它索引。
  late final String _digits;

  @override
  void initState() {
    super.initState();
    _digits = _digitsOf(widget.inboxUrl);
    _session = VisitorSession(
      book: readVisitors(),
      roster: readRoster(),
      currentEgress: () => egress.current,
      egressPool: () => egress.manifest,
      switchEgress: (p) => egress.useProxy(p),
      applyIdentity: applyIdentityProfile,
      mintIdentity: rotateIdentity,
      wipeSiteData: _wipeSite,
    );
    _store.onChanged = _onStoreChanged;
    unawaited(_loadScript());
    _armWatchdog();
    _startVerifyTick();
    // 先把访客决定好、应用上，**再**加载页面。
    //
    // 顺序反了就是「先用旧身份打了站点一次，再换成新的」—— 那一次在
    // 对方眼里是设备指纹变了，比不换更可疑。
    unawaited(_openWithVisitor());
  }

  /// 从收件页地址里取 11 位号码。取不到就返回空串（记忆功能跳过）。
  String _digitsOf(String url) {
    final m = RegExp(r'/numbers/(\d{10,11})').firstMatch(url);
    return m?.group(1) ?? '';
  }

  /// 清站点数据。换身份时必须调。
  ///
  /// 返回 null 表示**清不了**（页面还不存在），不是「清失败」。
  /// 这两件事必须分开：`false` 会让上层说「站点数据没清干净」，而
  /// 真相是这次根本没清 —— 报错文案会把人带到错误的排查方向。
  ///
  /// 两段一起做，**顺序不能反**：
  ///   1. 页面脚本删 IndexedDB `fus-reader-v1` + localStorage 的 sid
  ///      —— 这是身份的根，必须在页面还活着、还在站点 origin 上时做
  ///   2. 原生接口清 cookie / WebStorage / 缓存 —— 内核层，随时能清
  ///
  /// 先清内核再跑脚本的话，页面可能已经被导航走，脚本就碰不到站点的
  /// IndexedDB 了。
  Future<bool?> _wipeSite() async {
    final c = _controller;
    // 页面还没建（`initState` 阶段、或 WebView 已销毁）→ 清不了。
    // 调用方据此把「待清」记在自己身上（`wipeDeferred` → `_wipeOnLoad`），
    // 等 `_onPageFinished` 补做。**null 和 `false` 是两回事**：null 是
    // 「还没跑」，false 是「跑了但没清掉」—— 上面那段说清了为什么。
    if (c == null) return null;
    var ok = false;
    try {
      final r = await wipeSiteData(c);
      ok = r.identityCleared;
    } catch (_) {
      ok = false;
    }
    await wipeKernelData();
    return ok;
  }

  /// 决定访客 → 应用 → 加载页面。
  ///
  /// 只有这一条路会建 WebView（见 [_visitorReady]）。
  Future<void> _openWithVisitor() async {
    try {
      if (_digits.isEmpty) {
        // 地址里没号码（不该发生）→ 不碰身份，直接开。
        await _applyProxy();
        return;
      }

      VisitPlan plan;
      try {
        // `open` 里已经把「有没有人看过这个号 → 切回当时的 IP + 身份」
        // 判完并应用上了，这里只是把结论读出来报给用户。
        plan = await _session.open(_digits);
      } catch (e) {
        // 访客决策失败不该让页面打不开 —— 那会把「换个身份」这种可选
        // 优化变成硬故障。退回当前出口直开。
        _store.note('访客切换失败（$e），沿用当前出口。');
        await _applyProxy();
        return;
      }

      if (!mounted) return;
      // 把决定说出来。用户需要知道「这一页是哪个 IP 在看的」，
      // 否则他会以为一直是同一个出口。
      _store.note(plan.reason);
      // 逻辑同上：`open` 可能切回了一个旧访客，身份变了就要落盘。
      unawaited(writeProfile());
      // 这一轮没清成站点密钥 → 页面加载完（`_onPageFinished`）补清。
      if (plan.wipeDeferred) _wipeOnLoad = true;
      // 出口变了才重新指桥 —— 没变时重设一次无害，但会打断正在进行的
      // 请求，所以只在真的变了才设。
      await _applyProxy();
    } finally {
      // **一定要放行。** 这一步漏掉的话 WebView 永远不建，页面永远空白，
      // 而且没有任何报错 —— 决策里任何一个没接住的异常都会走到这里。
      if (mounted) setState(() => _visitorReady = true);
    }
  }

  /// 应用当前出口到 WebView。
  ///
  /// 直连时传 0 → 清掉 override，回到系统代理设置。
  Future<void> _applyProxy() async {
    try {
      await applyWebViewProxy(
        egress.choice == ProxyChoice.proxy ? egress.port : 0,
      );
    } catch (e) {
      // 设不上代理不是致命错误 —— 页面照样能开，只是走真实 IP。
      // 但**必须说出来**：用户以为在走代理而实际没有，是这里最坏的失败。
      if (!mounted) return;
      _store.note('代理没设上（$e），这一页走的是本机 IP。');
    }
  }

  @override
  void dispose() {
    _verifyTick?.cancel();
    _loadMoreTick?.cancel();
    _watchdog?.cancel();
    _scroll.dispose();
    _store.onChanged = null;
    super.dispose();
  }

  // ── 接线 ────────────────────────────────────────────────

  /// 状态变了。**唯一**刷界面的地方。
  ///
  /// 顺带做两件「状态驱动的副作用」：
  ///   1. 第一次拿到消息 → 记下「这个号码是这个访客看的」
  ///   2. 站点拒绝 → 换身份 + 换 IP
  ///
  /// 放在这里而不是散在回调里：这两件事的触发条件都是「状态变成什么样」，
  /// 而状态只有这一个变化点。散着挂必然漏一处，漏了不报错，只是记忆
  /// 永远写不进去、或者被拒了还在傻等。
  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    _reactToState();
  }

  /// 这次加载完要先清密钥。清完重载一次。
  bool _wipeOnLoad = false;

  /// 正在重置访客。按钮据此禁用，避免连点两次同时换两轮。
  bool _resetting = false;

  /// 上一轮见过的 hold 标识。避免同一份拒绝反复触发轮换。
  String? _lastHoldKey;

  /// 是否已经为这个号码记过「成功」。
  bool _remembered = false;

  void _reactToState() {
    final st = _store.state;

    // ① 拿到消息 → 记一笔。
    if (!_remembered && st.messages.isNotEmpty && _digits.isNotEmpty) {
      _remembered = true;
      _session.onSucceeded(_digits);
      // 身份名册也要落盘 —— 否则重启后「切回当时那个身份」找不到 UA。
      unawaited(writeRoster());
      unawaited(writeVisitors());
      return;
    }

    // ② 站点拒绝 → 换。
    final hold = st.hold;
    if (hold == null) {
      _lastHoldKey = null;
      return;
    }

    // 用 kind + retry 当标识：同一份拒绝重复上报不该反复轮换。
    final key = '${hold.kind}|${hold.retrySeconds}';
    if (key == _lastHoldKey) return;
    _lastHoldKey = key;

    // `503` 是站点自己忙，换什么都没用。
    final temporary = hold.kind == HoldKind.temporary;
    unawaited(_rotateOnHold(temporary: temporary, retry: hold.retrySeconds));
  }

  Future<void> _rotateOnHold({
    required bool temporary,
    required int retry,
  }) async {
    if (_digits.isEmpty) return;
    VisitPlan? plan;
    try {
      plan = await _session.onRejected(
        _digits,
        temporary: temporary,
        retrySeconds: retry,
      );
    } catch (e) {
      _store.note('换访客失败（$e）');
      return;
    }
    unawaited(writeRoster());
    unawaited(writeVisitors());
    unawaited(writeProfile());

    if (!mounted) return;
    if (plan == null) {
      // 站点自己忙 → 什么都不做，只提示。
      _store.note('站点暂时繁忙，等它自己恢复。');
      return;
    }
    _store.note(plan.reason);
    // 出口真的变了才重指桥 —— 不变时重设会打断正在飞的请求。
    await _applyProxy();
    // 换了访客 = 换了个人看这个号，页面必须重开。
    // 不重开的话站点已经按旧身份记了这次访问，再重扫也拿不到东西。
    if (mounted) await _reload();
  }

  /// 用户点了「重置身份并切换 IP」。
  ///
  /// 走的是 [VisitorSession.reset] —— 和「被站点拒绝」**同一条**换人路径，
  /// 不另造一套。区别只在于这次没有站点拒绝，是用户要换。
  ///
  /// 换完必须重开页面：站点已经把这次访问记在当前身份头上了，不重开
  /// 的话新身份根本没被用上。
  Future<void> _resetVisitor() async {
    if (_digits.isEmpty) {
      // 地址里没有号码 → 没有访客这一层可换（记忆也索引不了）。
      // 说出来，别让按钮点了没反应。
      _store.note('这个地址里没有号码，换不了访客。');
      return;
    }
    setState(() => _resetting = true);
    try {
      final plan = await _session.reset(_digits);
      unawaited(writeRoster());
      unawaited(writeVisitors());
      unawaited(writeProfile());
      if (!mounted) return;
      _store.note(plan.reason);
      // 这一轮没清成密钥 → 等页面加载完补清（见 `_onPageFinished`）。
      if (plan.wipeDeferred) _wipeOnLoad = true;
      await _applyProxy();
      // 换了访客 = 换了个人看这个号，页面必须重开。
      if (mounted) await _reload();
    } catch (e) {
      if (mounted) _store.note('重置失败（$e），没换成。');
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  Future<void> _loadScript() async {
    try {
      final text = await rootBundle.loadString('assets/scanner.js');
      if (!mounted) return;
      setState(() {
        _scannerScript = text;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      _store.fail('抓取脚本读不到：$e');
    }
  }

  // ── 三个 Timer ──────────────────────────────────────────

  /// 验证状态机的心跳。
  ///
  /// 只推进状态、不做别的事 —— 判断全在 `VerifyRoundVal` 里。
  void _startVerifyTick() {
    _verifyTick?.cancel();
    // 起算点在这里落定。**不能省** —— 不赋值的话 `_elapsed()` 恒为 0，
    // 于是自动弹层和超时永远不会触发。
    //
    // 只在「这一轮刚开始」时落：已经跑着一轮的时候重进（比如页面加载完
    // 又调一次）不该把等待时间清零，否则用户等了 5 秒又被重置回 0，
    // 永远等不到自动弹层。
    _roundStart ??= DateTime.now();
    _verifyTick = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted) return;
      // 弹层开着时**只查 cookie**，不碰页面。
      //
      // 用户明确要求：跳转过去之后不许自己刷新、不许自己动。
      // 读 cookie 走原生接口，完全不经过页面。
      if (_round.visible) {
        unawaited(_checkPassed());
        return;
      }
      final next = _round.tick(_elapsed());
      if (next.timedOut(window: _verifyWindow)) {
        _verifyTick?.cancel();
        _store.note('站点验证超时，已停止等待。');
        return;
      }
      if (next.shouldAutoPop(after: _autoPopAfter)) {
        _store.note('这个出口卡住了，已把页面放出来让你点一下。');
        setState(() => _round = next.pop(auto: true));
        return;
      }
      setState(() => _round = next);
    });
  }

  /// 这一轮已经等了多久。
  ///
  /// 每次读都重新算 —— 不存字段。存字段的话要记得在每个 tick 更新它，
  /// 漏一处（比如从别的路径进来）就会读到旧值，而症状是「超时不触发」
  /// 或「一进来就超时」，都很难联想到是这里。
  Duration _elapsed() {
    final start = _roundStart;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  /// 这一轮的起算时刻。
  ///
  /// **必须在开新一轮时赋值**，否则 [_elapsed] 恒返回 0，于是
  /// `shouldAutoPop` 和 `timedOut` 永远不会成立 —— 验证弹层既不自动弹、
  /// 也不超时，整套状态机形同虚设。这个坑上一版就踩过（只读不写）。
  DateTime? _roundStart;

  /// 看 `cf_clearance` 到了没。到了就自动收层。
  ///
  /// 判据只认这一个 cookie：它是 Cloudflare **只在真的放行之后**才下发的
  /// 凭证，而且是 HttpOnly（页面 JS 读不到），只有原生接口拿得到。
  /// 靠 DOM 猜（「挑战容器消失了」）在导航栏、广告上都成立，误判过。
  Future<void> _checkPassed() async {
    final c = _controller;
    if (c == null) return;

    // 判据是站点自己的凭证，**不是 cookie**。
    //
    // 站点的会话凭证在 `localStorage` 的 `fus:reader:v1` 里，形状
    // `{sid, until, offset}`，`sid` 是 32 位小写 hex（`reader.js:64`
    // 的正则就是站点自己的判据）。
    //
    // **不能用 `cf_clearance`** —— 站点根本不下发它（`live.js` /
    // `reader.js` 零命中，响应头也没有 Set-Cookie）。上一版拿它当判据，
    // 于是「验证通过」永远检测不到，自动收层永不发生。
    String? raw;
    try {
      raw = await c.evaluateJavascript(
        source: "localStorage.getItem('$kSiteGrantKey')",
      ) as String?;
    } catch (_) {
      return;
    }

    // 判定逻辑在 `core/site_grant.dart`，那里能测；这里只管读。
    if (!isLiveGrant(raw)) return;
    if (!mounted) return;

    setState(() => _round = _round.close());
    _store.note('验证通过，继续加载。');
    await c.reload();
  }

  // ── 看门狗 ──────────────────────────────────────────────

  /// 25 秒还没消息就提示一句。
  ///
  /// 只提示，不重臂 —— 重臂会让它在弹层开着时空转不休眠（旧代码的问题）。
  /// 需要重臂的场景（换身份 / 重载）会显式调 [_armWatchdog]。
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_watchdogAfter, _onWatchdog);
  }

  void _onWatchdog() {
    final st = _store.state;
    // 已经拿到消息、或已经明确失败 → 不需要这条提示。
    if (!mounted || st.messages.isNotEmpty || st.phase == InboxPhase.failed) {
      return;
    }
    // 弹层开着时状态栏被站点页面盖住，这一响没人看得见 —— 留着下次再说。
    if (_round.visible || st.hold != null) return;
    _store.note(st.hits == 0 ? '25 秒没截获到接口响应，可能卡在站点的人机验证。' : '截获到了接口，但里面没有消息。');
  }

  // ── 消息通道 ────────────────────────────────────────────

  void _onMessage(String channel, String payload) {
    _store.ingest(payload);
  }

  // ── 翻页 ────────────────────────────────────────────────

  /// 用户滑到底了。
  Future<void> _loadMore() async {
    final st = _store.state;
    if (st.loadingMore || !st.hasMore) return;

    _store.markLoadingMore();
    _loadMoreTick?.cancel();
    // 兜底：JS 可能因为拿不到号码 id、或注入没生效而一声不吭。
    // 没有这道兜底，底部会一直转圈转到用户杀掉页面。
    _loadMoreTick = Timer(_loadMoreTimeout, () {
      if (!mounted) return;
      _store.endLoadingMore();
      _store.note('翻页超时，稍后再试。');
    });

    try {
      await _controller?.evaluateJavascript(
        source: 'window.__fusScannerApi && window.__fusScannerApi.loadMore();',
      );
    } catch (e) {
      _loadMoreTick?.cancel();
      _store.endLoadingMore();
      _store.note('翻页失败，稍后再试。');
    }
  }

  /// 让抓取层重扫一遍当前页面。
  Future<void> _rescan() async {
    try {
      await _controller?.evaluateJavascript(
        source: 'window.__fusScannerApi && window.__fusScannerApi.rescan();',
      );
    } catch (e) {
      // 页面还没就绪时抛是正常的，不是错误。
    }
  }

  // ── 复制 ────────────────────────────────────────────────

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          // **不把内容贴进提示** —— 复制整条短信时会糊满屏幕底部，
          // 而用户刚刚就看着那条短信。只说「复制了什么」。
          content: Text('已复制$label'),
          duration: const Duration(milliseconds: 1200),
        ),
      );
  }

  // ── 界面 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = _store.state;
    // 这一帧的 key。**整帧共用同一个值** —— `onCreated` 是回调，跑起来时
    // `build` 早结束了，那时再算一次可能已经拿到另一个身份，会把控制器
    // 错记成新一代（于是 `_reload` 的守卫判错方向）。
    final viewKey = _viewKey;

    return Scaffold(
      appBar: _round.visible
          ? null
          : AppBar(
              title: Text(widget.title),
              actions: [
                IconButton(
                  tooltip: '重置身份并切换 IP',
                  onPressed: _resetting ? null : _resetVisitor,
                  icon: const Icon(Icons.swap_horiz),
                ),
                IconButton(
                  tooltip: '重新加载',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
      body: Stack(
        children: [
          // 界面层。铺满，永远可见。
          _body(st, theme),

          // 引擎层。整个页面树里**只有这一个** WebView。
          //
          // 用 Visibility + maintainSize，**不是 Offstage**。
          //
          // Offstage 会让子树不参与布局（尺寸变 0），而这里包的是原生
          // `InAppWebView` —— 它不是 Flutter 绘制的纹理，视口是 0×0 时
          // 页面照样「加载成功」，但什么都画不出来。真机表现就是
          // **打开收件页一片空白**，而 JS 其实在跑、消息其实在抓。
          Positioned.fill(
            child: Visibility(
              visible: _round.visible,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: ColoredBox(
                // 引擎看不见 Flutter 的背景，给个深色免得加载瞬间闪白。
                color: const Color(0xFF10131A),
                child: _ready && _visitorReady
                    ? buildWebView(
                        key: viewKey,
                        userAgent: currentUserAgent,
                        // 首屏地址。**必须给** —— 少了它页面永远不加载，
                        // 详见 `buildWebView` 的注释。
                        initialUrl: widget.inboxUrl,
                        scripts: [
                          // **环境伪装必须排第一。**
                          //
                          // 它要在任何站点脚本之前把 `screen.width`、
                          // `hardwareConcurrency`、时区这些改掉。只设
                          // `userAgent` 的话，站点读到的还是本机真实值，
                          // 和那串 UA 对不上 —— 一眼就是手改的。
                          UserScript(
                            source: identityScript(currentProfile),
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                          // 抓取层紧跟其后。站点自己的脚本一进来就会读
                          // navigator，晚一步就来不及。
                          UserScript(
                            source: _scannerScript,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                        ],
                        events: WebViewEvents(
                          onStarted: _onPageStarted,
                          onFinished: _onPageFinished,
                          onMessage: _onMessage,
                          onError: _onError,
                          allowNavigation: _allowNavigation,
                        ),
                        onCreated: (c) {
                          _controller = c;
                          _controllerKey = viewKey;
                        },
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),

          // 验证界面的标题栏。顶在 SafeArea 上沿。
          if (_round.visible)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _challengeHeader(theme),
            ),

          // 用户自己点开验证时的底栏。
          if (_round.visible && !_round.auto)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _challengeBar(theme),
            ),
        ],
      ),
    );
  }

  Widget _body(InboxState st, ThemeData theme) {
    if (st.messages.isNotEmpty) {
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 快到底了就拉下一页（留 300px 余量，让加载在用户滑到之前开始）。
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 300) {
            unawaited(_loadMore());
          }
          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.only(top: 6, bottom: 24),
          itemCount: st.shown.length + 1,
          itemBuilder: (context, i) {
            if (i == st.shown.length) return _footer(st, theme);
            final m = st.shown[i];
            return MessageCard(
              message: m,
              theme: theme,
              onCopyCode: (c) => _copy(c, '验证码'),
              onCopyAll: (msg) => _copy(msg.text, '整条短信'),
            );
          },
        ),
      );
    }
    return _emptyState(st, theme);
  }

  Widget _footer(InboxState st, ThemeData theme) {
    if (st.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    // 还有没显示出来的 → 先给「显示更多」。
    //
    // 这两个是不同的东西：`visible` 是「本机已收到但还没渲染」，
    // `hasMore` 是「站点那边还有更早的没拉」。混成一个按钮会让用户
    // 点一下以为在翻页，其实只是把已经在本机的几条放出来。
    if (st.hasHidden) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: _store.revealMore,
            icon: const Icon(Icons.expand_more, size: 18),
            label: Text('显示更多（还有 ${st.messages.length - st.visible} 条）'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          st.hasMore ? '滑到底加载更早的消息' : '没有更早的消息了',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 没有消息时显示什么。
  ///
  /// 三种情况分开说 —— 它们的含义和用户能做的事完全不同：
  ///   - 站点拒绝 → 说清是哪种拒绝、要不要换号
  ///   - 我们这边失败 → 说清原因、给重试按钮
  ///   - 在等 → 转圈 + 状态栏那行字
  Widget _emptyState(InboxState st, ThemeData theme) {
    final scheme = theme.colorScheme;
    final hold = st.hold;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hold != null) ...[
              Icon(
                switch (hold.kind) {
                  HoldKind.quota => Icons.hourglass_disabled,
                  HoldKind.challenge => Icons.shield_outlined,
                  HoldKind.temporary => Icons.cloud_queue,
                },
                size: 40,
                color: scheme.tertiary,
              ),
              const SizedBox(height: 14),
              Text(
                hold.title.isNotEmpty ? hold.title : _holdTitle(hold.kind),
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (hold.message.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  hold.message,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ] else if (st.phase == InboxPhase.failed) ...[
              Icon(Icons.cloud_off, size: 40, color: scheme.error),
              const SizedBox(height: 14),
              Text(
                st.error,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ] else ...[
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              st.status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                if (st.phase == InboxPhase.failed)
                  FilledButton.tonalIcon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                if (hold?.kind == HoldKind.challenge)
                  FilledButton.tonalIcon(
                    onPressed: () => _openChallenge(auto: false),
                    icon: const Icon(Icons.shield_outlined, size: 18),
                    label: const Text('自己过验证'),
                  ),
                TextButton(onPressed: _rescan, child: const Text('再扫一次')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _holdTitle(HoldKind kind) => switch (kind) {
    HoldKind.quota => '这个出口的额度用完了',
    HoldKind.challenge => '需要先过人机验证',
    HoldKind.temporary => '站点这会儿有点忙',
  };

  /// 验证界面的标题栏。
  ///
  /// 自动弹和用户自己点，副标题不一样 —— 前者要告诉他「过完会自动继续」，
  /// 后者要告诉他「过完点按钮」。
  Widget _challengeHeader(ThemeData theme) => Material(
    color: theme.colorScheme.surface,
    elevation: 2,
    child: SafeArea(
      bottom: false,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 4),
            IconButton(
              tooltip: '关闭验证',
              onPressed: _closeChallenge,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('完成人机验证', style: theme.textTheme.titleMedium),
                  Text(
                    _round.auto
                        ? '这个出口站点要求先过验证。过完会自动继续。'
                        : '在页面里完成验证；过完点底部的「验证好了」。',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    ),
  );

  Widget _challengeBar(ThemeData theme) => Material(
    color: theme.colorScheme.surfaceContainerHigh,
    elevation: 4,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '在上面完成验证。过完点「验证好了」。',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: _closeChallenge, child: const Text('收起')),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _confirmChallengeDone,
              child: const Text('验证好了'),
            ),
          ],
        ),
      ),
    ),
  );

  // ── 页面事件 ────────────────────────────────────────────

  /// 页面开始加载。
  ///
  /// 这里**什么都不做**。旧代码在这时注入脚本，而那时 document 还没建好，
  /// 注入必然失败 —— 真正的注入点是 `onDocumentStart`（见 build 里的
  /// `UserScript`），由内核保证在任何页面脚本之前执行。
  void _onPageStarted(String url) {}

  /// 页面加载完。
  ///
  /// 抓取层自己会扫描 + 挂钩（见 `assets/scanner.js` 的 `start()`），
  /// 这里只需要在**第一次**加载完成时把 `_ready` 立起来，让验证驱动器
  /// 开始跑。
  void _onPageFinished(String url) {
    if (!mounted) return;
    if (!_ready) setState(() => _ready = true);

    // 这一轮换过身份但没清成密钥（页面当时还没建）→ 现在补清。
    //
    // **必须在这里清，不能在 `initState`**：那时 WebView 还没建，脚本
    // 无处可跑。而且必须等页面真的在站点 origin 上 —— 只有那时
    // `indexedDB.open('fus-reader-v1')` 才指向站点的库。
    //
    // 清完立刻重载：这一页是用旧密钥加载的，站点可能已经认了旧身份。
    // 不重载的话这次访问算在旧身份头上，白换。
    if (_wipeOnLoad) {
      _wipeOnLoad = false;
      unawaited(() async {
        // 这次页面一定建好了（`_onPageFinished` 已经跑到），所以
        // `_wipeSite` 不该再返回 null。**它要是还返回 null，说明这个
        // 假设错了** —— 那就别假装清过，也别重载（重载只会拿着同一对
        // 旧密钥再来一次），直接把这一页标成失败说出来。
        if (await _wipeSite() == null) {
          _store.fail('换身份后没清成站点密钥（页面状态异常），请重新打开收件页。');
          return;
        }
        // 清干净了才重载 —— 这一页是用旧密钥加载的，站点可能已经认了
        // 旧身份，不重载这次访问算在旧身份头上，白换。
        if (mounted) await _reload();
      }());
      return;
    }

    // 站点「ready」了。
    //
    // `markReady` 返回「是否第一次」，用来决定要不要补一次重扫：
    // 每次都重扫会白白多发请求，完全不管又会漏掉「站点 ready 了但
    // 没推消息」那种情况 —— 那一版就是这么丢消息的。
    final (next, firstTime) = _round.markReady();
    if (next != _round) setState(() => _round = next);
    if (firstTime) {
      // 站点已经就绪但抓取层还没报东西 → 主动要一次。
      // 抓取层自己会在 DOM 稳定后报，这里只是补一发，重复的会被
      // `mergeFrame` 按 id 去重，不会多出消息。
      unawaited(_rescan());
    }
    _startVerifyTick();
  }

  /// 页面加载出错。
  void _onError(WebResourceError e) {
    if (!mounted) return;
    // 安卓给的是 `WebViewClient.ERROR_*`（-1..-16），`description` 是内核
    // 原文（`net::ERR_NAME_NOT_RESOLVED` 这种）。两者都交给
    // `describeLoadFailure`，它先查码表、再按原文关键字猜 —— 直接把
    // 英文原文甩给用户等于什么都没说。
    // `toNativeValue()` 在安卓上返回 `WebViewClient.ERROR_*`（-1..-16），
    // 正是 `describeLoadFailure` 的码表要的；`toValue()` 是跨平台的枚举
    // 名（`HOST_LOOKUP` 这种），码表不认识时按关键字兜底用。
    final f = describeLoadFailure(
      e.type.toNativeValue() ?? -1,
      e.description,
      kind: e.type.toValue(),
    );
    _store.fail('${f.title}：${f.detail}');
  }

  /// 导航闸门：只放行站点自己的域名。
  ///
  /// 通道会把页面发来的 JSON 直接交给状态层，任何第三方页面拿到它都是
  /// 不该有的攻击面。
  bool _allowNavigation(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == widget.allowedHost ||
        host.endsWith('.${widget.allowedHost}');
  }

  // ── 验证界面开关 ────────────────────────────────────────

  /// 打开验证界面。
  ///
  /// [auto] 区分「自动弹」和「用户自己点」——
  /// 自动弹时盯着 `cf_clearance`，它一出现就自己收层；手动点时不自动收
  /// （用户可能只是想顺便看看网页）。
  void _openChallenge({required bool auto}) {
    setState(() => _round = _round.pop(auto: auto));
    if (auto) unawaited(_checkPassed());
  }

  /// 收起验证界面，但继续等站点自己放行。
  void _closeChallenge() {
    setState(() => _round = _round.close());
    _startVerifyTick();
  }

  /// 用户说「我过好了」。
  ///
  /// 和 [_closeChallenge] 的区别：收起是「先退出来」，这个是**断言**
  /// 「我过了」—— 所以立刻重扫一次，站点那边刚放行的话马上就能拿到消息。
  void _confirmChallengeDone() {
    setState(() => _round = _round.close());
    _rescan();
    _startVerifyTick();
  }

  // ── 重新加载 ────────────────────────────────────────────

  Future<void> _reload() async {
    _verifyTick?.cancel();
    _loadMoreTick?.cancel();
    _store.reset();
    // 重载 = 新的一轮。起算点和验证闸门都要重来，否则旧的 `_roundStart`
    // 会让「已经等了 80 秒」这个判断在刚重载的页面上立刻成立，一进来
    // 就判超时。
    _roundStart = null;
    _round = _round.restart();
    // 换了页面 = 新的一次访问，成功记录要重新挣。
    _remembered = false;
    // 视图已经因为换身份重建过 → 旧控制器早被销毁。往它身上 `loadUrl`
    // 会抛 `used after being disposed`，被下面 catch 成一条**假**的
    // 「重新加载失败」。而且没必要：新视图创建时就带着 `initialUrl`，
    // 它自己会加载。
    if (!controllerOwnsView(controllerKey: _controllerKey, viewKey: _viewKey)) {
      _armWatchdog();
      _startVerifyTick();
      return;
    }
    try {
      await _controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri(widget.inboxUrl)),
      );
    } catch (e) {
      _store.note('重新加载失败，请再点一次。');
    }
    _armWatchdog();
    _startVerifyTick();
  }
}
