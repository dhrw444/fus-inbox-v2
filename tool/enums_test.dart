import '../lib/data/enums.dart';

int _pass = 0;
int _fail = 0;

void _eq(String what, Object? got, Object? want) {
  if (got == want) {
    _pass++;
    print('  ok   $what');
  } else {
    _fail++;
    print('  FAIL $what (got=$got want=$want)');
  }
}

void _ok(String what, bool cond) => _eq(what, cond, true);

void main() {
  // ── 明暗解析：三条路径 ──
  {
    _eq(
      '跟随系统 + 系统暗 → 暗',
      ThemeChoice.system.resolve(systemIsDark: true),
      ResolvedMode.dark,
    );
    _eq(
      '跟随系统 + 系统亮 → 亮',
      ThemeChoice.system.resolve(systemIsDark: false),
      ResolvedMode.light,
    );
    // 这条是关键：明确选了亮，系统再暗也不该跟着变。
    _eq(
      '明确选亮 + 系统暗 → 仍然亮',
      ThemeChoice.light.resolve(systemIsDark: true),
      ResolvedMode.light,
    );
    _eq(
      '明确选暗 + 系统亮 → 仍然暗',
      ThemeChoice.dark.resolve(systemIsDark: false),
      ResolvedMode.dark,
    );
    _ok('三条枚举都有', ThemeChoice.values.length == 3);
  }

  // ── 排序：三个键 ──
  {
    _eq('最近优先', NumberSort.recent.label, '最近活跃');
    _eq('条数优先', NumberSort.messages.label, '短信最多');
    _eq('号码优先', NumberSort.number.label, '号码顺序');
    // 四个排序选项。改成 4 是因为最近活跃/收录时间/短信最多/号码顺序
    // 这四条**都是真实需求**：用户可能按「哪个刚收到短信」找，也可能按
    // 「哪个号码最近被收录」找 —— 这是两个不同的问题。
    _eq('四个排序项', NumberSort.values.length, 4);
    // 不同键的 label 不能重名 —— 下拉框里重名等于选不了。
    final labels = NumberSort.values.map((s) => s.label).toSet();
    _ok('label 互不相同', labels.length == NumberSort.values.length);
  }

  // ── 目录标签页：两个 ──
  {
    _eq('全部', NumberTab.all.label, '全部');
    _eq('有短信', NumberTab.active.label, '有短信');
    _ok('两个页签', NumberTab.values.length == 2);
    final labels = NumberTab.values.map((t) => t.label).toSet();
    _ok('label 互不相同', labels.length == NumberTab.values.length);
  }

  print('\n  $_pass passed, $_fail failed');
  if (_fail != 0) throw StateError('$_fail 项失败');
}
