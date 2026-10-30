import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox_v2/data/visitor.dart';

/// 断言失败时 `package:test` 会打印 got/want 差异并让进程退出非 0。
void _ok(String label, bool cond) => expect(cond, isTrue, reason: label);
void _eq(String label, Object? got, Object? want) =>
    _ok('$label  (got=$got want=$want)', got == want);

void main() {
  test('一对一绑定', _testBinding);
  test('拒绝记录与临时繁忙', _testBlocked);
  test('换什么：按判据给出建议', _testPlan);
}

void _testBinding() {
  // 新出口 + 新身份 → 能绑。
  {
    final b = VisitorBook();
    _ok('空表能绑', b.bind('e1', 'i1'));
    _eq('出口查身份', b.identityOf('e1'), 'i1');
    _eq('身份查出口', b.egressOf('i1'), 'e1');
    _eq('绑了一对', b.boundCount, 1);
  }

  // 同一个出口绑第二个身份 → 必须被拒。
  //
  // 这是整份文件的核心不变量：同一个 IP 上出现两个身份，是站点眼里
  // 最扎眼的信号（真实用户不会前脚一台设备后脚换另一台）。
  {
    final b = VisitorBook();
    b.bind('e1', 'i1');
    _ok('同出口换身份被拒', !b.bind('e1', 'i2'));
    _eq('原绑定没被动', b.identityOf('e1'), 'i1');
    _eq('i2 仍然没绑', b.egressOf('i2'), null);
  }

  // 同一个身份绑到第二个出口 → 同样被拒。
  {
    final b = VisitorBook();
    b.bind('e1', 'i1');
    _ok('同身份换出口被拒', !b.bind('e2', 'i1'));
    _eq('原绑定没被动', b.egressOf('i1'), 'e1');
  }

  // 重复绑同一对 → 返回 false（没改动），不是错误。
  {
    final b = VisitorBook();
    b.bind('e1', 'i1');
    _ok('重复绑不算改动', !b.bind('e1', 'i1'));
    _eq('还是一对', b.boundCount, 1);
  }

  // 解绑之后可以重绑。
  {
    final b = VisitorBook();
    b.bind('e1', 'i1');
    b.forgetEgress('e1');
    _eq('解绑后出口没身份', b.identityOf('e1'), null);
    _eq('反向索引也清了', b.egressOf('i1'), null);
    _ok('解绑后能绑新身份', b.bind('e1', 'i2'));
    _eq('新身份绑上了', b.identityOf('e1'), 'i2');
  }

  // 解绑一个身份，出口也要跟着释放。
  {
    final b = VisitorBook();
    b.bind('e1', 'i1');
    b.forgetIdentity('i1');
    _eq('身份解绑后出口空', b.identityOf('e1'), null);
  }
}

void _testBlocked() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  // 没撞过墙 → 能用，等待为 0。
  {
    final b = VisitorBook();
    _ok('没撞过能用', b.usable('e1', 'i1', t0));
    _eq('等待为 0', b.waitFor('e1', 'i1', t0), Duration.zero);
  }

  // 记一次非临时拒绝，带 Retry-After。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    _ok('刚撞不能用', !b.usable('e1', 'i1', t0));
    _eq('还剩 60 秒', b.waitFor('e1', 'i1', t0), const Duration(seconds: 60));
    _ok(
      '到期前 1 秒仍不能用',
      !b.usable('e1', 'i1', t0.add(const Duration(seconds: 59))),
    );
    _ok('到期后能用', b.usable('e1', 'i1', t0.add(const Duration(seconds: 60))));
    _eq('过期记录被删', b.blockedCount, 0);
  }

  // 没给 Retry-After → 用兜底值。
  {
    final b = VisitorBook()..fallbackWait = const Duration(seconds: 20);
    b.block('e1', 'i1', t0, temporary: false);
    _eq('用兜底值', b.waitFor('e1', 'i1', t0), const Duration(seconds: 20));
  }

  // 临时繁忙不记 —— 站点自己忙，跟 IP 和身份都无关。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: true, retrySeconds: 60);
    _ok('临时繁忙不记', b.usable('e1', 'i1', t0));
    _eq('表还是空的', b.blockedCount, 0);
  }

  // 只影响被记的那一对，不波及别的组合。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    _ok('同出口别的身份还能用', b.usable('e1', 'i2', t0));
    _ok('同身份别的出口还能用', b.usable('e2', 'i1', t0));
  }

  // 换出口之后，那个出口名下的记录清掉。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    b.forgetEgress('e1');
    _ok('清掉后能用', b.usable('e1', 'i1', t0));
    _eq('表空了', b.blockedCount, 0);
  }
}

void _testPlan() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  const others = ['e2', 'e3'];
  const otherIds = ['i2', 'i3'];

  // 只有这一对被拒 → 两样都换。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    final p = b.plan(
      egressId: 'e1',
      identityId: 'i1',
      now: t0,
      otherEgresses: others,
      otherIdentities: otherIds,
    );
    _ok('两样都换', p.switchEgress && p.switchIdentity);
    _ok('没判出口有问题', !p.egressSuspect);
    _ok('没判身份有问题', !p.identitySuspect);
  }

  // 同一个出口下别的身份也被拒 → 问题在出口。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    b.block('e1', 'i2', t0, temporary: false, retrySeconds: 60);
    final p = b.plan(
      egressId: 'e1',
      identityId: 'i1',
      now: t0,
      otherEgresses: others,
      otherIdentities: otherIds,
    );
    _ok('判出口有问题', p.egressSuspect);
    _ok('换出口', p.switchEgress);
    _ok('身份没问题就不换身份', !p.switchIdentity);
    _ok('理由说清了', p.explain().contains('问题在出口'));
  }

  // 同一个身份在别的出口也被拒 → 问题在身份。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    b.block('e2', 'i1', t0, temporary: false, retrySeconds: 60);
    final p = b.plan(
      egressId: 'e1',
      identityId: 'i1',
      now: t0,
      otherEgresses: others,
      otherIdentities: otherIds,
    );
    _ok('判身份有问题', p.identitySuspect);
    _ok('换身份', p.switchIdentity);
    _ok('理由说清了', p.explain().contains('问题在身份'));
  }

  // 没有别的出口也没有别的身份 → 什么也换不了，必须如实说。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    final p = b.plan(
      egressId: 'e1',
      identityId: 'i1',
      now: t0,
      otherEgresses: const [],
      otherIdentities: const [],
    );
    _ok('换不了', p.isNoop);
    _ok('说出了原因', p.explain().contains('只能等'));
  }

  // 判据要看「别的」组合，不能把当前这一对自己算进去。
  {
    final b = VisitorBook();
    b.block('e1', 'i1', t0, temporary: false, retrySeconds: 60);
    final p = b.plan(
      egressId: 'e1',
      identityId: 'i1',
      now: t0,
      otherEgresses: others,
      otherIdentities: otherIds,
    );
    // 当前这一对当然是被拒的，但那不该被算成「出口有问题」。
    _ok('自己那一对不算证据', !p.egressSuspect && !p.identitySuspect);
  }
}
