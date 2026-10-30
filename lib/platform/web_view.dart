/// WebView 封装。
///
/// ## 为什么合成一个文件
///
/// 旧代码把这件事拆成 7 个文件（引擎 / 设置 / 视图构建 / 回调接线 / 平台
/// 探测 / UA 解析 / 工厂），于是「UA 什么时候生效」这种问题要跳三个文件
/// 才能回答。拆分的理由是「职责不同」，但实际读代码的成本远大于收益。
///
/// 新版只有两件事：**配置**（哪些开关要开、为什么）和**接线**（把内核
/// 回调接到我们的函数上）。它们的时间轴确实不同，但加起来不到 200 行，
/// 放一起反而更好读 —— 一眼能看见「设置是什么、回调什么时候来」。
///
/// ## 这个文件是唯一碰 `flutter_inappwebview` 的地方
///
/// 上面的数据层（`lib2/data/`）完全不依赖它，所以能在本机单测。
/// 这个文件不可单测（需要真机内核），但它做的事情少 —— 全是接线，
/// 没有判断逻辑。
library;

import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/identity_profile.dart';
import '../data/identity_roster.dart';

/// 内核设置。
///
/// ## 只传「偏离默认值」的项
///
/// CI 跑 `--fatal-infos`，显式传一个「值等于默认值」的参数会被
/// `avoid_redundant_argument_values` 判为冗余、直接挂。所以下面每一行
/// 都必须是**真的非默认**。默认就满足的那些写在注释里说明理由。
///
/// 默认就满足、但我们确实依赖的：
///   - `javaScriptEnabled` —— 整个抓取层的前提
///   - `domStorageEnabled` —— 站点把 reader 密钥放在 IndexedDB
///   - `thirdPartyCookiesEnabled` —— Turnstile 的挑战页在跨域 iframe 里
///   - `useWideViewPort` —— 站点模板是移动端优先的
InAppWebViewSettings webViewSettings(String userAgent) => InAppWebViewSettings(
  userAgent: userAgent,
  // 默认 false。关着的话站点内的重定向会直接跑掉，
  // 第三方页面一旦被引进来就能往 JS 通道里塞数据。
  useShouldOverrideUrlLoading: true,
  // 默认 false。Turnstile 有模式会**开新窗口**（先开隐藏窗再回填
  // 结果），关着时那些窗口被静默拒掉，挑战就永远转不完。
  javaScriptCanOpenWindowsAutomatically: true,
);

/// 把 WebView 的流量指到本地桥。
///
/// ## 为什么必须用 `ProxyController` 而不是别的东西
///
/// 安卓 WebView 的代理是**进程级**的，只能通过 `androidx.webkit` 的
/// `ProxyController` 设。`flutter_inappwebview` 把它包成了
/// [ProxyController.setProxyOverride]。
///
/// 两个容易踩的点：
///
///   1. **它是静态的、整个进程生效**，不是「这个 WebView 的代理」。
///      所以收件页和目录页用的是同一个出口 —— 这符合预期（一个出口 =
///      一个 IP，两处不一致反而奇怪）。
///   2. **`ProxyRule.url` 的格式是 `[scheme://]host[:port]`，不带凭据**。
///      这正是本地桥存在的理由：认证得在桥那边补。
///
/// [port] 为 0 表示清掉代理（回到系统设置）。
Future<void> applyWebViewProxy(int port) async {
  final c = ProxyController.instance();
  if (port <= 0) {
    try {
      await c.clearProxyOverride();
    } catch (_) {
      // 本来就没设过。清不掉不算错。
    }
    return;
  }
  await c.setProxyOverride(
    settings: ProxySettings(
      proxyRules: [ProxyRule(url: 'http://127.0.0.1:$port')],
      // 本地回环默认就会绕过代理，必须显式关掉这条隐式规则，
      // 否则 WebView 请求 `127.0.0.1` 时直接连，桥白搭。
      removeImplicitRules: true,
    ),
  );
}

/// 页面事件。内核回调统一转成这几个，界面层只认它们。
class const WebViewEvents({
  /// 主框架开始加载。
  required this.onStarted,

  /// 主框架加载完成。
  required this.onFinished,

  /// 页面里的 JS 通过 `callHandler` 发来一条消息。
  required this.onMessage,

  /// 主框架加载失败。
  required this.onError,

  /// 导航请求。返回 false 拦截。
  required this.allowNavigation,
}) {
  final void Function(String url) onStarted;
  final void Function(String url) onFinished;
  final void Function(String channel, String payload) onMessage;
  final void Function(WebResourceError error) onError;
  final bool Function(String url) allowNavigation;
}

/// inbox WebView 的重建标识 —— **必须跟着身份走**。
///
/// 原生视图只在 key 变（或 viewType 变）时重建：插件把 key 原样交给
/// `PlatformViewLink`，后者只在换成另一个平台视图时才重跑
/// `onCreatePlatformView`。
///
/// 而 UA 和注入脚本（环境伪装）都只在**创建时**下发一次 ——
/// `initialSettings` / `initialUserScripts`。插件里 `didUpdateWidget`
/// 零命中，本仓也没人调 `setSettings`。用恒定的 `GlobalKey` 时换了身份
/// 原生视图一动不动，站点看到的还是旧身份。
///
/// 实测见 `test/identity_view_key_test.dart`。
Key inboxViewKey(IdentityProfile? profile) {
  return ValueKey('inbox-wv-${profile == null ? '' : identityDigest(profile)}');
}

