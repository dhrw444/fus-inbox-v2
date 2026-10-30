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

import '../../core/code_extract.dart';
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

  /// 这条消息里要显示的验证码。
  ///
  /// 两个来源，优先级明确：
  ///   1. **站点给的** `copy_code` —— 那是站点自己认出来的真值，直接用
  ///   2. 站点没给 → 从正文里**提取**（`core/code_extract.dart`）
  ///
  /// 第二种是我们猜的，所以界面上要标出来（见 [_codeRow] 的 `guessed`）。
  /// 不标的话用户会以为「没验证码」和「提取不到」是同一件事，而实际
  /// 上后者只是我们没猜对，原文里可能明明有。
  ExtractedCode get _code {
    if (message.hasCode) {
      return ExtractedCode(value: message.code, fromSite: true);
    }
    return extractCode(message.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final code = _code;
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
            if (code.value.isNotEmpty) ...[
              const SizedBox(height: 8),
              _codeRow(scheme, code),
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
  /// 三种情况，三种显示：
  ///   1. 有正文、没受保护 —— 直接显示正文
  ///   2. 没正文、受保护 —— 「这条消息站点不公开」
  ///   3. **有正文、但受保护** —— 正文照显示，**外加一条提示条**
  ///
  /// 第 3 种原来没有。`isProtected` 只在「正文为空」时才被读，于是
  /// 「站点说暂时不可读、但页面上已经有一段文字」这种情况会被当成正常短信
  /// 显示出来 —— 用户分不清「这条是真短信」和「这条站点说不给看」。
  ///
  /// 这个组合是真实存在的：站点渲染正文是无条件的
  /// （live.js:546 `card.append(el('p','live-message-body',m.content||''))`），
  /// 而它自己判断「有没有可读正文」时要额外排除 protected
  /// （live.js:69 `...&&item.content.trim()&&!item.protected`）——
  /// 说明「正文非空 + 受保护」在站点的模型里是成立的。
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 受保护但已经有正文时，先给一句说明再显示正文 ——
        // 顺序是「说明在前」，因为用户要先知道这条不完全可信，再看内容。
        if (message.isProtected) ...[
          Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 14,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '站点标记这条暂时不完整，稍后刷新可能补齐',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        SelectableText(message.text, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  /// 验证码那一行。
  ///
  /// 验证码是用户唯一要**操作**的东西（复制去注册），所以给它最大的
  /// 点击面积和最高的对比度 —— 整行可点，不是只点那串数字。
  ///
  /// [code.fromSite] 为假时（从正文提取的）在行尾加一句「推断」。
  /// 必须标：站点没给、我们猜出来的值可能是订单号或别的数字，
  /// 用户需要知道这一条不那么确定。
  Widget _codeRow(ColorScheme scheme, ExtractedCode code) {
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onCopyCode(code.value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.password, size: 16, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                code.value,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              if (!code.fromSite) ...[
                const SizedBox(width: 6),
                Text(
                  '推断',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
              ],
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
