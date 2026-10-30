/// 收录时间解析的测试。
///
/// 样本来自真实抓取（`/tmp/inbox.html`，2026-10-30），不是编的。
/// 每个用例都配一条**反向判据**：该拒的必须拒 —— 只测「能解析」等于
/// 只测了一半，而漏掉的另一半是「把错的数据当真」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/data/directory_filter.dart';
import 'package:fus_inbox/data/number_insights.dart';

/// 真实样本，逐字来自站点。改一个字都会让下面的断言失败。
const _realIsland = '''
{"version":1,"number":"+14044225634",
"generated_at":"2026-10-30T11:48:03+00:00",
"expires_at":"2026-10-30T12:03:03+00:00",
"retained_count":32,"arrivals_24h":32,"arrivals_7d":32,
"active_days_7utc":2,
"first_retained_at":"2026-10-29T13:33:16+00:00",
"last_retained_at":"2026-10-30T11:47:39+00:00",
"directory_first_seen_at":"2026-10-29T13:23:06+00:00",
"daily":[{"date":"2026-10-24","count":0},{"date":"2026-10-25","count":0},
{"date":"2026-10-26","count":0},{"date":"2026-10-27","count":0},
{"date":"2026-10-28","count":0},{"date":"2026-10-29","count":20},
{"date":"2026-10-30","count":12}]}''';

/// 包成站点那种 `<script>` 块。
String _html(String island) =>
    '<html><body><script id="fus-number-insights" '
    'type="application/json">$island</script></body></html>';

/// 快照生成后 2 分钟。
final _now = DateTime.utc(2026, 10, 30, 11, 50);

void main() {
  group('收录时间', () {
    test('真实样本解析出收录时间', () {
      final s = parseNumberInsights(
        _html(_realIsland),
        wantDigits: '4044225634',
        now: _now,
      );
      expect(s, isNotNull);
      expect(s!.directoryFirstSeenAt, DateTime.utc(2026, 10, 29, 13, 23, 6));
      // 收录时间必须早于第一条短信 —— 号码先进目录才收到短信。
      expect(
        s.directoryFirstSeenAt!.isBefore(s.firstRetainedAt!),
        isTrue,
        reason: '收录时间应当早于首条短信时间',
      );
      expect(s.retainedCount, 32);
      expect(s.daily.length, 7);
    });

    test('11 位和 10 位都能对上', () {
      for (final n in ['4044225634', '14044225634', '+14044225634']) {
        expect(
          parseNumberInsights(_html(_realIsland), wantDigits: n, now: _now),
          isNotNull,
          reason: '号码 $n 应当解析成功',
        );
      }
    });

    test('号码对不上就拒 —— 防止把 A 的快照显示到 B 上', () {
      expect(
        parseNumberInsights(
          _html(_realIsland),
          wantDigits: '4155550100',
          now: _now,
        ),
        isNull,
      );
    });

    test('过期快照拒收', () {
      expect(
        parseNumberInsights(
          _html(_realIsland),
          wantDigits: '4044225634',
          // 有效期到 12:03，这里是 13:00。
          now: DateTime.utc(2026, 10, 30, 13),
        ),
        isNull,
      );
    });

    test('生成时间在未来就拒', () {
      expect(
        parseNumberInsights(
          _html(_realIsland),
          wantDigits: '4044225634',
          // 生成于 11:48，这里说现在是 10:00 —— 未来 108 分钟。
          now: DateTime.utc(2026, 10, 30, 10),
        ),
        isNull,
      );
    });

    test('页面里没有这块就返回 null，不抛', () {
      expect(
        parseNumberInsights(
          '<html><body>空</body></html>',
          wantDigits: '1',
          now: _now,
        ),
        isNull,
      );
    });

    test('损坏的 JSON 返回 null，不抛', () {
      expect(
        parseNumberInsights(
          _html('{"version":1,"number":'),
          wantDigits: '4044225634',
          now: _now,
        ),
        isNull,
      );
    });

    test('属性顺序颠倒也能抠出来', () {
      // 站点改一下属性顺序不该让整条链失效。
      const html =
          '<script type="application/json" id="fus-number-insights">'
          '$_realIsland</script>';
      expect(
        parseNumberInsights(html, wantDigits: '4044225634', now: _now),
        isNotNull,
      );
    });

    test('没有收录时间时字段是 null，不是编一个', () {
      final noSeen = _realIsland.replaceAll(
        '"directory_first_seen_at":"2026-10-29T13:23:06+00:00",',
        '',
      );
      final s = parseNumberInsights(
        _html(noSeen),
        wantDigits: '4044225634',
        now: _now,
      );
      expect(s, isNotNull);
      expect(s!.directoryFirstSeenAt, isNull);
      // 界面上必须说「未记录」。
      expect(
        describeFirstSeen(const FirstSeenInfo(probed: true), _now),
        '收录时间未记录',
      );
    });
  });

  group('收录时间的人话', () {
    test('各档位', () {
      final now = DateTime.utc(2026, 10, 30, 12);
      String at(Duration ago) =>
          describeFirstSeen(FirstSeenInfo(at: now.subtract(ago)), now);

      expect(at(const Duration(seconds: 20)), '刚收录');
      expect(at(const Duration(minutes: 22)), '22 分钟前收录');
      expect(at(const Duration(hours: 5)), '5 小时前收录');
      expect(at(const Duration(days: 3)), '3 天前收录');
      expect(at(const Duration(days: 75)), '2 个月前收录');
      expect(at(const Duration(days: 400)), '1 年前收录');
    });

    test('时钟往回跳时不显示负数', () {
      final now = DateTime.utc(2026, 10, 30, 12);
      expect(
        describeFirstSeen(
          FirstSeenInfo(at: now.add(const Duration(hours: 2))),
          now,
        ),
        '刚收录',
      );
    });

    test('还没查 vs 查过没有，说法不同', () {
      final now = DateTime.utc(2026, 10, 30, 12);
      expect(describeFirstSeen(FirstSeenInfo.unknown, now), '收录时间未查到');
      expect(describeFirstSeen(FirstSeenInfo.absent, now), '收录时间未记录');
    });

    test('精确时刻是 UTC 且补零', () {
      expect(
        exactFirstSeen(FirstSeenInfo(at: DateTime.utc(2026, 1, 5, 3, 7))),
        '2026-01-05 03:07 UTC',
      );
      expect(exactFirstSeen(FirstSeenInfo.unknown), '');
    });
  });
}
