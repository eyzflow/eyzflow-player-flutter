import 'package:flutter/material.dart';

import '../l10n/streaming_l10n.dart';
import 'cast_backend.dart';
import 'cast_controller.dart';

/// The device list: the TVs found, a fresh scan while it is open, and what
/// to do when there are none. Returns the picked TV, or null.
Future<CastTarget?> showCastPicker(
  BuildContext context,
  EyzflowCastController cast,
) {
  if (!cast.scanning) cast.scan();
  return showModalBottomSheet<CastTarget>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    builder: (context) => SafeArea(
      child: ListenableBuilder(
        listenable: cast,
        builder: (context, _) {
          final text = Theme.of(context).textTheme;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        streamingL10n.castTo,
                        style: text.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ),
                    if (cast.scanning)
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                  ],
                ),
              ),
              for (final device in cast.devices)
                ListTile(
                  leading: const Icon(Icons.tv, color: Colors.white70),
                  title: Text(
                    device.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: device.model == null
                      ? null
                      : Text(
                          device.model!,
                          style: const TextStyle(color: Colors.white54),
                        ),
                  onTap: () => Navigator.of(context).pop(device),
                ),
              if (cast.devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Text(
                    cast.scanning
                        ? streamingL10n.castSearching
                        : streamingL10n.castNoDevices,
                    style: text.bodyMedium?.copyWith(color: Colors.white70),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    ),
  );
}
