import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/discover/abb_client.dart';
import '../../services/discover/abb_models.dart';
import '../../services/discover/download_tracker.dart';
import '../../services/discover/hardcover_client.dart';
import '../../services/discover/title_matching.dart';
import '../../services/discover/transmission_client.dart';
import '../../services/player_settings.dart';
import 'abb_cover.dart';
import 'abb_series_view.dart';

enum _DlState { idle, busy, done }

/// ABB book detail page: full scrape plus the Transmission download action.
class AbbBookDetailView extends StatefulWidget {
  final AbbSearchResult result;

  const AbbBookDetailView({super.key, required this.result});

  @override
  State<AbbBookDetailView> createState() => _AbbBookDetailViewState();
}

class _AbbBookDetailViewState extends State<AbbBookDetailView> {
  AbbClient? _abb;
  AbbBookDetail? _detail;
  String? _error;
  String? _seriesName;
  _DlState _dlState = _DlState.idle;

  @override
  void initState() {
    super.initState();
    // Heuristic series parse is instant; Hardcover fallback lands async.
    _seriesName = AbbClient.parseSeriesFromTitle(widget.result.title)?.name ??
        widget.result.series;
    _load();
  }

  @override
  void dispose() {
    _abb?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final baseUrl = (await PlayerSettings.getAbbServerUrl()).trim();
    if (!mounted) return;
    final abb = AbbClient(baseUrl);
    _abb = abb;
    try {
      final detail = await abb.bookDetail(widget.result.detailUrl);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
    if (_seriesName == null) _findSeriesViaHardcover();
  }

  Future<void> _findSeriesViaHardcover() async {
    final token = (await PlayerSettings.getHardcoverApiToken()).trim();
    if (token.isEmpty || !mounted) return;
    final hc = HardcoverClient(token);
    try {
      final series = await hc.findBookSeries(
        coreTitle(widget.result.title),
        author: widget.result.author,
      );
      if (series != null && mounted && _seriesName == null) {
        setState(() => _seriesName = series.name);
      }
    } finally {
      hc.dispose();
    }
  }

  Future<void> _download() async {
    final detail = _detail;
    if (detail == null || _dlState != _DlState.idle) return;
    final l = AppLocalizations.of(context)!;
    setState(() => _dlState = _DlState.busy);
    try {
      final magnet = AbbClient.buildMagnet(
          detail.infoHash, detail.title, detail.trackers);
      final template = await PlayerSettings.getDownloadPathTemplate();
      final dir = TransmissionClient.buildDownloadPath(
        template: template,
        author: detail.author,
        narrator: detail.narrator,
        series: _seriesName,
        title: detail.title,
        year: widget.result.year?.toString(),
      );
      final tc = TransmissionClient(
        baseUrl: (await PlayerSettings.getTransmissionUrl()).trim(),
        username: await PlayerSettings.getTransmissionUsername(),
        password: await PlayerSettings.getTransmissionPassword(),
      );
      try {
        final added = await tc.torrentAdd(magnet, dir);
        await DownloadTracker.instance.track(
          torrentId: added.id,
          infoHash:
              added.hashString.isNotEmpty ? added.hashString : detail.infoHash,
          title: detail.title,
          author: detail.author ?? '',
          downloadPath: dir,
        );
      } finally {
        tc.dispose();
      }
      if (mounted) setState(() => _dlState = _DlState.done);
    } catch (e) {
      if (!mounted) return;
      setState(() => _dlState = _DlState.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.discoverDownloadFailed(e.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final detail = _detail;

    Widget body;
    if (detail == null && _error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.discoverLoadFailed(_error!),
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      );
    } else if (detail == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        physics: const BouncingScrollPhysics(),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: AbbCover(
                  url: detail.coverUrl ?? widget.result.coverUrl,
                  radius: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            detail.title,
            textAlign: TextAlign.center,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (detail.author != null) ...[
            const SizedBox(height: 4),
            Text(
              detail.author!,
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (detail.narrator != null) ...[
            const SizedBox(height: 2),
            Text(
              l.discoverReadBy(detail.narrator!),
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (detail.explicit)
                _chip(l.discoverExplicitChip, cs.errorContainer,
                    cs.onErrorContainer, tt),
              for (final v in [detail.format, detail.bitrate, detail.abridged])
                if (v != null && v.isNotEmpty)
                  _chip(v, cs.secondaryContainer, cs.onSecondaryContainer, tt),
            ],
          ),
          if (_seriesName != null) ...[
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: Icon(Icons.collections_bookmark_rounded,
                    color: cs.primary),
                title: Text(l.discoverViewSeries),
                subtitle: Text(_seriesName!),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AbbSeriesView(
                      seriesName: _seriesName!,
                      author: detail.author ?? widget.result.author,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _downloadButton(cs, l),
          if (detail.description != null) ...[
            const SizedBox(height: 24),
            Text(
              l.discoverDescription,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              detail.description!,
              style: tt.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.85),
                height: 1.4,
              ),
            ),
          ],
          if (detail.comments.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              l.discoverComments,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final c in detail.comments) _CommentRow(comment: c),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(),
      body: body,
    );
  }

  Widget _chip(String text, Color bg, Color fg, TextTheme tt) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: tt.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _downloadButton(ColorScheme cs, AppLocalizations l) {
    switch (_dlState) {
      case _DlState.idle:
        return FilledButton.icon(
          onPressed: _download,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(l.discoverDownloadButton),
        );
      case _DlState.busy:
        return FilledButton(
          onPressed: null,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cs.onSurfaceVariant,
            ),
          ),
        );
      case _DlState.done:
        return FilledButton.tonal(
          onPressed: null,
          child: Text(l.discoverDownloaded),
        );
    }
  }
}

class _CommentRow extends StatelessWidget {
  final AbbComment comment;

  const _CommentRow({required this.comment});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final avatarUrl = comment.avatarUrl;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: cs.surfaceContainerHigh,
            foregroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                ? CachedNetworkImageProvider(avatarUrl)
                : null,
            child: Text(
              comment.author.isNotEmpty
                  ? comment.author[0].toUpperCase()
                  : '?',
              style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        comment.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (comment.date != null)
                      Text(
                        comment.date!,
                        style: tt.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    for (var i = 0; i < 5; i++)
                      Icon(
                        i < comment.rating
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        size: 14,
                        color: i < comment.rating
                            ? cs.primary
                            : cs.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                  ],
                ),
                if (comment.body != null && comment.body!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    comment.body!,
                    style: tt.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
