import 'package:arcadiaplus/src/widgets/app_bottom_sheet.dart';
import 'package:flutter/material.dart';

import '../rust/types.dart';
import '../theme/app_shapes.dart';
import '../utils/app_memory_policy.dart';

String _mib(num bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MiB';

class MemoryInfoCard extends StatelessWidget {
  const MemoryInfoCard({
    super.key,
    required this.info,
    required this.device,
    required this.peakResidentBytes,
  });
  final SystemInfo info;
  final String device;
  final int? peakResidentBytes;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final c = Theme.of(context).colorScheme;
    return Card.filled(
      child: InkWell(
        customBorder: AppShapes.card,
        onTap: () => showAppBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: (_) => _MemoryDetails(
            info: info,
            device: device,
            peakResidentBytes: peakResidentBytes,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.memory_rounded, color: c.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      zh ? '内存与设备' : 'Memory & device',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                info.memoryUsed > BigInt.zero
                    ? _mib(info.memoryUsed.toDouble())
                    : (zh ? '暂无数据' : 'Unavailable'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              Text(
                zh ? '进程常驻内存 · RSS' : 'Process resident memory · RSS',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(
                    label: Text(
                      '${zh ? 'Rust 内核堆' : 'Rust core heap'} ${_mib(info.coreHeapBytes.toDouble())}',
                    ),
                  ),
                  Chip(
                    label: ValueListenableBuilder<int>(
                      valueListenable: AppMemoryPolicy.retainedBytes,
                      builder: (_, bytes, _) =>
                          Text('${zh ? '图像缓存' : 'Image cache'} ${_mib(bytes)}'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryDetails extends StatelessWidget {
  const _MemoryDetails({
    required this.info,
    required this.device,
    required this.peakResidentBytes,
  });
  final SystemInfo info;
  final String device;
  final int? peakResidentBytes;
  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final t = Theme.of(context).textTheme;
    final cache = PaintingBinding.instance.imageCache;
    final peak = peakResidentBytes;
    const budget = AppMemoryPolicy.processBudgetBytes;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    zh ? '内存信息' : 'Memory information',
                    style: t.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              info.memoryUsed > BigInt.zero
                  ? _mib(info.memoryUsed.toDouble())
                  : (zh ? '暂无数据' : 'Unavailable'),
              style: t.displaySmall,
            ),
            Text(
              zh
                  ? '进程 RSS 快照，包含同进程内核。'
                  : 'Process RSS snapshot, including the in-process core.',
            ),
            const SizedBox(height: 24),
            Text(zh ? '进程峰值 RSS' : 'Peak process RSS', style: t.titleMedium),
            const SizedBox(height: 8),
            if (peak != null) ...[
              LinearProgressIndicator(
                value: (peak / budget).clamp(0, 1),
                color: peak > budget
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                '${(peak / 1000000).toStringAsFixed(1)} MB / ${budget ~/ 1000000} MB',
              ),
              if (peak > budget)
                Text(
                  zh ? '本次运行已超出内存预算' : 'Memory budget exceeded this session',
                ),
            ] else
              Text(zh ? '系统未提供峰值' : 'Peak unavailable'),
            const SizedBox(height: 16),
            Text(
              '${zh ? 'Rust 内核堆' : 'Rust core heap'} · ${_mib(info.coreHeapBytes.toDouble())}',
              style: t.titleMedium,
            ),
            Text(
              zh ? '统计 Corduit、DNS 和桥接层仍在使用的 Rust 堆分配。' : 'Live Rust allocations in Corduit, DNS and the Flutter bridge.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 16),
            Card.filled(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<int>(
                  valueListenable: AppMemoryPolicy.retainedBytes,
                  builder: (_, bytes, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        zh ? '可清理的图像缓存' : 'Reclaimable image cache',
                        style: t.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withValues(alpha: .45),
                        value: cache.maximumSizeBytes == 0
                            ? 0
                            : (bytes / cache.maximumSizeBytes).clamp(0, 1),
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      const SizedBox(height: 8),
                      Text('${_mib(bytes)} / ${_mib(cache.maximumSizeBytes)}'),
                      Text(
                        zh ? '缓存达到容量的 95% 或达到图像数量上限时自动清理。' : 'Clears automatically at 95% capacity or when the image count limit is reached.',
                        style: t.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('${info.platform} · $device', style: t.titleMedium),
            if (info.cpuName.isNotEmpty) Text(info.cpuName),
          ],
        ),
      ),
    );
  }
}
