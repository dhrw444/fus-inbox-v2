/// `lib2/` 新代码的单测。
///
/// 跑法（不需要 Flutter SDK，纯 Dart）：
///
/// ```
/// dart run tool/rewrite_test.dart
/// ```
///
/// ## 为什么新代码全部写成纯逻辑
///
/// 旧代码最大的问题不是「有 bug」，而是**bug 无法验证**：判断逻辑埋在
/// Timer 回调、`initState`、`onChanged` 里，只能靠读代码「看着对」。
/// 于是每次改动都可能在别处引入新问题，而症状要等真机才知道。
///
/// 新代码把判断全部抽成纯函数：输入 → 输出，无副作用。这样每一块都能
/// 在本机跑断言，改一处不会静默弄坏另一处。
library;

import 'dart:math';
import '../lib/core/code_extract.dart';
import '../lib/core/sms_message.dart';
import '../lib/core/user_agent.dart';
import '../lib/data/frame.dart';
import '../lib/data/inbox_state.dart';
import '../lib/data/inbox_store.dart';
import '../lib/data/verify_round.dart';
import '../lib/data/merge_frame.dart';

int _pass = 0;
int _fail = 0;

void _ok(String label, bool cond) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
    print('FAIL $label');
  }
}

void _eq(String label, Object? got, Object? want) {
  _ok('$label  (got=$got want=$want)', got == want);
}

SmsMessage _m(String id, {String text = 'body', String time = ''}) =>
    SmsMessage(id: id, text: text, time: time);

void main() {
  _testCodeExtract();
  _testMerge();
  _testState();
  _testFrame();
  _testVerify();
  _testStore();
  _testUserAgent();
  print('\n$_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail failed');
}

void _testCodeExtract() {
  // ── 正常验证码 ──
  _eq('英文标准句式', extractCode('Your code is 123456').value, '123456');
  _eq('中文句式', extractCode('验证码：8888，请勿泄露').value, '8888');
  _eq('带句号', extractCode('Code: 482913.').value, '482913');

  // ── 必须排除的（这是最容易出错的部分）──
  _eq('电话号码不算', extractCode('Call 123-456-7890 now').value, '');
  _eq('带加号电话', extractCode('+1 415 555 0100 is your number').value, '');
  _eq('金额不算', extractCode('You saved \$1234 today').value, '');
  _eq('日期不算', extractCode('Order on 2026-10-29').value, '');
  _eq('时间不算', extractCode('Meeting at 09:30').value, '');
  _eq('字母前缀不算', extractCode('ID ABC123456').value, '');
  _eq('纯零不算', extractCode('code 000000').value, '');
  _eq('空串', extractCode('').value, '');

  // ── 多候选取最长 ──
  _eq('订单号 vs 验证码', extractCode('order 4455, code 998877').value, '998877');

  // ── 语义确认 ──
  _ok('验证短信判真', looksLikeVerification('Your verification code is 123456'));
  _ok('普通短信判假', looksLikeVerification('Your order 445566 has shipped'));
  _ok(
    '短句无关键词也算（纯验证码短信）',
    looksLikeVerification('123456'),
  );
  _ok(
    '长句无关键词不算',
    !looksLikeVerification(
      'This is a very long message without any relevant words at all 123456',
    ),
  );
}

