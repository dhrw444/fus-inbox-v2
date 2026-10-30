import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox_v2/data/identity_profile.dart';
import 'package:fus_inbox_v2/data/identity_roster.dart';
import 'package:fus_inbox_v2/data/proxy_config.dart';
import 'package:fus_inbox_v2/data/visitor.dart';
import 'package:fus_inbox_v2/data/visitor_session.dart';

/// 一个假的出口池 + 切出口记录。
///
/// 不真起桥、不发请求 —— 这几条性质（记忆、切换、两样一起换）全是
/// 决策逻辑，和网络无关。用假的池才能把「切到哪一条」断言清楚。
class _FakeEgress(this.pool) {
  final List<ProxyConfig> pool;
  ProxyConfig? current;
  final List<String> switched = [];
  final List<String> applied = [];

  /// 把某条出口设成「切不过去」，用来测降级路径。
  String? failOn;

  Future<bool> switchTo(ProxyConfig p) async {
    if (p.id == failOn) return false;
    switched.add(p.id);
    current = p;
    return true;
  }
}

ProxyConfig _eg(String host, int port) =>
    ProxyConfig(scheme: ProxyScheme.socks5, host: host, port: port);

/// 每次给一份**不同**的画像，模拟真实的 `rotateIdentity()`。
///
/// 写成常量的话「换了身份」这条断言恒假 —— 而那不是测试写错，是它
/// 正好证明了「身份不变」。真实的 `rotateIdentity()` 每次都会变
/// （机型、屏幕、时区都在动），所以假件也必须变。
IdentityProfile _profile(int n) => IdentityProfile(
  userAgent:
      'Mozilla/5.0 (Linux; Android 1$n; Model-$n) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/14$n.0.7000.$n Mobile Safari/537.36',
  model: 'Model-$n',
  androidVersion: '1$n',
  chromeMajor: 140 + n,
  screen: ScreenProfile.phones[n % ScreenProfile.phones.length],
  language: 'en-US',
  timeZone: 'America/New_York',
  hardwareConcurrency: 8,
  deviceMemory: 8,
);

