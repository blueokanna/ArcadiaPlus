import 'dart:async';

import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/rust/api.dart' as api;
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/services/native_core_service.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';

class DnsStatusCard extends StatefulWidget {
  const DnsStatusCard({super.key, this.readStatus});
  final Future<RecursiveDnsStatus> Function()? readStatus;
  @override
  State<DnsStatusCard> createState() => _DnsStatusCardState();
}

class _DnsStatusCardState extends State<DnsStatusCard> {
  RecursiveDnsStatus? _status;
  String? _error;
  Timer? _timer;
  bool _loading = false;
  bool _visible = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    AppLifecycle.instance.active.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  void _sync() {
    _generation++;
    _timer?.cancel();
    if (_visible && AppLifecycle.instance.isActive) {
      _refresh();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_loading || !_visible || !AppLifecycle.instance.isActive) return;
    final generation = _generation;
    _loading = true;
    try {
      if (widget.readStatus == null && !NativeCoreService.instance.isReady) {
        return;
      }
      final status = await (widget.readStatus ?? api.getRecursiveDnsStatus)();
      if (mounted &&
          generation == _generation &&
          (status != _status || _error != null)) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final status = _status;
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    zh ? 'RecurseX · 本地递归' : 'RecurseX · Local recursion',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: _refresh,
                  tooltip: zh ? '刷新 DNS 状态' : 'Refresh DNS status',
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Text(
              _error ??
                  (status == null
                      ? (zh ? '等待核心就绪' : 'Waiting for the core')
                      : status.running
                      ? (zh
                            ? '运行中 · ${status.listen}'
                            : 'Running · ${status.listen}')
                      : (zh
                            ? '本地递归未运行；不代表转发 DNS 已停止。设置将在下次启动代理时应用。'
                            : 'Local recursion is stopped; forwarding DNS may still be active. Settings apply on the next proxy start.')),
            ),
            if (status != null && status.running) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text('${zh ? '查询' : 'Queries'} ${status.queries}'),
                  Text('${zh ? '缓存命中' : 'Cache hits'} ${status.cacheHits}'),
                  Text(
                    '${zh ? '上游请求' : 'Upstream queries'} ${status.upstreamQueries}',
                  ),
                  Text('${zh ? '失败' : 'Failures'} ${status.failures}'),
                ],
              ),
            ],
            const Divider(height: 24),
            Text(
              zh
                  ? '本机递归减少对单个递归服务商的依赖，但直查权威服务器通常使用明文 DNS，不能承诺防监听。当前未启用根信任链 DNSSEC 验证。需要传输加密时，请使用经过证书校验的 DoH/DoT 上游；上游服务商仍能看到查询。'
                  : 'Local recursion reduces reliance on a single recursive provider. Queries to authoritative servers normally use plaintext DNS. This build does not validate an anchored DNSSEC chain. Use certificate-verified DoH/DoT for transport privacy; the resolver still sees your queries.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
