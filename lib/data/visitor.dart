/// 号码 ↔ 访客（出口 IP + 浏览器身份）的记忆。
///
/// ## 站点怎么认人
///
/// 按 **IP + 浏览器身份** 一起判。只换 IP 而身份不变，还是同一个人；
/// 只换身份而 IP 不变，也还是同一个人。两样都换才是另一个访客。
///
/// ## 这份记忆要解决什么
///
/// **一个号码在某个访客手里是能看的**，换一个访客可能就看不到了。
/// 所以「哪个访客看过这个号」值得记下来：再次打开同一个号时，
/// 直接用当时那个访客，而不是随便挑一个去试。
///
/// 这不是配额，是**缓存**。记的是「这个组合在这个号上成功过」，
/// 不是「这个身份已经看了几个号」——
/// **不限制一个身份能看几个号**，看得动就一直看。
///
/// ## 两条不变量
///
/// 1. **一个出口只绑一个身份。** 同一个 IP 上出现两个不同身份，
///    是站点眼里最扎眼的信号：真实用户不会前脚一台设备、后脚换另一台。
/// 2. **身份不可用就换掉。** 站点拒绝（`X-Fair-Use`）说明这个身份
///    在当前 IP 上不行了 —— 重置身份，并切到另一个 IP。
///
/// 这两条不是从别处抄的，是从站点自己的信号推出来的：
///   live.js:847 `const marker=response.headers.get('X-Fair-Use');`
///   配合状态码：`429+pause` / `503+unavailable` / `403+challenge`
///   live.js:353 `const retry=response.headers.get('Retry-After'),...`
///
/// 站点**从不告诉你还剩几个号**（没有用量字段，也没有配额数），
/// 所以这里也不记用量 —— 记的是「谁在这个号上成功过」和「谁被拒过」。
library;

/// 一个访客 = 出口 + 身份。
class const Visitor({
  /// 出口标识（`ProxyConfig.id`，`scheme://host:port`，不含密码）。
  required this.egressId,

  /// 身份标识（UA 的稳定摘要，不含完整 UA）。
  required this.identityId,
}) {
  final String egressId;
  final String identityId;

  String get key => '$egressId|$identityId';

  @override
  bool operator ==(Object other) =>
      other is Visitor &&
      other.egressId == egressId &&
      other.identityId == identityId;

  @override
  int get hashCode => Object.hash(egressId, identityId);

  @override
  String toString() => 'Visitor($egressId, $identityId)';
}

/// 号码 ↔ 访客的记忆，加上出口↔身份的一对一绑定。
///
/// 纯数据 + 纯判断：不碰网络、不碰存储、不碰界面。可以拿假时间直接测。
class VisitorBook() {
  /// 号码 → 最近一次成功看过它的访客。
  ///
  /// 键是号码的纯数字串（站点 URL 里那串）。值带一个时间戳：
  /// 太久以前的记录不一定还成立（站点那边的状态会变），
  /// 由调用方决定多久算过期（[memoryTtl]）。
  final Map<String, _Hit> _hits = {};

  /// 出口 → 绑在它上面的身份。一对一。
  final Map<String, String> _boundIdentity = {};

  /// 身份 → 绑在哪个出口。反向索引，保证一对一。
  final Map<String, String> _boundEgress = {};

  /// 被拒过的组合 → 解禁时刻。
  final Map<String, DateTime> _blockedUntil = {};

  /// 号码记忆多久算过期。超过这个时长的记录不再当依据。
  ///
  /// 由调用方定：站点那边的「这个号还能不能看」会随时间变
  /// （号码被回收、被占满、站点改策略）。拿一个陈年记录去套，
  /// 比没有记录更糟 —— 它会让用户以为「这次一定行」。
  Duration memoryTtl = const Duration(hours: 6);

  /// 站点没给 `Retry-After` 时等多久。由调用方按换线开销定。
  Duration fallbackWait = const Duration(seconds: 30);

  // ── 号码记忆 ────────────────────────────────────────────

