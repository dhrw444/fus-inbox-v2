/// 浏览器身份（User-Agent 与配套的客户端提示）。
///
/// ## 为什么要有这个
///
/// 站点按「访客」限流，而访客是靠 UA + 内核版本 + 机型认出来的。
/// 一组**自相矛盾**的 UA（比如 UA 说 Android 14 但 client hints 说
/// Windows）比不伪装更扎眼 —— 那正是「一眼看出被改过」的特征。
///
/// 所以这里的每条规则都围绕一个约束：**造出来的身份必须自洽**。
///
/// ## 单一来源
///
/// 内核报的那个 UA 是唯一的基准。机型、大版本、平台全部从它解析，
/// 不从别处拿 —— 从别处拿就会和真实内核漂开。
library;

import 'dart:math';

import '../data/identity_profile.dart';

/// 当前正在用的身份。
BrowserIdentity _current = BrowserIdentity.fallback;

/// 当前身份画像。null = 还没换过（还是内核那台机器）。
IdentityProfile? _currentProfile;

/// 内核大版本。用来给新身份定基准。
int? _kernelMajor;

/// 内核报的**完整** UA。
///
/// 和 [_kernelMajor] 分开存：主版本只用来给随机身份定基准，而完整 UA
/// 是「这个设备的真实身份」——「回到内核真值」这个操作要的就是它。
/// 少了它，用户换过身份之后就没法撤销了。
String? _kernelUa;

/// 内核真值身份。启动时没探到就是 null。
///
/// 返回 null 而不是 [BrowserIdentity.fallback]：fallback 是**编的**，
/// 把它当「真值」显示给用户等于告诉他「你的手机是 Pixel 8 Pro」，
/// 而实际上可能是别的。不知道就说不知道。
BrowserIdentity? get kernelIdentity {
  final ua = _kernelUa;
  if (ua == null) return null;
  return BrowserIdentity(
    userAgent: ua,
    model: _parseModel(ua) ?? '未知机型',
    chromeMajor: _parseMajor(ua) ?? 0,
    androidVersion: _parseAndroid(ua) ?? '未知',
  );
}

/// 回到内核真值。
///
/// 清掉画像（屏幕、时区回到本机真实值）并把 UA 换回内核报的那串。
/// 内核没探到（`_kernelUa == null`）时**什么都不做**，返回 false ——
/// 没有真值可回，假装回去只会造出一个更假的身份。
bool resetIdentity() {
  final ua = _kernelUa;
  if (ua == null) return false;
  _currentProfile = null;
  _current = BrowserIdentity(
    userAgent: ua,
    model: _parseModel(ua) ?? _current.model,
    chromeMajor: _parseMajor(ua) ?? _current.chromeMajor,
    androidVersion: _parseAndroid(ua) ?? _current.androidVersion,
  );
  return true;
}


/// 造一个身份随机数。注入进来是为了可测。
typedef RandomSource = Random Function();

/// 一个浏览器身份。
class const BrowserIdentity({
  required this.userAgent,
  required this.model,
  required this.chromeMajor,
  required this.androidVersion,
}) {
  /// 完整的 UA 串。
  final String userAgent;

  /// 机型（`Build/` 后面那段）。
  final String model;

  /// Chrome 大版本。
  final int chromeMajor;

  /// 安卓版本（`Android 14` 里的 14）。
  final String androidVersion;

  /// 探测失败时的兜底。
  ///
  /// 用一组真实存在的值（Pixel 8 Pro / Android 14 / Chrome 141）——
  /// 宁可少一点变化，也不给出一组自相矛盾的假身份。
  static const fallback = BrowserIdentity(
    userAgent:
        'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro Build/UQ1A.240205.004) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 '
        'Mobile Safari/537.36',
    model: 'Pixel 8 Pro',
    chromeMajor: 141,
    androidVersion: '14',
  );
}

/// 当前身份。读的地方用这个。
BrowserIdentity get currentIdentity => _current;

/// 当前身份对应的 UA 串。WebView 和注入层都用它。
String get currentUserAgent => _current.userAgent;

/// 内核大版本（探测到的真值）。探测不到就返回 null。
int? get kernelMajor => _kernelMajor;

/// 换一个身份。
///
/// **换的是整套环境，不是只换 UA。**
///
/// 只换 UA 是自欺：站点同时读 `screen.width`、`hardwareConcurrency`、
/// `deviceMemory`、时区、`Sec-CH-UA-*` 系列。UA 说「Pixel 8 Pro」而屏幕
/// 还是原来那块、时区还是东八区，等于告诉对方这串 UA 是手改的 —— 比
/// 不换更容易被抓。
///
/// 真正换掉这个「人」的是 IndexedDB 里那对 P-256 密钥，那一步在
/// `platform/site_wipe.dart`，不在这个函数里。这个函数只负责**表面
/// 那一层**，两者必须一起做。
///
/// Chrome 大版本只在 `内核值 ±2` 里动。窗口是对称的（原来写的是
/// `nextInt(4) - 2` = {−2,−1,0,+1}，均值 −0.5，每换一次就往下漂半个版本，
/// 换十几次之后大版本已经和真实内核差一代了）。
IdentityProfile rotateIdentity([Random? rnd]) {
  final r = rnd ?? Random();
  final p = IdentityProfile.mint(
    kernelMajor: _kernelMajor ?? _current.chromeMajor,
    rnd: r,
  );

  _current = BrowserIdentity(
    userAgent: p.userAgent,
    model: p.model,
    chromeMajor: p.chromeMajor,
    androidVersion: p.androidVersion,
  );
  _currentProfile = p;
  return p;
}

