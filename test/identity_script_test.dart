import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox_v2/data/identity_profile.dart';
import 'package:fus_inbox_v2/platform/identity_script.dart';

IdentityProfile _p({
  String lang = 'en-US',
  String tz = 'America/New_York',
  int cores = 8,
  int mem = 8,
}) => IdentityProfile(
  userAgent:
      'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/141.0.7390.122 Mobile Safari/537.36',
  model: 'Pixel 8 Pro',
  androidVersion: '14',
  chromeMajor: 141,
  screen: ScreenProfile.phones.first,
  language: lang,
  timeZone: tz,
  hardwareConcurrency: cores,
  deviceMemory: mem,
);

void main() {
  group('环境伪装脚本', () {
    test('没有画像时不注入任何东西', () {
      // null = 还没换过身份，还是内核那台机器。此时注入等于
      // 把真实值改写成别的东西，反而制造矛盾。
      expect(identityScript(null), isEmpty);
    });

    test('有画像时生成的脚本带上了每一项要改的值', () {
      final s = identityScript(_p());
      final sc = ScreenProfile.phones.first;
      expect(s, contains('${sc.width}'));
      expect(s, contains('${sc.height}'));
      expect(s, contains('${sc.devicePixelRatio}'));
      expect(s, contains('America/New_York'));
      expect(s, contains('en-US'));
      expect(s, contains('8'));
    });

    test('不同画像生成不同脚本', () {
      final a = identityScript(_p());
      final b = identityScript(_p(tz: 'Europe/London', lang: 'en-GB'));
      expect(a, isNot(b));
    });

    test('脚本把自己包起来，不污染全局', () {
      // IIFE 包住：站点读不到我们定义的临时变量。
      final s = identityScript(_p());
      expect(s.trimLeft(), startsWith('(function'));
    });

    test('方法型属性直接装函数，不套一层 return', () {
      // 这条是回归测试。曾经写成 `value: function(){ return val; }`，
      // 于是 `getHighEntropyValues()` 返回的是**函数本身**而不是
      // Promise —— 站点 `await` 它拿到一个函数，读 `.platformVersion`
      // 得到 undefined。编译、语法、看起来全正常，实测才露。
      final s = identityScript(_p());
      // 只看 `defFn` 的**函数体**，不看全文 —— 注释里提到那句
      // `return val;`（作为反面例子），搜全文会命中注释。
      final body = s.substring(
        s.indexOf('function defFn'),
        s.indexOf('}', s.indexOf('function defFn')),
      );
      expect(body, isNot(contains('return val')));
      expect(body, contains('value: fn'));
      expect(s, contains('defFn(navigator.userAgentData'));
    });

    test('UA 里的 Chrome 大版本和画像一致', () {
      // UA 说 141、brands 也说 141、uaFullVersion 也说 141。
      // 三处对不上就是「手改的 UA」。
      final s = identityScript(_p());
      expect(s, contains('141'));
    });
  });
}
