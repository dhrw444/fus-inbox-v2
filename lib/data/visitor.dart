import 'inbox_state.dart';

/// 一个「访客」= 出口 + 身份。
///
/// 站点把配额记在这个二元组上，换掉任何一半都还是同一个人。
///
/// 依据来自代码行为，不是注释：
/// - 撞 `pause` / `challenge` 时，旧版换出口之后**紧接着**重置身份
///   [src:fus-final/lib/features/inbox/application/identity_rotator.dart
///    _rotateToNextProxy 调用 _rotateIdentityBody]
/// - 站点只给 `X-Fair-Use` + `Retry-After`，不给「还剩几个」
///   [src:fus2/assets/scanner.js readHold]
class const VisitorKey({required this.egressId, required this.identityId}) {
  /// `ProxyConfig.id`（`scheme://host:port`，不含密码）。
  final String egressId;

  /// 当前浏览器身份的稳定标识。
  final String identityId;

  String get key => '$egressId|$identityId';
}

/// 访客冷却表：这个二元组撞过墙之后，到什么时候为止别再碰。
///
/// 纯数据 + 纯判断，不碰网络不碰存储，可以拿假时间直接测。
class VisitorCooldowns({required this.fallbackSeconds}) {
  /// 站点没给 `Retry-After` 时的兜底秒数。
  ///
  /// **这个值必须由调用方给，不写死。** 理由：新版换出口是桥的热切换
  /// [src:fus2/lib/data/egress.dart switchTo]，几乎瞬时，没有旧版那种
  /// 「清数据 + 换 UA + 重载 + 重新验人机」的开销；拿旧版为那个开销定的
  /// 45 秒来兜底，等于给一个不存在的耗时留余量。
  final int fallbackSeconds;

  final Map<String, DateTime> _until = {};

  /// 这个访客现在能不能用。到期的条目顺手删掉，别让表无限长。
  bool isUsable(VisitorKey v, DateTime now) {
    final until = _until[v.key];
    if (until == null) return true;
    if (now.isBefore(until)) return false;
    _until.remove(v.key);
    return true;
  }

  /// 记一次撞墙。
  ///
  /// `temporary` 不记：站点自己说那是「服务端忙」，跟出口和身份都无关
  /// [src:fus2/lib/data/inbox_state.dart HoldKind.temporary]
  void record(VisitorKey v, HoldKind kind, int retrySeconds, DateTime now) {
    if (kind == HoldKind.temporary) return;
    final wait = retrySeconds > 0 ? retrySeconds : fallbackSeconds;
    _until[v.key] = now.add(Duration(seconds: wait));
  }

  /// 换了出口或身份之后，旧二元组的记录就没意义了 —— 顺手清掉，
  /// 免得表里堆一堆再也不会被查到的键。
  void forgetEgress(String egressId) =>
      _until.removeWhere((k, _) => k.startsWith('$egressId|'));

  void forgetIdentity(String identityId) =>
      _until.removeWhere((k, _) => k.endsWith('|$identityId'));
}