void main() {
  final now = DateTime.utc(2026, 10, 30, 12);

  late _FakeEgress fake;
  late VisitorBook book;
  late IdentityRoster roster;
  late VisitorSession session;
  var mintSeq = 0;
  // 清站点数据的调用次数。换身份不清数据 = 没换，这条要能断言。
  var wipes = 0;

  setUp(() {
    mintSeq = 0;
    wipes = 0;
    fake = _FakeEgress([
      _eg('1.1.1.1', 1080),
      _eg('2.2.2.2', 1080),
      _eg('3.3.3.3', 1080),
    ]);
    book = VisitorBook();
    roster = IdentityRoster();
    session = VisitorSession(
      book: book,
      roster: roster,
      currentEgress: () => fake.current,
      egressPool: () => fake.pool,
      switchEgress: fake.switchTo,
      applyIdentity: (p) => fake.applied.add(p.userAgent),
      mintIdentity: () => _profile(++mintSeq),
      wipeSiteData: () async {
        wipes++;
        return true;
      },
      clock: () => now,
      random: Random(42),
    );
  });

  group('P1 不限额', () {
    test('同一个身份看很多个号，不会被拦', () async {
      // 连看 20 个号，都用同一个访客（因为没有轮换过）。
      final plan1 = await session.open('4044225634');
      session.onSucceeded('4044225634');
      final v = session.current!;

      for (var i = 0; i < 20; i++) {
        final digits = '40442256${i.toString().padLeft(2, '0')}';
        final plan = await session.open(digits);
        // 没有任何配额拦它 —— 用的还是同一个访客。
        expect(plan.identityId, v.identityId, reason: '第 $i 个号不该换身份');
        expect(plan.egress?.id, v.egressId, reason: '第 $i 个号不该换出口');
        session.onSucceeded(digits);
      }
      // 第一个号必然换一次：还没有「当前访客」，只能新造。
      expect(plan1.reused, isFalse, reason: '第一次打开没有当前访客，必须新造');
      expect(wipes, 1, reason: '只该为「第一次造身份」清一次');

      // 之后 20 个号**一个都不该换** —— 没有任何配额拦它。
      // 这条才是 P1 的核心：不限额。
      expect(wipes, 1, reason: '20 个号看下来不该再清第二次');
    });
  });

  group('P3/P4 按号码记忆', () {
    test('再次打开同一个号，切回当时的出口 + 身份', () async {
      // 第一次：看 A，用某个访客。
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final remembered = session.current!;

      // 换去看 B，访客可能被轮换。
      await session.open('4155550100');
      session.onSucceeded('4155550100');

      // 回头打开 A —— 必须切回 A 当时那个访客。
      final back = await session.open('4044225634');
      // 切回旧身份也要清数据：IndexedDB 里现在装的是 B 那轮留下的密钥，
      // 不清就是「旧 UA + 别人的密钥」。
      expect(wipes, greaterThan(0), reason: '切回记忆里的身份也要清站点数据');
      expect(back.reused, isTrue, reason: '有记忆就该复用');
      expect(back.egress?.id, remembered.egressId);
      expect(back.identityId, remembered.identityId);
      // 而且确实把出口切过去了。
      expect(fake.current?.id, remembered.egressId);
      // 身份也应用了。
      expect(fake.applied.last, roster.uaOf(remembered.identityId));

      // B 的记忆还在（A 的恢复不该抹掉 B）。
      final bHit = book.visitorFor('4155550100', now);
      expect(bHit, isNotNull);
      expect(bHit!.egressId.isNotEmpty, isTrue);
    });

    test('记忆里的出口已下架 → 当作没记忆，不硬切', () async {
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final remembered = session.current!;

      // 把池子换成不含那条出口的。
      fake.pool.removeWhere((p) => p.id == remembered.egressId);

      final back = await session.open('4044225634');
      // 切不过去，所以不是「复用」，但要给出一个能用的方案。
      expect(back.reused, isFalse);
      expect(back.egress, isNotNull);
      // 记忆被清掉了，下次不再试着切回一个不存在的出口。
      expect(book.visitorFor('4044225634', now), isNull);
    });

    test('记忆过期 → 不再切回', () async {
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final remembered = session.current!;

      // 往前拨 7 小时（memoryTtl 是 6 小时）。
      final later = now.add(const Duration(hours: 7));
      final s2 = VisitorSession(
        book: book,
        roster: roster,
        currentEgress: () => fake.current,
        egressPool: () => fake.pool,
        switchEgress: fake.switchTo,
        applyIdentity: (p) => fake.applied.add(p.userAgent),
        mintIdentity: () => _profile(++mintSeq),
        wipeSiteData: () async {
          wipes++;
          return true;
        },
        clock: () => later,
        random: Random(7),
      );
      final back = await s2.open('4044225634');
      expect(back.reused, isFalse, reason: '过期记忆不该复用');
      expect(remembered.identityId.isNotEmpty, isTrue);
    });
  });

  group('P2 被拒 → 两样一起换', () {
    test('403 challenge：身份和出口都变', () async {
      await session.open('4044225634');
      final before = session.current!;

      final plan = await session.onRejected('4044225634', temporary: false);
      expect(plan, isNotNull);
      expect(plan!.identityId, isNot(before.identityId), reason: '身份必须换');
      expect(plan.egress?.id, isNot(before.egressId), reason: '出口必须换');
      // 出口真的切了。
      expect(fake.current?.id, plan.egress?.id);
    });

    test('429 pause：也换（带重试秒数）', () async {
      await session.open('4044225634');
      final before = session.current!;

      final plan = await session.onRejected(
        '4044225634',
        temporary: false,
        retrySeconds: 30,
      );
      expect(plan, isNotNull);
      expect(plan!.identityId, isNot(before.identityId));
      expect(plan.egress?.id, isNot(before.egressId));
      // 被拒的组合进了冷却，之后 usable() 会挡住它。
      expect(book.usable(before.egressId, before.identityId, now), isFalse);
    });

    test('503 unavailable：什么都不换，只记一笔', () async {
      await session.open('4044225634');
      final before = session.current!;

      final plan = await session.onRejected('4044225634', temporary: true);
      // 站点自己忙 —— 换什么都没用，返回 null 表示「别换」。
      expect(plan, isNull);
      // 当前访客没变。
      expect(session.current?.identityId, before.identityId);
    });

    test('池里只剩一条出口：换身份，但说清没换 IP', () async {
      fake.pool
        ..clear()
        ..add(_eg('1.1.1.1', 1080));
      await session.open('4044225634');
      final before = session.current!;

      final plan = await session.onRejected('4044225634', temporary: false);
      expect(plan, isNotNull);
      expect(plan!.identityId, isNot(before.identityId), reason: '身份还是要换');
      // 没有别的出口可换，reason 里要说出来。
      expect(plan.reason, contains('没有别的出口'));
    });
  });

  group('身份名册', () {
    test('同一个画像算出同一个 id', () {
      final p = _profile(1);
      expect(identityDigest(p), identityDigest(_profile(1)));
    });

    test('不同画像算出不同 id', () {
      expect(identityDigest(_profile(1)), isNot(identityDigest(_profile(2))));
    });

    test('UA 一样但屏幕不同 → 是两个身份', () {
      // 这条证明「身份不只是 UA」。机型池不大，两个身份碰巧同 UA
      // 很正常 —— 但屏幕不同就是两个人。
      final a = _profile(1);
      final b = IdentityProfile(
        userAgent: a.userAgent,
        model: a.model,
        androidVersion: a.androidVersion,
        chromeMajor: a.chromeMajor,
        screen: ScreenProfile.phones.last,
        language: a.language,
        timeZone: a.timeZone,
        hardwareConcurrency: a.hardwareConcurrency,
        deviceMemory: a.deviceMemory,
      );
      expect(identityDigest(a), isNot(identityDigest(b)));
    });

    test('记进去能还原整套画像，不只是 UA', () {
      final r = IdentityRoster();
      final p = _profile(1);
      final id = r.remember(p);
      final back = r.profileOf(id);
      expect(back, isNotNull);
      expect(back!.userAgent, p.userAgent);
      // 屏幕和时区也必须还原 —— 只还原 UA 就是「换了一半」。
      expect(back.screen.width, p.screen.width);
      expect(back.timeZone, p.timeZone);
      expect(r.length, 1);
    });

    test('没记过的 id 还原不出来', () {
      expect(IdentityRoster().profileOf('deadbeef'), isNull);
    });

    test('超过上限时淘汰最久没用的', () {
      final r = IdentityRoster();
      for (var i = 0; i < kIdentityRosterCap + 5; i++) {
        r.remember(_profile(i));
      }
      expect(r.length, kIdentityRosterCap);
      // 最早那条没了。
      expect(r.profileOf(identityDigest(_profile(0))), isNull);
      // 最近那条还在。
      expect(
        r.profileOf(identityDigest(_profile(kIdentityRosterCap + 4))),
        isNotNull,
      );
    });

    test('落盘再读回，id 不变', () {
      final r = IdentityRoster();
      final p = _profile(1);
      final id = r.remember(p);

      final r2 = IdentityRoster()..restore(r.toMap());
      expect(r2.profileOf(id)?.userAgent, p.userAgent);
      expect(r2.profileOf(id)?.timeZone, p.timeZone);
    });
  });

  group('清站点数据的结果要如实说出来', () {
    /// 造一个 wipe 结果固定的会话。
    VisitorSession make(bool? Function() wipe) => VisitorSession(
      book: book,
      roster: roster,
      currentEgress: () => fake.current,
      egressPool: () => fake.pool,
      switchEgress: fake.switchTo,
      applyIdentity: (p) => fake.applied.add(p.userAgent),
      mintIdentity: () => _profile(++mintSeq),
      wipeSiteData: () async {
        wipes++;
        return wipe();
      },
      clock: () => now,
      random: Random(11),
    );

    test('清不了（页面还没建）→ 顶回调用方，且不说成「没清干净」', () async {
      final s = make(() => null);
      final plan = await s.open('4044225634');
      // 关键：null 不是失败。说成「没清干净」会把用户带到错误的排查方向
      // ——真相是这次根本没清，页面加载完会补做。
      expect(plan.reason, isNot(contains('没清干净')));
      expect(plan.reason, contains('加载完会立刻清'));
      // 而且要**顶回调用方**，否则这次换身份永远漏掉清库那一步。
      // 之前这里存盘上的标记，现在靠返回值 —— 跨页标记会在应用被杀掉
      // 之后变成一条没人消费的陈旧状态，下次打开莫名其妙清一次库。
      expect(plan.wipeDeferred, isTrue, reason: '清不了就要顶回去，不然密钥永远不清');
    });

    test('清成功 → wipeDeferred 为假，调用方不必补做', () async {
      final s = make(() => true);
      final plan = await s.open('4044225634');
      expect(plan.wipeDeferred, isFalse);
      expect(plan.reason, isNot(contains('加载完会立刻清')));
    });

    test('真清失败 → 说「没清干净」，不说成「加载完会清」', () async {
      final s = make(() => false);
      final plan = await s.open('4044225634');
      expect(plan.reason, contains('没清干净'));
      expect(plan.reason, isNot(contains('加载完会立刻清')));
    });

    test('清干净了 → reason 里两个都不提', () async {
      final s = make(() => true);
      final plan = await s.open('4044225634');
      expect(plan.reason, isNot(contains('没清干净')));
      expect(plan.reason, isNot(contains('加载完会立刻清')));
    });
  });

  group('手动重置访客', () {
    test('重置后换到另一个访客 —— 不能原样返回当前那一对', () async {
      // 先正常打开一次，手里有「当前访客」。
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final before = session.current!;

      final plan = await session.reset('4044225634');

      // 这两条是这次动作存在的全部意义。少了任何一条，用户点了按钮、
      // 界面也报了文案，实际还是同一个人在看同一个号。
      expect(
        plan.identityId,
        isNot(before.identityId),
        reason: '重置必须换身份，否则站点看到的还是同一个人',
      );
      expect(
        plan.egress?.id,
        isNot(before.egressId),
        reason: '重置必须换出口，否则站点看到的还是同一个 IP',
      );
      expect(plan.reused, isFalse);
    });

    test('重置后紧接着 open 不会又切回旧的那一对', () async {
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final before = session.current!;

      await session.reset('4044225634');
      session.onSucceeded('4044225634');

      // 关键点：重置把旧组合记进了拒绝账，所以接下来的 `open` 走不到
      // 「当前还能用就用它」那条捷径。不记账的话它照样返回 `before`，
      // 用户点按钮那次换人就白换了。
      final again = await session.open('4044225634');
      expect(again.identityId, isNot(before.identityId));
      expect(again.egress?.id, isNot(before.egressId));
    });

    test('重置清掉这个号的记忆 —— 下次打开不许再照旧切回去', () async {
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final before = session.current!;
      expect(
        book.visitorFor('4044225634', now),
        before,
        reason: '前提：这一轮确实记下了记忆',
      );

      await session.reset('4044225634');

      // 记忆清掉了，下次打开只能看「当前访客」那一路 —— 而它已经被
      // 重置换成了新的。留着记忆的话，重置完再打开又回到刚才那一对。
      expect(book.visitorFor('4044225634', now), isNull);
    });

    test('重置作废旧身份在别的号码上的记忆', () async {
      // 先让同一个访客看两个号，两个号都记下它。
      await session.open('4044225634');
      session.onSucceeded('4044225634');
      final old = session.current!;
      await session.open('4155550100');
      session.onSucceeded('4155550100');
      expect(
        book.visitorFor('4155550100', now),
        old,
        reason: '前提：第二个号也记的是同一个访客',
      );

      await session.reset('4044225634');

      // 这条是 `reset` 里那步 `block` 存在的**全部理由**：被换掉的身份
      // 已经判定不可信，它在别的号码上的记忆也必须一起失效（`block`
      // 内部会清，见 `visitor.dart:205`）。只清当前这个号的记忆是不够
      // 的 —— 用户重置完点开另一个号，又会照着一份不可信的记忆切回刚
      // 被换掉的那个人。
      expect(
        book.visitorFor('4155550100', now),
        isNull,
        reason: '旧身份在别的号上的记忆也要作废',
      );
    });
  });

  group('记忆落盘', () {
    test('访客记忆能存能读', () {
      final b = VisitorBook();
      const v = Visitor(egressId: 'socks5://1.1.1.1:1080', identityId: 'abc');
      b.rememberGood('4044225634', v, now);
      b.block(
        'socks5://2.2.2.2:1080',
        'def',
        now,
        temporary: false,
        retrySeconds: 30,
      );

      final json = b.toJson();
      final b2 = VisitorBook()..restore(json);

      expect(b2.visitorFor('4044225634', now), v);
      expect(b2.blockedCount, 1);
    });

    test('坏的磁盘数据不让整份作废', () {
      final b = VisitorBook();
      // 故意塞几条坏条目，混一条好的。
      b.restore({
        'hits': {
          // 时间戳必须是**现在附近** —— 用 0 的话换算出来是 1970 年，
          // 早过了 memoryTtl（6 小时），记忆会被当成过期而读不出来。
          // 这条用例要验的是「坏条目跳过」，不是「过期跳过」。
          '4044225634': [
            'socks5://1.1.1.1:1080',
            'abc',
            now.millisecondsSinceEpoch,
          ],
          'bad1': ['only-one-element'], // 长度不够
          'bad2': 'not-a-list', // 类型不对
        },
        'bound': {'eg': 'id', 'bad': 123},
        'blocked': {'k': 'not-int'},
      });
      // 好的那条活下来了。
      expect(b.visitorFor('4044225634', now), isNotNull);
      expect(b.rememberedCount, 1);
    });
  });
}
