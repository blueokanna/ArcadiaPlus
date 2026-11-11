import 'package:flutter/material.dart';

import '../services/dns_configuration_validator.dart';
import '../services/storage_service.dart';
import 'expressive_action.dart';

/// DNS preflight and service application share the runtime converter. A
/// generation guard prevents an older read from replacing a newer selection.
class DnsApplyCard extends StatefulWidget {
  const DnsApplyCard({
    super.key,
    required this.settings,
    this.running = false,
    this.busy = false,
    this.onApply,
    this.serviceError,
    this.readProfile,
  });

  final DnsSettings settings;
  final bool running;
  final bool busy;
  final Future<void> Function()? onApply;
  final String? serviceError;
  final Future<String?> Function()? readProfile;

  @override
  State<DnsApplyCard> createState() => _DnsApplyCardState();
}

class _DnsApplyCardState extends State<DnsApplyCard> {
  int _generation = 0;
  bool _checking = true;
  bool _hasProfile = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(DnsApplyCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings ||
        oldWidget.readProfile != widget.readProfile) {
      _check();
    }
  }

  Future<void> _check() async {
    final generation = ++_generation;
    final settings = widget.settings;
    setState(() => _checking = true);
    String? error;
    var hasProfile = false;
    try {
      final profile =
          await (widget.readProfile ??
              DnsConfigurationValidator.readActiveProfile)();
      hasProfile = profile != null;
      if (profile != null) {
        await DnsConfigurationValidator.validate(profile, settings);
      }
    } catch (failure) {
      error = failure.toString();
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _checking = false;
      _hasProfile = hasProfile;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final error = _error ?? widget.serviceError;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _checking
                ? (zh ? '正在检查当前配置…' : 'Checking the active profile…')
                : !_hasProfile
                ? (zh ? '请先选择配置。' : 'Select a profile first.')
                : _error != null
                ? (zh
                      ? 'DNS 配置不兼容。请修正下列地址；私有解析规则会保留。'
                      : 'DNS configuration is incompatible. Correct these endpoints; private DNS rules are preserved.')
                : (zh
                      ? 'DNS 策略检查通过。保存的设置在启动或重启服务后生效。'
                      : 'DNS policy checked. Saved settings apply when the service starts or restarts.'),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            if (_error == null) Text(zh ? '上次启动错误' : 'Previous startup error'),
            SelectableText(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (widget.onApply != null) ...[
            const SizedBox(height: 12),
            ExpressiveAction(
              onPressed:
                  _checking || !_hasProfile || _error != null || widget.busy
                  ? null
                  : widget.onApply,
              child: Text(
                widget.busy
                    ? (zh ? '正在应用…' : 'Applying…')
                    : widget.running
                    ? (zh ? '重启服务并应用' : 'Restart and apply')
                    : (zh ? '启动服务并应用' : 'Start and apply'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
