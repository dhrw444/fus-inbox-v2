/// 主题明暗选择。
///
/// 三态而不是布尔 —— 「跟随系统」不是「关掉深色模式」，它是一档独立状态。
/// 用 bool 的话，用户选过「深色」之后系统切到深色，应用还是深色，
/// 而用户以为自己设的是「跟随系统」。
///
/// 名字避开 `ThemeModeChoice.mode` 那种直译：这个枚举描述的是**用户的
/// 选择**，不是最终生效的 [ThemeMode] —— 后者由 `跟随系统` 加上系统状态
/// 推出来，两者混用会在「系统深色 + 用户选浅色」时判错。
enum ThemeChoice(this.label) {
  system('跟随系统'),
  light('浅色'),
  dark('深色');

  final String label;

  /// 用户选了 `跟随系统` 时由系统决定，其余直接映射。
  ///
  /// 返回 [ResolvedMode] 而不是 `material.dart` 的 `ThemeMode` ——
  /// **这个文件零 Flutter 依赖，才能脱离框架跑测试**。
  ResolvedMode resolve({required bool systemIsDark}) => switch (this) {
    ThemeChoice.system => systemIsDark ? ResolvedMode.dark : ResolvedMode.light,
    ThemeChoice.light => ResolvedMode.light,
    ThemeChoice.dark => ResolvedMode.dark,
  };
}

/// 目录的排序方式。
///
/// `firstSeen` 依赖本地记录（第一次看到某个号码的时间），**不是站点给的**。
/// 所以它只在「至少抓过一次」之后才有意义 —— 界面要在没有本地记录时
/// 说明这一点，否则用户选了「收录时间」看到的顺序和「号码顺序」一样，
/// 会以为功能坏了。
enum NumberSort(this.label) {
  recent('最近活跃'),
  firstSeen('收录时间'),
  messages('短信最多'),
  number('号码顺序');

  final String label;

  /// 从持久化的名字反查。认不出来时退回 [recent]。
  ///
  /// 不抛异常：这个值来自磁盘，可能是旧版本写的、也可能被外部改过。
  /// 为了一个排序偏好让整页打不开不值得。
  static NumberSort fromName(String? name) => NumberSort.values.firstWhere(
    (s) => s.name == name,
    orElse: () => NumberSort.recent,
  );
}

/// 目录页的两个视图。
enum NumberTab(this.label) {
  /// 全部号码，按 [NumberSort] 排。
  all('全部'),

  /// 只看有短信的。
  active('有短信');

  final String label;
}

/// 明暗的最终结果。跟 `material.dart` 的 `ThemeMode` 一一对应，
/// 但**不带那一层依赖** —— 这个文件要能脱离 Flutter 跑测试。
enum ResolvedMode() {
  light,
  dark,
}
