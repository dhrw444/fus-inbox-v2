import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox_v2/core/site_grant.dart';

void main() {
  // 站点真实形状：32 位 hex sid + 毫秒 until。
  final now = DateTime.utc(2026, 10, 30, 12);
  String grant({String sid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90', int? until}) {
    final u = until ?? now.add(const Duration(hours: 1)).millisecondsSinceEpoch;
    return '{"sid":"$sid","until":$u,"offset":0}';
  }

  group('站点凭证判据', () {
    test('合法且没过期 → 通过', () {
      expect(isLiveGrant(grant(), now: now), isTrue);
    });

    test('已过期 → 不通过（站点下次请求会拒）', () {
      expect(
        isLiveGrant(
          grant(
            until: now
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch,
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('sid 不是 32 位 hex → 不通过', () {
      expect(isLiveGrant(grant(sid: 'abc'), now: now), isFalse);
      expect(
        isLiveGrant(grant(sid: 'A1B2C3D4E5F60718293A4B5C6D7E8F90'), now: now),
        isFalse,
        reason: '站点正则是小写 a-f，大写不算',
      );
      expect(
        isLiveGrant(grant(sid: 'a1b2c3d4e5f60718293a4b5c6d7e8f9'), now: now),
        isFalse,
        reason: '少一位也不算',
      );
    });

    test('空 / null / 坏 JSON → 不通过', () {
      expect(isLiveGrant(null, now: now), isFalse);
      expect(isLiveGrant('', now: now), isFalse);
      expect(isLiveGrant('null', now: now), isFalse);
      expect(isLiveGrant('{broken', now: now), isFalse);
      expect(
        isLiveGrant('{"sid":"a1b2c3d4e5f60718293a4b5c6d7e8f90"}', now: now),
        isFalse,
        reason: '缺 until 就没有过期判断',
      );
    });

    test('cf_clearance 那种 cookie 字符串不算凭证', () {
      // 这条是回归：上一版拿 cf_clearance 当判据，站点根本不下发它。
      expect(isLiveGrant('cf_clearance=abc123', now: now), isFalse);
    });

    test('键名要和站点一致', () {
      expect(kSiteGrantKey, 'fus:reader:v1');
    });
  });
}
