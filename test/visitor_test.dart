import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/data/inbox_state.dart';
import 'package:fus_inbox/data/visitor.dart';

void main() {
  const a = VisitorKey(egressId: 'socks5://1.2.3.4:1080', identityId: 'ua-A');
  const b = VisitorKey(egressId: 'socks5://5.6.7.8:1080', identityId: 'ua-A');
  final t0 = DateTime.utc(2026, 1, 1, 12);

  test('没撞过墙的访客可以用', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    expect(c.isUsable(a, t0), isTrue);
  });

  test('撞墙后进冷却，到期自动放行', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    c.record(a, HoldKind.quota, 10, t0);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 5))), isFalse);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 10))), isTrue);
  });

  test('冷却只影响撞墙的那个二元组', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    c.record(a, HoldKind.quota, 10, t0);
    // 换了出口、身份没变 → 是另一个访客，不受影响
    expect(c.isUsable(b, t0.add(const Duration(seconds: 5))), isTrue);
  });

  test('Retry-After 缺失时用兜底值', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    c.record(a, HoldKind.quota, 0, t0);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 20))), isFalse);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 30))), isTrue);
  });

  test('temporary 不记冷却 —— 它跟出口无关', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    c.record(a, HoldKind.temporary, 10, t0);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 5))), isTrue);
  });

  test('换出口后清掉该出口的记录', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    c.record(a, HoldKind.quota, 10, t0);
    c.forgetEgress(a.egressId);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 5))), isTrue);
  });

  test('换身份后清掉该身份的记录', () {
    final c = VisitorCooldowns(fallbackSeconds: 30);
    c.record(a, HoldKind.quota, 10, t0);
    c.forgetIdentity(a.identityId);
    expect(c.isUsable(a, t0.add(const Duration(seconds: 5))), isTrue);
  });
}