/// 手上这个控制器，是否还属于**当前这一代**视图。
///
/// [controllerKey] 是建控制器时那一次 `build` 用的 key。它和当前 key 不
/// 一致 = key 变过 = 原生视图已经重建，旧控制器已被销毁。
///
/// 此时**不要**再往它身上导航：实测会抛
/// `AndroidInAppWebViewController was used after being disposed`
/// （`test/identity_view_key_test.dart`），而调用点又把异常 catch 成
/// 「重新加载失败」—— 一次纯粹的误报。而且没必要：新视图创建时就带着
/// `initialUrl`，它自己会加载。
bool controllerOwnsView({required Key? controllerKey, required Key viewKey}) {
  return controllerKey == viewKey;
}

/// 造一个 WebView。
///
/// [key] 决定「换 key 就重建平台视图」—— 必须真的挂到 `InAppWebView` 上，
/// 旧代码收了这个参数却一路丢掉，导致本该重建的场景复用了旧视图。
/// **必须传 [inboxViewKey] 的结果**，别传恒定 key —— 理由见那里。
///
/// [scripts] 是页面加载**之前**要注入的脚本（垫片 + 抓取层）。
/// 必须走 `initialUserScripts` 而不是加载后再 `evaluateJavascript` ——
/// 站点自己的脚本一进来就会读 `navigator`，晚一步那一屏已经被判定过了。
/// [initialUrl] 是首屏地址，**必须给**。
///
/// 不给的话这个 `InAppWebView` 建出来是空白的：`initialUrlRequest` 为
/// `null` 时内核只停在 `about:blank`，而本仓唯一一处 `loadUrl` 在
/// `_reload()` 里、只在「被拒之后 / 用户按刷新」才走到 —— 于是页面
/// 永远不加载，`onLoadStop` 也永远不来。之前缺这个参数，症状就是
/// 「收件箱打开一片空白，什么都不发生」。
///
/// [onCreated] 拿到刚建好的控制器。调用方要把它连同**当次 [key]** 一起
/// 记下来，才能判断它有没有被后来的一次重建作废（[controllerOwnsView]）。
///
/// 空串是配置错误（调用方地址没解析出来），直接抛 —— 静默建一个白屏
/// 视图比报错更难查。
Widget buildWebView({
  required Key key,
  required String userAgent,
  required List<UserScript> scripts,
  required WebViewEvents events,
  required String initialUrl,
  void Function(InAppWebViewController controller)? onCreated,
}) {
  if (initialUrl.isEmpty) {
    throw ArgumentError.value(initialUrl, 'initialUrl', '首屏地址不能为空');
  }
  return InAppWebView(
    key: key,
    initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
    initialSettings: webViewSettings(userAgent),
    initialUserScripts: UnmodifiableListView(scripts),
    onWebViewCreated: (controller) {
      // 通道要在页面脚本跑之前注册好，否则第一帧消息会丢。
      controller.addJavaScriptHandler(
        handlerName: messageChannel,
        // 参数类型必须显式写：`JavaScriptHandlerCallback` 的签名是
        // `dynamic Function(List<dynamic>)`。省略会让 `args.isNotEmpty`
        // 变成「条件不是 bool」（`non_bool_condition`），CI 会挂。
        callback: (List<dynamic> args) {
          if (args.isEmpty) return null;
          final first = args.first;
          // 站点 JS 发的是字符串。不是字符串就丢掉 —— 与其把任意 dynamic
          // 拼成字符串塞给状态层（那层会直接解析 JSON），不如在这里挡住。
          if (first is String) events.onMessage(messageChannel, first);
          return null;
        },
      );
      onCreated?.call(controller);
    },
    shouldOverrideUrlLoading: (controller, action) async {
      final url = action.request.url?.toString() ?? '';
      if (url.isEmpty) return NavigationActionPolicy.ALLOW;
      return events.allowNavigation(url)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
    onLoadStart: (controller, url) {
      if (url != null) events.onStarted(url.toString());
    },
    onLoadStop: (controller, url) {
      if (url != null) events.onFinished(url.toString());
    },
    onReceivedError: (controller, request, error) {
      // 只报**主框架**的错。子资源（图床、埋点）失败是常态，
      // 拿它当页面失败会让每挂一张图就走一轮重试。
      if (request.isForMainFrame ?? true) {
        events.onError(error);
      }
    },
  );
}

/// JS ↔ Dart 的通道名。
///
/// **两头必须一致**：这边是 `callHandler` 的第一个参数，JS 那边是
/// `bridge.callHandler('FusInbox', ...)`。改一处忘另一处 = 消息全部静默
/// 丢掉（界面永远空白，且不报任何错）。旧代码把这条约定写在三个文件的
/// 注释里；新版只有这一处定义，JS 侧引用同一个字面量。
const messageChannel = 'FusInbox';
