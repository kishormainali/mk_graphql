import 'dart:async';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

import '../../auth/token_pair.dart';
import '../../auth/token_storage.dart';
import '../../client/client.dart';
import '../../core/graphql_error_mapper.dart';

/// Callback that builds the auth headers (e.g. `Authorization`) for a given
/// token, read from [TokenStorage.i] by the caller — only invoked when a
/// token is actually stored, so [token] is always non-null.
typedef TokenHeaderCallback = FutureOr<Map<String, String>> Function(
    String token);

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

/// How `AuthLink` should react to a possibly-unauthorized response, decided
/// by [IsUnauthorizedCallback] (or the built-in default when none is
/// supplied).
enum AuthFailure {
  /// Not an auth failure — the response/exception is passed through as-is.
  none,

  /// The access token needs a refresh: `AuthLink` attempts one via
  /// `onTokenRefresh` and retries the request once.
  refresh,

  /// Refreshing wouldn't help (e.g. a valid-but-insufficient token — HTTP
  /// 403/`FORBIDDEN`): `AuthLink` skips the refresh attempt entirely and
  /// revokes immediately.
  revoke,
}

/// Normalized info about a possibly-unauthorized response, passed to
/// [IsUnauthorizedCallback] — built the same way whether it came from a
/// normal streamed [Response] or a thrown [ServerException], so detection
/// logic doesn't need to juggle two nullable inputs or duplicate checks for
/// both cases.
class UnauthorizedContext {
  const UnauthorizedContext({
    this.errors,
    this.statusCode,
    this.response,
    this.exception,
  });

  /// GraphQL errors from the response (or the exception's parsed response),
  /// if any.
  final List<GraphQLError>? errors;

  /// The HTTP status code, when known — from a thrown [ServerException].
  final int? statusCode;

  /// The raw [Response] this was derived from, when available (a normal
  /// HTTP 200 carrying a GraphQL error payload, or the parsed body of a
  /// non-2xx response the terminating link managed to parse before
  /// throwing).
  final Response? response;

  /// The thrown [ServerException] this was derived from — non-null only
  /// when the terminating link raised one instead of yielding a [Response]
  /// (e.g. a real non-2xx HTTP status).
  final ServerException? exception;

  /// The `extensions.code` of the first error, upper-cased, or `null`.
  String? get errorCode => extractErrorCode(errors?.firstOrNull?.extensions);

  /// The `extensions.status` of the first error, or `null`.
  Object? get extensionsStatus => errors?.firstOrNull?.extensions?['status'];
}

/// Classifies a possibly-unauthorized response/exception into an
/// [AuthFailure]. Receives a normalized [UnauthorizedContext] built the same
/// way for both a streamed [Response] and a thrown [ServerException], so
/// custom detection logic can read `errors`/`statusCode` without caring
/// which case it came from.
///
/// Use this to recognize your API's own conventions (a custom error code, a
/// non-standard status field, a particular message, etc.) instead of
/// relying on the built-in default, which maps `extensions.code`/HTTP status
/// of `UNAUTHORIZED`/`UNAUTHENTICATED`/401 to [AuthFailure.refresh] and
/// `FORBIDDEN`/403 to [AuthFailure.revoke] (no refresh attempted).
typedef IsUnauthorizedCallback = AuthFailure Function(
    UnauthorizedContext context);

/// Performs token refresh given the currently stored refresh token — always
/// non-null, since `GraphQLClient` only calls this when one is actually
/// persisted (no stored refresh token revokes immediately without calling
/// this at all) — and returns the new [TokenPair] to persist, or null/throws
/// to revoke. Receives a plain [GraphQLClient] (no auth link attached) to run
/// the refresh request via its normal typed API.
///
/// Pass this to `GraphQLClient(refreshCallback: ...)` — the sole source of
/// truth for refresh — to let the client manage token storage and the
/// `Authorization` header itself — see [TokenStorage].
typedef RefreshCallback = FutureOr<TokenPair?> Function(
    GraphQLClient refreshClient, String refreshToken);

/// Callback invoked when the token is revoked (refresh failed or server returned
/// unauthorized and refresh is not possible).
typedef OnRevokeTokenCallback = void Function();
