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

import 'package:test/test.dart';

import 'package:fus_inbox/core/code_extract.dart';
import 'package:fus_inbox/core/sms_message.dart';
import 'package:fus_inbox/core/user_agent.dart';
import 'package:fus_inbox/data/frame.dart';
import 'package:fus_inbox/data/number_entry.dart';
import 'package:fus_inbox/data/proxy_config.dart';
import 'package:fus_inbox/data/inbox_state.dart';
import 'package:fus_inbox/data/inbox_store.dart';
import 'package:fus_inbox/data/verify_round.dart';
import 'package:fus_inbox/data/merge_frame.dart';

/// 断言失败时 `package:test` 会打印 got/want 差异，并让进程退出非 0 ——
/// 比原来只 print 一行 `FAIL` 可靠：原脚本的 `_fail` 只被打印，没有 exitCode，
/// 所以 192 条断言全挂时 CI 依然是绿的。
void _ok(String label, bool cond) {
  expect(cond, isTrue, reason: label);
}

void _eq(String label, Object? got, Object? want) {
  _ok('$label  (got=$got want=$want)', got == want);
}

SmsMessage _m(String id, {String text = 'body', String time = ''}) =>
    SmsMessage(id: id, text: text, time: time);

void main() {
  group('code_extract', () => test('code_extract', _testCodeExtract));
  group('merge', () => test('merge', _testMerge));
  group('inbox_state', () => test('inbox_state', _testState));
  group('frame', () => test('frame', _testFrame));
  group('verify', () => test('verify', _testVerify));
  group('store', () => test('store', _testStore));
  group('user_agent', () => test('user_agent', _testUserAgent));
  group('proxy', () => test('proxy', _testProxy));
  group('numbers', () => test('numbers', _testNumbers));
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
  _ok('短句无关键词也算（纯验证码短信）', looksLikeVerification('123456'));
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
      current: [const SmsMessage(id: 'a', text: '')],
      incoming: [const SmsMessage(id: 'a', text: '完整正文', code: '123456')],
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
      incoming: [const SmsMessage(id: '', text: 'x')],
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('空 id 被丢', r.messages.length, 0);
  }

  // ── 裁剪：留最新 240 条 ──
  {
    final many = [
      for (var i = 0; i < 250; i++)
        // 时间必须是**合法**的 ISO 串。
        //
        // 原来这里写 `'2026-10-29 10:${i.toString().padLeft(3, '0')}'`，
        // 补三位是为了让字典序等于时间序 —— 但那造出的是 `10:099`
        // （99 秒非法），`DateTime.tryParse` 返回 null。
        // 排序一旦改成「先解析成时间戳」，这批消息就全都没有时间，
        // 顺序退化成按编号比，用例断言的是排序而不是裁剪。
        //
        // 现在用秒数直接进时间串（`i` 最多 249，即 4 分 9 秒，合法），
        // 裁剪与排序两件事就分开了。
        SmsMessage(
          id: 'id$i',
          text: 't',
          time:
              '2026-10-29T10:'
              '${(i ~/ 60).toString().padLeft(2, '0')}:'
              '${(i % 60).toString().padLeft(2, '0')}',
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

  // ── 排序：带时区与不带时区混着来，要按真实时间排 ──
  //
  // 站点的 `received_at` 格式不统一（站点自己解析时要先判时区，见 live.js:267），
  // 而 DOM 路径给的是 `toISOString()`（定宽带 Z，live.js:544）。
  // 直接比字符串会在 `'T'` vs `' '`、`'Z'` vs 空处分叉。
  {
    final r = mergeFrame(
      current: const [],
      incoming: [
        // UTC 04:00
        _m('a', time: '2026-10-30T12:00:00+08:00'),
        // UTC 11:00
        _m('b', time: '2026-10-30T11:00:00Z'),
        // UTC 11:30（不带时区，按 UTC 解释）
        _m('c', time: '2026-10-30T11:30:00'),
      ],
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('跨时区按真实时间排', r.messages.map((e) => e.id).join(','), 'c,b,a');
  }

  // ── 排序：时间都缺时，数字编号必须按数值比，不能按字符串比 ──
  //
  // 站点给的是 `event_id` 数字（live.js:541 `String(m.event_id)`），位数不等很常见。
  // 字符串比较是逐码元比的，`'99' > '123'` —— 数值上 123 更新却排到后面。
  {
    final r = mergeFrame(
      current: const [],
      incoming: [_m('99'), _m('123'), _m('1000')],
      seenIds: const {},
      firstFrameDone: false,
    );
    _eq('数字编号按数值倒序', r.messages.map((e) => e.id).join(','), '1000,123,99');
  }

  // ── 合并：`isProtected` 真值粘住，不被后到的 false 抹掉 ──
  //
  // DOM 路径靠「页面上有没有那句说明」反推，说明还没渲染时会给出 false；
  // 接口路径给的是站点真值 true。false 不该覆盖 true。
  {
    const old = SmsMessage(id: 'p', text: '', isProtected: true);
    final merged = old.mergeWith(const SmsMessage(id: 'p', text: ''));
    _ok('true 不被 false 抹掉', merged.isProtected);

    // 反方向：先 false 后 true，也该变成 true。
    const plain = SmsMessage(id: 'q', text: '');
    final up = plain.mergeWith(
      const SmsMessage(id: 'q', text: '', isProtected: true),
    );
    _ok('false 可以变 true', up.isProtected);

    // 正文补齐之后标记仍在（界面按正文非空走正文分支，标记不影响显示，
    // 但状态本身不该丢）。
    final filled = old.mergeWith(const SmsMessage(id: 'p', text: 'hello'));
    _ok('补正文后标记仍在', filled.isProtected);
    _eq('正文补上了', filled.text, 'hello');
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
    const st = InboxState(
      messages: [],
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
    _ok(
      'restart 后等够可以弹',
      v.tick(const Duration(seconds: 7)).shouldAutoPop(after: after),
    );
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
  const msg =
      '{"type":"messages","items":[{"id":"a","text":"hello"}],"hits":1,"src":"api"}';

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
    store.ingest(
      '{"type":"holdup","kind":"pause","title":"T","message":"M","retry":30}',
    );
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
    final many = [for (var i = 0; i < 20; i++) '{"id":"id$i","text":"t"}']
        .join(',');
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
    _ok(
      '新 UA 和安卓版本一致',
      next.userAgent.contains('Android ${next.androidVersion}'),
    );
    _ok(
      '新 UA 和 Chrome 版本一致',
      next.userAgent.contains('Chrome/${next.chromeMajor}.'),
    );
    // ±2 窗口
    _ok('大版本在 ±2 内', (next.chromeMajor - 141).abs() <= 2);
  }

  // ── 空 UA 不改状态 ──
  {
    final before = currentIdentity.userAgent;
    bootstrapUserAgent('');
    _eq('空串不动', currentIdentity.userAgent, before);
  }

  // ── 内核真值：换过身份之后还拿得回来 ──
  //
  // 这是「回到内核真值」那个按钮的依据。少了它，用户换完身份就
  // 撤销不了 —— 而撤销是他发现「换坏了」时唯一能做的事。
  {
    const kernel =
        'Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.7390.122 '
        'Mobile Safari/537.36';
    bootstrapUserAgent(kernel);

    final k = kernelIdentity;
    _ok('探到内核就非 null', k != null);
    _eq('内核真值就是内核那句', k!.userAgent, kernel);
    _eq('机型解析出来', k.model, 'SM-S918B');
    _eq('安卓版本解析出来', k.androidVersion, '14');

    // 换掉之后，真值还在。
    rotateIdentity(Random(11));
    _ok('换身份后当前变了', currentIdentity.userAgent != kernel);
    _eq('内核真值没被换掉', kernelIdentity!.userAgent, kernel);

    // 撤销。
    restoreUserAgent(kernelIdentity!.userAgent);
    _eq('撤销后回到真值', currentUserAgent, kernel);
  }
}

void _testProxy() {
  // ── 完整形式 ──
  {
    final c = parseProxyLine('socks5://1.2.3.4:1080')!;
    _eq('协议', c.scheme, ProxyScheme.socks5);
    _eq('主机', c.host, '1.2.3.4');
    _eq('端口', c.port, 1080);
    _ok('没凭据', !c.hasAuth);
    _eq('id 不含密码', c.id, 'socks5://1.2.3.4:1080');
  }

  // ── 带凭据 ──
  {
    final c = parseProxyLine('http://u:p@1.2.3.4:8080')!;
    _eq('协议', c.scheme, ProxyScheme.http);
    _eq('用户名', c.user, 'u');
    _eq('密码', c.password, 'p');
    _ok('有凭据', c.hasAuth);
  }

  // ── 密码里带 @ 和 : ──
  {
    final c = parseProxyLine('socks5://u:p@ss:w0rd@1.2.3.4:1080')!;
    _eq('取最后一个 @ 之后当主机', c.host, '1.2.3.4');
    _eq('密码完整保留', c.password, 'p@ss:w0rd');
  }

  // ── 缺协议默认 socks5 ──
  {
    final c = parseProxyLine('1.2.3.4:1080')!;
    _eq('默认协议', c.scheme, ProxyScheme.socks5);
  }

  // ── 畸形行返回 null，不抛 ──
  _ok('空行', parseProxyLine('') == null);
  _ok('注释', parseProxyLine('# 说明') == null);
  _ok('没端口', parseProxyLine('socks5://1.2.3.4') == null);
  _ok('端口不是数字', parseProxyLine('1.2.3.4:abc') == null);
  _ok('端口越界', parseProxyLine('1.2.3.4:99999') == null);
  _ok('端口为 0', parseProxyLine('1.2.3.4:0') == null);
  _ok('未知协议', parseProxyLine('ftp://1.2.3.4:21') == null);

  // ── 列表解析：去重 + 跳过坏行 ──
  {
    final list = parseProxyList('''
# 注释
socks5://1.2.3.4:1080
socks5://1.2.3.4:1080
坏行
http://5.6.7.8:8080
''');
    _eq('去重后两条', list.length, 2);
  }

  // ── SOCKS5 要走桥 ──
  {
    final s5 = parseProxyLine('socks5://1.2.3.4:1080')!;
    final ht = parseProxyLine('http://1.2.3.4:8080')!;
    _ok('socks5 需要桥', s5.scheme.needsBridge);
    _ok('http 不需要桥', !ht.scheme.needsBridge);
  }

  // ── 显示名 ──
  {
    final c = parseProxyLine('socks5://1.2.3.4:1080')!;
    _eq('没 label 用 host:port', c.displayName, '1.2.3.4:1080');
  }
}

void _testNumbers() {
  // ── 11 位分组，非 11 位原样 ──
  {
    _eq(
      '分组',
      const NumberEntry(digits: '18607507091').formatted,
      '(860) 750-7091',
    );
    _eq(
      '10 位原样',
      const NumberEntry(digits: '8607507091').formatted,
      '8607507091',
    );
    _eq('空串原样', const NumberEntry(digits: '').formatted, '');
    _eq(
      '收件页地址',
      const NumberEntry(digits: '18607507091').inboxUrl,
      'https://freeussms.com/numbers/18607507091/',
    );
  }

  // ── 归属地一行：两个字段都可能缺 ──
  {
    _eq(
      '都有',
      const NumberEntry(
        digits: '1',
        state: 'Virginia',
        areaCode: '757',
      ).regionLabel,
      'Virginia · 757',
    );
    _eq(
      '只有州',
      const NumberEntry(digits: '1', state: 'Texas').regionLabel,
      'Texas',
    );
    _eq(
      '只有区号',
      const NumberEntry(digits: '1', areaCode: '512').regionLabel,
      '512',
    );
    _eq('都没有', const NumberEntry(digits: '1').regionLabel, '');
  }

  // ── 解析：真实结构（照着站点实测的原文缩的）──
  {
    const html = '''
<div class="numbers-grid" data-live-grid>
<article class="number-card is-fresh has-messages" data-live-card="c3ce">
  <span class="number-area">Virginia · 757</span>
  <a href="https://freeussms.com/numbers/17573596469/">+1 (757) 359-6469</a>
  <span class="fresh-text">Last text <time data-rel-time="2026-10-29T21:00:21">41 sec ago</time></span>
  <div class="number-card-meta" data-count="23" data-empty="false">
</article>
<article class="number-card" data-live-card="aaaa">
  <span class="number-area">Texas · 512</span>
  <a href="https://freeussms.com/numbers/15125550100/">+1 (512) 555-0100</a>
  <div class="number-card-meta" data-count="0" data-empty="true">
</article>
</div>''';
    final list = parseNumberList(html);
    _eq('两条', list.length, 2);
    _eq('号码', list[0].digits, '17573596469');
    _eq('州', list[0].state, 'Virginia');
    _eq('区号', list[0].areaCode, '757');
    _eq('条数', list[0].messageCount, 23);
    _ok('有时间', list[0].lastTextAt != null);
    _ok('非空号', list[0].hasMessages);
    _eq('第二条条数', list[1].messageCount, 0);
    _ok('第二条是空号', !list[1].hasMessages);
  }

  // ── 时间按 UTC 解析，不按设备本地时区 ──
  {
    const html =
        '<article><a href="/numbers/18607507091/">x</a>'
        '<time data-rel-time="2026-10-29T21:00:21">41 sec ago</time></article>';
    final t = parseNumberList(html).first.lastTextAt;
    _ok('是 UTC', t!.isUtc);
    _eq('小时', t.hour, 21);
    _eq(
      '不认相对文字',
      parseNumberList(
        '<article><a href="/numbers/18607507091/">x</a>41 sec ago</article>',
      ).first.lastTextAt,
      null,
    );
  }

  // ── 去重：同一号码出现两次只算一条 ──
  {
    const html = '''
<article><a href="/numbers/18607507091/">A</a></article>
<article><a href="/numbers/18607507091/">A 又来一次</a></article>''';
    _eq('只算一条', parseNumberList(html).length, 1);
  }

  // ── 退回路径：没有 article 也要能出列表 ──
  {
    const html = '''
<a href="/numbers/18607507091/">A</a>
<a href='/numbers/18603130709/'>B</a>''';
    final list = parseNumberList(html);
    _eq('退回拿到两条', list.length, 2);
    _eq('顺序保持', list[0].digits, '18607507091');
    _eq('退回没州名', list[0].state, '');
    _eq('退回没条数', list[0].messageCount, 0);
  }

  // ── 太短太长的数字不算（站点 ID、分页参数也是数字）──
  {
    const html =
        '<a href="/numbers/123/">短</a>'
        '<a href="/numbers/1234567890123456/">长</a>'
        '<a href="/numbers/18607507091/">正常</a>';
    final list = parseNumberList(html);
    _eq('只留正常那条', list.length, 1);
    _eq('留下的是对的', list[0].digits, '18607507091');
  }

  // ── 空输入不抛 ──
  _eq('空串', parseNumberList('').length, 0);
  _eq('无关内容', parseNumberList('<html>没有号码</html>').length, 0);

  // ── 相等只看号码 ──
  {
    _ok(
      '同号码相等，就算条数不同',
      const NumberEntry(digits: '1', messageCount: 5) ==
          const NumberEntry(digits: '1', messageCount: 9),
    );
    _ok(
      '不同号码不等',
      const NumberEntry(digits: '1') != const NumberEntry(digits: '2'),
    );
  }

  // ── describeAge 用绝对时间重算 ──
  {
    final now = DateTime.utc(2026, 10, 29, 21, 5);
    _eq(
      '分钟',
      NumberEntry(
        digits: '1',
        lastTextAt: DateTime.utc(2026, 10, 29, 21, 0, 21),
        messageCount: 3,
      ).describeAge(now),
      '4 分钟前 · 3 条',
    );
    _eq(
      '小时',
      NumberEntry(
        digits: '1',
        lastTextAt: DateTime.utc(2026, 10, 29, 19),
      ).describeAge(now),
      '2 小时前',
    );
    _eq(
      '天',
      NumberEntry(
        digits: '1',
        lastTextAt: DateTime.utc(2026, 10, 27, 21),
      ).describeAge(now),
      '2 天前',
    );
    _eq(
      '没时间有条数',
      const NumberEntry(digits: '1', messageCount: 7).describeAge(now),
      '7 条',
    );
    _eq('没时间没条数', const NumberEntry(digits: '1').describeAge(now), '暂无短信');
    // 站点时间比手机快一点是常见的（时钟漂移），别显示成负数。
    _eq(
      '未来时间不显示负数',
      NumberEntry(
        digits: '1',
        lastTextAt: DateTime.utc(2026, 10, 29, 21, 5, 30),
      ).describeAge(now),
      '刚刚',
    );
  }
}
