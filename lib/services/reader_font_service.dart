import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A reader font. Built-ins ([url] empty) use device fonts via a CSS family
/// stack; downloadable ones pull a woff2 once and render via an injected
/// @font-face, so the same font works on iOS and Android inside the WebView.
class ReaderFont {
  final String id;
  final String label;
  /// CSS font-family value. For built-ins this is a generic stack; for
  /// downloadables it's the family name the injected @font-face declares.
  final String family;
  /// woff2 download URL (empty = built-in, nothing to download).
  final String url;
  const ReaderFont({
    required this.id,
    required this.label,
    required this.family,
    this.url = '',
  });
  bool get downloadable => url.isNotEmpty;
}

const kBuiltinReaderFonts = [
  ReaderFont(id: 'original', label: 'Original', family: ''),
  ReaderFont(id: 'serif', label: 'Serif', family: 'Georgia, "Times New Roman", serif'),
  ReaderFont(id: 'sans', label: 'Sans', family: 'system-ui, Roboto, "Helvetica Neue", Arial, sans-serif'),
];

// Fontsource on jsDelivr: stable URLs, no API key, all OFL/Apache licensed.
const _fs = 'https://cdn.jsdelivr.net/fontsource/fonts';

const kDownloadableReaderFonts = [
  ReaderFont(id: 'lora', label: 'Lora', family: 'Lora', url: '$_fs/lora@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'merriweather', label: 'Merriweather', family: 'Merriweather', url: '$_fs/merriweather@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'literata', label: 'Literata', family: 'Literata', url: '$_fs/literata@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'eb-garamond', label: 'EB Garamond', family: 'EB Garamond', url: '$_fs/eb-garamond@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'bitter', label: 'Bitter', family: 'Bitter', url: '$_fs/bitter@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'pt-serif', label: 'PT Serif', family: 'PT Serif', url: '$_fs/pt-serif@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'source-sans-3', label: 'Source Sans', family: 'Source Sans 3', url: '$_fs/source-sans-3@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'inter', label: 'Inter', family: 'Inter', url: '$_fs/inter@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'atkinson-hyperlegible', label: 'Atkinson Hyperlegible', family: 'Atkinson Hyperlegible', url: '$_fs/atkinson-hyperlegible@latest/latin-400-normal.woff2'),
  ReaderFont(id: 'opendyslexic', label: 'OpenDyslexic', family: 'OpenDyslexic', url: '$_fs/opendyslexic@latest/latin-400-normal.woff2'),
];

ReaderFont? readerFontById(String id) {
  for (final f in kBuiltinReaderFonts) {
    if (f.id == id) return f;
  }
  for (final f in kDownloadableReaderFonts) {
    if (f.id == id) return f;
  }
  return null;
}

/// Downloads and caches reader fonts. Singleton + ChangeNotifier so the picker
/// reflects download/installed state live. Install state is stored globally
/// (raw prefs, not per-account) since fonts are shared across profiles.
class ReaderFontService extends ChangeNotifier {
  static final ReaderFontService _instance = ReaderFontService._();
  factory ReaderFontService() => _instance;
  ReaderFontService._();

  static const _kInstalled = 'reader_fonts_installed';

  final Set<String> _installed = {};
  final Set<String> _downloading = {};
  bool _loaded = false;

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/reader_fonts');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _installed.addAll(prefs.getStringList(_kInstalled) ?? const []);
    final d = await _dir();
    // Drop entries whose file went missing (e.g. cache cleared).
    _installed.removeWhere((id) => !File('${d.path}/$id.woff2').existsSync());
    _loaded = true;
    notifyListeners();
  }

  bool isInstalled(String id) => _installed.contains(id);
  bool isDownloading(String id) => _downloading.contains(id);

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kInstalled, _installed.toList());
  }

  Future<bool> download(ReaderFont font) async {
    if (!font.downloadable) return true;
    await load();
    if (_installed.contains(font.id) || _downloading.contains(font.id)) return true;
    _downloading.add(font.id);
    notifyListeners();
    try {
      final resp = await http
          .get(Uri.parse(font.url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final d = await _dir();
      await File('${d.path}/${font.id}.woff2').writeAsBytes(resp.bodyBytes);
      _installed.add(font.id);
      await _persist();
      return true;
    } catch (e) {
      debugPrint('[ReaderFont] download failed ${font.id}: $e');
      return false;
    } finally {
      _downloading.remove(font.id);
      notifyListeners();
    }
  }

  Future<void> remove(String id) async {
    await load();
    final d = await _dir();
    final f = File('${d.path}/$id.woff2');
    if (await f.exists()) await f.delete();
    _installed.remove(id);
    await _persist();
    notifyListeners();
  }

  /// base64 of the cached woff2 for @font-face data-URI injection, or null.
  Future<String?> base64Woff2(String id) async {
    await load();
    if (!_installed.contains(id)) return null;
    final d = await _dir();
    final f = File('${d.path}/$id.woff2');
    if (!await f.exists()) return null;
    return base64Encode(await f.readAsBytes());
  }
}
