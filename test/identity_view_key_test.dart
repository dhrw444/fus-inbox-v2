// 换身份之后，新的 UA / 身份注入脚本到底有没有到内核？
//
// 官方源码把「UA、initialUserScripts、首屏地址」全部塞在**创建参数**里
// 下发（`flutter_inappwebview_android/lib/src/in_app_webview/in_app_webview.dart`
// 的 `build`：`PlatformViewLink(onCreatePlatformView: ... creationParams:
// {..., 'initialSettings': settingsMap, 'initialUserScripts': ...})`）。
// 所以「参数能不能更新」等价于「原生视图会不会被重建」。
//
// 不靠读源码下结论 —— 这里用**真插件**注册真平台，数 platform_views
// 通道收到几次 `create`，再看每次下发的 UA。
//
// 结论（两条断言，删掉修复就挂）：
//   固定 key  → 原生视图只建 1 次，UA 恒为旧值 —— **换身份到不了内核**
//   key 跟身份走 → 建 2 次，UA 真的换成新的
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    show AndroidInAppWebViewPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox_v2/data/identity_profile.dart';
import 'package:fus_inbox_v2/data/identity_roster.dart';
import 'package:fus_inbox_v2/platform/web_view.dart';

/// `platform_views` 通道把 creationParams 编成字节下发，要解一次。
Map<Object?, Object?>? _creationParams(MethodCall c) {
  final a = c.arguments;
  if (a is! Map) return null;
  final raw = a['params'];
  Object? decoded;
  if (raw is Map) {
    decoded = raw;
  } else if (raw is Uint8List) {
    decoded = const StandardMessageCodec().decodeMessage(
      ByteData.sublistView(raw),
    );
  } else {
    return null;
  }
  if (decoded is! Map) return null;
  final settings = decoded['initialSettings'];
  return settings is Map ? settings : null;
}

Object? _uaOf(MethodCall c) => _creationParams(c)?['userAgent'];

