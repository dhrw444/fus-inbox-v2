/// 站点会话凭证（`localStorage` 里 `fus:reader:v1` 的内容）。
///
/// 站点自己的形状是 `{sid, until, offset}`（`reader.js:64`）：
///   - `sid`：32 位小写 hex，服务端签发
///   - `until`：毫秒时间戳，过期时刻
///   - `offset`：服务端与本地时钟的差值
library;

/// 站点凭证的 localStorage 键（`reader.js:3` 的 `STORE`）。
const kSiteGrantKey = 'fus:reader:v1';

/// 站点自己的 sid 判据（`reader.js:64` 的正则）。
final _sidPattern = RegExp(r'^[a-f0-9]{32}$');

/// 判断一段 `localStorage` 原文是不是**有效**的站点凭证。
///
/// 有效 = 能解析 + `sid` 符合站点的格式 + `until` 是数字 + 没过期。
///
/// 抽成纯函数是为了能测：真机上这个值只能从 WebView 里读，而沙箱没有
/// 安卓环境。判定逻辑和读取逻辑分开，前者才测得到。
///
/// [now] 注入是为了能测过期，不依赖真实时钟。
bool isLiveGrant(String? raw, {DateTime? now}) {
  if (raw == null || raw.isEmpty || raw == 'null') return false;

  // 手写解析而不是 `jsonDecode`：这个函数要在 `core/` 里保持零依赖，
  // 方便测试。代价是只认站点这一种形状 —— 那正是我们要的。
  final sid = _pick(raw, 'sid');
  if (sid == null || !_sidPattern.hasMatch(sid)) return false;

  final untilRaw = _pick(raw, 'until');
  if (untilRaw == null) return false;
  final until = int.tryParse(untilRaw);
  if (until == null) return false;

  final t = now ?? DateTime.now();
  return DateTime.fromMillisecondsSinceEpoch(until).isAfter(t);
}

/// 从一段 JSON 文本里取一个**字符串或数字**字段的值。
///
/// 返回字符串形式；取不到返回 null。只支持顶层字段 —— 站点凭证是平的。
String? _pick(String raw, String key) {
  final m = RegExp('"$key"\\s*:\\s*(?:"([^"]*)"|([-0-9.]+))').firstMatch(raw);
  if (m == null) return null;
  return m.group(1) ?? m.group(2);
}
