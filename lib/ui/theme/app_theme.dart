import 'package:flutter/material.dart';

import 'neutral_schemes.dart';

/// 把一套配色 + 一个字体主题拼成 `ThemeData`。
///
/// ## 为什么只有明暗两套，没有对比度档位
///
/// 原来这里有个 `Contrast { standard, medium, high }` 枚举，配着六套配色。
/// 但 `scheme()` 全仓只有 `main.dart` 两处调用，都用默认值 —— 也就是说
/// `medium` / `high` 两档和它们对应的四套配色**一次都不会被选中**。
///
/// 那不是「为将来的无障碍功能预留」，那是死代码：四套配色各 40 行，
/// 改一个公共色要改六处，而其中四处永远不生效。要真做对比度，
/// 应该先做出让用户能选的入口，再补配色 —— 顺序反了就是给自己留坑。
///
/// 现在只留 [NeutralSchemes.light] 与 [NeutralSchemes.dark]。
class AppTheme(this.textTheme) {
  final TextTheme textTheme;

  /// 取一套配色。`dark` 为真时用深色。
  ThemeData scheme({bool dark = false}) =>
      _assemble(dark ? NeutralSchemes.dark : NeutralSchemes.light);

  ThemeData _assemble(ColorScheme cs) => ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    // 图标比正文低一档对比度 —— 图标是装饰，正文是内容。两者同等显眼时
    // 眼睛会先落在图标上，读短信正文反而要费劲。
    iconTheme: IconThemeData(color: cs.onSurfaceVariant),
    textTheme: textTheme.apply(
      bodyColor: cs.onSurface,
      displayColor: cs.onSurface,
    ),
    scaffoldBackgroundColor: cs.surface,
  );
}