/// 当前身份画像（含屏幕、时区、Client Hints）。
///
/// 没换过身份时是 `null` —— 那表示「还是内核给的那台机器」，不是
/// 「不知道」。两者不能混。
IdentityProfile? get currentProfile => _currentProfile;

/// 用内核报的 UA 建立基准身份。
///
/// 必须在任何页面加载之前调一次 —— [currentUserAgent] 之前用的是
/// [BrowserIdentity.fallback]，那只是个说得过去的占位。
void bootstrapUserAgent(String kernelUa) {
  final ua = kernelUa.trim();
  if (ua.isEmpty) return;

  final major = _parseMajor(ua);
  if (major != null && major > 0) _kernelMajor = major;
  // 完整 UA 也留着 —— 「回到内核真值」要用它。
  _kernelUa = ua;

  _current = BrowserIdentity(
    userAgent: ua,
    model: _parseModel(ua) ?? _current.model,
    chromeMajor: major ?? _current.chromeMajor,
    androidVersion: _parseAndroid(ua) ?? _current.androidVersion,
  );
}

/// 从 UA 里取 Chrome 大版本。
int? _parseMajor(String ua) {
  final m = RegExp(r'Chrome/(\d+)\.').firstMatch(ua);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// 从 UA 里取安卓版本号。
String? _parseAndroid(String ua) {
  final m = RegExp(r'Android (\d+(?:\.\d+)?)').firstMatch(ua);
  return m?.group(1);
}

/// 从 UA 里取机型串。
///
/// ## 一定要剥掉 `Build/`
///
/// UA 的形状是 `Android 14; Pixel 8 Pro Build/UQ1A.240205.004)`。
/// 直接取 `Android 14;` 和 `)` 之间那段，会得到
/// `Pixel 8 Pro Build/UQ1A.240205.004` —— 而 `Build/...` 是系统版本号，
/// **不是机型**。真 Chrome 报的 UA 里两者是分开的字段，粘在一起是
/// 「被人拼出来的」特征。
///
/// 旧代码有两套正则，其中一版就漏了这一步，于是 client hints 里
/// 带着一段 Build 串发出去。
String? _parseModel(String ua) {
  final m = RegExp(r'Android [^;]+;\s*([^;)]+)').firstMatch(ua);
  final raw = m?.group(1)?.trim();
  if (raw == null || raw.isEmpty) return null;
  // 切掉 `Build/` 及其之后。
  final cut = raw.indexOf(' Build/');
  final model = cut >= 0 ? raw.substring(0, cut) : raw;
  final out = model.trim();
  // `wv` 是 WebView 的标记，不是机型。
  return out.isEmpty || out == 'wv' ? null : out;
}

/// 从磁盘读回上次用的身份。
///
/// 站点把「访客」绑在一对存在 IndexedDB 里的密钥上。重启回到内核真值
/// 等于拿旧密钥配一个全新的身份 —— 比不换更可疑（对方会认为这台设备
/// 的指纹变了）。
void restoreUserAgent(String? raw) {
  if (raw == null || raw.trim().isEmpty) return;
  final ua = raw.trim();
  final major = _parseMajor(ua);
  _current = BrowserIdentity(
    userAgent: ua,
    model: _parseModel(ua) ?? _current.model,
    chromeMajor: major ?? _current.chromeMajor,
    androidVersion: _parseAndroid(ua) ?? _current.androidVersion,
  );
}

/// 把一串 UA 设成当前身份。
///
/// 和 [restoreUserAgent] 是同一个动作，但**语义不同**：那个是「从磁盘
/// 读回上次的身份」，这个是「访客会话要求切到这个身份」。分开命名是因为
/// 调用点读起来该是哪个就是哪个 —— 一个地方说「恢复」，一个地方说「切换」，
/// 混用会让人以为它们在做什么不一样的事。
///
/// 空串**不生效**：那会把身份变成空 UA，而空 UA 比旧 UA 更可疑。
void applyUserAgent(String ua) {
  if (ua.trim().isEmpty) return;
  restoreUserAgent(ua);
}

/// 把一整套身份画像设成当前身份。
///
/// 和 [applyUserAgent] 的区别是**它把屏幕、时区、Client Hints 一起换**。
/// 换身份必须走这个，只设 UA 是「换了一半」—— 站点一对比就知道。
void applyIdentityProfile(IdentityProfile p) {
  _current = BrowserIdentity(
    userAgent: p.userAgent,
    model: p.model,
    chromeMajor: p.chromeMajor,
    androidVersion: p.androidVersion,
  );
  _currentProfile = p;
}
