/**
 * 安卓侧的 Activity。
 *
 * ## 现在是空的，为什么留着
 *
 * `GeneratedPluginRegistrant` 在 `configureFlutterEngine` 里注册插件，
 * 而 Flutter 只会在 Activity 是 `FlutterActivity` 时调它。删掉这个类
 * 会连插件注册一起删掉，WebView 插件就用不了了。
 *
 * ## 这里曾经挂过两条通道，都删了
 *
 * | 通道 | 方法 | 为什么删 |
 * |---|---|---|
 * | `fusinbox/theme` | `getColorSchemes` | 新版主题是 `lib/ui/theme/neutral_schemes.dart` 里写死的两套，不读系统配色。Kotlin 侧忘了跟着删 |
 * | `fusinbox/webview` | `openUrl` | 新版外链由 `InboxPage._allowNavigation` 只放行站点域、其余拦掉，不走系统浏览器 |
 * | `fusinbox/webview` | `applyUserAgentMetadata` | **见下** |
 *
 * 前两条是死代码 —— Dart 侧零调用方（`rg -n "MethodChannel" --glob '*.dart'`
 * 在新版里零命中），留着只会让人以为功能还在。删。
 *
 * ## `applyUserAgentMetadata` 那条不一样：它是缺口，不是死代码
 *
 * 它改的是 WebView 真正**发出去**的 `Sec-CH-UA*` 请求头，而 JS 改不了头 ——
 * 铺片只覆盖页面里读到的 `navigator.userAgentData`。旧版靠这条通道让
 * 「UA 字符串」和「请求头」同源。
 *
 * 新版把身份做成在内核版本 ±2 浮动（`IdentityProfile.mint`），
 * `IdentityProfile.chUa` 也算好了正确的头值 —— **但没有任何地方把它送出去**，
 * 因为能送它的这条通道没有 Dart 侧对接。
 *
 * 也就是说：`Sec-CH-UA` 头由引擎按真实内核发，UA 字符串是 ±2 浮动值，
 * 两者在约 4/5 的情况下对不上。旧版 `browser_identity.dart` 把这种不一致
 * 定性为「比不伪装更明显的机器特征」。
 *
 * 这条**暂时**随另外两条一起删，因为它上面的消费方从来没存在过 —— 留一个
 * 没人调的原生方法，比删掉更容易被误认为「已经在防」。要补回来必须先定：
 *
 *   1. 身份到底该不该偏离内核（现在 ±2，自洽性就已经破了）
 *   2. 插件这一代有没有暴露 metadata 能力（查过 platform_interface 和
 *      android 实现，`userAgentMetadata` 零命中 —— 要绕开插件自己写 Kotlin）
 *
 * 这两条都是产品决策 + 真机验证才能定的事，沙箱里定不了。
 * 详见 `lib/data/identity_profile.dart` 顶部那张分层表。
 */
package com.yg.fusv2

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