  /// 这个号码上次是被哪个访客成功看过的。没有记录或过期返回 null。
  Visitor? visitorFor(String numberDigits, DateTime now) {
    final hit = _hits[numberDigits];
    if (hit == null) return null;
    if (now.difference(hit.at) > memoryTtl) {
      _hits.remove(numberDigits);
      return null;
    }
    return Visitor(egressId: hit.egressId, identityId: hit.identityId);
  }

  /// 记下「这个号码在这个访客手里成功过」。
  ///
  /// 同一个号码有新记录就覆盖旧的 —— 只留最近一次，
  /// 因为站点的状态会变，旧记录的价值低于新记录。
  void rememberGood(String numberDigits, Visitor v, DateTime now) {
    if (numberDigits.isEmpty) return;
    _hits[numberDigits] = _Hit(
      egressId: v.egressId,
      identityId: v.identityId,
      at: now,
    );
  }

  /// 忘掉这个号码的记录（比如它已经不可用了）。
  void forgetNumber(String numberDigits) => _hits.remove(numberDigits);

  /// 记着几个号码。排查用。
  int get rememberedCount => _hits.length;

  // ── 出口 ↔ 身份 ─────────────────────────────────────────

  /// 这个出口现在绑着哪个身份。没绑过返回 null。
  String? identityOf(String egressId) => _boundIdentity[egressId];

  /// 这个身份现在绑在哪个出口。没绑过返回 null。
  String? egressOf(String identityId) => _boundEgress[identityId];

  /// 绑一对。返回是否真的改了。
  ///
  /// 出口已有别的身份、或身份已在别的出口上，一律**拒绝**并返回 false。
  /// 调用方必须先解绑 —— 不给「悄悄覆盖」留口子，因为覆盖的后果
  /// 是同一个 IP 上换了身份，而调用方以为自己只是换个绑定。
  bool bind(String egressId, String identityId) {
    final curId = _boundIdentity[egressId];
    final curEg = _boundEgress[identityId];
    if (curId == identityId && curEg == egressId) return false;
    if (curId != null && curId != identityId) return false;
    if (curEg != null && curEg != egressId) return false;
    _boundIdentity[egressId] = identityId;
    _boundEgress[identityId] = egressId;
    return true;
  }

  /// 解绑一个出口（连带反向索引和它名下的拒绝记录）。
  void forgetEgress(String egressId) {
    final id = _boundIdentity.remove(egressId);
    if (id != null && _boundEgress[id] == egressId) _boundEgress.remove(id);
    _blockedUntil.removeWhere((k, _) => k.startsWith('$egressId|'));
    // 记忆里用这个出口的那些号码也一起清 —— 出口没了，那些记录没依据了。
    _hits.removeWhere((_, h) => h.egressId == egressId);
  }

  /// 解绑一个身份（连带反向索引和它名下的拒绝记录）。
  void forgetIdentity(String identityId) {
    final eg = _boundEgress.remove(identityId);
    if (eg != null && _boundIdentity[eg] == identityId) {
      _boundIdentity.remove(eg);
    }
    _blockedUntil.removeWhere((k, _) => k.endsWith('|$identityId'));
    _hits.removeWhere((_, h) => h.identityId == identityId);
  }

  /// 绑了几对。排查用。
  int get boundCount => _boundIdentity.length;

  // ── 拒绝记录 ────────────────────────────────────────────

  /// 这个组合现在能不能用。过期的记录顺手删掉。
  bool usable(String egressId, String identityId, DateTime now) {
    final until = _blockedUntil['$egressId|$identityId'];
    if (until == null) return true;
    if (now.isBefore(until)) return false;
    _blockedUntil.remove('$egressId|$identityId');
    return true;
  }

