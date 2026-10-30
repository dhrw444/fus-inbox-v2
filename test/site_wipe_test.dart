import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/platform/site_wipe.dart';

void main() {
  group('清站点数据的判定', () {
    test('库删了 + 凭证删了 → 算清干净', () {
      const r = WipeResult(indexedDb: true, localStorage: true, sessionStorage: true);
      expect(r.identityCleared, isTrue);
    });

    test('库没删 → 不算清干净（密钥还在就是同一个人）', () {
      const r = WipeResult(indexedDb: false, localStorage: true, sessionStorage: true);
      expect(r.identityCleared, isFalse);
    });

    test('凭证没删 → 不算清干净', () {
      const r = WipeResult(indexedDb: true, localStorage: false, sessionStorage: true);
      expect(r.identityCleared, isFalse);
    });

    test('被 blocked 挡过 → 不算清干净，哪怕两个都报成功', () {
      const r = WipeResult(
        indexedDb: true,
        localStorage: true,
        sessionStorage: true,
        blocked: true,
      );
      expect(r.identityCleared, isFalse,
          reason: 'blocked 时库很可能还在，报成功会让上层不再重试');
    });

    test('failed 常量本身不算清干净', () {
      expect(WipeResult.failed.identityCleared, isFalse);
    });

    test('failed 常量本身不算清干净', () {
      expect(WipeResult.failed.identityCleared, isFalse);
    });

    test('blocked 和「请求失败」是两个独立字段', () {
      // 删库请求失败（indexedDb:false, blocked:false）和「被挡住、删没删
      // 掉不确定」（blocked:true）是两件事，排查时看哪个字段决定了
      // 该不该重试。两个字段必须能独立表达。
      //
      // **脚本本身的行为不在这里验** —— `_wipeBody` 是 JS，Dart 测试
      // 跑不了它。真正的行为验证是 `tool/wipe_harness.js`（用假的
      // indexedDB 在 node 里跑真实脚本体）。改脚本时两个都要跑。
      const failedReq = WipeResult(
        indexedDb: false,
        localStorage: true,
        sessionStorage: true,
      );
      const blockedReq = WipeResult(
        indexedDb: false,
        localStorage: true,
        sessionStorage: true,
        blocked: true,
      );
      expect(failedReq.blocked, isFalse);
      expect(blockedReq.blocked, isTrue);
      expect(failedReq.identityCleared, isFalse);
      expect(blockedReq.identityCleared, isFalse);
    });
  });
}
