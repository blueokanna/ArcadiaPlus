import 'package:flutter/material.dart';

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
        final records = _controller.records;
        final status = _controller.status;
        final content = Column(
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
                Text('${records.length}', style: t.titleMedium),
                IconButton(
                  onPressed: _controller.refresh,
                  tooltip: zh ? '刷新' : 'Refresh',
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (status?.running == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Text(
                      'RecurseX · ${status!.listen ?? ""}',
                      style: t.labelLarge,
                    ),
                    Text(
                      '${zh ? '递归查询' : 'Recursive queries'} ${status.queries}',
                    ),
                    Text('${zh ? '命中缓存' : 'Cache hits'} ${status.cacheHits}'),
                    Text('${zh ? '失败' : 'Failures'} ${status.failures}'),
                  ],
                ),
              ),
            if (_controller.failed)
              Text(
                zh ? '读取失败，保留上次快照' : 'Read failed; showing the last snapshot',
                style: TextStyle(color: c.error),
              ),
            if (records.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  zh ? '暂无可读取的 DNS 查询事件' : 'No DNS query events available',
                  style: t.titleSmall,
                  textAlign: TextAlign.center,
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide =
                      constraints.maxWidth >= 600 &&
                      MediaQuery.textScalerOf(context).scale(14) < 22;
                  final rows = records.take(widget.compact ? 6 : 80);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 90,
                                child: Text(
                                  zh ? '时间' : 'Time',
                                  style: t.labelMedium,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  zh ? '域名' : 'Domain',
                                  style: t.labelMedium,
                                ),
                              ),
                              SizedBox(
                                width: 64,
                                child: Text(
                                  zh ? '类型' : 'Type',
                                  style: t.labelMedium,
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child: Text(
                                  zh ? '发起' : 'Source',
                                  style: t.labelMedium,
                                ),
                              ),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  zh ? '结果/耗时' : 'Result/time',
                                  style: t.labelMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      for (final row in rows)
                        Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: c.surfaceContainerHighest.withValues(
                              alpha: .45,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: wide
                              ? Row(
                                  children: [
                                    SizedBox(
                                      width: 90,
                                      child: Text(
                                        _time(row.time),
                                        style: t.bodySmall,
                                      ),
                                    ),
                                    Expanded(
                                      child: SelectableText(
                                        row.domain,
                                        maxLines: 1,
                                        style: t.bodyMedium?.copyWith(
                                          fontFamily: AppTypography.codeFamily,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 64,
                                      child: Text(
                                        row.type,
                                        style: t.labelMedium,
                                      ),
                                    ),
                                    SizedBox(
                                      width: 110,
                                      child: Text('TUN', style: t.bodySmall),
                                    ),
                                    const SizedBox(width: 72, child: Text('—')),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText(
                                      row.domain,
                                      style: t.bodyMedium?.copyWith(
                                        fontFamily: AppTypography.codeFamily,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${_time(row.time)} · ${row.type} · TUN',
                                      style: t.labelMedium,
                                    ),
                                  ],
                                ),
                        ),
                    ],
                  );
                },
              ),
            const SizedBox(height: 12),
            Text(
              zh
                  ? '读取内核保留的 TUN 查询事件，最多显示 80 条。仅覆盖已输出的 INFO 日志；结果、逐条缓存命中与耗时尚未由当前内核公开。递归计数只统计本地 RecurseX。'
                  : 'Up to 80 retained TUN INFO events. The current core does not expose per-query answers, cache hits or timings. Recursive counters cover local RecurseX only.',
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ],
        );
        return Card.filled(
          child: Padding(padding: const EdgeInsets.all(16), child: content),
        );
      },
    );
  }

  String _time(String input) {
    // Corduit's log clock is UTC but its legacy format omits the suffix.
    final date = DateTime.tryParse('${input.replaceFirst(' ', 'T')}Z')
        ?.toLocal();
    if (date == null) return input;
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  }
}
