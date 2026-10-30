/// 号码目录页：搜索、页签、排序、收藏，每条带**收录时间**。
///
/// ## 出口这件事是本页的重点
///
/// 抓目录走 `dart:io` 的 `HttpClient`，**完全不经过 WebView 的代理设置**。
/// 「以为在走代理」和「真的在走代理」从外面看不出区别，所以本页对出口
/// 只允许三种明确的说法：
///
/// - `'DIRECT'` —— 用户**明确**选了直连
/// - `'PROXY 127.0.0.1:<端口>'` —— 走本地桥
/// - `null` —— 要代理但桥没起来 → **抓取失败**，绝不偷偷直连
///
/// 第三种最容易写错：写成「桥没起来就直连」，界面一片祥和，而真实 IP
/// 已经交出去了。
///
/// ## 收录时间是**按需**抓的
///
/// 目录页本身**没有**收录时间 —— 站点只在号码详情页的
/// `<script id="fus-number-insights">` 里给。所以：
///
///   1. 列表先出来，收录时间那一行显示「收录时间未查到」
///   2. 后台按顺序慢慢补，一条一条来
///   3. 补到的就地替换
///
/// 不并发抓：那等于对站点发一轮上百个请求，是标准的爬取行为，会被当成
/// 机器人。一次一条，看起来就是「用户看了几个号」。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/directory_filter.dart';
import '../data/number_entry.dart';
import '../data/number_fetch.dart';
import 'inbox_page.dart';

/// 出口由外部提供：给一个函数，返回那三种取值之一。
///
/// 做成回调而不是传一个固定字符串：桥的端口**每次重建都不一样**
/// （代理轮换、桥重启都会换），抓一个快照就等于永远指向死端口。
typedef EgressResolver = String? Function();

/// 号码目录页。
class const NumbersPage({
  super.key,
  this.resolveEgress,
  this.loadStars,
  this.saveStars,
}) extends StatefulWidget {
  /// 为空 = 本页不做代理判断，直接直连（测试和「用户明确选直连」用）。
  final EgressResolver? resolveEgress;

  /// 读回收藏。为空 = 不持久化（收藏只在本次会话有效）。
  final Future<Set<String>> Function()? loadStars;

  /// 写收藏。
  final Future<void> Function(Set<String>)? saveStars;

  @override
  State<NumbersPage> createState() => _NumbersPageState();
}

class _NumbersPageState() extends State<NumbersPage> {
  late final NumberFetcher _fetcher;

  /// 全量号码，抓回来后不再变。
  final _entries = <NumberEntry>[];

  /// 收录时间缓存。key 是号码，value 是查到的结果。
  final _firstSeen = <String, FirstSeenInfo>{};

  /// 收藏的号码。
  final _stars = <String>{};

  DirectoryFilter _filter = const DirectoryFilter();

  bool _loading = true;
  String? _error;
  int _loadedPages = 0;
  int _total = 0;

  /// 抓取轮次。每次 `_load` 递增，回来时对不上就丢弃结果。
  ///
  /// **必须要有**：刷新按钮和 `initState` 都能触发 `_load`，用户手快连点
  /// 两下就有两个 `fetchAll` 在跑。两者都会改 `_entries`，交错写入的后果
  /// 是列表内容来自两次抓取 —— 看起来是「号码忽多忽少」，而且先发起的
  /// 那次可能后回来，把新数据整个覆盖掉。
  int _run = 0;

  /// 收录时间查询是否还在跑。用它防止两轮并行去抓同一批号码。
  bool _probingInsights = false;

  /// 已排进查询队列的号码。避免同一号码被排两次。
  final _insightQueued = <String>{};

  @override
  void initState() {
    super.initState();
    _fetcher = NumberFetcher(egress: widget.resolveEgress);
    _restoreStars();
    _load();
  }

  @override
  void dispose() {
    _fetcher.dispose();
    super.dispose();
  }

  Future<void> _restoreStars() async {
    final load = widget.loadStars;
    if (load == null) return;
    final s = await load();
    if (!mounted) return;
    setState(() {
      _stars
        ..clear()
        ..addAll(s);
    });
  }

