/// 换身份时清掉站点数据。
///
/// ## 为什么必须清
///
/// 站点认人的根不是 UA，是**一对存在 IndexedDB 里的 P-256 ECDSA 密钥**。
/// 实测确认（2026-10-30，打真实接口）：
///
/// ```
/// POST /sms-api/v1/session  {"key": {kty,crv,x,y}}
/// → 403 {"error":"reader_verification_required",
///        "challenge_id":"…", "sitekey":"0x4AAAAAAFMV6MztbYjlS6VW",
///        "action":"reader_access", "cdata":"…"}
/// ```
///
/// 也就是说：**每个密钥都要单独过一次 Cloudflare Turnstile** 才能拿到
/// `sid`。密钥留在 IndexedDB 里，就等于身份没变 —— 换 UA 只是换了张脸。
///
/// 站点自己的 `reader.js` 里三处把这件事写死了：
///
/// ```js
/// // :3  常量
/// const STORE='fus:reader:v1', DB='fus-reader-v1'
/// // :61 公钥导出
/// async function publicKey(){ ... exportKey('jwk', ...) }
/// // :62 keyId = 公钥的 SHA-256
/// async function keyId(){return hash(JSON.stringify(await publicKey()));}
/// // :65 凭证绑在 keyId 上，密钥一换旧 sid 立即作废
/// if(d && d.keyId===await keyId()){ ... }
/// ```
///
/// 所以清三样：**IndexedDB（根）、localStorage（旧 sid）、cookie**。
///
/// ## 顺序
///
/// 必须在**页面加载之前**清。页面一加载，站点就会用旧密钥签名换 sid；
/// 那时再清，旧密钥已经用过了。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 站点自己的常量。从 `reader.js:3` 抄来，改版时要跟着改。
const _siteDbName = 'fus-reader-v1';
const _siteGrantKey = 'fus:reader:v1';

/// 在页面里跑的清除脚本**函数体**。
///
/// 为什么是函数体而不是整段表达式：`callAsyncJavaScript` 的
/// `functionBody` 会被原生包成 `async function(){ ... }`，内部可以直接
/// `await`。传 `(async () => { ... })()` 进去会变成嵌套 IIFE，返回值
/// 也就成了 Promise 而不是结果。
///
/// `return` 一个对象，原生侧会 JSON 化后交回来。
///
/// 不抛异常：删不掉（隐私模式、内核不支持 `indexedDB.databases()`）
/// 是**已知情形**，不是错误。抛出去只会让调用方以为整个换身份失败。
const _wipeBody = r'''
  var out = {db: false, ls: false, ss: false, blocked: false, names: []};

  // 删一个库。返回 true 表示**真的删掉了**。
  //
  // `onblocked` 不能当成完成：它表示还有连接开着、库没删。
  // 把它当成功会让上层以为「身份换了」，实际密钥还在盘上 ——
  // 那是最坏的一种失败，因为它看起来成功了。
  //
  // 遇到 blocked 时先断掉本站自己的连接（`indexedDB.databases()` 不用
  // 关闭，它不占连接），等 300ms 再试一次；再不行就如实报 false。
  function drop(name, retried) {
    return new Promise(function (resolve) {
      var req;
      try { req = indexedDB.deleteDatabase(name); }
      catch (e) { resolve(false); return; }
      req.onsuccess = function () { resolve(true); };
      req.onerror = function () { resolve(false); };
      req.onblocked = function () {
        if (retried) { resolve(false); return; }
        // 再给一次机会。站点自己的连接可能刚好在这一刻关掉。
        setTimeout(function () { resolve(drop(name, true)); }, 300);
      };
    });
  }

  // ① 主库 —— 这是身份的根。`out.db` 只表示**这一个**删掉了。
  //
  // 不能把「遍历时随便删掉哪个库」也记进 `out.db`：那样主库被 blocked、
  // 而某个无关库删成功时，上层会看到 `db:true` 以为身份换了 —— 密钥
  // 还在盘上，却报告成功。`out.db` 的语义必须是单指主库。
  var target = '%DB%';
  try {
    if (await drop(target, false)) out.db = true;
    else out.blocked = true;
  } catch (_) {}

  // ② 再遍历一遍：站点改过库名时也能删到。跳过主库名，别删两次。
  try {
    if (indexedDB.databases) {
      var dbs = await indexedDB.databases();
      for (var i = 0; i < dbs.length; i++) {
        var n = dbs[i] && dbs[i].name;
        if (!n || n === target) continue;
        out.names.push(n);
        // 这些库删不掉**不**影响 `out.db`，只记 blocked。
        if (!(await drop(n, false))) out.blocked = true;
      }
    }
  } catch (_) {}
  // ② 旧 sid。
  try { localStorage.removeItem('%GRANT%'); out.ls = true; } catch (_) {}
  // ③ 会话级的零碎。
  try { sessionStorage.clear(); out.ss = true; } catch (_) {}
  return out;
''';

