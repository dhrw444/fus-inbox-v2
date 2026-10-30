import 'package:flutter/material.dart';

/// 中性灰阶配色。
///
/// 外观是旧的：`primary` 是纯黑/纯白，不是 Material 默认的紫，也没有任何
/// 彩色派生 —— 这个应用的内容全是短信文本，彩色会在阅读时抢注意力。
///
/// ## 结构（这是重写的部分）
///
/// 不是「六套完整配色各写一遍」。六套之间有 **28~39 个字段是重合的**，
/// 原样摊开就是 282 行里有 235 行在重复同一个值。
///
/// 所以拆成 **一份基准 + 五份差异**：
///
///   - [light]  —— 基准。47 个字段全给。
///   - 其余四套  —— 只写跟基准不同的字段，`copyWith` 覆盖上去。
///
/// 好处不只是少写。**改一个公共色只要改一处** —— 摊开写的时候，
/// 想让六套的 `outline` 都深一点，得挨个改六遍，漏一个就出现
/// 「切到深色模式时边框颜色不一样」这种只在对某套配色下才看得见的差异。
///
/// ## 为什么不是「深色开关」
///
/// 对比度是**无障碍**需求，不是审美偏好：有人在强光下看不清低对比度的灰字，
/// 那时需要的是高对比度那套，而不是把整个界面调亮。
class NeutralSchemes() {
  /// 浅色基准。47 个字段全给 —— 其余各套都以它为准。
  static const ColorScheme light = ColorScheme(
    brightness: Brightness.light,
    error: Color(0xffba1a1a),
    errorContainer: Color(0xffffdad6),
    inversePrimary: Color(0xffc6c6c6),
    inverseSurface: Color(0xff303030),
    onError: Color(0xffffffff),
    onErrorContainer: Color(0xff93000a),
    onInverseSurface: Color(0xfff1f1f1),
    onPrimary: Color(0xffffffff),
    onPrimaryContainer: Color(0xff848484),
    onPrimaryFixed: Color(0xff1b1b1b),
    onPrimaryFixedVariant: Color(0xff474747),
    onSecondary: Color(0xffffffff),
    onSecondaryContainer: Color(0xff646464),
    onSecondaryFixed: Color(0xff1b1b1b),
    onSecondaryFixedVariant: Color(0xff474747),
    onSurface: Color(0xff1b1b1b),
    onSurfaceVariant: Color(0xff4c4546),
    onTertiary: Color(0xffffffff),
    onTertiaryContainer: Color(0xff848484),
    onTertiaryFixed: Color(0xff1b1b1b),
    onTertiaryFixedVariant: Color(0xff474747),
    outline: Color(0xff7e7576),
    outlineVariant: Color(0xffcfc4c5),
    primary: Color(0xff000000),
    primaryContainer: Color(0xff1b1b1b),
    primaryFixed: Color(0xffe2e2e2),
    primaryFixedDim: Color(0xffc6c6c6),
    scrim: Color(0xff000000),
    secondary: Color(0xff5e5e5e),
    secondaryContainer: Color(0xffe2e2e2),
    secondaryFixed: Color(0xffe2e2e2),
    secondaryFixedDim: Color(0xffc6c6c6),
    shadow: Color(0xff000000),
    surface: Color(0xfff9f9f9),
    surfaceBright: Color(0xfff9f9f9),
    surfaceContainer: Color(0xffeeeeee),
    surfaceContainerHigh: Color(0xffe8e8e8),
    surfaceContainerHighest: Color(0xffe2e2e2),
    surfaceContainerLow: Color(0xfff3f3f3),
    surfaceContainerLowest: Color(0xffffffff),
    surfaceDim: Color(0xffdadada),
    surfaceTint: Color(0xff5e5e5e),
    tertiary: Color(0xff000000),
    tertiaryContainer: Color(0xff1b1b1b),
    tertiaryFixed: Color(0xffe2e2e2),
    tertiaryFixedDim: Color(0xffc6c6c6),
  );

  /// 深色基准。
  ///
  /// 它跟 [light] 差的字段最多（32 处），几乎每个颜色都换了 —— 但
  /// **依然以 [light] 为基准写差异**，因为这样「两套之间差什么」是显式的。
  static final ColorScheme dark = light.copyWith(
    brightness: Brightness.dark,
    error: const Color(0xffffb4ab),
    errorContainer: const Color(0xff93000a),
    inversePrimary: const Color(0xff5e5e5e),
    inverseSurface: const Color(0xffe2e2e2),
    onError: const Color(0xff690005),
    onErrorContainer: const Color(0xffffdad6),
    onInverseSurface: const Color(0xff303030),
    onPrimary: const Color(0xff303030),
    onPrimaryContainer: const Color(0xff757575),
    onSecondary: const Color(0xff303030),
    onSecondaryContainer: const Color(0xffb5b5b5),
    onSurface: const Color(0xffe2e2e2),
    onSurfaceVariant: const Color(0xffcfc4c5),
    onTertiary: const Color(0xff303030),
    onTertiaryContainer: const Color(0xff757575),
    outline: const Color(0xff988e90),
    outlineVariant: const Color(0xff4c4546),
    primary: const Color(0xffc6c6c6),
    primaryContainer: const Color(0xff000000),
    secondary: const Color(0xffc6c6c6),
    secondaryContainer: const Color(0xff474747),
    surface: const Color(0xff131313),
    surfaceBright: const Color(0xff393939),
    surfaceContainer: const Color(0xff1f1f1f),
    surfaceContainerHigh: const Color(0xff2a2a2a),
    surfaceContainerHighest: const Color(0xff353535),
    surfaceContainerLow: const Color(0xff1b1b1b),
    surfaceContainerLowest: const Color(0xff0e0e0e),
    surfaceDim: const Color(0xff131313),
    surfaceTint: const Color(0xffc6c6c6),
    tertiary: const Color(0xffc6c6c6),
    tertiaryContainer: const Color(0xff000000),
  );
}
