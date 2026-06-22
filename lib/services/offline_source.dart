import 'package:just_audio/just_audio.dart';

/// True when a stored download location is an Android Storage Access Framework
/// content URI rather than a filesystem path. SAF custom folders store
/// content:// URIs in DownloadInfo.localPaths; everything else (iOS app-group,
/// Android internal and legacy downloads) stays a filesystem path.
bool isContentUri(String pathOrUri) => pathOrUri.startsWith('content://');

/// Build the right AudioSource for a downloaded track. Content URIs play via
/// AudioSource.uri (media3's ContentDataSource opens them through the persisted
/// SAF permission); filesystem paths play via AudioSource.file.
AudioSource localAudioSource(String pathOrUri) => isContentUri(pathOrUri)
    ? AudioSource.uri(Uri.parse(pathOrUri))
    : AudioSource.file(pathOrUri);
