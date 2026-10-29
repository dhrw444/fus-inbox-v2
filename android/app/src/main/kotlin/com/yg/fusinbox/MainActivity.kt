/**
 * 原生侧要挂的两件事，以及它们的理由。
 *
 * | 方法 | 为什么还得走原生 |
 * |---|---|
 * | applyUserAgentMetadata | Sec-CH-UA* 请求头由引擎按真实内核版本生成，Dart 侧改不掉；只有 WebSettingsCompat.setUserAgentMetadata 能改 |
 * | openUrl | 用系统浏览器打开链接；不引 url_launcher 是为了不动 pubspec.lock |
 *
 * 代理、cookie、清站点数据、装垫片都不在这里 —— 见 Dart 侧
 * lib/core/webview/native_capabilities.dart 顶部那张对照表。
 *
 * 通道名常量在 lib/core/webview/platform_channel.dart，两边必须一致。
 */
package com.yg.fusinbox

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.webkit.WebView
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /// 把 client hints 也改成我们声称的身份。
    ///
    /// **为什么必须做**：WebView 发出的 `Sec-CH-UA*` 请求头由引擎按
    /// **真实内核版本**生成，而 UA 字符串是我们自己设的。身份在真实内核
    /// 附近浮动 ±2 之后（见 browser_identity.dart 的 `_kernelMajor`），
    /// 「UA 说 Chrome/143、Sec-CH-UA 头说 141」就成立 —— 撕裂面从
    /// 「版本号乱编」变成「UA 与请求头不一致」，而 Cloudflare 恰好能同时
    /// 看到这两处。
    /// 当年是靠「身份钉死在内核版本上」绕开的，现在有了真正的解法。
    ///
    /// 垫片（BrowserShim）只改了页面里 JS 读到的 `navigator.userAgentData`，
    /// **改不了 HTTP 头**。这里是唯一能改头的地方。
    ///
    /// 三份数据必须同源：设进去的 UA、这里的 metadata、垫片里的
    /// BRANDS / FULL_LIST —— 全部由 Dart 侧同一组参数生成。
    ///
    /// @return 是否真的设上了。false 不是错误：老内核不支持这个特性时
    ///         只能靠「身份不偏离内核」兜底。
    private fun applyUserAgentMetadata(args: Map<*, *>?): Boolean {
        if (args == null) return false
        val major = args["chromeMajor"] as? String ?: return false
        val full = args["appVersion"] as? String ?: return false
        val platformVersion = args["platformVersion"] as? String ?: return false
        val platform = args["platform"] as? String ?: "Android"
        val model = args["model"] as? String ?: ""
        val isMobile = args["isMobile"] as? Boolean ?: true
        if (major.isBlank() || full.isBlank()) return false
        // BrandVersion.Builder.build() 对空串会抛 IllegalArgumentException，
        // 这里先挡一道，别让一个空机型串把整条通道打挂。
        val pv = if (platformVersion.contains('.')) platformVersion else
            "$platformVersion.0.0"

        val webView = findWebView() ?: return false
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
            return false
        }
        return try {
            // GREASE 占位品牌。真 Chrome 的 sec-ch-ua 里必有这么一项，
            // 缺了反而是特征。必须与 Dart 侧同一组参数生成的
            // `BrowserIdentity.secChUa` 逐字同值 —— 一处改了另一处没改，
            // 就又造出一个「JS 说 A、请求头说 B」的不一致。
            val brands = listOf(
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand("Chromium")
                    .setMajorVersion(major)
                    .setFullVersion(full)
                    .build(),
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand("Google Chrome")
                    .setMajorVersion(major)
                    .setFullVersion(full)
                    .build(),
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand("Not?A_Brand")
                    .setMajorVersion("99")
                    .setFullVersion("99.0.0.0")
                    .build(),
            )
            val metadata = UserAgentMetadata.Builder()
                .setBrandVersionList(brands)
                .setFullVersion(full)
                .setPlatform(platform)
                .setPlatformVersion(pv)
                .setArchitecture("arm")
                // 传字面量 64：这个类里**没有** BITNESS_64 常量
                // （javap 过 1.14.0 的 aar，只有 BITNESS_DEFAULT = 0），
                // 官方文档里那行示例是错的。
                .setBitness(64)
                .setModel(model)
                .setMobile(isMobile)
                .setWow64(false)
                .build()
            WebSettingsCompat.setUserAgentMetadata(webView.settings, metadata)
            true
        } catch (error: Exception) {
            // 内核版本够新但具体实现不认某个字段时会走到这里。
            // 设不上也不该崩 —— 页面照常能用，只是回到「不偏离内核」的兜底。
            false
        }
    }

    /// 找到当前 Activity 里的 WebView 实例。
    ///
    /// WebView 是 Flutter 的 platform view 造出来的，没有公开引用。
    /// 这里遍历 content view 找第一个 —— 不管上面那层是哪个包
    /// （webview_flutter 还是 flutter_inappwebview），底下都是同一个
    /// `android.webkit.WebView`，这个遍历照样找得到。
    private fun findWebView(): WebView? {
        return try {
            val root = findViewById<android.view.View>(android.R.id.content)
            val found = mutableListOf<WebView>()
            fun walk(view: android.view.View?) {
                if (view == null || found.isNotEmpty()) return
                if (view is WebView) { found.add(view); return }
                if (view is android.view.ViewGroup) {
                    for (i in 0 until view.childCount) walk(view.getChildAt(i))
                }
            }
            walk(root)
            found.firstOrNull()
        } catch (error: Exception) {
            null
        }
    }
    /// 交给系统浏览器打开一个链接。
    ///
    /// 用 ACTION_VIEW 而不是 WebView —— 用户点仓库链接是想在真浏览器
    /// 里看，不是想在 App 内嵌的 WebView 里再开一个页面。
    ///
    /// 返回 false 表示设备上没有能处理这个 URL 的应用，调用方据此
    /// 提示用户，而不是静默失败。
    private fun openExternalUrl(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                // 从非 Activity 上下文启动时要带，这里是 Activity，
                // 但显式声明能避免某些 ROM 的歧义。
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (error: Exception) {
            false
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fusinbox/theme")
            .setMethodCallHandler { call, result ->
                if (call.method != "getColorSchemes") {
                    result.notImplemented()
                } else {
                    try {
                        result.success(systemColorSchemes(this))
                    } catch (error: Exception) {
                        result.error("colors_unavailable", "Could not read Android color roles", null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fusinbox/webview")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "applyUserAgentMetadata" -> {
                        val args = call.arguments as? Map<*, *>
                        result.success(applyUserAgentMetadata(args))
                    }
                    // 用系统浏览器打开外部链接。不用 url_launcher 是为了
                    // 不动 pubspec.lock —— CI 跑 --enforce-lockfile，
                    // 加依赖就得同步改锁文件，不值当。
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            result.success(openExternalUrl(url))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
