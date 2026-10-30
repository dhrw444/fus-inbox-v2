// 身份画像落盘：写进去的必须能原样读回来。
//
// **这个文件存在的理由是一次真实的回归。** 全仓唯一写 `kProfileKey`
// 的地方原本在出口页那张身份卡里；那张卡删掉之后，两个键变成
// 「只读不写」—— `main` 里启动恢复还在读它们，永远读不到，于是冷启动
// 会退回本机真值指纹，而站点 IndexedDB 里存的还是上一个身份的密钥。
//
// 所以这里必须钉住两件事：
//   1. `writeProfile()` 真的往**两个**键里写了东西；
//   2. 写进去的能 `fromJson` 回来，且和原画像逐字段一致。
//
// 用官方的 `SharedPreferences.setMockInitialValues` —— 不自己造存储假件。

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fus_inbox_v2/core/store.dart';
import 'package:fus_inbox_v2/core/user_agent.dart';
import 'package:fus_inbox_v2/data/identity_profile.dart';
import 'package:fus_inbox_v2/main.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('writeProfile 把画像写进 kProfileKey，且能原样读回', () async {
    final p = IdentityProfile.mint(kernelMajor: 141, rnd: Random(7));
    applyIdentityProfile(p);

    await app.writeProfile();

    final raw = await app.store.read(kProfileKey);
    expect(raw, isNotNull, reason: 'kProfileKey 必须被写入');
    final back = IdentityProfile.fromJson(jsonDecode(raw!));
    expect(back, isNotNull, reason: '写进去的必须能解析回来');
    // 逐字段比。UA 相同但屏幕不同也是「换了个人」，只比 UA 会漏掉。
    expect(back!.userAgent, p.userAgent);
    expect(back.model, p.model);
    expect(back.androidVersion, p.androidVersion);
    expect(back.chromeMajor, p.chromeMajor);
    expect(back.screen.width, p.screen.width);
    expect(back.screen.height, p.screen.height);
    expect(back.screen.devicePixelRatio, p.screen.devicePixelRatio);
    expect(back.language, p.language);
    expect(back.timeZone, p.timeZone);
  });

  test('writeProfile 同时写 kUserAgentKey —— 老恢复路径读的是它', () async {
    final p = IdentityProfile.mint(kernelMajor: 141, rnd: Random(8));
    applyIdentityProfile(p);

    await app.writeProfile();

    // `main` 里 `currentProfile == null` 那条兜底路径读的是这个键。
    // 只写 kProfileKey 的话，那份坏掉时就没得退。
    expect(await app.store.read(kUserAgentKey), p.userAgent);
  });

  test('没有画像时要把旧键删掉 —— 不许留下过期身份', () async {
    // 先让它盘上真的有一份有效画像。
    final p = IdentityProfile.mint(kernelMajor: 141, rnd: Random(9));
    applyIdentityProfile(p);
    await app.writeProfile();
    expect(await app.store.read(kProfileKey), isNotNull, reason: '前提：盘上有画像');

    // 回到内核真值 —— currentProfile 变 null。
    bootstrapUserAgent(
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
    );
    resetIdentity();
    expect(currentProfile, isNull, reason: '前提：确实回到内核真值了');

    await app.writeProfile();

    // 这条是重点。留着旧画像的话，冷启动会照着一份早就作废的身份把假
    // 指纹装回去 —— 用户明明重置过，开机却又是那个人，而且日志里没有
    // 任何迹象。删掉才是「重置」。
    expect(await app.store.read(kProfileKey), isNull, reason: '旧画像必须消失');
    expect(await app.store.read(kUserAgentKey), isNull);
  });
}
