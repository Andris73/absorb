import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/discover/abb_client.dart';
import '../../services/discover/hardcover_client.dart';
import '../../services/player_settings.dart';
import '../stackable_sheet.dart';

/// AudiobookBay + Hardcover config sheet for the Discover tab.
Future<void> showAbbConfigSheet(BuildContext context) {
  return showStackableSheet<void>(
    context: context,
    initialChildSize: 0.78,
    maxChildSize: 0.95,
    showHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    useSafeArea: true,
    builder: (ctx, scrollController) =>
        _AbbConfigSheet(scrollController: scrollController),
  );
}

class _AbbConfigSheet extends StatefulWidget {
  final ScrollController scrollController;

  const _AbbConfigSheet({required this.scrollController});

  @override
  State<_AbbConfigSheet> createState() => _AbbConfigSheetState();
}

class _AbbConfigSheetState extends State<_AbbConfigSheet> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();

  bool _loaded = false;
  bool _testing = false;
  bool _verifying = false;
  bool _obscureToken = true;
  bool _hideExplicit = false;
  bool _hideOwned = true;
  String? _errorText;
  String? _verifiedUsername;
  bool _verifyFailed = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final url = await PlayerSettings.getAbbServerUrl();
    final token = await PlayerSettings.getHardcoverApiToken();
    final hideExplicit = await PlayerSettings.getHideExplicitContent();
    final hideOwned = await PlayerSettings.getHideOwnedTitles();
    if (!mounted) return;
    setState(() {
      _urlController.text = url;
      _tokenController.text = token;
      _hideExplicit = hideExplicit;
      _hideOwned = hideOwned;
      _loaded = true;
    });
  }

  Future<void> _verifyToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty || _verifying) return;
    setState(() {
      _verifying = true;
      _verifiedUsername = null;
      _verifyFailed = false;
    });
    final hc = HardcoverClient(token);
    try {
      final username = await hc.verifyToken();
      if (!mounted) return;
      setState(() {
        _verifiedUsername = username;
        _verifyFailed = username == null;
        _verifying = false;
      });
    } finally {
      hc.dispose();
    }
  }

  /// Persists the token unconditionally; the URL only after a successful
  /// test search against the entered mirror.
  Future<void> _saveAndTest() async {
    if (_testing) return;
    final l = AppLocalizations.of(context)!;
    setState(() {
      _testing = true;
      _errorText = null;
    });
    await PlayerSettings.setHardcoverApiToken(_tokenController.text.trim());

    var url = _urlController.text.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.contains('://')) url = 'https://$url';

    final abb = AbbClient(url);
    try {
      final results = await abb.search('harry potter');
      if (results.isEmpty) {
        throw const AbbPageLoadException('test search returned no results');
      }
      await PlayerSettings.setAbbServerUrl(url);
      if (mounted) Navigator.of(context).pop();
    } on AbbCloudflareException {
      if (mounted) setState(() => _errorText = l.discoverAbbCloudflare);
    } catch (_) {
      if (mounted) setState(() => _errorText = l.discoverAbbTestFailed);
    } finally {
      abb.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final mediaQuery = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.travel_explore_rounded, color: cs.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l.discoverAbbSheetTitle,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            TextField(
              controller: _urlController,
              enabled: _loaded && !_testing,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l.discoverAbbUrlLabel,
                hintText: 'https://audiobookbay.lu',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              enabled: _loaded && !_testing,
              autocorrect: false,
              obscureText: _obscureToken,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: l.discoverHardcoverTokenLabel,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureToken
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton(
                onPressed: _loaded && !_verifying ? _verifyToken : null,
                child: _verifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.discoverVerifyToken),
              ),
              const SizedBox(width: 12),
              if (_verifiedUsername != null)
                Expanded(
                  child: Row(children: [
                    Icon(Icons.check_circle_rounded,
                        size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l.discoverTokenValid(_verifiedUsername!),
                        style: tt.bodySmall?.copyWith(color: cs.primary),
                      ),
                    ),
                  ]),
                )
              else if (_verifyFailed)
                Expanded(
                  child: Text(
                    l.discoverTokenInvalid,
                    style: tt.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.discoverHideExplicit),
              value: _hideExplicit,
              onChanged: _loaded
                  ? (v) {
                      setState(() => _hideExplicit = v);
                      PlayerSettings.setHideExplicitContent(v);
                    }
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.discoverHideOwned),
              value: _hideOwned,
              onChanged: _loaded
                  ? (v) {
                      setState(() => _hideOwned = v);
                      PlayerSettings.setHideOwnedTitles(v);
                    }
                  : null,
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.error_outline_rounded, size: 18, color: cs.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorText!,
                    style: tt.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed:
                      _testing ? null : () => Navigator.of(context).pop(),
                  child: Text(l.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loaded &&
                          !_testing &&
                          _urlController.text.trim().isNotEmpty
                      ? _saveAndTest
                      : null,
                  child: _testing
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.onPrimary,
                          ),
                        )
                      : Text(l.discoverSaveAndTest),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
