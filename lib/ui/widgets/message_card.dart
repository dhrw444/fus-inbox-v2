/// 一条短信的卡片。
///
/// ## 为什么单独一个文件
///
/// 它是列表里重复最多的东西。旧代码里它嵌在 `inbox_message_list.dart`
/// 的一个 300 行 `build` 方法里，和列表逻辑、搜索高亮、复制回调全部
/// 混在一起 —— 改一个间距要在两百行里找位置。
///
/// 抽出来之后这个文件只回答一个问题：**一条短信长什么样**。
library;

import 'package:flutter/material.dart';

import '../../core/sms_message.dart';

/// 一条短信。
class const MessageCard({
  required this.message,
  required this.theme,
  required this.onCopyCode,
  required this.onCopyAll,
  super.key,
}) extends StatelessWidget {
  final SmsMessage message;
  final ThemeData theme;
  final void Function(String code) onCopyCode;
  final void Function(SmsMessage message) onCopyAll;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(scheme),
            const SizedBox(height: 6),
            _body(),
            if (message.hasCode) ...[
              const SizedBox(height: 8),
              _codeRow(scheme),
            ],
          ],
        ),
      ),
    );
  }

  /// 第一行：发送方 + 时间。
  ///
  /// 两个都可能没有（受保护的消息没有时间、站点偶尔不给发送方）。
  /// 都没有时整行不占位置 —— 留一行空白比缺内容更难看。
  Widget _header(ColorScheme scheme) {
    final sender = message.sender;
    final time = message.time;
    if (sender.isEmpty && time.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        if (sender.isNotEmpty) ...[
          Icon(Icons.business_outlined, size: 14, color: scheme.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              sender,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (time.isNotEmpty)
          Text(
            time,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  /// 正文。
  ///
  /// 受保护的消息站点不给正文 —— 那时显示一句说明，而不是空白。
  /// 空白会让人以为「这条短信是空的」。
  Widget _body() {
    if (message.text.isEmpty) {
      return Text(
        message.isProtected ? '这条消息站点不公开' : '（没有正文）',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return SelectableText(message.text, style: theme.textTheme.bodyMedium);
  }

  /// 验证码那一行。
  ///
  /// 验证码是用户唯一要**操作**的东西（复制去注册），所以给它最大的
  /// 点击面积和最高的对比度 —— 整行可点，不是只点那串数字。
  Widget _codeRow(ColorScheme scheme) {
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onCopyCode(message.code),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.password, size: 16, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                message.code,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
              Icon(Icons.copy, size: 15, color: scheme.onPrimaryContainer),
              const SizedBox(width: 4),
              Text(
                '复制',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
