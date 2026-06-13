import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Material 3 Expressive wavy linear progress indicator.
///
/// Flutter 3.41's stock LinearProgressIndicator only supports the 2023 M3
/// look (stop indicator + track gap), not the 2024 expressive squiggle.
/// Drop-in once Flutter ships it.
class WavyProgressIndicator extends StatefulWidget {
  const WavyProgressIndicator({
    super.key,
    required this.value,
    this.color,
    this.trackColor,
    this.height = 12,
    this.amplitude = 2.5,
    this.wavelength = 36,
    this.strokeWidth = 4,
    this.gap = 6,
  });

  final double? value;
  final Color? color;
  final Color? trackColor;
  final double height;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;
  final double gap;

  @override
  State<WavyProgressIndicator> createState() => _WavyProgressIndicatorState();
}

class _WavyProgressIndicatorState extends State<WavyProgressIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => CustomPaint(
          painter: _WavyPainter(
            value: widget.value,
            color: widget.color ?? cs.primary,
            trackColor: widget.trackColor ?? cs.surfaceContainerHighest,
            phase: _ctrl.value * 2 * math.pi,
            amplitude: widget.amplitude,
            wavelength: widget.wavelength,
            strokeWidth: widget.strokeWidth,
            gap: widget.gap,
            indeterminate: widget.value == null,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.phase,
    required this.amplitude,
    required this.wavelength,
    required this.strokeWidth,
    required this.gap,
    required this.indeterminate,
  });

  final double? value;
  final Color color;
  final Color trackColor;
  final double phase;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;
  final double gap;
  final bool indeterminate;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final v = (value ?? 0).clamp(0.0, 1.0);
    // Damp the wave near the ends so it doesn't poke past the rounded caps.
    final tail = strokeWidth;
    final filledEnd = indeterminate ? size.width : size.width * v;

    final wavePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Wavy filled portion.
    if (filledEnd > tail) {
      final path = Path();
      const step = 1.5;
      for (double x = tail / 2; x <= filledEnd - tail / 2; x += step) {
        // Fade amplitude in over the first wavelength and out over the last.
        final fromStart = (x / wavelength).clamp(0.0, 1.0);
        final toEnd = ((filledEnd - x) / wavelength).clamp(0.0, 1.0);
        final amp = amplitude * fromStart * toEnd;
        final y = centerY +
            amp * math.sin(2 * math.pi * x / wavelength - phase);
        if (x == tail / 2) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, wavePaint);
    }

    // Remaining track (straight) with a small gap after the wave.
    if (!indeterminate) {
      final trackStart = filledEnd + gap;
      final trackEnd = size.width - strokeWidth / 2;
      if (trackStart < trackEnd) {
        canvas.drawLine(
          Offset(trackStart, centerY),
          Offset(trackEnd, centerY),
          trackPaint,
        );
      }
      // Stop indicator at the very end.
      final stopRadius = strokeWidth / 2;
      canvas.drawCircle(
        Offset(size.width - stopRadius, centerY),
        stopRadius,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.indeterminate != indeterminate;
}
