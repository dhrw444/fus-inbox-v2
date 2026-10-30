/// 出口设置页：从内置清单里挑一条，或者自己填。
///
/// ## 这个页面存在的理由
///
/// 站点对同一 IP 有配额。直连时所有用户共用「你这台手机的宽带 IP」，
/// 几条短信之后就是 429。要换出口就必须有个地方让他**看见**有哪些、
/// 哪些真的通、当前用的是哪条。
///
/// ## 三条界面规则
///
///   1. **不自动挑**。清单里 588 条全是陌生人的节点，默认挑一条等于把
///      他的流量交给一个随机的人。必须他自己点。
///   2. **当前出口永远显示在最上面**，不是「选中高亮」—— 因为出口可能在
///      别处被换（自动轮换、桥崩了），高亮会留在旧行上，而顶部那行是
///      实时读状态的。
///   3. **起不来就说起不来**。桥绑不上端口时不退回直连，界面上一行红字
///      说明原因，抓取那边会直接失败。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/store.dart';
import '../core/user_agent.dart';
import '../data/egress.dart';
import '../data/proxy_config.dart';
import '../data/proxy_probe.dart';
import '../main.dart' show store;

/// 出口设置页。
class const EgressPage({required this.egress, super.key})
    extends StatefulWidget {
  final Egress egress;

  @override
  State<EgressPage> createState() => _EgressPageState();
}

class _EgressPageState() extends State<EgressPage> {
  /// 手填框。
  final _input = TextEditingController();

  /// 手填解析出来的结果。null = 还没填或填错了。
  ProxyConfig? _typed;
  String _typedError = '';

  /// 正在测速的出口 id 集合。
  final _probing = <String>{};

  /// 清单有没有加载过。
  bool _loaded = false;
  String _loadError = '';

  @override
  void initState() {
    super.initState();
    widget.egress.onChanged = () {
      if (mounted) setState(() {});
    };
    _loadManifest();
  }

