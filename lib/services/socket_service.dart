import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  static final SocketService _instance = SocketService._();
  factory SocketService() => _instance;
  SocketService._();

  io.Socket? _socket;
  String? _token;
  String? _serverUrl;
  DateTime? _connectedAt;

  bool get isConnected => _socket?.connected ?? false;
  bool get hasSocket => _socket != null;

  Map<String, String> _customHeaders = {};

  /// Build socket.io options with capped reconnection to avoid
  /// hammering an unreachable server (and draining battery).
  Map<String, dynamic> _buildOptions() {
    final builder = io.OptionBuilder()
        .setTransports(['websocket'])
        .enableReconnection()
        .setReconnectionDelay(1000)
        .setReconnectionDelayMax(30000)
        .setReconnectionAttempts(5);
    if (_customHeaders.isNotEmpty) {
      builder.setExtraHeaders(_customHeaders);
    }
    return builder.build();
  }

  /// Called when the server pushes a progress update (cross-device sync).
  void Function(Map<String, dynamic> progress)? onProgressUpdated;

  /// Called when a library item is added, updated, or removed.
  void Function(Map<String, dynamic> data)? onItemUpdated;

  /// Called when a library item is removed.
  void Function(Map<String, dynamic> data)? onItemRemoved;

  /// Called when series data changes.
  void Function()? onSeriesUpdated;

  /// Called when a collection changes.
  void Function()? onCollectionUpdated;

  /// Called when the current user's data changes on the server.
  void Function(Map<String, dynamic> data)? onUserUpdated;

  /// Called when socket.io exhausts all reconnection attempts.
  VoidCallback? onReconnectFailed;

  /// Called when an M4B encode task finishes on the server.
  /// Payload: serialized Task object including action and data.libraryItemId.
  void Function(Map<String, dynamic> data)? onEncodeFinished;

  /// Update the stored token (e.g. after a JWT refresh) and re-auth if connected.
  void updateToken(String newToken) {
    _token = newToken;
    if (_socket?.connected == true) {
      debugPrint('[Socket] Re-authenticating with refreshed token');
      _socket!.emit('auth', _token);
    }
  }

  void connect(String serverUrl, String token, {Map<String, String> customHeaders = const {}}) {
    if (_socket != null) disconnect();

    _token = token;
    _serverUrl = serverUrl;
    _customHeaders = customHeaders;

    try {
      _socket = io.io(serverUrl, _buildOptions());

      // onConnect fires on initial connect AND every reconnect
      _socket!.onConnect((_) {
        _connectedAt = DateTime.now();
        debugPrint('[Socket] Connected, sending auth');
        _socket!.emit('auth', _token);
      });

      _socket!.on('init', (_) {
        debugPrint('[Socket] Authenticated - user is online');
      });

      _socket!.on('auth_failed', (_) {
        debugPrint('[Socket] Auth failed');
        disconnect();
      });

      // Cross-device progress sync
      _socket!.on('user_item_progress_updated', (data) {
        if (data is Map<String, dynamic>) {
          final patch = data['data'] as Map<String, dynamic>?;
          if (patch != null) {
            onProgressUpdated?.call(patch);
          }
        }
      });

      // Library item changes
      _socket!.on('item_added', (data) {
        debugPrint('[Socket] Item added');
        if (data is Map<String, dynamic>) onItemUpdated?.call(data);
      });
      _socket!.on('item_updated', (data) {
        debugPrint('[Socket] Item updated');
        if (data is Map<String, dynamic>) onItemUpdated?.call(data);
      });
      _socket!.on('item_removed', (data) {
        debugPrint('[Socket] Item removed');
        if (data is Map<String, dynamic>) onItemRemoved?.call(data);
      });

      // Series changes
      _socket!.on('series_added', (_) {
        debugPrint('[Socket] Series added');
        onSeriesUpdated?.call();
      });
      _socket!.on('series_updated', (_) {
        debugPrint('[Socket] Series updated');
        onSeriesUpdated?.call();
      });
      _socket!.on('series_removed', (_) {
        debugPrint('[Socket] Series removed');
        onSeriesUpdated?.call();
      });

      // Collection changes
      _socket!.on('collection_added', (_) {
        debugPrint('[Socket] Collection added');
        onCollectionUpdated?.call();
      });
      _socket!.on('collection_updated', (_) {
        debugPrint('[Socket] Collection updated');
        onCollectionUpdated?.call();
      });
      _socket!.on('collection_removed', (_) {
        debugPrint('[Socket] Collection removed');
        onCollectionUpdated?.call();
      });

      // Current user updated
      _socket!.on('user_updated', (data) {
        debugPrint('[Socket] User updated');
        if (data is Map<String, dynamic>) onUserUpdated?.call(data);
      });

      // M4B encode task finished (fires once for the whole task, not per track)
      _socket!.on('task_finished', (data) {
        if (data is Map<String, dynamic> && data['action'] == 'encode-m4b') {
          debugPrint('[Socket] Encode finished');
          onEncodeFinished?.call(data);
        }
      });

      _socket!.onDisconnect((reason) {
        final duration = _connectedAt != null
            ? DateTime.now().difference(_connectedAt!).inSeconds
            : 0;
        debugPrint('[Socket] Disconnected after ${duration}s (Reason: $reason)');
        _connectedAt = null;
      });

      _socket!.onConnectError((err) {
        debugPrint('[Socket] Connect error: $err');
      });

      _socket!.on('reconnect_failed', (_) {
        debugPrint('[Socket] Reconnection attempts exhausted — giving up');
        _socket?.dispose();
        _socket = null;
        onReconnectFailed?.call();
      });
    } catch (e) {
      debugPrint('[Socket] Failed to connect: $e');
      _socket = null;
      _token = null;
      _serverUrl = null;
    }
  }

  /// Disconnect and tear down the socket, clearing all callbacks.
  void disconnect() {
    _socket?.dispose();
    _socket = null;
    _token = null;
    _serverUrl = null;
    onProgressUpdated = null;
    onItemUpdated = null;
    onItemRemoved = null;
    onSeriesUpdated = null;
    onCollectionUpdated = null;
    onUserUpdated = null;
    onReconnectFailed = null;
    onEncodeFinished = null;
  }

  /// Disconnect the socket but keep callbacks and credentials so we can
  /// cheaply reconnect later without re-wiring everything.
  void softDisconnect() {
    if (_socket == null) return;
    debugPrint('[Battery] Socket DISCONNECTED (soft, battery saving)');
    _socket!.dispose();
    _socket = null;
  }

  /// Switch to a different server URL (e.g. local/remote swap).
  /// Does a soft disconnect then reconnect with the new URL.
  void switchServer(String newUrl) {
    if (_serverUrl == newUrl) return;
    debugPrint('[Socket] Switching server: $_serverUrl -> $newUrl');
    _serverUrl = newUrl;
    if (_socket != null) {
      _socket!.dispose();
      _socket = null;
      softReconnect();
    }
  }

  /// Reconnect after a soft disconnect, reusing saved credentials.
  void softReconnect() {
    if (_socket != null) return; // already connected
    final url = _serverUrl;
    final token = _token;
    if (url == null || token == null) return;
    debugPrint('[Battery] Socket RECONNECTED (soft)');

    try {
      _socket = io.io(url, _buildOptions());

      _socket!.onConnect((_) {
        _connectedAt = DateTime.now();
        debugPrint('[Socket] Connected, sending auth');
        _socket!.emit('auth', _token);
      });

      _socket!.on('init', (_) {
        debugPrint('[Socket] Authenticated - user is online');
      });

      _socket!.on('auth_failed', (_) {
        debugPrint('[Socket] Auth failed');
        disconnect();
      });

      _socket!.on('user_item_progress_updated', (data) {
        if (data is Map<String, dynamic>) {
          final patch = data['data'] as Map<String, dynamic>?;
          if (patch != null) onProgressUpdated?.call(patch);
        }
      });

      _socket!.on('item_added', (data) {
        if (data is Map<String, dynamic>) onItemUpdated?.call(data);
      });
      _socket!.on('item_updated', (data) {
        if (data is Map<String, dynamic>) onItemUpdated?.call(data);
      });
      _socket!.on('item_removed', (data) {
        if (data is Map<String, dynamic>) onItemRemoved?.call(data);
      });

      _socket!.on('series_added', (_) => onSeriesUpdated?.call());
      _socket!.on('series_updated', (_) => onSeriesUpdated?.call());
      _socket!.on('series_removed', (_) => onSeriesUpdated?.call());

      _socket!.on('collection_added', (_) => onCollectionUpdated?.call());
      _socket!.on('collection_updated', (_) => onCollectionUpdated?.call());
      _socket!.on('collection_removed', (_) => onCollectionUpdated?.call());

      _socket!.on('user_updated', (data) {
        if (data is Map<String, dynamic>) onUserUpdated?.call(data);
      });

      _socket!.on('task_finished', (data) {
        if (data is Map<String, dynamic> && data['action'] == 'encode-m4b') {
          onEncodeFinished?.call(data);
        }
      });

      _socket!.onDisconnect((reason) {
        final duration = _connectedAt != null
            ? DateTime.now().difference(_connectedAt!).inSeconds
            : 0;
        debugPrint('[Socket] Disconnected after ${duration}s (Reason: $reason)');
        _connectedAt = null;
      });

      _socket!.onConnectError((err) {
        debugPrint('[Socket] Connect error: $err');
      });

      _socket!.on('reconnect_failed', (_) {
        debugPrint('[Socket] Reconnection attempts exhausted — giving up');
        _socket?.dispose();
        _socket = null;
        onReconnectFailed?.call();
      });
    } catch (e) {
      debugPrint('[Socket] Failed to reconnect: $e');
      _socket = null;
    }
  }
}
