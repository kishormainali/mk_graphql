import 'dart:async';

import 'package:dio/dio.dart' hide Response;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import '../transport/dio_link.dart';
import '../logging/logger.dart';

import '../../client/client.dart';
import '../../core/error.dart';

/// Callback that supplies the current access-token headers (e.g. Authorization).
/// Return null or empty map when no token is available.
typedef AccessTokenCallback = FutureOr<Map<String, String>?> Function();

/// Callback invoked when the access token is expired.
/// Receives a plain [GraphQLClient] (no auth link attached) that can be used
/// to perform the refresh request via its normal typed API (e.g. `refreshClient.future(...)`).
/// Should return new headers to use (e.g. `{'Authorization': 'Bearer <newToken>'}`),
/// or return null / throw to trigger token revocation.
typedef OnRefreshCallback = FutureOr<Map<String, String>?> Function(
    GraphQLClient refreshClient);

/// Optional callback that returns whether the current token is expired.
/// If omitted, expiry is not checked proactively — only unauthorized responses trigger refresh.
typedef IsTokenExpiredCallback = FutureOr<bool> Function();

/// Callback invoked when the token is revoked (refresh failed or server returned
/// unauthorized and refresh is not possible).
typedef OnRevokeTokenCallback = void Function();

/// {@template auth_link}
/// A [Link] that injects authentication headers into every request.
///
/// If the server responds with an unauthorized error and [onTokenRefresh] is
/// provided, it will attempt to refresh the token via [_refreshClient] and retry
/// the request once. If the refresh fails, [onRevokeToken] and all registered
/// [_revokeTokenListeners] are called.
///
/// Optionally provide [isTokenExpired] to proactively refresh the token before
/// sending the request.
/// {@endtemplate}
class AuthLink extends Link {
  /// {@macro auth_link}
  AuthLink({
    required this.url,
    Dio? dio,
    this.tokenHeader,
    this.isTokenExpired,
    this.onTokenRefresh,
    this.onRevokeToken,
  }) : _refreshClient =
            GraphQLClient.fromLink(DioLink(url, client: dio ?? Dio()));

  /// The GraphQL endpoint URL — also used for token refresh requests.
  final String url;

  /// Callback that returns the current auth headers (e.g. `Authorization`).
  final AccessTokenCallback? tokenHeader;

  /// Optional callback to check whether the current token is expired.
  final IsTokenExpiredCallback? isTokenExpired;

  /// Callback to perform token refresh.
  final OnRefreshCallback? onTokenRefresh;

  /// Called when the token is revoked.
  final OnRevokeTokenCallback? onRevokeToken;

  /// Internal [GraphQLClient] (no auth link) used exclusively for refresh requests.
  late final GraphQLClient _refreshClient;

  /// Concurrent-refresh lock.
  Future<Map<String, String>?>? _ongoingRefresh;

  // ---------------------------------------------------------------------------
  // Static revoke-token listener registry
  // ---------------------------------------------------------------------------

  static final List<void Function()> _revokeTokenListeners = [];

  static void registerRevokeTokenListener(void Function() listener) =>
      _revokeTokenListeners.add(listener);

  static void removeRevokeTokenListener(void Function() listener) =>
      _revokeTokenListeners.remove(listener);

  static void clearRevokeTokenListeners() => _revokeTokenListeners.clear();

  static void notifyRevokeToken() {
    for (final listener in List.of(_revokeTokenListeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // gql_link.Link implementation
  // ---------------------------------------------------------------------------

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    assert(forward != null, 'AuthLink cannot be a terminating link.');
    if (forward == null) {
      throw StateError('AuthLink cannot be a terminating link.');
    }

    // 1. Build initial headers from the gql_exec context
    final contextHeaders =
        req.context.entry<HttpLinkHeaders>()?.headers ?? const {};
    var currentHeaders = Map<String, String>.from(contextHeaders);

    // 2. Proactive token-expiry check
    if (tokenHeader != null &&
        isTokenExpired != null &&
        onTokenRefresh != null) {
      final expired = await isTokenExpired!();
      if (expired) {
        Logger.d(
            'Access token expired before request — attempting proactive refresh.',
            tag: 'AuthLink');
        try {
          final newHeaders = await _refreshToken();
          if (newHeaders != null) currentHeaders.addAll(newHeaders);
        } on RevokeTokenException {
          _handleRevokeToken();
          return;
        }
      } else {
        final authHeaders = await tokenHeader!();
        if (authHeaders != null && authHeaders.isNotEmpty) {
          currentHeaders.addAll(authHeaders);
        }
      }
    } else if (tokenHeader != null) {
      final authHeaders = await tokenHeader!();
      if (authHeaders != null && authHeaders.isNotEmpty) {
        currentHeaders.addAll(authHeaders);
      }
    }

    if (currentHeaders.containsKey('Authorization')) {
      Logger.d('Auth header applied to request.', tag: 'AuthLink');
    }

    // Attach updated headers back into the gql_exec context
    final authReq = currentHeaders.isNotEmpty
        ? req.withContextEntry(HttpLinkHeaders(headers: currentHeaders))
        : req;

    // 3. Execute and watch for unauthorized responses mid-stream
    await for (final response in forward(authReq)) {
      if (_isUnauthorized(response) && onTokenRefresh != null) {
        Logger.w(
            'Unauthorized response received — attempting token refresh and retry.',
            tag: 'AuthLink');
        try {
          final newHeaders = await _refreshToken();
          if (newHeaders != null && newHeaders.isNotEmpty) {
            final retryHeaders = Map<String, String>.from(contextHeaders)
              ..addAll(newHeaders);
            final retryReq =
                req.withContextEntry(HttpLinkHeaders(headers: retryHeaders));
            yield* forward(retryReq);
          } else {
            _handleRevokeToken();
          }
        } on RevokeTokenException {
          _handleRevokeToken();
        }
        return;
      }
      yield response;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, String>?> _refreshToken() {
    if (_ongoingRefresh != null) {
      Logger.d('Token refresh already in progress — joining existing request.',
          tag: 'AuthLink');
      return _ongoingRefresh!;
    }
    Logger.d('Refreshing access token…', tag: 'AuthLink');
    final completer = Completer<Map<String, String>?>();
    _ongoingRefresh = completer.future;
    _runRefresh(completer);
    return completer.future;
  }

  Future<void> _runRefresh(Completer<Map<String, String>?> completer) async {
    try {
      final newHeaders = await onTokenRefresh!(_refreshClient);
      Logger.s('Access token refreshed successfully.', tag: 'AuthLink');
      completer.complete(newHeaders);
    } catch (exception, stackTrace) {
      Logger.e('Failed to refresh access token — revoking.',
          error: exception, stackTrace: stackTrace, tag: 'AuthLink');
      completer.completeError(const RevokeTokenException(), stackTrace);
    } finally {
      _ongoingRefresh = null;
    }
  }

  void _handleRevokeToken() {
    Logger.w('Token revoked — notifying listeners.', tag: 'AuthLink');
    onRevokeToken?.call();
    notifyRevokeToken();
  }

  bool _isUnauthorized(Response response) {
    if (response.errors != null && response.errors!.isNotEmpty) {
      final code = response.errors!.first.extensions?['code'];
      return code == 'UNAUTHORIZED' ||
          code == 'UNAUTHENTICATED' ||
          code == 'FORBIDDEN';
    }
    return false;
  }
}
