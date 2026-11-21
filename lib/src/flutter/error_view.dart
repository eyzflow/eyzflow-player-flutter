import 'package:flutter/material.dart';

/// The failure screen for a refused key or a limit: the message and an OK
/// that closes the player. Black, like the player around it; the OK button is
/// focused so a TV remote can press it.
class EyzflowErrorView extends StatelessWidget {
  const EyzflowErrorView({
    super.key,
    required this.message,
    required this.onClose,
    this.isTv = false,
  });

  final String message;
  final VoidCallback onClose;
  final bool isTv;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scale = isTv ? 1.4 : 1.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480 * scale),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  color: Colors.white70,
                  size: 40 * scale,
                ),
                SizedBox(height: 16 * scale),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  textScaler: TextScaler.linear(scale),
                  style: text.bodyLarge?.copyWith(color: Colors.white),
                ),
                SizedBox(height: 24 * scale),
                TextButton(
                  autofocus: true,
                  onPressed: onClose,
                  child: Text(
                    MaterialLocalizations.of(context).okButtonLabel,
                    textScaler: TextScaler.linear(scale),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
