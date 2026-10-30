/// 身份画像：一个「人」在站点眼里是什么样。
///
/// ## 为什么不能只换 UA
///
/// 只换 UA 等于没换。站点认人的依据分三层，从浅到深：
///
/// | 层 | 是什么 | 换 UA 能改吗 |
/// |---|---|---|
/// | 表面 | `User-Agent`、`Sec-CH-UA` 系列 Client Hints | ✅ 能 |
/// | 环境 | 时区、语言、屏幕、`hardwareConcurrency` | ❌ 不能 |
/// | **根** | **IndexedDB 里那对 P-256 ECDSA 密钥** | ❌ 不能 |
///
/// 最深层才是真的。站点自己的 `reader.js` 写得很清楚：
///
/// ```js
/// // reader.js:49
/// const fresh = await crypto.subtle.generateKey(
///   {name:'ECDSA', namedCurve:'P-256'}, false, ['sign','verify']);
/// // reader.js:61
/// async function publicKey(){ ... crypto.subtle.exportKey('jwk', ...) }
/// // reader.js:63
/// async function sign(value){ ... crypto.subtle.sign(...) }
/// ```
///
/// 这对密钥存在 IndexedDB 的 `keys` store 里（`reader.js:3`
/// `DB='fus-reader-v1'`），私钥 `extractable:false` 导不出来。请求靠它签名
/// 换 `sid`，`sid` 又存在 localStorage（`STORE='fus:reader:v1'`）。
///
/// 而且 `reader.js` 的 `currentGrant()` 会校验 `d.keyId === await keyId()`，
/// 其中 `keyId` 是公钥 JWK 的 SHA-256 —— **密钥一换，旧 sid 立刻作废**。
///
/// 所以「换身份」必须同时做三件事：
///
///   1. 换 [IdentityProfile] 里的表面值（UA + Client Hints）
///   2. **删掉 IndexedDB 里的 `fus-reader-v1`**（真正的根）
///   3. 删掉 localStorage 的 `fus:reader:v1`（旧凭证）
///
/// 只做 1 是自欺 —— 站点看到的是同一对密钥，只是换了张脸。
library;

import 'dart:math';

/// 机型 ↔ 安卓版本。**成对**，不能拆开挑 —— `Pixel 7a` 配 `Android 15`
/// 在现实里不存在，站点拿版本和机型对一下就知道是编的。
const _androidModels = <(String, String)>[
  ('Pixel 8 Pro', '14'),
  ('Pixel 7a', '14'),
  ('Pixel 7', '13'),
  ('SM-S918B', '14'),
  ('SM-S911B', '13'),
  ('SM-A546E', '13'),
  ('V2312A', '14'),
  ('CPH2581', '14'),
];

/// 语言 ↔ 时区。同样成对：`en-US` 配 `Asia/Shanghai` 是矛盾的，
/// 而 `Intl.DateTimeFormat()` 一读就露。
///
/// 只用英语区：站点是英文站，一个报 `zh-CN` 的访客反而不像它的用户群。
const _localePairs = <(String, String)>[
  ('en-US', 'America/New_York'),
  ('en-US', 'America/Chicago'),
  ('en-US', 'America/Los_Angeles'),
  ('en-US', 'America/Denver'),
  ('en-GB', 'Europe/London'),
];

/// 屏幕/环境参数。这些站点也能读到（`screen.width` 之类）。
///
/// 不追求「唯一」——目标是**与 UA 自洽**：一个 Pixel 8 Pro 报
/// 412×915，一个桌面 UA 报 1920×1080。自相矛盾比重复更可疑。
class const ScreenProfile({
  required this.width,
  required this.height,
  required this.devicePixelRatio,
}) {
  final int width;
  final int height;
  final double devicePixelRatio;

  /// 常见安卓机（Pixel 8 / 8 Pro / S24 一类）的逻辑分辨率。
  static const phones = [
    ScreenProfile(width: 412, height: 915, devicePixelRatio: 2.625),
    ScreenProfile(width: 411, height: 914, devicePixelRatio: 2.625),
    ScreenProfile(width: 360, height: 800, devicePixelRatio: 3.0),
    ScreenProfile(width: 393, height: 873, devicePixelRatio: 2.75),
    ScreenProfile(width: 384, height: 854, devicePixelRatio: 2.8125),
  ];

  Map<String, Object?> toJson() => {
    'w': width,
    'h': height,
    'dpr': devicePixelRatio,
  };

  static ScreenProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final w = raw['w'];
    final h = raw['h'];
    final d = raw['dpr'];
    if (w is! int || h is! int || d is! num) return null;
    return ScreenProfile(width: w, height: h, devicePixelRatio: d.toDouble());
  }
}

