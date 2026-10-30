/// 把「记忆」「出口」「身份名册」三样接起来，回答一个问题：
///
/// **打开这个号码，该用哪个 IP + 哪个身份？**
///
/// ## 三条规则（用户定的，不是我从站点推的）
///
/// 1. **不限制一个身份能看几个号。** 看得动就一直看。这里没有任何计数、
///    没有配额、没有「已用 N 个」的账 —— 站点也从不告诉你还剩几个。
/// 2. **身份不可用就重置身份 + 切换 IP。** 两样都换，不挑。
///    只换一半等于在同一个宽带后面换个马甲，站点看到的还是同一个访客。
/// 3. **号码有记忆就切回去。** 这个号码上次是谁看的，就用那个
///    IP + 那个身份 —— 因为「这个号在某个访客手里能看」这件事已经验过了。
///
/// ## 为什么规则 2 不「智能判断」
///
/// `VisitorBook.plan()` 里那套「出口可疑就只换出口」的推断是**多余的聪明**。
/// 它靠的是「这个出口下别的身份也被拒过」这种间接证据，而站点从不说
/// 到底是哪一半的问题 —— 猜错了一半就是白换一次，还得再来一轮。
/// 两样一起换的代价只是多换一次出口，收益是**一次就能成**。
///
/// 所以这里直接覆盖：**拒绝就两样都换**。`plan()` 留作诊断用
/// （界面可以说「这次是出口的问题」），不参与决策。
library;

import 'dart:math';

import 'identity_profile.dart';
import 'identity_roster.dart';
import 'proxy_config.dart';
import 'visitor.dart';

/// 一次「该用谁」的结论。
class const VisitPlan({
  required this.egress,
  required this.identityId,
  required this.identityUa,
  required this.reused,
  required this.reason,
  required this.wipeDeferred,
}) {
  /// 要用的出口。null = 直连（没有代理可用）。
  final ProxyConfig? egress;

  /// 要用的身份 id。
  final String identityId;

  /// 要用的 UA 串（由 id 还原，或新造的）。
  final String identityUa;

  /// 这个号码有历史记录、且这次就是照它切回去的。
  final bool reused;

  /// 一句人话，给状态栏用。
  final String reason;

  /// **这次的清库没做成**（页面还没建），要等页面加载完补一次。
  ///
  /// 由调用方落实 —— 只有它知道页面什么时候真的在了。收件箱拿到真就
  /// 在 `_onPageFinished` 里清一次再重载。**不能省**：这一轮要是换个
  /// 身份又不清密钥，站点看到的是「新 UA + 旧密钥」，比不换更可疑。
  final bool wipeDeferred;

  Visitor get visitor =>
      Visitor(egressId: egress?.id ?? '', identityId: identityId);
}