/// 注入脚本的源码列表 —— 「身份伪装有没有随创建一起下发」看它。
List<Object?> _scriptsOf(MethodCall c) {
  final a = c.arguments;
  if (a is! Map) return const [];
  final raw = a['params'];
  if (raw is! Uint8List) return const [];
  final decoded = const StandardMessageCodec().decodeMessage(
    ByteData.sublistView(raw),
  );
  if (decoded is! Map) return const [];
  final s = decoded['initialUserScripts'];
  return s is List ? s : const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    InAppWebViewPlatform.instance = AndroidInAppWebViewPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (
          MethodCall call,
        ) async {
          calls.add(call);
          if (call.method == 'create') return 0; // 假装创建成功
          return null;
        });
  });

  int creates() => calls.where((c) => c.method == 'create').length;

  MethodCall lastCreate() => calls.lastWhere((c) => c.method == 'create');

  Widget wrap(Key k, String ua) => Directionality(
    textDirection: TextDirection.ltr,
    child: buildWebView(
      key: k,
      userAgent: ua,
      scripts: [
        UserScript(
          source: 'identity:$ua',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ],
      initialUrl: 'https://example.com/',
      events: WebViewEvents(
        onStarted: (_) {},
        onFinished: (_) {},
        onMessage: (_, _) {},
        onError: (_) {},
        allowNavigation: (_) => true,
      ),
    ),
  );

  testWidgets('恒定 key：换了身份原生视图不重建，UA 到不了内核', (tester) async {
    final fixed = GlobalKey();
    await tester.pumpWidget(wrap(fixed, 'UA-OLD'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrap(fixed, 'UA-NEW'));
    await tester.pumpAndSettle();

    expect(creates(), equals(1), reason: '恒定 key 不重建原生视图 —— 这正是 bug 的形状');
    expect(
      _uaOf(lastCreate()),
      equals('UA-OLD'),
      reason: '下发的 UA 还是旧的，站点看到的仍是旧身份',
    );
  });

  testWidgets('key 跟身份走：原生视图重建，UA 与注入脚本都换成新的', (tester) async {
    await tester.pumpWidget(wrap(const ValueKey('id-A'), 'UA-OLD'));
    await tester.pumpAndSettle();
    final before = creates();

    await tester.pumpWidget(wrap(const ValueKey('id-B'), 'UA-NEW'));
    await tester.pumpAndSettle();

    expect(creates(), greaterThan(before), reason: '换 key 必须重建原生视图');
    expect(_uaOf(lastCreate()), equals('UA-NEW'));
    final scripts = _scriptsOf(lastCreate());
    expect(scripts, isNotEmpty, reason: '身份注入脚本要随创建一起下发');
    final first = scripts.first as Map;
    expect(first['source'], equals('identity:UA-NEW'));
  });

  // 上面两条验的是内核行为，用的是我传进去的 key。这一条把**真函数**
  // 钉住：页面重建标识由 `inboxViewKey` 决定，它必须随身份变。
  test('inboxViewKey 随身份变 —— 恒定 key 会让上面那条 bug 复活', () {
    final a = IdentityProfile.mint(kernelMajor: 141);
    final b = IdentityProfile.mint(kernelMajor: 141);

    expect(
      identityDigest(a),
      isNot(equals(identityDigest(b))),
      reason: '两个独立 mint 的身份指纹本来就该不同',
    );
    expect(
      inboxViewKey(a),
      isNot(equals(inboxViewKey(b))),
      reason: '换了身份必须换 key，否则原生视图不重建、新身份到不了内核',
    );
    expect(
      inboxViewKey(null),
      isNot(equals(inboxViewKey(a))),
      reason: '首帧还没有身份 vs 已有身份，也不该是同一个 key',
    );
    expect(inboxViewKey(a), equals(inboxViewKey(a)), reason: '同一个身份要稳定，别每次重建');
  });

  // 换了身份 = 视图重建 = 旧控制器被销毁。实测往它身上 loadUrl 会抛
  // `used after being disposed`，而调用点把异常 catch 成「重新加载失败」
  // —— 一条纯粹的误报。这条守住那个守卫。
  test('视图重建后不许再往旧控制器导航', () {
    final a = IdentityProfile.mint(kernelMajor: 141);
    final b = IdentityProfile.mint(kernelMajor: 141);
    final keyA = inboxViewKey(a);
    final keyB = inboxViewKey(b);

    expect(
      controllerOwnsView(controllerKey: keyA, viewKey: keyA),
      isTrue,
      reason: '同一代：该导航',
    );
    expect(
      controllerOwnsView(controllerKey: keyA, viewKey: keyB),
      isFalse,
      reason: '换了代：旧控制器已销毁，不能再 loadUrl',
    );
    expect(
      controllerOwnsView(controllerKey: null, viewKey: keyA),
      isFalse,
      reason: '还没建过视图：没有可导航的控制器',
    );
  });

  // `controllerOwnsView` 的前提是「换 key 之后旧控制器真的废了」。
  // 这条不查文档，直接打一次 —— 实测抛
  // `AndroidInAppWebViewController was used after being disposed`。
  testWidgets('换 key 后旧控制器真的不能用了', (tester) async {
    InAppWebViewController? created;
    Widget wrap(Key k) => Directionality(
      textDirection: TextDirection.ltr,
      child: InAppWebView(
        key: k,
        initialUrlRequest: URLRequest(url: WebUri('https://example.com/')),
        onWebViewCreated: (c) => created = c,
      ),
    );

    await tester.pumpWidget(wrap(const ValueKey('A')));
    await tester.pumpAndSettle();
    final old = created!;

    await tester.pumpWidget(wrap(const ValueKey('B')));
    await tester.pumpAndSettle();

    Object? err;
    try {
      await old.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://example.com/')),
      );
    } catch (e) {
      err = e;
    }

    expect(
      err,
      isNotNull,
      reason: '旧控制器该是废的 —— 否则 `controllerOwnsView` 那道守卫没必要存在',
    );
    expect(err.toString(), contains('disposed'));
  });
}
