/// 首页：填一个号码，打开它的收件页。
///
/// 号码目录那一步（从站点拉整份可用号码列表）还没接 —— 它需要走代理、
/// 有缓存、要分页，是独立的一块。这里先只做「我已知号码，直接看」这条
/// 最短路径，把整条链跑通。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import 'inbox_page.dart';

/// 站点收件页的地址模板。
///
/// 站点把号码收在 path 里（`/numbers/<11 位>/`）—— 这是**站点自己的**
/// 路由形状，不是我们能选的。
const _siteHost = 'freeussms.com';

class const HomePage({super.key}) extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState() extends State<HomePage> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 把用户输入规整成 11 位纯数字。
  ///
  /// 允许他粘 `+1 (415) 555-0100` 这种 —— 那是他从别处复制来的形状，
  /// 要求他先手动删干净是没必要的。但不能允许位数不对：那会打开一个
  /// 404 页面，而用户看到的只是「一片空白」。
  String? _normalize(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 11 && digits.startsWith('1')) {
      return digits.substring(1);
    }
    if (digits.length == 10) return digits;
    return null;
  }

  void _open() {
    final n = _normalize(_input.text);
    if (n == null) {
      setState(() => _error = '需要 10 位美国号码（可以带 +1、空格、括号）');
      return;
    }
    setState(() => _error = null);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InboxPage(
          inboxUrl: 'https://$_siteHost/numbers/$n/',
          title:
              '(${n.substring(0, 3)}) ${n.substring(3, 6)}-${n.substring(6)}',
          // `allowedHost` 不传 —— `InboxPage` 的默认值就是同一个域名，
          // 显式传一遍会被 `avoid_redundant_argument_values` 判冗余。
          // 站点换域名时改 `InboxPage` 的默认值那一处即可。
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('短信查看器')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('输入号码', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _input,
              autofocus: true,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d+()\-\s]')),
              ],
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: '4155550100',
                errorText: _error,
              ),
              onSubmitted: (_) => _open(),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _open,
              icon: const Icon(Icons.inbox_outlined),
              label: const Text('打开收件箱'),
            ),
            const SizedBox(height: 28),
            Text(
              '数据来自公开号码池。每条短信只在该号码被公开分享后可见，'
              '不需要注册。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
