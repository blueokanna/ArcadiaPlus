import 'package:flutter/material.dart';

import '../rust/types.dart';
import '../services/dns_activity_service.dart';
import '../theme/app_typography.dart';

class DnsActivityPanel extends StatefulWidget {
  const DnsActivityPanel({
    super.key,
    this.reader = readDnsActivity,
    this.compact = false,
  });
  final DnsActivityReader reader;
  final bool compact;
  @override
  State<DnsActivityPanel> createState() => _DnsActivityPanelState();
}

class _DnsActivityPanelState extends State<DnsActivityPanel> {
  late final _controller = DnsActivityController(reader: widget.reader);
  String _search = '';
  String _filter = 'all';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.setVisible(TickerMode.valuesOf(context).enabled);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final rows = _controller.records.where(
          (row) =>
              row.domain.toLowerCase().contains(_search) &&
              (_filter != 'cache' || row.fromCache) &&
              (_filter != 'failed' || _failed(row)),
        );
        return Card.filled(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.dns_rounded, color: c.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        zh ? 'DNS 查询' : 'DNS queries',
                        style: t.titleMedium,
                      ),
                    ),
                    Text('${_controller.records.length}', style: t.titleMedium),
                    IconButton(
                      onPressed: _controller.loading
                          ? null
                          : _controller.refresh,
                      tooltip: zh ? '刷新' : 'Refresh',
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    if (!widget.compact)
                      IconButton(
                        onPressed: _controller.clearing
                            ? null
                            : _controller.clear,
                        tooltip: zh ? '清空记录' : 'Clear history',
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                  ],
                ),
                if (!widget.compact) ...[
                  const SizedBox(height: 8),
                  TextField(
                    onChanged: (value) =>
                        setState(() => _search = value.trim().toLowerCase()),
                    decoration: InputDecoration(
                      hintText: zh ? '搜索域名' : 'Search domains',
                      prefixIcon: const Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (key, label) in [
                        ('all', zh ? '全部' : 'All'),
                        ('cache', zh ? '缓存' : 'Cached'),
                        ('failed', zh ? '失败' : 'Failed'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: _filter == key,
                          onSelected: (_) => setState(() => _filter = key),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (_controller.failed)
                  Text(
                    zh
                        ? '读取失败，保留上次快照'
                        : 'Read failed; showing the last snapshot',
                    style: TextStyle(color: c.error),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      zh ? '暂无匹配的 DNS 查询' : 'No matching DNS queries',
                      textAlign: TextAlign.center,
                      style: t.titleSmall,
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide =
                          constraints.maxWidth >= 760 &&
                          MediaQuery.textScalerOf(context).scale(14) < 22;
                      return Column(
                        children: [
                          if (wide)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: _columns([
                                Text(zh ? '时间' : 'Time', style: t.labelMedium),
                                Text(
                                  zh ? '域名' : 'Domain',
                                  style: t.labelMedium,
                                ),
                                Text(zh ? '类型' : 'Type', style: t.labelMedium),
                                Text(zh ? '解析' : 'Path', style: t.labelMedium),
                                Text(
                                  zh ? '结果' : 'Answer',
                                  style: t.labelMedium,
                                ),
                                Text(
                                  zh ? '耗时' : 'Duration',
                                  style: t.labelMedium,
                                ),
                              ]),
                            ),
                          for (final row in rows.take(widget.compact ? 6 : 80))
                            _QueryRow(row: row, wide: wide, zh: zh),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: 12),
                Text(
                  zh
                      ? '最近 80 条解析记录 · 累计 ${_controller.total} 次。包含内核查址与本机递归；同一次访问可能触发多条解析，未进入解析器的 Fake-IP 合成不在此列。'
                      : 'Latest 80 resolver calls · ${_controller.total} completed. Includes engine lookups and local recursion, not Fake-IP synthesis. One visit can trigger multiple calls.',
                  style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
                ),
                if (_controller.dropped > BigInt.zero)
                  Text(
                    zh
                        ? '繁忙时跳过 ${_controller.dropped} 条记录，解析不受影响。'
                        : '${_controller.dropped} observations skipped under contention; resolution is unaffected.',
                    style: t.bodySmall,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

bool _failed(DnsQueryEvent row) =>
    !const {'NOERROR', 'NXDOMAIN', 'YXDOMAIN'}.contains(row.outcome);

String _time(DnsQueryEvent row) {
  final time = DateTime.fromMillisecondsSinceEpoch(
    row.completedAtMs.toInt(),
    isUtc: true,
  ).toLocal();
  return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}

String _duration(DnsQueryEvent row) {
  final micros = row.elapsedUs.toInt();
  return micros < 1000
      ? '<1 ms'
      : '${(micros / 1000).toStringAsFixed(micros < 10000 ? 1 : 0)} ms';
}

String _path(DnsQueryEvent row, bool zh) => row.path == 'recursive'
    ? (zh ? '本机递归' : 'Recursive')
    : (zh ? '转发' : 'Forward');

Widget _columns(List<Widget> children) => Row(
  children: [
    SizedBox(width: 80, child: children[0]),
    Expanded(flex: 3, child: children[1]),
    const SizedBox(width: 12),
    SizedBox(width: 56, child: children[2]),
    SizedBox(width: 84, child: children[3]),
    Expanded(flex: 3, child: children[4]),
    const SizedBox(width: 12),
    SizedBox(width: 70, child: children[5]),
  ],
);

class _QueryRow extends StatelessWidget {
  const _QueryRow({required this.row, required this.wide, required this.zh});
  final DnsQueryEvent row;
  final bool wide;
  final bool zh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = row.answers.isEmpty ? row.outcome : row.answers.join(', ');
    final cache = row.stale ? (zh ? '过期缓存' : 'Stale') : (zh ? '缓存' : 'Cached');
    final resultText = '${row.fromCache ? '$cache · ' : ''}$result';
    final domain = Text(
      row.domain,
      maxLines: wide ? 1 : 3,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontFamily: AppTypography.codeFamily,
      ),
    );
    final answer = Text(
      resultText,
      maxLines: wide ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: _failed(row) ? theme.colorScheme.error : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(zh ? 'DNS 查询详情' : 'DNS query details'),
              scrollable: true,
              content: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.domain, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Text(
                      '${row.queryType} · ${_path(row, zh)} · ${row.outcome}',
                    ),
                    Text('${_time(row)} · ${_duration(row)}'),
                    if (row.fromCache) Text(cache),
                    const Divider(height: 24),
                    for (final answer in row.answers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(answer),
                      ),
                    if (row.answers.isEmpty)
                      Text(zh ? '没有返回资源记录' : 'No resource records returned'),
                    if (row.truncated)
                      Text(
                        zh ? '结果摘要已截取，DNS 应答未受影响。' : 'Display summary shortened; the DNS answer is unaffected.',
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(zh ? '关闭' : 'Close'),
                ),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: wide
                ? _columns([
                    Text(_time(row), style: theme.textTheme.bodySmall),
                    domain,
                    Text(row.queryType, style: theme.textTheme.labelMedium),
                    Text(_path(row, zh), style: theme.textTheme.bodySmall),
                    answer,
                    Text(_duration(row), style: theme.textTheme.bodySmall),
                  ])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      domain,
                      const SizedBox(height: 6),
                      Text(
                        '${_time(row)} · ${row.queryType} · ${_path(row, zh)} · ${_duration(row)}',
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(height: 6),
                      answer,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
