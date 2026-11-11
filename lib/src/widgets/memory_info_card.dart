import 'package:flutter/material.dart';

import '../rust/types.dart';
import '../utils/app_memory_policy.dart';

String _mib(num bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MiB';

class MemoryInfoCard extends StatelessWidget {
  const MemoryInfoCard({super.key, required this.info, required this.device});
  final SystemInfo info;
  final String device;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final c = Theme.of(context).colorScheme;
    final cache = PaintingBinding.instance.imageCache;
    return Card.filled(
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: (_) => _MemoryDetails(info: info, device: device),
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
                _mib(info.memoryUsed.toDouble()),
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
                    label: Text(info.platform),
                    avatar: const Icon(Icons.devices_rounded, size: 18),
                  ),
                  Chip(label: Text(device)),
                  Chip(
                    label: Text(
                      '${zh ? '图像缓存' : 'Image cache'} ${_mib(cache.currentSizeBytes)}',
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

class _MemoryDetails extends StatefulWidget {
  const _MemoryDetails({required this.info, required this.device});
  final SystemInfo info;
  final String device;
  @override
  State<_MemoryDetails> createState() => _MemoryDetailsState();
}

class _MemoryDetailsState extends State<_MemoryDetails> {
  int? _released;
  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final t = Theme.of(context).textTheme;
    final cache = PaintingBinding.instance.imageCache;
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
                IconButton.filledTonal(
                  tooltip: zh ? '清理图像缓存' : 'Clear image cache',
                  onPressed: cache.currentSizeBytes == 0
                      ? null
                      : () => setState(() {
                          _released = AppMemoryPolicy.releaseImageCache(cache);
                        }),
                  icon: const Icon(Icons.cleaning_services_rounded),
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
              _mib(widget.info.memoryUsed.toDouble()),
              style: t.displaySmall,
            ),
            Text(
              zh
                  ? '进程 RSS 快照，包含同进程内核。'
                  : 'Process RSS snapshot, including the in-process core.',
            ),
            const SizedBox(height: 24),
            Card.filled(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
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
                          : (cache.currentSizeBytes / cache.maximumSizeBytes)
                                .clamp(0, 1),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_mib(cache.currentSizeBytes)} / ${_mib(cache.maximumSizeBytes)}',
                    ),
                    Text(
                      zh ? '正在显示的图像、活动连接和 DNS 缓存不会被强制清除。' : 'Displayed images, active connections and DNS caches remain in use.',
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            if (_released != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    zh
                        ? '已从图像缓存移除 ${_mib(_released!)}；系统 RSS 不一定立即下降。'
                        : 'Evicted ${_mib(_released!)} from image cache; RSS may not fall immediately.',
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              '${widget.info.platform} · ${widget.device}',
              style: t.titleMedium,
            ),
            if (widget.info.cpuName.isNotEmpty) Text(widget.info.cpuName),
            const SizedBox(height: 8),
            Text(
              zh ? '当前接口未提供 Dart 堆与 Rust 分配器的独立占用，不拆分或估算百分比。' : 'Separate Dart heap and Rust allocator measurements are not available.',
              style: t.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
