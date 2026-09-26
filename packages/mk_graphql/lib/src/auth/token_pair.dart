import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

/// A session's access token, optional refresh token, and when they were
/// issued/last refreshed.
///
/// This is both what your `refreshCallback` returns and what
/// `TokenStorage.getToken` reads back. Two pairs are equal when all four
/// fields match.
@immutable
class TokenPair extends Equatable {
  const TokenPair({
    required this.accessToken,
    this.refreshToken,
    this.createdAt,
    this.updatedAt,
  });

  /// Sent on every request (as `Authorization: Bearer <token>` by default).
  final String accessToken;

  /// Passed to `refreshCallback` when the access token needs refreshing.
  /// Without one, an unauthorized response revokes the session immediately
  /// instead of attempting a refresh.
  final String? refreshToken;

  /// When this session's tokens were first issued — preserved across
  /// refreshes. `null` on a pair you build yourself (`TokenStorage` stamps it
  /// on save) and on sessions stored before timestamps were tracked.
  final DateTime? createdAt;

  /// When the tokens were last written — set on login and again on every
  /// refresh. `null` under the same conditions as [createdAt].
  final DateTime? updatedAt;

  @override
  List<Object?> get props => [accessToken, refreshToken, createdAt, updatedAt];
}
