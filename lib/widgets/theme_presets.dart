import 'package:flutter/material.dart';

/// A named manual app-color preset. Names are intentionally English-only
/// constants (an "absorption across domains" theme), not localized.
class ThemePreset {
  final String id;
  final String name;
  final Color color;
  const ThemePreset(this.id, this.name, this.color);
}

/// The fixed color presets offered in Manual color mode. The dynamic
/// (cover-driven) option is handled separately, so it is not in this list.
const List<ThemePreset> kThemePresets = [
  ThemePreset('wavelength', 'Wavelength', Color(0xFF4DB6AC)),
  ThemePreset('soak', 'Soak', Color(0xFF2E6FB0)),
  ThemePreset('inkwell', 'Inkwell', Color(0xFF3D4A8C)),
  ThemePreset('tincture', 'Tincture', Color(0xFF7C6FBF)),
  ThemePreset('saturate', 'Saturate', Color(0xFFC8487E)),
  ThemePreset('steeped', 'Steeped', Color(0xFFB07A3C)),
  ThemePreset('eventHorizon', 'Event Horizon', Color(0xFFF97316)),
  ThemePreset('redshift', 'Redshift', Color(0xFFCC4436)),
  ThemePreset('osmosis', 'Osmosis', Color(0xFF2A9D8F)),
  ThemePreset('chlorophyll', 'Chlorophyll', Color(0xFF4CAF50)),
  ThemePreset('adsorb', 'Adsorb', Color(0xFF3A3A3A)),
];
