import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/exit_ip_service.dart';

/// The same compact identity block fits a phone hero or a desktop status card.
class ExitIdentity extends StatelessWidget {
  const ExitIdentity({
    super.key,
    required this.report,
    required this.loading,
    required this.failed,
    required this.onRefresh,
  });
  final ExitIpReport? report;
  final bool loading;
  final bool failed;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final value = report;
    final network = switch (value?.network ?? IpNetworkKind.unknown) {
      IpNetworkKind.residentialCandidate =>
        zh ? '住宅候选' : 'Residential candidate',
      IpNetworkKind.mobile => zh ? '移动网络' : 'Mobile',
      IpNetworkKind.hosting => zh ? '数据中心' : 'Hosting',
      IpNetworkKind.proxy => zh ? '代理出口' : 'Proxy exit',
      IpNetworkKind.unknown => zh ? '类型未知' : 'Type unknown',
    };
    final score = value?.riskScore;
    final risk = score == null
        ? (zh ? '质量未知' : 'Risk unknown')
        : score <= 10
        ? (zh ? '风险较低' : 'Lower risk')
        : (zh ? '风险 $score/100' : 'Risk $score/100');
    final detail = value == null
        ? (zh ? '刷新出口信息' : 'Refresh exit information')
        : '${value.source} · ${TimeOfDay.fromDateTime(value.checkedAt).format(context)}\n${zh ? '类型与风险来自第三方情报；住宅候选不等于确认住宅，风险分数不是安全概率。' : 'Third-party classification. Residential candidate is not verified residential service; risk is not a probability.'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onLongPress: value == null
              ? null
              : () => Clipboard.setData(ClipboardData(text: value.ip)),
          child: Text(
            value?.ip ?? (loading ? (zh ? '检测出口…' : 'Checking exit…') : '—'),
            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final label in [network, risk])
              Tooltip(
                message: detail,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: label == risk && score != null
                        ? score > 50
                              ? c.errorContainer
                              : c.secondaryContainer
                        : c.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    label,
                    style: t.labelMedium?.copyWith(
                      color: label == risk && score != null
                          ? score > 50
                                ? c.onErrorContainer
                                : c.onSecondaryContainer
                          : c.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          value?.organization ??
              (failed
                  ? (zh ? '检测暂不可用' : 'Lookup unavailable')
                  : (zh ? '出口运营商' : 'Exit provider')),
          style: t.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Tooltip(
          message: detail,
          child: TextButton.icon(
            onPressed: loading ? null : onRefresh,
            icon: Icon(
              loading ? Icons.more_horiz : Icons.refresh_rounded,
              size: 16,
            ),
            label: Text(value?.source ?? (zh ? '检测 IP' : 'Check IP')),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
            ),
          ),
        ),
      ],
    );
  }
}
