import 'dart:async';

import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/rust/api.dart' as api;
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/services/native_core_service.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';

import 'expressive_shape.dart';

class DnsStatusCard extends StatefulWidget {
  const DnsStatusCard({
    super.key,
    this.readStatus,
    this.enabled,
    this.encrypted = false,
    this.busy = false,
    this.serviceRunning,
    this.startupError,
  });
  final Future<RecursiveDnsStatus> Function()? readStatus;
  final bool? enabled;
  final bool encrypted;
  final bool busy;
  final bool? serviceRunning;
  final String? startupError;
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

  @override
  void didUpdateWidget(DnsStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busy != widget.busy ||
        oldWidget.serviceRunning != widget.serviceRunning) {
      _refresh();
    }
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
                AnimatedExpressiveShape(
                  progress: status?.running == true ? 1 : 0,
                  pair: ExpressiveShapePair.activity,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: SizedBox.square(
                      dimension: 40,
                      child: Icon(
                        Icons.hub_outlined,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
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
              widget.startupError ??
                  _error ??
                  (widget.busy
                      ? (zh ? '正在应用 DNS 设置…' : 'Applying DNS settings…')
                      : status?.running == true
                      ? (zh
                            ? '监听中 · ${status!.listen}'
                            : 'Listening · ${status!.listen}')
                      : widget.encrypted
                      ? (zh
                            ? '严格加密模式已开启，本机递归已禁用。'
                            : 'Local recursion is disabled by strict encryption.')
                      : widget.enabled == false
                      ? (zh ? '本机递归已关闭。' : 'Local recursion is disabled.')
                      : widget.enabled == true && widget.serviceRunning != true
                      ? (zh
                            ? '已启用；启动服务后监听。'
                            : 'Enabled; starts with the proxy service.')
                      : status == null
                      ? (zh ? '等待核心就绪' : 'Waiting for the core')
                      : (zh
                            ? '本机递归未运行。请应用设置；若仍失败，请查看 DNS 启动日志。'
                            : 'Local recursion is stopped. Apply settings; check DNS startup logs if it still fails.')),
            ),
            if (status != null && status.running) ...[
              const SizedBox(height: 12),
              Text(
                zh ? '监听就绪不代表每次解析都成功。递归失败时由配置中的上游接替。' : 'A ready listener does not guarantee every lookup succeeds. Configured upstreams recover recursive failures.',
              ),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text('${zh ? '查询' : 'Queries'} ${status.queries}'),
                  Text('${zh ? '缓存命中' : 'Cache hits'} ${status.cacheHits}'),
                  Text(
                    '${zh ? '上游请求' : 'Upstream queries'} ${status.upstreamQueries}',
                  ),
                  Tooltip(
                    message: zh ? '核心计数包含部分 NODATA / NXDOMAIN，不等于网络失败次数。' : 'The core counter includes some NODATA / NXDOMAIN replies; it is not a network failure count.',
                    child: Text(
                      '${zh ? '错误/负答' : 'Errors / negative replies'} ${status.failures}',
                    ),
                  ),
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