  /// 还要等多久。能用时是 [Duration.zero]。
  Duration waitFor(String egressId, String identityId, DateTime now) {
    final until = _blockedUntil['$egressId|$identityId'];
    if (until == null) return Duration.zero;
    final left = until.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 记一次「这个组合被拒」。
  ///
  /// **临时繁忙不记。** 站点 `503 + unavailable` 是它自己忙，跟这个 IP
  /// 和这个身份都无关 —— 换了也一样，记下来只是白等。另外两态
  /// （`429 + pause` / `403 + challenge`）才是针对「你这个访客」的。
  void block(
    String egressId,
    String identityId,
    DateTime now, {
    required bool temporary,
    int retrySeconds = 0,
  }) {
    if (temporary) return;
    final wait = retrySeconds > 0
        ? Duration(seconds: retrySeconds)
        : fallbackWait;
    _blockedUntil['$egressId|$identityId'] = now.add(wait);
    // 被拒的组合，它在号码记忆里的记录也不再可信 —— 那个号可能已经不可用了。
    _hits.removeWhere(
      (_, h) => h.egressId == egressId && h.identityId == identityId,
    );
  }

  /// 被记着的组合有几条。排查用。
  int get blockedCount => _blockedUntil.length;

  // ── 落盘 ────────────────────────────────────────────────

  /// 导出成能直接落盘的形状。
  ///
  /// 存三样：号码记忆、出口↔身份绑定、拒绝记录。
  ///
  /// **拒绝记录也要存**：它带着解禁时刻，重启后仍然有效。不存的话，
  /// 用户杀掉应用重开就能绕过一次限流，而站点那边照样记得 —— 那只会
  /// 换来一次更快的拒绝。
  Map<String, Object?> toJson() => {
    'hits': {
      for (final e in _hits.entries)
        e.key: [
          e.value.egressId,
          e.value.identityId,
          e.value.at.millisecondsSinceEpoch,
        ],
    },
    'bound': _boundIdentity,
    'blocked': {
      for (final e in _blockedUntil.entries)
        e.key: e.value.millisecondsSinceEpoch,
    },
  };

  /// 从磁盘形状恢复。
  ///
  /// **坏条目跳过，不让整份作废。** 记忆是锦上添花：丢一条只是某个号码
  /// 下次用新身份，而整份读不出来会让所有记忆失效。
  void restore(Object? raw) {
    _hits.clear();
    _boundIdentity.clear();
    _boundEgress.clear();
    _blockedUntil.clear();
    if (raw is! Map) return;

    // 号码记忆。
    final hits = raw['hits'];
    if (hits is Map) {
      hits.forEach((k, v) {
        if (k is! String || k.isEmpty) return;
        if (v is! List || v.length < 3) return;
        final eg = v[0];
        final id = v[1];
        final ms = v[2];
        if (eg is! String || id is! String || ms is! int) return;
        _hits[k] = _Hit(
          egressId: eg,
          identityId: id,
          at: DateTime.fromMillisecondsSinceEpoch(ms),
        );
      });
    }

    // 绑定。**用 bind() 重建**，让一对一这条规则在恢复时也成立 ——
    // 直接写两个 Map 的话，一份被改坏的磁盘数据可以造出「两个出口绑同一个
    // 身份」这种不可能状态，而下游假定它不可能。
    final bound = raw['bound'];
    if (bound is Map) {
      bound.forEach((eg, id) {
        if (eg is! String || id is! String) return;
        bind(eg, id);
      });
    }

    // 拒绝记录。
    final blocked = raw['blocked'];
    if (blocked is Map) {
      blocked.forEach((k, ms) {
        if (k is! String || ms is! int) return;
        _blockedUntil[k] = DateTime.fromMillisecondsSinceEpoch(ms);
      });
    }
  }

  // ── 打开一个号码时用谁 ──────────────────────────────────

  /// 决定「看这个号码该用哪个访客」。
  ///
  /// 顺序：
  /// 1. **这个号码有成功记录，且那个访客现在还能用** → 直接用那个。
  ///    （这就是「检查当前查看的号码有没有 IP 看过，有就切到它当时用的」）
  /// 2. 没有记录 / 记录过期 / 那个访客现在被拒 → 需要换。
  ///    换的时候按 [plan] 判该换哪一半。
  ///
  /// [current] 是当前正在用的访客，可能为 null（还没有绑定）。
  OpenVisitor decide({
    required String numberDigits,
    required Visitor? current,
    required DateTime now,
    required List<String> otherEgresses,
    required List<String> otherIdentities,
  }) {
    // ① 这个号码有成功记录吗？有就直接用那个。
    final remembered = visitorFor(numberDigits, now);
    if (remembered != null &&
        usable(remembered.egressId, remembered.identityId, now)) {
      return OpenVisitor(
        visitor: remembered,
        reuse: true,
        reason: '这个号码之前就是用这个出口 + 身份看的，直接沿用',
      );
    }

    // ② 没有可用记录。如果当前访客还能用，就用当前。
    if (current != null && usable(current.egressId, current.identityId, now)) {
      return OpenVisitor(
        visitor: current,
        reuse: true,
        reason: '这个号码没有历史记录，沿用当前出口 + 身份',
      );
    }

    // ③ 当前访客不可用 → 换。换哪一半由 plan 判。
    final plan = this.plan(
      egressId: current?.egressId ?? '',
      identityId: current?.identityId ?? '',
      now: now,
      otherEgresses: otherEgresses,
      otherIdentities: otherIdentities,
    );
    return OpenVisitor(
      visitor: null,
      reuse: false,
      plan: plan,
      reason: plan.explain(),
    );
  }

  /// 当前访客被拒了，该换哪一半。
  ///
  /// 判据来自「一对一」这条不变量，不需要数用量：
  ///
  /// - **这个出口下还有别的身份被拒过** → 问题在这个 IP，
  ///   换出口更有效（留在同一个 IP 上换身份，站点看到的还是同一个宽带）
  /// - **这个身份在别的出口上也拒过** → 问题在这个身份，换身份更有效
  /// - 两者都不是（只有这一对出问题）→ 两样都换
  RotationPlan plan({
    required String egressId,
    required String identityId,
    required DateTime now,
    required List<String> otherEgresses,
    required List<String> otherIdentities,
  }) {
    final egressSuspect = otherIdentities.any(
      (id) => !usable(egressId, id, now),
    );
    final identitySuspect = otherEgresses.any(
      (e) => !usable(e, identityId, now),
    );

    if (egressSuspect) {
      return RotationPlan(
        switchEgress: otherEgresses.isNotEmpty,
        switchIdentity: identitySuspect && otherIdentities.isNotEmpty,
        egressSuspect: true,
        identitySuspect: identitySuspect,
      );
    }
    if (identitySuspect) {
      return RotationPlan(
        switchEgress: otherEgresses.isNotEmpty,
        switchIdentity: otherIdentities.isNotEmpty,
        egressSuspect: false,
        identitySuspect: true,
      );
    }
    return RotationPlan(
      switchEgress: otherEgresses.isNotEmpty,
      switchIdentity: otherIdentities.isNotEmpty,
      egressSuspect: false,
      identitySuspect: false,
    );
  }
}

/// 号码记忆里的一条。
class const _Hit({
  required this.egressId,
  required this.identityId,
  required this.at,
}) {
  final String egressId;
  final String identityId;
  final DateTime at;
}

/// 「打开这个号码用谁」的结论。
///
/// [reuse] 为真表示 [visitor] 可以直接用；为假表示要按 [plan] 换，
/// 换完之后由调用方自己挑出具体的新访客再调 [VisitorBook.bind]。
class const OpenVisitor({
  required this.visitor,
  required this.reuse,
  required this.reason,
  this.plan,
}) {
  final Visitor? visitor;
  final bool reuse;
  final String reason;
  final RotationPlan? plan;
}

/// 「换什么」的建议。
class const RotationPlan({
  required this.switchEgress,
  required this.switchIdentity,
  required this.egressSuspect,
  required this.identitySuspect,
}) {
  final bool switchEgress;
  final bool switchIdentity;
  final bool egressSuspect;
  final bool identitySuspect;

  bool get isNoop => !switchEgress && !switchIdentity;

  /// 一句人话，给界面用。
  String explain() {
    if (isNoop) return '没有别的出口也没有别的身份可换 —— 只能等站点解禁';
    if (egressSuspect && switchEgress) {
      return identitySuspect && switchIdentity
          ? '这个出口和这个身份都被拒过，两样一起换'
          : '这个出口下别的身份也被拒了，问题在出口，换出口';
    }
    if (identitySuspect && switchIdentity) {
      return '这个身份在别的出口上也被拒了，问题在身份，换身份';
    }
    return '只有这一对组合被拒，两样都换最稳';
  }
}
