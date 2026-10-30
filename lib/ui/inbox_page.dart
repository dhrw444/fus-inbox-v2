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

import '../core/user_agent.dart';
import '../data/egress.dart';
import '../data/inbox_state.dart';
import '../data/inbox_store.dart';
import '../data/verify_round.dart';
import '../main.dart' show egress;
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
  final _key = GlobalKey();

  VerifyRoundVal _round = VerifyRoundVal.fresh;
  String _scannerScript = '';
  bool _ready = false;

  /// WebView 控制器。视图建好之前是 null。
  InAppWebViewController? _controller;

  Timer? _verifyTick;
  Timer? _loadMoreTick;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _store.onChanged = _onStoreChanged;
    unawaited(_loadScript());
    _armWatchdog();
    _startVerifyTick();
    // 把 WebView 的流量指到桥。
    //
    // **这一步必须在页面加载之前** —— 代理是进程级的，页面已经开始
    // 加载时再设，第一个请求已经用真实 IP 发出去了。而且必须在这里做，
    // 不能只依赖首页那次设置：桥可能被重建（换出口），端口变了，
    // 而 `ProxyController` 的 override 还指着旧端口。
    unawaited(_applyProxy());
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
  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
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
  /// 或「一进来就超时」，都很难联想到是这里。旧代码踩过。
  Duration _elapsed() {
    final start = _roundStart;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  DateTime? _roundStart;

  /// 看 `cf_clearance` 到了没。到了就自动收层。
  ///
  /// 判据只认这一个 cookie：它是 Cloudflare **只在真的放行之后**才下发的
  /// 凭证，而且是 HttpOnly（页面 JS 读不到），只有原生接口拿得到。
  /// 靠 DOM 猜（「挑战容器消失了」）在导航栏、广告上都成立，误判过。
  Future<void> _checkPassed() async {
    final c = _controller;
    if (c == null) return;
    List<Cookie> cookies;
    try {
      final jar = CookieManager.instance();
      cookies = await jar.getCookies(url: WebUri(widget.inboxUrl));
    } catch (_) {
      return;
    }
    final passed = cookies.any(
      // `Cookie.value` 的类型是 `dynamic`（平台层返回的原始值），
      // 直接 `?? ''` 得到的还是 `dynamic` —— `&&` 的操作数不是 bool，
      // analyzer 会判 `non_bool_operand`。显式转一次字符串。
      (e) => e.name == 'cf_clearance' && (e.value?.toString() ?? '').isNotEmpty,
    );
    if (!passed || !mounted) return;
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

    return Scaffold(
      appBar: _round.visible
          ? null
          : AppBar(
              title: Text(widget.title),
              actions: [
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
                child: _ready
                    ? buildWebView(
                        key: _key,
                        userAgent: currentUserAgent,
                        scripts: [
                          // 抓取层必须在**任何页面脚本之前**装好 ——
                          // 站点自己的脚本一进来就会读 navigator。
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
                        onCreated: (c) => _controller = c,
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
    _startVerifyTick();
  }

  /// 页面加载出错。
  void _onError(WebResourceError e) {
    if (!mounted) return;
    _store.fail(e.description.isEmpty ? '页面加载失败' : e.description);
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
