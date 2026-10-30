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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'core/store.dart';
import 'core/user_agent.dart';
import 'data/egress.dart';
import 'data/proxy_config.dart';
import 'ui/home_page.dart';
import 'ui/theme/app_theme.dart';

/// 整个应用唯一的出口管理器。
///
/// 放在顶层而不是塞进 provider 树里：出口要同时被三个地方读
/// （目录抓取的 `findProxy`、桥的上游、界面显示），而它们分布在
/// 数据层、平台层、界面层 —— 一个顶层单例比一根穿透三层的依赖链短。
/// 它没有生命周期问题：桥随进程走，进程结束系统回收端口。
final egress = Egress();

/// 磁盘。
final store = Store();

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

  // 读回上次的身份。
  //
  // **必须在探到内核之后、打开页面前**。顺序反了就是「拿旧 UA 打了
  // 一次站点，再换成新的」—— 那一次在对方眼里是设备指纹变了。
  final savedUa = await store.read(kUserAgentKey);
  if (savedUa != null) restoreUserAgent(savedUa);

  // 读回上次的出口。找不到那条就退回直连 —— **不猜**。
  //
  // 清单可能更新过（某条出口下架），这时按 id 找不到，按下标再试一次；
  // 两次都对不上就说明这条没了，退回直连比随便挑一条好：挑中的可能
  // 是条完全不通的，而用户会以为是网络问题。
  final savedId = await store.read(kEgressIdKey);
  if (savedId != null) {
    final match = _findBy(savedId, await store.readInt(kEgressIndexKey));
    if (match != null) await egress.useProxy(match);
  }

  // 出口一变就写盘。挂在 `onChanged` 上而不是散在各个调用点 ——
  // 出口有四个改法（`useProxy` / `switchTo` / `direct` / 桥崩了），
  // 散着挂必然漏一个，而漏了不报错，只是下次启动回到直连。
  egress.onChanged = () {
    final cur = egress.current;
    if (cur == null) {
      // 直连：把 id 清掉，别留一条已经不用的。
      unawaited(store.remove(kEgressIdKey));
      return;
    }
    unawaited(store.write(kEgressIdKey, cur.id));
  };

  runApp(const FusApp());
}

/// 在清单里找回上次那条出口。
///
/// 先按 id（稳定、不受清单顺序影响），再按下标（清单重排过时还能中）。
/// 下标命中的前提是**它的 id 也还在清单里**——只按下标取会让「清单换了
/// 一批出口」时悄悄切到一条完全无关的线。
ProxyConfig? _findBy(String id, int? index) {
  for (final p in egress.manifest) {
    if (p.id == id) return p;
  }
  if (index == null) return null;
  final list = egress.manifest;
  if (index < 0 || index >= list.length) return null;
  // 下标兜底也要验 id 的**主机部分**没变，否则就是「按位置撞上了一条
  // 无关的出口」。
  return list[index].host == Uri.tryParse(id)?.host ? list[index] : null;
}

/// 启动失败时显示的东西。
///
/// **私有 widget 不加 `super.key`** —— 它在外面只被 new 一次、从不传 key，
/// 加了会被 `unused_element_parameter` 判成「参数从没被给过值」。
/// （`use_key_in_widget_constructors` 只管公开 widget。）
class const _StartupFailed({required this.message}) extends StatelessWidget {
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
    // 外观沿用旧项目的：中性灰阶，不是 Material 默认紫，也不是之前
    // 这里临时用的蓝色种子色。种子色那条路会生成一整套**带彩的**派生色，
    // 而旧的观感是「素」—— 内容全是短信文本，彩色会抢注意力。
    final theme = AppTheme(ThemeData().textTheme);

    return MaterialApp(
      title: '短信查看器',
      debugShowCheckedModeBanner: false,
      theme: theme.scheme(),
      darkTheme: theme.scheme(dark: true),
      home: const HomePage(),
    );
  }
}
