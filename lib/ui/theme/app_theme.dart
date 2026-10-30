import 'package:flutter/material.dart';

import 'neutral_schemes.dart';

/// 对比度档位。
///
/// 这是**无障碍**设定，不是审美偏好。强光下看不清低对比度灰字的人需要的是
/// 高对比度那套配色，把屏幕调亮解决不了这个问题 —— 亮度和对比度是两件事。
enum Contrast() {
  standard,
  medium,
  high,
}

/// 把一套配色 + 一个字体主题拼成 `ThemeData`。
///
/// 外观沿用旧的：配色数值、`useMaterial3: true`、图标取 `onSurfaceVariant`、
/// 正文取 `onSurface`、背景取 `surface` —— 这几条一条没改。
///
/// 装配方式是我重写的，改掉了旧实现的四处：
///
/// **① 六个「一个配色一个方法」的壳子。** 旧的是 `light()` / `dark()` /
/// `lightMediumContrast()` …… 每个方法体只有一行 `theme(某套配色)`。它们
/// 存在的唯一理由是让调用方写 `appTheme.light()`，可是调用方永远要成对写
/// （明暗 × 三档对比度），于是六个方法名变成六处拼写风险 —— 拼错一个不报错，
/// 只是那个主题永远不会被选中。改成一张 switch 表，六个组合必须全覆盖，
/// 漏一个编译器直接报。
///
/// **② 冗余的 `brightness` 参数。** `ThemeData` 自己会从 `colorScheme` 读
/// 同一个值。传两遍的唯一后果是它们可以不一致 —— 那时界面会在「认为自己是
/// 深色」的配色上画出「认为自己是浅色」的滚动条，而且只在某一档下才看得见。
///
/// **③ `canvasColor` 与 `scaffoldBackgroundColor` 重复。** 前者默认就是从
/// `surface` 推出来的，写两遍等于给自己留一个「改了一处忘了另一处」的口子。
///
/// **④ 一个永远返回空列表的 `extendedColors` getter。** 没人调用它，
/// 它也不会返回任何东西。
class AppTheme(this.textTheme) {
  final TextTheme textTheme;

  /// 按 (明暗, 对比度) 取一套。六个组合一个不缺。
  ThemeData scheme({
    required bool dark,
    Contrast contrast = Contrast.standard,
  }) => _assemble(_pick(dark: dark, contrast: contrast));

  static ColorScheme _pick({required bool dark, required Contrast contrast}) =>
      switch ((dark, contrast)) {
        (true, Contrast.standard) => NeutralSchemes.dark,
        (true, Contrast.medium) => NeutralSchemes.darkMediumContrast,
        (true, Contrast.high) => NeutralSchemes.darkHighContrast,
        (false, Contrast.standard) => NeutralSchemes.light,
        (false, Contrast.medium) => NeutralSchemes.mediumContrast,
        (false, Contrast.high) => NeutralSchemes.highContrast,
      };

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