/// 一个身份的完整画像。
class const IdentityProfile({
  required this.userAgent,
  required this.model,
  required this.androidVersion,
  required this.chromeMajor,
  required this.screen,
  required this.language,
  required this.timeZone,
  required this.hardwareConcurrency,
  required this.deviceMemory,
}) {
  /// 完整 UA 串。
  final String userAgent;

  /// 机型（`Build/` 前面那段，或 UA 里的 `SM-xxxx`）。
  final String model;

  /// 安卓版本号（`14`）。
  final String androidVersion;

  /// Chrome 大版本。
  final int chromeMajor;

  /// 屏幕。
  final ScreenProfile screen;

  /// `navigator.language`，如 `en-US`。
  final String language;

  /// `Intl.DateTimeFormat().resolvedOptions().timeZone`，如 `America/New_York`。
  final String timeZone;

  /// `navigator.hardwareConcurrency`。
  final int hardwareConcurrency;

  /// `navigator.deviceMemory`（GB）。
  final int deviceMemory;

  /// `Sec-CH-UA` 的值。
  ///
  /// **必须和 UA 里的 Chrome 大版本一致。** 站点会两边对比，不一致就是
  /// 「这个 UA 是手改的」的直接证据 —— 比任何指纹都更容易被抓。
  String get chUa =>
      '"Chromium";v="$chromeMajor", "Google Chrome";v="$chromeMajor", '
      '"Not-A.Brand";v="24"';

  /// `Sec-CH-UA-Platform`。
  String get chUaPlatform => '"Android"';

  /// `Sec-CH-UA-Platform-Version`，形如 `"14.0.0"`。
  String get chUaPlatformVersion => '"$androidVersion.0.0"';

  /// `Sec-CH-UA-Model`。
  String get chUaModel => '"$model"';

  /// `Sec-CH-UA-Mobile`。
  String get chUaMobile => '?1';

  /// 落盘。**不含密钥** —— 密钥在 IndexedDB 里，不在我们的存储里。
  Map<String, Object?> toJson() => {
    'ua': userAgent,
    'model': model,
    'os': androidVersion,
    'major': chromeMajor,
    'screen': screen.toJson(),
    'lang': language,
    'tz': timeZone,
    'cores': hardwareConcurrency,
    'mem': deviceMemory,
  };

  /// 新造一个身份。
  ///
  /// **整组一起换**，不是只换 UA。理由：站点同时读 UA、Client Hints、
  /// `screen.width`、`hardwareConcurrency`、时区 —— 只换 UA 而屏幕还是
  /// 原来那块、时区还是东八区，等于告诉对方「这个 UA 是手改的」。
  ///
  /// [kernelMajor] 是内核报的真实 Chrome 大版本。新身份的版本在它
  /// ±2 之间 —— 编一个和内核差十代的版本号，比不换更可疑。
  static IdentityProfile mint({
    required int kernelMajor,
    Random? rnd,
  }) {
    final r = rnd ?? Random();

    // 机型 + 安卓版本一起挑：一对自洽的组合。
    final (model, android) = _androidModels[r.nextInt(_androidModels.length)];

    final baseMajor = kernelMajor > 0 ? kernelMajor : 141;
    final major = baseMajor + r.nextInt(5) - 2;
    // 小版本也要真：`Chrome/141.0.7390.122` 这个形状。
    final build = 6000 + r.nextInt(2000);
    final patch = r.nextInt(200);

    final ua =
        'Mozilla/5.0 (Linux; Android $android; $model Build/UQ1A.240205.004) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/$major.0.$build.$patch Mobile Safari/537.36';

    // 屏幕跟机型走：大屏机配大屏，别让 Pixel 8 Pro 报 360×800。
    final screen = ScreenProfile.phones[r.nextInt(ScreenProfile.phones.length)];

    // 时区和语言一起挑：`en-US` 配 `America/New_York` 才自洽。
    final (lang, tz) = _localePairs[r.nextInt(_localePairs.length)];

    return IdentityProfile(
      userAgent: ua,
      model: model,
      androidVersion: android,
      chromeMajor: major,
      screen: screen,
      language: lang,
      timeZone: tz,
      // 8 核 / 8GB 是主流安卓机的常见值。给 2 核 1GB 反而像老旧设备。
      hardwareConcurrency: const [4, 8, 8, 8][r.nextInt(4)],
      deviceMemory: const [4, 8, 8][r.nextInt(3)],
    );
  }

  /// 从磁盘恢复。字段缺一个就返回 null —— 半个身份比没有更糟。
  static IdentityProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ua = raw['ua'];
    final model = raw['model'];
    final os = raw['os'];
    final major = raw['major'];
    final screen = ScreenProfile.fromJson(raw['screen']);
    final lang = raw['lang'];
    final tz = raw['tz'];
    final cores = raw['cores'];
    final mem = raw['mem'];
    if (ua is! String || ua.isEmpty) return null;
    if (model is! String || model.isEmpty) return null;
    if (os is! String || os.isEmpty) return null;
    if (major is! int || major <= 0) return null;
    if (screen == null) return null;
    if (lang is! String || lang.isEmpty) return null;
    if (tz is! String || tz.isEmpty) return null;
    if (cores is! int || cores <= 0) return null;
    if (mem is! int || mem <= 0) return null;
    return IdentityProfile(
      userAgent: ua,
      model: model,
      androidVersion: os,
      chromeMajor: major,
      screen: screen,
      language: lang,
      timeZone: tz,
      hardwareConcurrency: cores,
      deviceMemory: mem,
    );
  }
}

/// 身份的 id。
///
/// **算的是整个画像，不是只有 UA。** 只按 UA 算的话，两个「UA 相同但屏幕
/// 不同」的身份会撞成同一个 id，于是「切回当时那个身份」会切到一个
/// 只有 UA 对、其它全错的状态 —— 而那正是最容易被识别的组合。
///
/// 用 FNV-1a 而不是 `String.hashCode`：后者跨进程不保证稳定，而这份 id
/// 要写进磁盘跨重启读回来。
String identityIdOf(IdentityProfile p) {
  final src = [
    p.userAgent,
    p.model,
    p.androidVersion,
    '${p.chromeMajor}',
    '${p.screen.width}x${p.screen.height}@${p.screen.devicePixelRatio}',
    p.language,
    p.timeZone,
    '${p.hardwareConcurrency}',
    '${p.deviceMemory}',
  ].join('\u0000');
  var h = 0x811c9dc5;
  for (final unit in src.codeUnits) {
    h ^= unit & 0xff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
