import 'dart:async';

import 'package:dio/dio.dart' hide Response;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

import '../../auth/token_storage.dart';
import '../../client/client.dart';
import '../../core/error.dart' hide GraphQLError;
import '../logging/logger.dart';
import '../transport/dio_link.dart';
import 'auth_types.dart';
import 'refresh_header_link.dart';

export 'auth_types.dart';

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
    this.accessTokenHeader,
    this.refreshTokenHeader,
    this.isTokenExpired,
    this.isUnauthorized,
    this.onTokenRefresh,
    this.onRevokeToken,
  }) : _ownedDio = dio == null ? Dio() : null {
    final dioLink = DioLink(url, client: dio ?? _ownedDio!);
    _refreshClient = GraphQLClient.fromLink(
      refreshTokenHeader != null
          ? Link.from([RefreshHeaderLink(refreshTokenHeader!), dioLink])
          : dioLink,
    );
  }

  /// The GraphQL endpoint URL — also used for token refresh requests.
  final String url;

  /// Callback that returns the current auth headers built from the access
  /// token (e.g. `Authorization`) — attached to every normal outgoing
  /// request.
  final TokenHeaderCallback? accessTokenHeader;

  /// Callback that returns headers built from the refresh token (e.g.
  /// `Authorization`) — when provided, attached to every request sent
  /// through [_refreshClient] instead of [accessTokenHeader].
  final TokenHeaderCallback? refreshTokenHeader;

  /// Optional callback to check whether the current token is expired.
  final IsTokenExpiredCallback? isTokenExpired;

  /// Optional override for classifying a possibly-unauthorized response.
  /// Falls back to [_defaultClassify]'s built-in convention when omitted.
  final IsUnauthorizedCallback? isUnauthorized;

  /// Callback to perform token refresh.
  final OnRefreshCallback? onTokenRefresh;

  /// Called when the token is revoked.
  final OnRevokeTokenCallback? onRevokeToken;

  /// Internal [GraphQLClient] (no auth link) used exclusively for refresh requests.
  late final GraphQLClient _refreshClient;

  /// The [Dio] this [AuthLink] created for itself (no `dio:` argument was
  /// supplied) — closed by [dispose]. Null when the caller supplied their
  /// own [Dio], which stays theirs to close.
  final Dio? _ownedDio;

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
    if (accessTokenHeader != null &&
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
        } on RevokeTokenException catch (e) {
          _handleRevokeToken();
          throw e; // surfaces the real refresh failure to the caller
        }
      } else {
        final authHeaders = await _buildAccessHeaders();
        if (authHeaders != null && authHeaders.isNotEmpty) {
          currentHeaders.addAll(authHeaders);
        }
      }
    } else if (accessTokenHeader != null) {
      final authHeaders = await _buildAccessHeaders();
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

    // 3. Execute, watching for unauthorized responses both as a normal
    // GraphQL error payload (HTTP 200 + errors[].extensions.code) and as a
    // thrown ServerException (real HTTP 401/403 — e.g. DioLinkServerException,
    // which terminating links throw instead of yielding for non-2xx statuses).
    try {
      await for (final response in forward(authReq)) {
        if (onTokenRefresh != null) {
          switch (_classify(response: response)) {
            case AuthFailure.refresh:
              yield* _refreshAndRetry(req, contextHeaders, forward,
                  originalResponse: response);
              return;
            case AuthFailure.revoke:
              _handleRevokeToken();
              yield response; // still surfaces the real GraphQL error
              return;
            case AuthFailure.none:
              break;
          }
        }
        yield response;
      }
    } on ServerException catch (e) {
      if (onTokenRefresh != null) {
        switch (_classify(response: e.parsedResponse, exception: e)) {
          case AuthFailure.refresh:
            yield* _refreshAndRetry(req, contextHeaders, forward,
                originalException: e);
            return;
          case AuthFailure.revoke:
            _handleRevokeToken();
            rethrow; // still surfaces the real HTTP status/response
          case AuthFailure.none:
            break;
        }
      }
      rethrow;
    }
  }

  /// [originalResponse]/[originalException] is the unauthorized
  /// response/exception that triggered this refresh — surfaced to the
  /// caller if the refresh itself fails, instead of silently ending the
  /// stream with no error at all.
  Stream<Response> _refreshAndRetry(
    Request req,
    Map<String, String> contextHeaders,
    NextLink forward, {
    Response? originalResponse,
    ServerException? originalException,
  }) async* {
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
        if (originalResponse != null) {
          yield originalResponse;
        } else if (originalException != null) {
          throw originalException;
        }
      }
    } on RevokeTokenException catch (e) {
      _handleRevokeToken();
      throw e; // the refresh failure itself, more specific than the original
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Reads the current access token from [TokenStorage.i] and passes it to
  /// [accessTokenHeader] — only called when a token is actually stored.
  Future<Map<String, String>?> _buildAccessHeaders() async {
    final token = await TokenStorage.i.accessToken;
    if (token == null) return null;
    return accessTokenHeader!(token);
  }

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
      completer.completeError(
        exception is RevokeTokenException
            ? exception
            : RevokeTokenException(
                message: 'Token refresh failed: $exception',
                originalException: exception,
                originalStackTrace: stackTrace,
              ),
        stackTrace,
      );
    } finally {
      _ongoingRefresh = null;
    }
  }

  void _handleRevokeToken() {
    Logger.w('Token revoked — notifying listeners.', tag: 'AuthLink');
    onRevokeToken?.call();
    notifyRevokeToken();
  }

  /// Builds a normalized [UnauthorizedContext] and dispatches to the
  /// app-supplied [isUnauthorized] when provided, else falls back to
  /// [_defaultClassify].
  AuthFailure _classify({Response? response, ServerException? exception}) {
    final context = UnauthorizedContext(
      errors: response?.errors,
      statusCode: exception?.statusCode,
      response: response,
      exception: exception,
    );
    return isUnauthorized != null
        ? isUnauthorized!(context)
        : _defaultClassify(context);
  }

  /// Treats `FORBIDDEN`/HTTP 403 (a valid token lacking permission — a
  /// refresh wouldn't grant more access) as [AuthFailure.revoke], and
  /// `UNAUTHORIZED`/`UNAUTHENTICATED`/HTTP 401 (an expired/invalid token) as
  /// [AuthFailure.refresh].
  AuthFailure _defaultClassify(UnauthorizedContext context) {
    final code = context.errorCode;
    final status = context.statusCode;
    final extStatus = context.extensionsStatus;
    if (code == 'FORBIDDEN' || status == 403 || extStatus == 403) {
      return AuthFailure.revoke;
    }
    if (code == 'UNAUTHORIZED' ||
        code == 'UNAUTHENTICATED' ||
        status == 401 ||
        extStatus == 401) {
      return AuthFailure.refresh;
    }
    return AuthFailure.none;
  }

  /// Closes the [Dio] used by the internal refresh client, but only if this
  /// [AuthLink] created it itself (see [_ownedDio]) — a caller-supplied
  /// [Dio] stays theirs to close. Deliberately does NOT call
  /// `_refreshClient.dispose()`: that would also clear the *global*
  /// revoke-token listener registry (see [clearRevokeTokenListeners]), an
  /// unrelated side effect this internal helper client shouldn't trigger.
  @override
  Future<void> dispose() async {
    _ownedDio?.close();
  }
}
