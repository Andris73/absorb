/// The app's standard compact duration label: "3h 12m", or "42m" under
/// an hour. For the player-style padded "H:MM:SS" see fmtTime in
/// absorbing_shared.dart.
String formatHm(double seconds) {
  final h = (seconds / 3600).floor();
  final m = ((seconds % 3600) / 60).floor();
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
