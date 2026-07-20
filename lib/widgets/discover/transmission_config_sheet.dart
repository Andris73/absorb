import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/discover/transmission_client.dart';
import '../../services/player_settings.dart';
import '../stackable_sheet.dart';

/// Transmission daemon config sheet for the Discover tab.
Future<void> showTransmissionConfigSheet(BuildContext context) {
  return showStackableSheet<void>(
    context: context,
    initialChildSize: 0.78,
    maxChildSize: 0.95,
    showHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    useSafeArea: true,
    builder: (ctx, scrollController) =>
        _TransmissionConfigSheet(scrollController: scrollController),
  );
}

class _TransmissionConfigSheet extends StatefulWidget {
  final ScrollController scrollController;

  const _TransmissionConfigSheet({required this.scrollController});

  @override
  State<_TransmissionConfigSheet> createState() =>
      _TransmissionConfigSheetState();
}

class _TransmissionConfigSheetState extends State<_TransmissionConfigSheet> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _templateController = TextEditingController();

  bool _loaded = false;
  bool _testing = false;
  bool _obscurePassword = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _templateController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final url = await PlayerSettings.getTransmissionUrl();
    final username = await PlayerSettings.getTransmissionUsername();
    final password = await PlayerSettings.getTransmissionPassword();
    final template = await PlayerSettings.getDownloadPathTemplate();
    if (!mounted) return;
    setState(() {
      _urlController.text = url;
      _userController.text = username;
      _passController.text = password;
      _templateController.text = template;
      _loaded = true;
    });
  }

  /// Persists everything only after a successful session-get handshake.
  Future<void> _saveAndTest() async {
    if (_testing) return;
    final l = AppLocalizations.of(context)!;
    setState(() {
      _testing = true;
      _errorText = null;
    });

    var url = _urlController.text.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.contains('://')) url = 'http://$url';
    final username = _userController.text.trim();
    final password = _passController.text;

    final tc = TransmissionClient(
      baseUrl: url,
      username: username,
      password: password,
    );
    try {
      await tc.sessionGet();
      await PlayerSettings.setTransmissionUsername(username);
      await PlayerSettings.setTransmissionPassword(password);
      await PlayerSettings.setDownloadPathTemplate(
          _templateController.text.trim());
      await PlayerSettings.setTransmissionUrl(url);
      if (mounted) Navigator.of(context).pop();
    } on TransmissionAuthException {
      if (mounted) {
        setState(() => _errorText = l.discoverTransmissionAuthFailed);
      }
    } catch (e) {
      if (mounted) {
        setState(
            () => _errorText = l.discoverTransmissionTestFailed(e.toString()));
      }
    } finally {
      tc.dispose();
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
              Icon(Icons.swap_vert_circle_outlined,
                  color: cs.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l.discoverTransmissionSheetTitle,
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
                labelText: l.discoverTransmissionUrlLabel,
                hintText: 'http://nas:9091',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userController,
              enabled: _loaded && !_testing,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l.discoverUsernameLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passController,
              enabled: _loaded && !_testing,
              autocorrect: false,
              obscureText: _obscurePassword,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l.discoverPasswordLabel,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _templateController,
              enabled: _loaded && !_testing,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l.discoverPathTemplateLabel,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _saveAndTest(),
            ),
            const SizedBox(height: 6),
            Text(
              // The placeholder tokens are literal syntax, not translatable.
              '${l.discoverPathTemplateHelp} '
              '{author} {narrator} {series} {title} {year}',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
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
            const SizedBox(height: 20),
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