  Future<void> _toggleStar(String digits) async {
    setState(() {
      if (!_stars.remove(digits)) _stars.add(digits);
    });
    // 写盘失败不该让界面回滚 —— 那会让用户以为点击没生效。
    // 收藏是锦上添花，丢了下一次重开还在内存里。
    final save = widget.saveStars;
    if (save != null) unawaited(save(Set<String>.from(_stars)));
  }

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
      // 列表出来了，开始补收录时间。
      unawaited(_probeFirstSeen(run));
    } on NumberFetchError catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// 逐条补收录时间。
  ///
  /// 一条一条来，失败就跳过 —— 某一条抓不到不该让整轮停下。
  /// 已经在查的不重复查；[run] 变了（用户刷新了）就停。
  Future<void> _probeFirstSeen(int run) async {
    if (_probingInsights) return;
    _probingInsights = true;
    try {
      for (final e in List<NumberEntry>.from(_entries)) {
        if (!mounted || run != _run) return;
        // 已经查到（不管有没有时间）就不再抓。
        if (_firstSeen.containsKey(e.digits)) continue;
        if (_insightQueued.contains(e.digits)) continue;
        _insightQueued.add(e.digits);

        try {
          final snap = await _fetcher.fetchInsights(e.digits);
          if (!mounted || run != _run) return;
          setState(() {
            // 抓到 = 站点有这份数据；抓不到内容 = 站点确实没给。
            // 两种都要记下来，否则会一直重试同一个号。
            _firstSeen[e.digits] = snap == null
                ? FirstSeenInfo.absent
                : FirstSeenInfo(at: snap.directoryFirstSeenAt, probed: true);
          });
        } on NumberFetchError {
          // 网络/出口问题。不记进缓存 —— 下次刷新还有机会。
          if (!mounted || run != _run) return;
        } finally {
          _insightQueued.remove(e.digits);
        }
      }
    } finally {
      _probingInsights = false;
    }
  }

  void _open(NumberEntry n) {
    // 直接 push，不用命名路由 —— 命名路由要在全局表里注册，改一个跳转
    // 要动两个文件，而且写错名字不会编译报错，只在点下去那一刻崩。
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

    final rows = applyDirectoryFilter(
      entries: _entries,
      filter: _filter,
      starredOf: _stars.contains,
      firstSeenOf: (d) => _firstSeen[d] ?? FirstSeenInfo.unknown,
      now: DateTime.now(),
    );

    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        _buildSearchBar(theme),
        _buildTabs(theme),
        _buildSummary(theme, rows),
        Expanded(child: _buildList(theme, rows)),
      ],
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: '搜号码、区号或州',
          suffixIcon: _filter.query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: '清空',
                  onPressed: () =>
                      setState(() => _filter = _filter.copyWith(query: '')),
                ),
        ),
        onChanged: (v) => setState(() => _filter = _filter.copyWith(query: v)),
      ),
    );
  }

  Widget _buildTabs(ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final t in NumberTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(t.label),
                selected: _filter.tab == t,
                onSelected: (_) =>
                    setState(() => _filter = _filter.copyWith(tab: t)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              avatar: const Icon(Icons.star, size: 16),
              label: const Text('收藏'),
              selected: _filter.starredOnly,
              onSelected: (v) =>
                  setState(() => _filter = _filter.copyWith(starredOnly: v)),
            ),
          ),
          // 排序下拉放在页签同一行：三个维度一起改，不占额外高度。
          PopupMenuButton<NumberSort>(
            tooltip: '排序方式',
            initialValue: _filter.sort,
            onSelected: (s) =>
                setState(() => _filter = _filter.copyWith(sort: s)),
            itemBuilder: (_) => [
              for (final s in NumberSort.values)
                PopupMenuItem<NumberSort>(value: s, child: Text(s.label)),
            ],
            child: Chip(
              avatar: const Icon(Icons.sort, size: 16),
              label: Text(_filter.sort.label),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ThemeData theme, List<DirectoryRow> rows) {
    final shown = rows.whereType<NumberRow>().length;
    final text = _loading
        ? '已加载 $_total 个号 · 第 $_loadedPages 页'
        : _filter.isDefault
        ? '共 ${_entries.length} 个号码'
        : '筛出 $shown 个 / 共 ${_entries.length} 个';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  Widget _buildList(ThemeData theme, List<DirectoryRow> rows) {
    if (rows.isEmpty) {
      return Center(child: Text('没有匹配的号码', style: theme.textTheme.bodyLarge));
    }
    final now = DateTime.now();
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        return switch (row) {
          GroupRow() => _buildGroupHeader(theme, row),
          NumberRow() => _buildNumberTile(theme, row, now),
        };
      },
    );
  }

  Widget _buildGroupHeader(ThemeData theme, GroupRow row) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        '${row.title}  ·  ${row.count}',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildNumberTile(ThemeData theme, NumberRow row, DateTime now) {
    final n = row.entry;
    final info = _firstSeen[n.digits] ?? FirstSeenInfo.unknown;
    final age = describeFirstSeen(info, now);
    final exact = exactFirstSeen(info);

    return ListTile(
      leading: IconButton(
        icon: Icon(
          row.starred ? Icons.star : Icons.star_border,
          size: 20,
          color: row.starred ? theme.colorScheme.primary : null,
        ),
        tooltip: row.starred ? '取消收藏' : '收藏',
        onPressed: () => _toggleStar(n.digits),
      ),
      title: Text(n.formatted),
      // 第二行是收录时间（用户要的那个），第三行才是归属地和短信情况。
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  exact.isEmpty ? age : '$age · $exact',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (n.regionLabel.isNotEmpty) n.regionLabel,
              n.describeAge(now),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      isThreeLine: true,
      onTap: () => _open(n),
    );
  }
}
