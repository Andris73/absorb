import 'package:flutter/material.dart';
import '../services/api_service.dart';

// GMS-free stub of chromecast_button.dart for the F-Droid flavor. Chromecast
// needs Google Play Services, so the picker is a no-op and the control sheet
// renders nothing. Swapped in (with chromecast_service_stub.dart) at build time
// via the fdroiddata recipe. Signatures mirror the real file so callers in
// card_buttons.dart etc. compile unchanged.

/// No-op on F-Droid: there are no cast devices without Google Play Services.
void showCastDevicePicker(
  BuildContext context, {
  ApiService? api,
  String? itemId,
  String? title,
  String? author,
  String? coverUrl,
  double? totalDuration,
  List<dynamic>? chapters,
  String? episodeId,
}) {}

/// Empty on F-Droid: the cast control sheet is never shown (cast never connects).
class CastControlSheet extends StatelessWidget {
  const CastControlSheet({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
