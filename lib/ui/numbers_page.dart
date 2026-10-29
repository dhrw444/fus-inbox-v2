/// 号码目录页：从站点拉整份可用号码，点一条进它的收件箱。
///
/// ## 出口这件事是本页的重点
///
/// 抓目录走的是 `dart:io` 的 `HttpClient`，**完全不经过 WebView 的代理
/// 设置**。也就是说「以为在走代理」和「真的在走代理」从外面看不出区别 ——
/// 实测确认过：不挂 `findProxy` 时请求照样成功、SOCKS5 侧连接数为 0。
///
/// 所以本页对出口只允许三种明确的说法：
///
/// - `'DIRECT'` —— 用户**明确**选了直连
/// - `'PROXY 127.0.0.1:<端口>'` —— 走本地桥
/// - `null` —— 用户要代理但桥没起来 → **抓取失败**，绝不偷偷直连
///
/// 第三种是最容易写错的：写成「桥没起来就直连」，界面上一片祥和，
/// 而真实 IP 已经交出去了。
library;

import 'package:flutter/material.dart';

import '../data/number_entry.dart';
import '../data/number_fetch.dart';
import 'inbox_page.dart';

/// 出口由外部提供：给一个函数，返回上面那三种取值之一。
///
/// 做成回调而不是传一个固定字符串，是因为桥的端口**每次重建都不一样**
/// （代理轮换、桥重启都会换端口），抓一个快照就等于永远指向死端口。
typedef EgressResolver = String? Function();

class const NumbersPage({super.key, this.resolveEgress})
    extends StatefulWidget {
  /// 为空 = 本页不做代理判断，直接直连。
  ///
  /// 这是给测试和「用户明确选了直连」用的。生产环境由 `main.dart` 注入
  /// 一个读实时状态的解析器。
  final EgressResolver? resolveEgress;

  @override
  State<NumbersPage> createState() => _NumbersPageState();
}

class _NumbersPageState() extends State<NumbersPage> {
  late final NumberFetcher _fetcher;

  final _entries = <NumberEntry>[];
  bool _loading = true;
  String? _error;
  int _loadedPages = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _fetcher = NumberFetcher(egress: widget.resolveEgress);
    _load();
  }

  @override
  void dispose() {
    _fetcher.dispose();
    super.dispose();
  }

  /// 抓取代号。每次 `_load` 递增，回来时对不上就丢弃结果。
  ///
  /// **必须要有**：刷新按钮和 `initState` 都能触发 `_load`，用户手快
  /// 连点两下就有两个 `fetchAll` 在跑。两者都会调 `setState` 改 `_entries`，
  /// 交错写入的后果是列表内容来自两次抓取 —— 看起来是「号码忽多忽少」。
  /// 而且先发起的那次可能后回来，把新数据整个覆盖掉。
  int _run = 0;

  Future<void> _load() async {
    final run = ++_run;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _entries.clear();
        _loadedPages = 0;
        _total = 0;
      });
    }
    try {
      final all = await _fetcher.fetchAll(
        onProgress: (loaded, page) {
          if (!mounted || run != _run) return;
          setState(() {
            _total = loaded;
            _loadedPages = page;
          });
        },
        onPage: (soFar) {
          if (!mounted || run != _run) return;
          setState(() {
            _entries
              ..clear()
              ..addAll(soFar);
          });
        },
      );
      if (!mounted || run != _run) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(all);
        _loading = false;
      });
    } on NumberFetchError catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _open(NumberEntry n) {
    // 直接 push，不用命名路由 —— 命名路由要在一个全局表里注册，
    // 而那张表离这里十万八千里，改一个跳转要动两个文件。更要紧的是
    // **写错名字不会编译报错，只在点下去那一刻崩**。
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InboxPage(inboxUrl: n.inboxUrl, title: n.formatted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('号码目录'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '重新拉取',
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) return _buildError(theme);
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      return Center(child: Text('目录是空的', style: theme.textTheme.bodyLarge));
    }
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        _buildSummary(theme),
        Expanded(child: _buildList(theme)),
      ],
    );
  }

  /// 顶部那条「已加载 N 个号 · 第 M 页」。
  ///
  /// 抓取是分页并发的，边抓边显示 —— 用户看到数字在涨就知道还在动，
  /// 而不是盯着一个转圈等十秒。
  Widget _buildSummary(ThemeData theme) {
    final text = _loading
        ? '已加载 $_total 个号 · 第 $_loadedPages 页'
        : '共 ${_entries.length} 个号码';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final n = _entries[i];
        return ListTile(
          title: Text(n.formatted),
          subtitle: Text(n.regionLabel),
          trailing: n.messageCount > 0
              ? Text('${n.messageCount} 条', style: theme.textTheme.bodySmall)
              : null,
          onTap: () => _open(n),
        );
      },
    );
  }
}