void _testMerge() {
  // ── 首帧：全部算旧 ──
  {
    final r = mergeFrame(
      current: const [],
      incoming: [_m('a'), _m('b')],
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('首帧两条', r.messages.length, 2);
    _ok('首帧不算新', !r.anyNew);
    _eq('seen 记了两条', r.seenIds.length, 2);
  }

  // ── 后续帧：新 id 算新 ──
  {
    final r = mergeFrame(
      current: [_m('a')],
      incoming: [_m('b')],
      seenIds: {'a'},
      firstFrameDone: true,
    );
    _eq('合并后两条', r.messages.length, 2);
    _ok('b 是新消息', r.anyNew);
  }

  // ── 同 id 补字段，位置不变 ──
  {
    final r = mergeFrame(
      current: [
        SmsMessage(id: 'a', text: '', code: ''),
      ],
      incoming: [
        SmsMessage(id: 'a', text: '完整正文', code: '123456'),
      ],
      seenIds: {'a'},
      firstFrameDone: true,
    );
    _eq('还是一条', r.messages.length, 1);
    _eq('正文补齐', r.messages.first.text, '完整正文');
    _eq('验证码补齐', r.messages.first.code, '123456');
    _ok('不算新（同 id）', !r.anyNew);
  }

  // ── 空 id 丢掉 ──
  {
    final r = mergeFrame(
      current: const [],
      incoming: [SmsMessage(id: '', text: 'x')],
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('空 id 被丢', r.messages.length, 0);
  }

  // ── 裁剪：留最新 240 条 ──
  {
    final many = [
      for (var i = 0; i < 250; i++)
        // 时间要**等宽**：`padLeft(3,'0')` 保证 `10:099` < `10:249`，
        // 字典序才等于时间序。用 `padLeft(2)` 的话 `10:249` 会排在 `10:49`
        // 之后（字符串比较不看位数），测出来的「最新」是错的。
        SmsMessage(
          id: 'id$i',
          text: 't',
          time: '2026-10-29 10:${i.toString().padLeft(3, '0')}',
        ),
    ];
    final r = mergeFrame(
      current: const [],
      incoming: many,
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('裁到 240', r.messages.length, maxMessages);
    _eq('留下最新的一条', r.messages.first.id, 'id249');
    _eq('seen 仍然记全 250', r.seenIds.length, 250);
  }

  // ── 排序：时间新的在前，空时间排最后 ──
  {
    final r = mergeFrame(
      current: const [],
      incoming: [
        _m('noTime'),
        _m('t1', time: '2026-10-29 10:00'),
        _m('t2', time: '2026-10-29 11:00'),
      ],
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('新的在前', r.messages[0].id, 't2');
    _eq('第二新', r.messages[1].id, 't1');
    _eq('无时间排最后', r.messages[2].id, 'noTime');
  }

  // ── 排序稳定：同样输入两次结果一致 ──
  {
    final input = [_m('x'), _m('y'), _m('z')];
    final a = mergeFrame(
      current: const [],
      incoming: input,
      seenIds: const {},
      firstFrameDone: false,
    ).messages.map((e) => e.id).toList();
    final b = mergeFrame(
      current: const [],
      incoming: input,
      seenIds: const {},
      firstFrameDone: false,
    ).messages.map((e) => e.id).toList();
    _ok('排序稳定', a.join(',') == b.join(','));
  }
}

void _testState() {
  // ── shown 不会越界（旧代码里 sublist 越界崩过）──
  {
    const st = InboxState(messages: [], phase: InboxPhase.waiting);
    _eq('空列表 shown 为空', st.shown.length, 0);
  }
  {
    final st = InboxState(
      messages: [for (var i = 0; i < 3; i++) _m('id$i')],
      phase: InboxPhase.ready,
    );
    _eq('3 条少于 visible，全显示', st.shown.length, 3);
    _ok('没有隐藏的', !st.hasHidden);
  }
  {
    final st = InboxState(
      messages: [for (var i = 0; i < 10; i++) _m('id$i')],
      phase: InboxPhase.ready,
    );
    _eq('只显示 5 条', st.shown.length, 5);
    _ok('还有隐藏的', st.hasHidden);
  }

  // ── copyWith 的 clear 语义 ──
  {
    const st = InboxState(
      messages: [],
      phase: InboxPhase.failed,
      error: '代理不可用',
    );
    _eq('不改就保留 error', st.copyWith(status: 'x').error, '代理不可用');
    _eq('clearError 才清', st.copyWith(clearError: true).error, '');
  }
  {
    const hold = SiteHold(kind: HoldKind.quota, title: '', message: '');
    const st = InboxState(messages: [], phase: InboxPhase.waiting, hold: hold);
    _ok('hold 保留', st.copyWith(status: 'x').hold != null);
    _ok('clearHold 才清', st.copyWith(clearHold: true).hold == null);
  }

  // ── applyFrame：拿到消息 → ready + 清 hold + 清 error ──
  {
    const hold = SiteHold(kind: HoldKind.challenge, title: '', message: '');
    final st = InboxState(
      messages: const [],
      phase: InboxPhase.waiting,
      error: '某个错误',
      hold: hold,
    );
    final merged = mergeFrame(
      current: const [],
      incoming: [_m('a')],
      seenIds: const {},
      firstFrameDone: false,
    );
    final next = st.applyFrame(merged: merged, status: '拿到消息了');
    _eq('变成 ready', next.phase, InboxPhase.ready);
    _ok('hold 被清', next.hold == null);
    _eq('error 被清', next.error, '');
    _eq('状态栏更新', next.status, '拿到消息了');
  }

  // ── applyFrame：空帧不报错，保持 waiting ──
  {
    const st = InboxState(messages: [], phase: InboxPhase.waiting);
    final merged = mergeFrame(
      current: const [],
      incoming: const [],
      seenIds: const {},
      firstFrameDone: false,
    );
    final next = st.applyFrame(merged: merged, status: '还没消息');
    _eq('保持 waiting', next.phase, InboxPhase.waiting);
  }

  // ── applyFrame：本来 failed 的，空帧不该把它变回 waiting ──
  {
    const st = InboxState(
      messages: [],
      phase: InboxPhase.failed,
      error: '代理不可用',
    );
    final merged = mergeFrame(
      current: const [],
      incoming: const [],
      seenIds: const {},
      firstFrameDone: false,
    );
    final next = st.applyFrame(merged: merged, status: 'x');
    _eq('保持 failed', next.phase, InboxPhase.failed);
    _eq('error 保留', next.error, '代理不可用');
  }
}

void _testFrame() {
  // ── messages 帧 ──
  {
    final f = parseFrame(
      '{"type":"messages","items":[{"id":"a","text":"hello","code":"1234","sender":"Google","time":"10:00","phone":"+1","protected":false}],"hits":2,"src":"api"}',
    );
    _ok('解析成 MessagesFrame', f is MessagesFrame);
    final mf = f as MessagesFrame;
    _eq('一条消息', mf.items.length, 1);
    _eq('hits', mf.hits, 2);
    _eq('source', mf.source, 'api');
    _eq('正文', mf.items.first.text, 'hello');
    _eq('验证码', mf.items.first.code, '1234');
  }

  // ── 空 id 被过滤 ──
  {
    final f = parseFrame(
      '{"type":"messages","items":[{"id":"","text":"x"},{"id":"b","text":"y"}]}',
    );
    _eq('空 id 丢掉，剩一条', (f as MessagesFrame).items.length, 1);
  }

  // ── 字段缺失用默认值，不崩 ──
  {
    final f = parseFrame('{"type":"messages","items":[{"id":"c"}]}');
    final m = (f as MessagesFrame).items.first;
    _eq('缺正文给空串', m.text, '');
    _eq('缺验证码给空串', m.code, '');
    _ok('缺 protected 给 false', !m.isProtected);
  }

  // ── status 帧 ──
  {
    final f = parseFrame('{"type":"status","text":"正在加载"}');
    _ok('解析成 StatusFrame', f is StatusFrame);
    _eq('文案', (f as StatusFrame).text, '正在加载');
  }

  // ── holdup 帧 ──
  {
    final f = parseFrame(
      '{"type":"holdup","kind":"pause","title":"T","message":"M","retry":30}',
    );
    _ok('解析成 HoldFrame', f is HoldFrame);
    final hf = f as HoldFrame;
    _eq('kind', hf.kind, 'pause');
    _eq('retry', hf.retrySeconds, 30);
    _ok('不是解除', !hf.isClear);
  }
  {
    final f = parseFrame('{"type":"holdup","kind":""}');
    _ok('空 kind = 解除', (f as HoldFrame).isClear);
  }

  // ── moreDone / moreFail ──
  {
    final f = parseFrame('{"type":"moreDone","empty":true}');
    _ok('解析成 MoreDoneFrame', f is MoreDoneFrame);
    _ok('empty 为真', (f as MoreDoneFrame).empty);
  }
  {
    final f = parseFrame('{"type":"moreFail","reason":"no_id"}');
    _eq('失败原因', (f as MoreFailFrame).reason, 'no_id');
  }

  // ── 畸形帧全部丢掉，不抛 ──
  _ok('空串', parseFrame('') == null);
  _ok('非 JSON', parseFrame('not json') == null);
  _ok('非对象', parseFrame('123') == null);
  _ok('没有 type', parseFrame('{"items":[]}') == null);
  _ok('未知 type', parseFrame('{"type":"unknown"}') == null);
  _ok('items 不是数组', parseFrame('{"type":"messages","items":1}') == null);

  // ── 数字字段兼容字符串 ──
  {
    final f = parseFrame('{"type":"messages","items":[],"hits":"7"}');
    _eq('hits 从字符串解析', (f as MessagesFrame).hits, 7);
  }
}

void _testVerify() {
  const after = Duration(seconds: 6);
  const window = Duration(seconds: 90);

  // ── 初始：不该弹、不该超时 ──
  {
    const v = VerifyRoundVal.fresh;
    _ok('初始不弹', !v.shouldAutoPop(after: after));
    _ok('初始不超时', !v.timedOut(window: window));
    _ok('初始不盯 cf_clearance', !v.watchingForAutoPass);
  }

  // ── 等够了就弹（旧代码：等 6 秒弹）──
  {
    final v = VerifyRoundVal.fresh.tick(const Duration(seconds: 7));
    _ok('等够要弹', v.shouldAutoPop(after: after));
  }

  // ── 弹出之后不再弹（旧代码的「收起 6 秒又弹回来」）──
  {
    final v = VerifyRoundVal.fresh
        .tick(const Duration(seconds: 7))
        .pop(auto: true);
    _ok('弹过不再弹', !v.shouldAutoPop(after: after));
    _ok('自动弹要盯 cf_clearance', v.watchingForAutoPass);
  }

  // ── 弹层开着不算超时（旧代码：用户过验证时状态机自杀）──
  {
    final v = VerifyRoundVal.fresh
        .tick(const Duration(seconds: 200))
        .pop(auto: true);
    _ok('弹层开着不判超时', !v.timedOut(window: window));
  }

  // ── 收起之后不算超时 ──
  {
    final v = VerifyRoundVal.fresh.tick(const Duration(seconds: 200));
    _ok('弹层没开且等久了 = 超时', v.timedOut(window: window));
  }

  // ── 用户自己点开：不自动收 ──
  {
    final v = VerifyRoundVal.fresh.pop(auto: false);
    _ok('手动弹层不盯 cf_clearance', !v.watchingForAutoPass);
  }

  // ── 收起：open 和 auto 一起清（旧代码的「半个状态」）──
  {
    final v = VerifyRoundVal.fresh.pop(auto: true).close();
    _ok('收起后不可见', !v.visible);
    _ok('收起后 auto 也清', !v.auto);
    _ok('收起后不盯 cf_clearance', !v.watchingForAutoPass);
  }

  // ── markReady 只认第一次 ──
  {
    final (v1, first1) = VerifyRoundVal.fresh.markReady();
    _ok('第一次 ready 算第一次', first1);
    final (_, first2) = v1.markReady();
    _ok('第二次 ready 不算', !first2);
  }

  // ── restart：拿到消息时 rearm=true，闸门解开 ──
  {
    final v = VerifyRoundVal.fresh
        .tick(const Duration(seconds: 7))
        .pop(auto: true)
        .restart();
    // 新一轮从 0 开始计时，所以「刚 restart 就弹」是错的 ——
    // 要先等够。这才是对的：重启后立刻又弹等于没给他喘气。
    _ok('restart 当刻不弹（计时归零）', !v.shouldAutoPop(after: after));
    _ok('restart 后等够可以弹', v.tick(const Duration(seconds: 7))
        .shouldAutoPop(after: after));
    _ok('restart 清 readySeen', !v.readySeen);
  }

  // ── restart：用户收起时 rearm=false，闸门保持关上 ──
  {
    final v = VerifyRoundVal.fresh
        .tick(const Duration(seconds: 7))
        .pop(auto: true)
        .restart(rearm: false)
        .tick(const Duration(seconds: 30));
    _ok('rearm=false 时不弹回来', !v.shouldAutoPop(after: after));
  }
}

void _testStore() {
  const msg = '{"type":"messages","items":[{"id":"a","text":"hello"}],"hits":1,"src":"api"}';

  // ── 收消息帧 → ready ──
  {
    final store = InboxStore();
    store.ingest(msg);
    _eq('一条消息', store.state.messages.length, 1);
    _eq('phase 变 ready', store.state.phase, InboxPhase.ready);
    _eq('hits 记下', store.state.hits, 1);
  }

  // ── 畸形帧不抛、不改状态 ──
  {
    final store = InboxStore();
    store.ingest('not json');
    store.ingest('{"type":"unknown"}');
    store.ingest('');
    _eq('状态没动', store.state.messages.length, 0);
    _eq('phase 还是 waiting', store.state.phase, InboxPhase.waiting);
  }

  // ── status 帧只改 status ──
  {
    final store = InboxStore();
    store.ingest('{"type":"status","text":"加载中"}');
    _eq('状态栏更新', store.state.status, '加载中');
    _eq('phase 没变', store.state.phase, InboxPhase.waiting);
  }

  // ── hold 帧：设上 ──
  {
    final store = InboxStore();
    store.ingest('{"type":"holdup","kind":"pause","title":"T","message":"M","retry":30}');
    _ok('hold 设上', store.state.hold != null);
    _eq('kind 映射成 quota', store.state.hold!.kind, HoldKind.quota);
  }

  // ── hold 帧：解除（不动 error）──
  {
    final store = InboxStore();
    store.fail('代理不可用');
    store.ingest('{"type":"holdup","kind":""}');
    _ok('hold 没设上', store.state.hold == null);
    _eq('error 保留', store.state.error, '代理不可用');
  }

  // ── 拿到消息清 hold ──
  {
    final store = InboxStore();
    store.ingest('{"type":"holdup","kind":"challenge"}');
    _ok('先有 hold', store.state.hold != null);
    store.ingest(msg);
    _ok('拿到消息后 hold 清掉', store.state.hold == null);
    _eq('error 也清', store.state.error, '');
  }

  // ── 翻页结束：empty=true 表示到底 ──
  {
    final store = InboxStore();
    store.markLoadingMore();
    store.ingest('{"type":"moreDone","empty":true}');
    _ok('loadingMore 清了', !store.state.loadingMore);
    _ok('hasMore 变假', !store.state.hasMore);
  }
  {
    final store = InboxStore();
    store.markLoadingMore();
    store.ingest('{"type":"moreDone","empty":false}');
    _ok('还有更多', store.state.hasMore);
  }

  // ── 翻页失败：保留 hasMore ──
  {
    final store = InboxStore();
    store.markLoadingMore();
    store.ingest('{"type":"moreFail","reason":"no_id"}');
    _ok('loadingMore 清了', !store.state.loadingMore);
    _ok('hasMore 保留', store.state.hasMore);
  }

  // ── fail 必须清 loadingMore（旧 bug：一个瞬时错误让翻页永久失效）──
  {
    final store = InboxStore();
    store.markLoadingMore();
    store.fail('页面出错');
    _ok('fail 后 loadingMore 为假', !store.state.loadingMore);
    _eq('phase 变 failed', store.state.phase, InboxPhase.failed);
  }

  // ── reset 清干净（换出口/换身份）──
  {
    final store = InboxStore();
    store.ingest(msg);
    store.ingest('{"type":"holdup","kind":"pause"}');
    store.reset();
    _eq('消息清空', store.state.messages.length, 0);
    _ok('hold 清掉', store.state.hold == null);
    _eq('phase 回 waiting', store.state.phase, InboxPhase.waiting);
  }

  // ── onChanged 每次状态变化都触发 ──
  {
    final store = InboxStore();
    var n = 0;
    store.onChanged = () => n++;
    store.ingest('{"type":"status","text":"a"}');
    store.ingest('{"type":"status","text":"b"}');
    _eq('通知两次', n, 2);
  }

  // ── revealMore 每次多 5 条 ──
  {
    final store = InboxStore();
    final many = [
      for (var i = 0; i < 20; i++) '{"id":"id$i","text":"t"}',
    ].join(',');
    store.ingest('{"type":"messages","items":[$many]}');
    _eq('初始显示 5 条', store.state.shown.length, 5);
    store.revealMore();
    _eq('多显示 5 条', store.state.shown.length, 10);
  }
}

void _testUserAgent() {
  // ── 从真实内核 UA 解析 ──
  {
    bootstrapUserAgent(
      'Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.7390.122 '
      'Mobile Safari/537.36',
    );
    _eq('机型直取', currentIdentity.model, 'SM-S918B');
    _eq('安卓版本', currentIdentity.androidVersion, '14');
    _eq('Chrome 大版本', currentIdentity.chromeMajor, 141);
    _eq('内核大版本记下', kernelMajor, 141);
  }

  // ── `wv` 不是机型 ──
  {
    bootstrapUserAgent(
      'Mozilla/5.0 (Linux; Android 13; wv) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    );
    _ok('wv 不当作机型', currentIdentity.model != 'wv');
  }

  // ── 换身份之后自洽 ──
  {
    bootstrapUserAgent(
      'Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 '
      'Mobile Safari/537.36',
    );
    final before = currentIdentity.userAgent;
    final next = rotateIdentity(Random(7));
    _ok('UA 变了', next.userAgent != before);
    _ok('新 UA 和机型一致', next.userAgent.contains(next.model));
    _ok('新 UA 和安卓版本一致',
        next.userAgent.contains('Android ${next.androidVersion}'));
    _ok('新 UA 和 Chrome 版本一致',
        next.userAgent.contains('Chrome/${next.chromeMajor}.'));
    // ±2 窗口
    _ok('大版本在 ±2 内', (next.chromeMajor - 141).abs() <= 2);
  }

  // ── 空 UA 不改状态 ──
  {
    final before = currentIdentity.userAgent;
    bootstrapUserAgent('');
    _eq('空串不动', currentIdentity.userAgent, before);
  }
}