/// 清一次站点数据的结果。
class const WipeResult({
  required this.indexedDb,
  required this.localStorage,
  required this.sessionStorage,
  this.databaseNames = const [],
  this.blocked = false,
}) {
  /// IndexedDB 删掉了没有 —— **这一项是身份的根**。
  final bool indexedDb;
  final bool localStorage;
  final bool sessionStorage;

  /// 页面里见到过哪些库名。排查用。
  final List<String> databaseNames;

  /// 删库时被 `onblocked` 挡过 —— 还有连接开着，库**可能还在**。
  ///
  /// 和 [indexedDb] 为 false 是两件事：那个是「请求失败」，这个是
  /// 「请求被挡住，删没删掉不确定」。后者更隐蔽，因为脚本跑完了、
  /// 没报错，只有这个标记能说明它没成功。
  final bool blocked;

  /// 身份层真的清干净了？
  ///
  /// **必须同时满足「库删掉了」和「凭证删掉了」，且没有被 blocked。**
  ///
  /// `blocked` 要算进来：那时脚本跑完没报错，但库很可能还在 ——
  /// 只看 `indexedDb` 的话会把它当成成功，而上层据此判断「身份换了」，
  /// 于是不再重试。这是最坏的一种失败：看起来成功了。
  bool get identityCleared => indexedDb && localStorage && !blocked;

  static const failed = WipeResult(
    indexedDb: false,
    localStorage: false,
    sessionStorage: false,
  );
}

/// 把一个 WebView 的站点数据清干净。
///
/// [controller] 是当前的 WebView。它会先导航到 `about:blank` 之外的一个
/// **同源空页**，这样脚本才有站点的 origin —— `about:blank` 的 origin
/// 是 null，碰不到站点的 IndexedDB。
///
/// 做法是：在**当前已加载的站点页面**上直接跑脚本，而不是先导航走。
/// 页面已经在站点 origin 上，脚本天然有权限；先导航走反而会丢掉 origin。
Future<WipeResult> wipeSiteData(InAppWebViewController controller) async {
  try {
    // **必须用 `callAsyncJavaScript`，不能用 `evaluateJavascript`。**
    //
    // 实测（读 `flutter_inappwebview_android-1.2.0-beta.3` 的
    // `in_app_webview_controller.dart:2225-2232`）：`evaluateJavascript`
    // 走的是原生 `WebView.evaluateJavascript()`，它只返回**同步表达式**
    // 的值。我们的脚本是 async IIFE，返回 Promise，序列化不了 → 拿到
    // null → 每次都判失败。功能静默失效，但**不会假装成功**（那条路
    // 走 `decoded is! Map` → `WipeResult.failed`），所以至少不会骗人。
    //
    // `callAsyncJavaScript` 的 `functionBody` 是**函数体**，不带
    // `async () =>` 包装 —— 传整段 IIFE 进去会语法错。返回的
    // `value` 是脚本 `return` 的值。
    final res = await controller.callAsyncJavaScript(
      functionBody: _wipeBody
          .replaceAll('%DB%', _siteDbName)
          .replaceAll('%GRANT%', _siteGrantKey),
    );
    if (res == null) return WipeResult.failed;
    if (res.error != null) {
      // 脚本里抛了异常。这**不是**「删不掉」那种已知情形（那种被 try
      // 吞掉了），是脚本本身出了问题，当失败处理并保留原因。
      return WipeResult.failed;
    }

    // 原生侧把 `return` 的对象 JSON 化再交回来，所以 `value` 通常是
    // `Map`（`in_app_webview_controller.dart:2872-2878` 里
    // `json.decode(data)` 之后的 `data["value"]`）。但也可能是字符串
    // —— 不做假设，两种都收。
    final v = res.value;
    Object? decoded = v;
    if (v is String) {
      try {
        decoded = jsonDecode(v);
      } catch (_) {
        // 不是 JSON。说明脚本返回值形状变了，不是「清不干净」。
        return WipeResult.failed;
      }
    }
    if (decoded is! Map) return WipeResult.failed;
    final names = decoded['names'];
    return WipeResult(
      indexedDb: decoded['db'] == true,
      localStorage: decoded['ls'] == true,
      sessionStorage: decoded['ss'] == true,
      databaseNames: names is List
          ? names.whereType<String>().toList()
          : const [],
      blocked: decoded['blocked'] == true,
    );
  } catch (_) {
    // 脚本跑不起来（页面还没加载、被导航打断）。当失败处理。
    return WipeResult.failed;
  }
}

/// 清 cookie / 缓存 / WebStorage。
///
/// 这几项走原生接口，不依赖页面。和 [wipeSiteData] 互补：
/// 那个清的是页面能碰到的东西，这个清的是内核层的。
///
/// `WebStorageManager.deleteAllData()` 在安卓上**是否覆盖 IndexedDB
/// 没有官方确认**（androidx 的 `WebStorage` 文档 404）。所以它只能当
/// 补充，不能当主力 —— 主力是 [wipeSiteData] 里那段显式删库。
Future<void> wipeKernelData() async {
  try {
    await CookieManager.instance().deleteAllCookies();
  } catch (_) {}
  try {
    await WebStorageManager.instance().deleteAllData();
  } catch (_) {}
  try {
    // 静态方法，清全进程的缓存。
    await InAppWebViewController.clearAllCache();
  } catch (_) {}
}
