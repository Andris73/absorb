import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A circular HSV color picker: hue around the wheel, saturation from center to
/// edge, with a brightness (value) slider underneath.
class ColorWheelPicker extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onChanged;
  const ColorWheelPicker({super.key, required this.initialColor, required this.onChanged});

  @override
  State<ColorWheelPicker> createState() => _ColorWheelPickerState();
}

class _ColorWheelPickerState extends State<ColorWheelPicker> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    // A pure-black seed would hide the whole wheel; start it bright instead.
    if (_hsv.value == 0) _hsv = _hsv.withValue(1.0);
  }

  void _pickFromWheel(Offset localPos, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final v = localPos - center;
    final sat = (v.distance / radius).clamp(0.0, 1.0);
    var angle = math.atan2(v.dy, v.dx);
    if (angle < 0) angle += 2 * math.pi;
    final hue = angle / (2 * math.pi) * 360.0;
    setState(() => _hsv = _hsv.withHue(hue).withSaturation(sat));
    widget.onChanged(_hsv.toColor());
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            onPanDown: (d) => _pickFromWheel(d.localPosition, size),
            onPanUpdate: (d) => _pickFromWheel(d.localPosition, size),
            child: CustomPaint(painter: _WheelPainter(_hsv)),
          );
        }),
      ),
      const SizedBox(height: 12),
      Row(children: [
        const Icon(Icons.brightness_6_rounded, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(thumbColor: _hsv.toColor()),
            child: Slider(
              value: _hsv.value,
              onChanged: (v) {
                setState(() => _hsv = _hsv.withValue(v));
                widget.onChanged(_hsv.toColor());
              },
            ),
          ),
        ),
      ]),
    ]);
  }
}

class _WheelPainter extends CustomPainter {
  final HSVColor hsv;
  _WheelPainter(this.hsv);

  static const _hueColors = [
    Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00),
    Color(0xFF00FFFF), Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Hue around the circle
    canvas.drawCircle(center, radius,
        Paint()..shader = const SweepGradient(colors: _hueColors).createShader(rect));
    // Saturation: white at the center fading out toward the rim
    canvas.drawCircle(center, radius,
        Paint()..shader = RadialGradient(colors: [Colors.white, Colors.white.withValues(alpha: 0)]).createShader(rect));
    // Brightness: darken the whole wheel as value drops
    if (hsv.value < 1) {
      canvas.drawCircle(center, radius, Paint()..color = Colors.black.withValues(alpha: 1 - hsv.value));
    }

    // Selection thumb
    final angle = hsv.hue / 360.0 * 2 * math.pi;
    final pos = center + Offset(math.cos(angle), math.sin(angle)) * (hsv.saturation * radius);
    canvas.drawCircle(pos, 11, Paint()..color = Colors.white);
    canvas.drawCircle(pos, 11, Paint()..color = Colors.black54..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawCircle(pos, 8, Paint()..color = hsv.toColor());
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.hsv != hsv;
}