  @override
  void dispose() {
    widget.egress.onChanged = null;
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadManifest() async {
    try {
      final text = await rootBundle.loadString('assets/proxies/builtin.txt');
      if (!mounted) return;
      widget.egress.loadManifest(text);
      setState(() {
        _loaded = true;
        _loadError = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '清单读不到：$e');
    }
  }

  /// 手填框变了。立刻解析、立刻给结果 —— 不等到点按钮。
  ///
  /// 用户填完一行马上要知道「这行能不能用」，等点了「应用」才报错的话，
  /// 他会以为是代理不通，而不是格式不对。
  void _onTyped(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      setState(() {
        _typed = null;
        _typedError = '';
      });
      return;
    }
    final parsed = parseProxyLine(text);
    setState(() {
      _typed = parsed;
      _typedError = parsed == null
          ? '看不懂这一行（格式：socks5://user:pass@host:port）'
          : '';
    });
  }

  /// 应用一条出口。
  ///
  /// 失败**不弹 SnackBar**：桥起不来是持续状态，SnackBar 几秒就消失，
  /// 用户回头看不见原因。状态留在顶部那张卡的红字里（读 `egress`）。
  Future<void> _apply(ProxyConfig target) async {
    await widget.egress.useProxy(target);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _probe(ProxyConfig target) async {
    setState(() => _probing.add(target.id));
    await widget.egress.probe(target);
    if (!mounted) return;
    setState(() => _probing.remove(target.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.egress;

    return Scaffold(
      appBar: AppBar(title: const Text('出口设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _statusCard(theme, e),
          _identityCard(theme),
          _manualCard(theme),
          _sectionHeader(theme, '内置清单'),
          ..._manifestRows(theme, e),
        ],
      ),
    );
  }

  // ── 顶部状态 ─────────────────────────────────────────────

  /// 当前出口。**实时读 egress，不存快照。**
  Widget _statusCard(ThemeData theme, Egress e) {
    final bad = e.choice == ProxyChoice.unavailable;
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: bad ? scheme.errorContainer : scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (e.choice) {
                    ProxyChoice.direct => Icons.lan_outlined,
                    ProxyChoice.proxy => Icons.vpn_lock_outlined,
                    ProxyChoice.unavailable => Icons.report_problem_outlined,
                  },
                  size: 20,
                  color: bad ? scheme.onErrorContainer : scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.summary,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: bad ? scheme.onErrorContainer : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 桥转了几条连接。**界面空白时第一个该看的就是这个** ——
            // 是 0 说明 WebView 根本没走过来，不是站点不给数据。
            Text(
              '桥：${e.port == 0 ? '未启动' : '端口 ${e.port}'}'
              ' · 转过 ${e.connections} 条连接',
              style: theme.textTheme.bodySmall?.copyWith(
                color: bad ? scheme.onErrorContainer : scheme.onSurfaceVariant,
              ),
            ),
            if (e.bridgeError.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '最近一次失败：${e.bridgeError}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: bad
                      ? scheme.onErrorContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                if (e.choice != ProxyChoice.direct)
                  FilledButton.tonal(
                    onPressed: () => setState(e.direct),
                    child: const Text('改用直连'),
                  ),
                if (e.choice == ProxyChoice.unavailable)
                  FilledButton.tonal(
                    onPressed: () {
                      // 「重试」要重试**那条起不来的出口**，不是 _typed
                      // （那可能还没填）。_current 是上次选的那条。
                      final target = e.current ?? _typed;
                      if (target != null) _apply(target);
                    },
                    child: const Text('重试'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 身份 ────────────────────────────────────────────────

  /// 当前身份 + 换一个。
  ///
  /// **换身份和换出口是一件事的两面**：站点同时看 IP 和浏览器身份。
  /// 只换 IP 而身份不变，等于「同一个人换了个门进来」；只换身份而 IP
  /// 不变，等于「同一个人换了个帽子」。两个都换才是另一个访客。
  ///
  /// 所以这里**故意把两者放在同一页**，而不是各开一个设置项。
  Widget _identityCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final id = currentIdentity;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前身份', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '${id.model} · Android ${id.androidVersion} · Chrome ${id.chromeMajor}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            // UA 全文给出来，但小字、可选中。调试时这是唯一能确认
            // 「内核真的用上了这个 UA」的地方。
            SelectableText(
              id.userAgent,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _rotate,
                  icon: const Icon(Icons.refresh),
                  label: const Text('换一个身份'),
                ),
                OutlinedButton.icon(
                  onPressed: _resetIdentity,
                  icon: const Icon(Icons.restore),
                  label: const Text('回到内核真值'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '换身份要重开收件页才生效，并且会清掉站点在这台设备上存的'
              '验证状态。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 换一个随机身份并写盘。
  ///
  /// **先写盘再改内存**？反过来才对 —— 顺序无所谓，但必须两边都做：
  /// 只改内存不写盘 = 重启变回旧的（用户以为换过了）；
  /// 只写盘不改内存 = 这一轮还用旧的（用户以为没换）。
  void _rotate() {
    final next = rotateIdentity();
    store.write(kUserAgentKey, next.userAgent);
    setState(() {});
  }

  /// 回到内核真值。
  ///
  /// 这是「撤销」。内核真值是这个设备的真实身份 —— 站点看它最正常。
  /// 同时清掉存盘，否则下次启动又读回那个随机的。
  void _resetIdentity() {
    final kernel = kernelIdentity;
    if (kernel == null) {
      // 启动时没探到（`getDefaultUserAgent` 抛了）。这时没有真值可回，
      // 说出来，别假装成功。
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('启动时没拿到内核 UA，回不去')));
      return;
    }
    store.remove(kUserAgentKey);
    restoreUserAgent(kernel.userAgent);
    setState(() {});
  }

  // ── 手填 ────────────────────────────────────────────────

  Widget _manualCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('自己填一条', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _input,
              onChanged: _onTyped,
              // 密码里可能有 `@`、`:`、`/`，别让输入法自动纠错把它们改掉。
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'socks5://user:pass@1.2.3.4:1080',
                errorText: _typedError.isEmpty ? null : _typedError,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: _typed == null ? null : () => _apply(_typed!),
                  child: const Text('用这条'),
                ),
                const SizedBox(width: 8),
                if (_typed != null)
                  TextButton(
                    onPressed: _probing.contains(_typed!.id)
                        ? null
                        : () => _probe(_typed!),
                    child: Text(_probing.contains(_typed!.id) ? '测速中…' : '先测速'),
                  ),
                const Spacer(),
                if (_typed != null)
                  Text(
                    _typed!.hasAuth ? '带认证' : '无认证',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (_typed != null) ...[
              const SizedBox(height: 8),
              _probeLine(theme, widget.egress.probeOf(_typed!)),
            ],
          ],
        ),
      ),
    );
  }

  // ── 清单 ────────────────────────────────────────────────

  Widget _sectionHeader(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );

  List<Widget> _manifestRows(ThemeData theme, Egress e) {
    if (_loadError.isNotEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _loadError,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      ];
    }
    if (!_loaded) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    // 按测速结果排序：通的在前、快的在前。没测过的在最后 ——
    // 排前面的话用户点「最快的那条」会点到一条从没测过的。
    final list = rankByProbe(e.manifest, e.probeOf);
    if (list.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('清单是空的', style: theme.textTheme.bodyMedium),
        ),
      ];
    }
    return [for (final p in list) _row(theme, e, p)];
  }

  Widget _row(ThemeData theme, Egress e, ProxyConfig p) {
    final selected = e.current?.id == p.id;
    final probing = _probing.contains(p.id);
    return ListTile(
      dense: true,
      // 当前那条打个勾。**但顶部状态卡才是真来源** —— 这里只是
      // 「清单里哪一行是他选的」，桥崩了的时候顶卡会红，这里还是勾。
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        size: 18,
        color: selected ? theme.colorScheme.primary : null,
      ),
      title: Text(p.displayName, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        '${p.scheme.wire}${p.hasAuth ? ' · 带认证' : ''}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (probing)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              _probeText(e.probeOf(p)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: _probeColor(theme, e.probeOf(p)),
              ),
            ),
          IconButton(
            tooltip: '测速',
            iconSize: 18,
            onPressed: probing ? null : () => _probe(p),
            icon: const Icon(Icons.speed),
          ),
        ],
      ),
      onTap: () => _apply(p),
    );
  }

  /// 一行测速结果。
  Widget _probeLine(ThemeData theme, ProxyProbe? r) {
    if (r == null) {
      return Text(
        '还没测过。测速会真的连一次站点 —— 通不通、多快，一次就知道。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Text(
      r.ok
          ? '通 · ${r.millis}ms · ${r.detail}'
          : '不通 · ${r.millis}ms · ${r.detail}',
      style: theme.textTheme.bodySmall?.copyWith(color: _probeColor(theme, r)),
    );
  }

  String _probeText(ProxyProbe? r) {
    if (r == null) return '未测';
    return r.ok ? '${r.millis}ms' : '不通';
  }

  Color _probeColor(ThemeData theme, ProxyProbe? r) {
    if (r == null) return theme.colorScheme.onSurfaceVariant;
    if (!r.ok) return theme.colorScheme.error;
    // 超过 1.5 秒就算慢 —— 站点单页 TLS 握手实测要 2~4 秒，
    // 代理再加 1.5 秒以上基本没法用。
    return r.millis > 1500
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
  }
}