/// 访客会话。
///
/// 所有外部依赖都是注入的：出口池、切出口、换身份。这样 `test/` 下
/// 能用一个假的出口池跑完整流程，而不用真的起桥、真的发请求。
class VisitorSession({
  /// 号码 ↔ 访客记忆 + 出口↔身份绑定。纯逻辑。
  required this.book,

  /// 身份 id ↔ UA 还原表。
  required this.roster,

  /// 当前出口。null = 直连。
  required this.currentEgress,

  /// 可用的出口池。挑新出口时从这里取。
  required this.egressPool,

  /// 切到一条出口。返回是否成功（桥起不来就是 false）。
  required this.switchEgress,

  /// 把一整套身份应用到 WebView（下次加载生效）。
  ///
  /// **收整份画像，不收一串 UA。** 只设 UA 而屏幕、时区、Client Hints
  /// 还是当前这台机器的，等于「换了一半」—— 站点一对比就知道。
  required this.applyIdentity,

  /// 新造一个身份（整组环境一起换）。返回完整画像。
  required this.mintIdentity,

  /// **清站点数据**。换身份时必须调它，否则等于没换。
  ///
  /// 站点认人的根是一对存在 IndexedDB 里的 P-256 密钥（实测确认：
  /// 每个新密钥都要单独过 Cloudflare Turnstile 才能拿 sid）。UA 换了
  /// 但密钥还在，站点看到的还是同一个人。
  ///
  /// 返回是否清干净。清不干净要说出来 —— 那意味着这次「换身份」
  /// 只是换了张脸，用户该知道。
  ///
  /// **返回 null 表示「没清成」**（页面还没建，脚本无处可跑）。和
  /// `false` 分开只因为原因不同：`false` 是脚本跑了但没清掉，`null`
  /// 是根本没跑。对用户是同一件事 —— 这轮没清掉，别当成干净了。
  required this.wipeSiteData,

  /// 取当前时间。注入是为了能测过期。
  this.clock = DateTime.now,

  /// 生成随机数。注入是为了「挑哪条出口」可复现。
  this.random,
}) {
  final VisitorBook book;
  final IdentityRoster roster;
  final ProxyConfig? Function() currentEgress;
  final List<ProxyConfig> Function() egressPool;
  final Future<bool> Function(ProxyConfig) switchEgress;
  final void Function(IdentityProfile p) applyIdentity;
  final IdentityProfile Function() mintIdentity;
  final Future<bool?> Function() wipeSiteData;
  final DateTime Function() clock;
  final Random? random;

  /// 上一次真正应用过的访客。null = 还没决定过。
  Visitor? _current;

  /// 当前访客。界面显示「正在用哪个 IP + 哪个身份」用。
  Visitor? get current => _current;

  /// 决定「打开这个号码该用谁」，并**立刻把它应用上**。
  ///
  /// 顺序：
  ///   1. 这个号码有记忆，且那个访客现在没被拒 → 切回那个（规则 3）
  ///   2. 当前访客还能用 → 就用当前的（没有记忆时的默认）
  ///   3. 都不行 → 换：**身份和出口一起换**（规则 2）
  Future<VisitPlan> open(String digits) async {
    final now = clock();

    // ① 号码记忆。这是用户最在意的那条：「有 IP 看过就切回它当时用的」。
    final remembered = book.visitorFor(digits, now);
    if (remembered != null &&
        book.usable(remembered.egressId, remembered.identityId, now)) {
      final applied = await _applyRemembered(remembered);
      if (applied != null) return applied;
      // 切不过去（那条出口已经不在池里了）→ 落到下面，当作没记忆。
      book.forgetNumber(digits);
    }

    // ② 当前访客还能用就用它 —— 没有记忆时这是最省事的一条：
    //    不换出口就不用重新握手，站点也不会看到「IP 突然变了」。
    final cur = _current;
    if (cur != null && book.usable(cur.egressId, cur.identityId, now)) {
      final eg = _findEgress(cur.egressId);
      if (eg != null) {
        final prof = roster.profileOf(cur.identityId);
        if (prof != null) {
          applyIdentity(prof);
          return VisitPlan(
            egress: eg,
            identityId: cur.identityId,
            identityUa: prof.userAgent,
            reused: true,
            reason: '这个号码没有记录，沿用当前出口 + 身份',
            // 沿用当前访客 = 没换身份，密钥本来就是这个人的，不用清。
            wipeDeferred: false,
          );
        }
      }
    }

    // ③ 换。两样一起。
    return _rotateBoth(reason: '当前出口或身份不可用，两样都换');
  }

  /// 站点拒绝了。**重置身份 + 切换 IP**，两样都做。
  ///
  /// [temporary] 为真（`503 unavailable`）时**什么都不做** —— 那是站点
  /// 自己忙，换什么都没用，换了只是白烧一条出口。这个判断由调用方给，
  /// 因为它读的是响应头。
  Future<VisitPlan?> onRejected(
    String digits, {
    required bool temporary,
    int retrySeconds = 0,
  }) async {
    final cur = _current;
    final now = clock();
    if (cur != null) {
      // 记一笔，之后 `usable()` 会挡住这条组合一段时间。
      book.block(
        cur.egressId,
        cur.identityId,
        now,
        temporary: temporary,
        retrySeconds: retrySeconds,
      );
    }
    if (temporary) return null;

    // 站点说这个号不行了 → 记忆作废，别下次还照着它切回去。
    book.forgetNumber(digits);

    return _rotateBoth(reason: '被站点拒绝，重置身份并切换 IP');
  }

  /// 用户手动点了「重置身份 + 切换 IP」。
  ///
  /// 和 [onRejected] 走**同一条**换人路径（换身份 → 换出口 → 清密钥），
  /// 唯一的区别是**没有站点拒绝这回事** —— 当前这一对其实还能用，只是
  /// 用户要换。
  ///
  /// [VisitorBook.block] 那一步不是为了让 [open] 绕开「当前还能用就用
  /// 它」那条路（`_rotateBoth` 本来就会把 `_current` 换掉，已经换的
  /// 组合不会被再选一次）。它真正的作用是 `block` 内部的记忆清理
  /// （`visitor.dart:205`）：**被换掉的那个身份，它在其它号码上的记忆
  /// 也一并作废**。留着的话，用户重置完再点开另一个号，又会照着一份
  /// 已经被判定不可信的记忆，切回刚被换掉的那个身份。
  ///
  /// 号码记忆也要清：用户要的是「换个人看这个号」，留着记忆会让下一次
  /// 打开又切回刚才那一对。
  Future<VisitPlan> reset(String digits) async {
    final cur = _current;
    if (cur != null) {
      book.block(cur.egressId, cur.identityId, clock(), temporary: false);
    }
    book.forgetNumber(digits);
    return _rotateBoth(reason: '已重置：身份和 IP 都换了');
  }

  /// 这次拿到了消息 → 记下来，下次打开同一个号直接用这一对。
  void onSucceeded(String digits) {
    final cur = _current;
    if (cur == null || digits.isEmpty) return;
    final now = clock();
    book.rememberGood(digits, cur, now);
    // 绑定也要落 —— 保证「一个出口只绑一个身份」这条不变量不被破坏。
    book.bind(cur.egressId, cur.identityId);
  }

  // ── 内部 ────────────────────────────────────────────────

  /// 按记忆切回去。切不动返回 null。
  Future<VisitPlan?> _applyRemembered(Visitor v) async {
    final eg = _findEgress(v.egressId);
    if (eg == null) return null;
    final prof = roster.profileOf(v.identityId);
    if (prof == null) return null;

    // **顺序：清库 → 身份 → 出口。** 和 [_rotateBoth] 完全一致。
    //
    // 清库必须在**页面还活着**时做 —— 脚本要在站点 origin 上跑才碰得到
    // IndexedDB。`applyIdentity` 是纯内存 setter（`user_agent.dart:230-238`），
    // `switchEgress` 只动桥（`egress.dart:116-132`），两者都不导航；
    // 真正导航的 `_reload` 在调用方拿到结果之后才跑。所以清库这一步
    // 放在最前，两种顺序对脚本都没影响，统一只是为了两处不会漂。
    //
    // **切回去也要清站点数据。**
    //
    // 直觉上「切回旧身份」不该清东西 —— 但 IndexedDB 里现在那对密钥
    // 是**上一个**身份留下的。不清就切回去，站点会看到「旧 UA + 别人的
    // 密钥」，那是两种身份混在一起，比全新身份更可疑。
    //
    // 清完之后这个身份下次要重新过一遍 Turnstile，代价是慢一点；
    // 不清的代价是身份对不上。
    //
    // 清不了就把「待清」顶回调用方（`wipeDeferred`），让它在页面加载完
    // 之后补 —— 这里不把结果说进 reason，切回旧身份本来就慢一点，
    // 用户已经知道。
    final cleared = await wipeSiteData();

    applyIdentity(prof);

    final ok = await switchEgress(eg);
    if (!ok) return null;

    _current = v;
    return VisitPlan(
      egress: eg,
      identityId: v.identityId,
      identityUa: prof.userAgent,
      reused: true,
      reason: '这个号码之前就是用这个出口 + 身份看的，已切回',
      wipeDeferred: cleared == null,
    );
  }

  /// 身份和出口一起换。
  Future<VisitPlan> _rotateBoth({required String reason}) async {
    final now = clock();

    // 身份：造一个新的，**整份**记进名册（下次要能还原屏幕和时区）。
    final prof = mintIdentity();
    final identityId = roster.remember(prof);

    // 出口：从池里挑一条没被拒的。
    final eg = _pickEgress(identityId, now);

    // 清站点数据。**顺序：清库 → 身份 → 出口**，和 [_applyRemembered] 一致。
    //
    // 清库放最前是因为脚本要在**还活着的站点页面**上跑。这一段里没有
    // 任何东西会导航 —— `applyIdentity` 是纯内存 setter
    // （`user_agent.dart:230-238`），`switchEgress` 只动桥
    // （`egress.dart:116-132`）—— 真正导航的 `_reload` 在调用方拿到结果
    // 之后才跑。所以两种顺序对脚本都没影响，统一成一条只为两处不漂。
    //
    // `cleared` 可能是 null（页面还没建，清不了）—— 那不是失败，是
    // 「这轮还没清」。**把这件事顶回调用方**（`wipeDeferred`），让它
    // 在页面加载完之后补清。不写盘：那是调用方自己的事，盘子里的
    // 标记一多，谁消费谁清理就得靠对账。
    final cleared = await wipeSiteData();

    applyIdentity(prof);
    if (eg != null) await switchEgress(eg);

    final plan = VisitPlan(
      egress: eg,
      identityId: identityId,
      identityUa: prof.userAgent,
      reused: false,
      reason: _reasonOf(reason, eg: eg, cleared: cleared),
      wipeDeferred: cleared == null,
    );
    _current = plan.visitor;
    return plan;
  }

  /// 把这一轮做了什么说成人话。
  ///
  /// 三种「没做到位」都要说出来，不能笼统报成功：
  ///   - 没换成 IP（池里没有别的）
  ///   - 站点数据没清干净（密钥还在 = 身份没真的换）
  /// [cleared] 为 null 表示「清不了」（页面还没建），**不是清失败** ——
  /// 那会说「页面加载完立刻清」，而不是「没清干净」把人带偏。
  String _reasonOf(String base, {ProxyConfig? eg, bool? cleared}) {
    final notes = <String>[];
    if (eg == null) notes.add('没有别的出口可用，只换了身份');
    if (cleared == false) notes.add('站点数据没清干净，身份可能没真换');
    if (cleared == null) notes.add('页面还没建，加载完会立刻清掉旧密钥');
    if (notes.isEmpty) return base;
    return '$base；${notes.join('；')}';
  }

  /// 挑一条现在没被拒的出口。
  ///
  /// 优先挑**这个身份还没被拒过**的：身份是新的，理论上哪条都能用，
  /// 但同一个出口上如果最近刚拒过一个身份，说明那条 IP 可能被盯上了。
  /// 全都不能挑时返回 null —— 调用方只换身份，并且要说出来。
  ProxyConfig? _pickEgress(String identityId, DateTime now) {
    final pool = egressPool();
    if (pool.isEmpty) return null;

    final curId = currentEgress()?.id;
    final usable = <ProxyConfig>[];
    final fallback = <ProxyConfig>[];
    for (final p in pool) {
      if (p.id == curId) continue; // 要换 IP，当前这条先排除
      if (book.usable(p.id, identityId, now)) {
        usable.add(p);
      } else {
        fallback.add(p);
      }
    }
    // 一条都不剩时**返回 null**，不退回去用当前那条。
    //
    // 退回当前那条的后果：调用方拿到一个非 null 的出口，以为「IP 换了」，
    // 而实际上还是同一条 —— 身份换了、IP 没换，站点看到「同一 IP 换人」，
    // 那比不换更可疑。返回 null 让调用方把「没换成 IP」说出来。
    if (usable.isEmpty) return null;
    return usable[random?.nextInt(usable.length) ?? 0];
  }

  /// 在池里按 id 找回一条出口。
  ///
  /// 池里没有 = 清单更新过、这条下架了。返回 null，调用方当作没记忆。
  ProxyConfig? _findEgress(String id) {
    if (id.isEmpty) return currentEgress();
    for (final p in egressPool()) {
      if (p.id == id) return p;
    }
    return null;
  }
}
