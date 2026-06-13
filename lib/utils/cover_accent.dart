import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Picks an accent color from a cover's [palette].
///
/// Guards against a small but highly-saturated corner badge (e.g. the yellow
/// "Only from Audible" banner) hijacking the result. PaletteGenerator's
/// "vibrant" target is scored mostly on saturation, so a tiny vivid badge can
/// outrank the dominant artwork color - turning a mostly-blue cover's accent
/// yellow. When the vibrant swatch covers only a small slice of the cover
/// relative to the dominant color, we treat it as a badge and fall back to the
/// most prominent swatch that still reads as a real color. Genuinely vibrant
/// covers (where the vivid color IS a large share of the image) are unaffected.
Color? accentFromCoverPalette(PaletteGenerator palette) {
  final vibrant = palette.vibrantColor ??
      palette.lightVibrantColor ??
      palette.darkVibrantColor;
  final dominant = palette.dominantColor;

  if (vibrant != null &&
      dominant != null &&
      vibrant.population < dominant.population * 0.4) {
    final colorful = _mostProminentColorful(palette);
    if (colorful != null) return colorful;
    return dominant.color;
  }

  return vibrant?.color ??
      dominant?.color ??
      (palette.colors.isEmpty ? null : palette.colors.first);
}

/// Highest-population swatch that still reads as a color - skips grey, near
/// white and near black so the fallback accent matches the artwork rather than
/// washing out.
Color? _mostProminentColorful(PaletteGenerator palette) {
  PaletteColor? best;
  for (final pc in palette.paletteColors) {
    final hsv = HSVColor.fromColor(pc.color);
    if (hsv.saturation < 0.15) continue; // grey / white / black
    if (hsv.value < 0.12) continue; // near black
    if (best == null || pc.population > best.population) best = pc;
  }
  return best?.color;
}
