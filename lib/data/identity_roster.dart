/// 身份名册：记住「身份 id」和它当时那**整套环境**。
///
/// ## 为什么不能只存 UA
///
/// 一个身份在站点眼里不是一串 UA，是一组互相印证的值：UA、Client Hints、
/// 屏幕尺寸、CPU 核数、内存、语言、时区。只还原 UA 而屏幕还是当前那块，
/// 等于「换了一半」—— 站点一对比 `screen.width` 就知道这不是同一个人。
///
/// 所以名册存的是完整画像（`IdentityProfile`），不是字符串。
///
/// ## id 由什么算
///
/// 由**画像的规范串**算，不是单看 UA。两个身份可能碰巧有一样的 UA
/// （机型池不大，重复很正常），但屏幕或时区不同 —— 那仍然是两个人。
///
/// 用 `String.hashCode` 不行：它在不同 Dart 版本、不同进程之间不保证
/// 相同。而这份 id 要写进磁盘、跨重启读回来，算法一变旧记录就全指向
/// 不存在的身份。所以用 FNV-1a 自己算，算法写死在代码里。
library;

import 'dart:convert';

import 'identity_profile.dart';

/// 名册最多留几个身份。
///
/// 有上限是因为它只增不减：每次换身份都加一条。不设上限的话，一天换
/// 几十次、跑几个月，这份表会一直涨，而读它要反序列化整个 JSON。
/// 40 条足够覆盖「最近用过的那些」。
const kIdentityRosterCap = 40;

/// 身份 id：画像规范串的 FNV-1a 32 位摘要，小写十六进制。
///
/// 只取 32 位是够用的：这里只需要「同一画像算出同一个 id、不同画像
/// 极大概率不同」。它不是密码学哈希，也不承担安全职责 —— 它只是个
/// 标签，撞了也只是两条记录合并。
String identityDigest(IdentityProfile p) {
  final canonical = jsonEncode(p.toJson());
  var h = 0x811c9dc5;
  for (final unit in canonical.codeUnits) {
    h ^= unit & 0xff;
    // 0x01000193 是 FNV 素数。Dart 的 int 是任意精度，但这里要 32 位
    // 环绕 —— 所以每步都截回 32 位。
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// 一张画像还原表。
///
/// 纯数据，不碰磁盘也不碰网络 —— 序列化交给调用方。
class IdentityRoster() {
  /// id → 画像。用插入序判「哪条最旧」。
  final Map<String, IdentityProfile> _byId = {};

  /// 记一个身份，返回它的 id。
  ///
  /// 已经在名册里的会**移到末尾**（刷新「最近用过」的顺序），
  /// 这样淘汰时丢的是真的最久没用的那条。
  String remember(IdentityProfile p) {
    final id = identityDigest(p);
    _byId.remove(id);
    _byId[id] = p;
    while (_byId.length > kIdentityRosterCap) {
      _byId.remove(_byId.keys.first);
    }
    return id;
  }

  /// 还原一个身份。没记过返回 null。
  IdentityProfile? profileOf(String id) => _byId[id];

  /// 还原那串 UA。**只给「只需要 UA 的地方」用** —— 比如 WebView 的
  /// UA 设置。真正切身份要走 [profileOf]，否则屏幕、时区不会跟着还原。
  String? uaOf(String id) => _byId[id]?.userAgent;

  /// 名册里有几条。
  int get length => _byId.length;

  /// 所有 id，从最久没用到最近用过。
  List<String> get ids => List<String>.unmodifiable(_byId.keys);

  /// 导出成可以直接落盘的形状。
  Map<String, Object?> toMap() => {
    for (final e in _byId.entries) e.key: e.value.toJson(),
  };

  /// 从磁盘形状恢复。
  ///
  /// **坏的条目跳过，不让整份作废。** 少一条只会让某个号码下次换新身份，
  /// 而整份读不出来会让所有记忆失效。
  ///
  /// 存的是嵌套 JSON（id → 画像对象），不是 id → 字符串。
  void restore(Object? raw) {
    _byId.clear();
    if (raw is! Map) return;
    raw.forEach((id, value) {
      if (id is! String || id.isEmpty) return;
      final p = IdentityProfile.fromJson(value);
      if (p == null) return;
      // 按画像重算 id，不信磁盘上那个 —— 旧摘要算法留下的 id 会让
      // 「切回这个身份」切到一个对不上的画像上。
      _byId[identityDigest(p)] = p;
    });
    while (_byId.length > kIdentityRosterCap) {
      _byId.remove(_byId.keys.first);
    }
  }
}
