/// 应用入口。
///
/// ## 启动只有三件事
///
///   1. 探测内核 UA —— 之后所有网络请求都用它，晚一步就会有一次
///      「用占位身份打站点」，那一次在对方眼里是可疑的
///   2. 挂上错误兜底 —— **启动期任何异常都不该是闪退**
///   3. 打开首页
///
/// 旧代码在 `main` 里做了一堆事（读盘、建桥、探 WebView 环境）却一行
/// catch 都没有 —— 任何一步抛异常，用户看到的就是「打开就闪退」，
/// 屏幕上什么都没有、日志也拿不到。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'core/user_agent.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await _bootstrap();
  } catch (e, st) {
    // 兜底：显示一句人话，而不是闪退。
    //
    // 这句话里带异常内容 —— 用户截图发过来就能定位，不必再猜。
    runApp(_StartupFailed(message: '$e\n\n$st'));
  }
}

/// 启动准备。
Future<void> _bootstrap() async {
  // 内核真值。`getDefaultUserAgent` 在安卓上不需要 WebView 实例，
  // 直接问内核要 —— 这是唯一可信的来源。
  try {
    final ua = await InAppWebViewController.getDefaultUserAgent();
    // `getDefaultUserAgent` 的返回类型非空，不用判 null。
    if (ua.trim().isNotEmpty) bootstrapUserAgent(ua);
  } catch (e) {
    // 探测失败就用 `BrowserIdentity.fallback`（一组真实存在的值）。
    // 不编版本号、不留空字段 —— 宁可少变化，也不给自相矛盾的身份。
  }

  runApp(const FusApp());
}

/// 启动失败时显示的东西。
class const _StartupFailed({required this.message, super.key})
    extends StatelessWidget {
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 44),
                const SizedBox(height: 16),
                const Text(
                  '启动失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      message,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 应用外壳。
class const FusApp({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '短信查看器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B6EA5),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
