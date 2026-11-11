import 'package:arcadiaplus/src/theme/app_typography.dart';

import 'dart:io';

import 'package:flutter/material.dart';

/// Shows only a domain reported by the core, never a guessed PTR identity.
class ConnectionDestination extends StatelessWidget {
  const ConnectionDestination({
    super.key,
    required this.host,
    required this.port,
    this.ip,
  });
  final String host;
  final int port;
  final String? ip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = InternetAddress.tryParse(host);
    final knownDomain = address == null && host.isNotEmpty;
    String endpoint(String value) =>
        value.contains(':') ? '[$value]:$port' : '$value:$port';
    final destination = ip?.isNotEmpty == true ? ip : address?.address;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: endpoint(host),
          child: Text(
            knownDomain ? host : endpoint(host),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (knownDomain && destination != null) ...[
          const SizedBox(height: 4),
          Text(
            endpoint(destination),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: AppTypography.codeFamily,
            ),
          ),
        ],
      ],
    );
  }
}
