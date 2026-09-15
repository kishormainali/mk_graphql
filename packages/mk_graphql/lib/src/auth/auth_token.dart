import 'package:meta/meta.dart';

/// The access/refresh token pair a [TokenStorage] persists on behalf of
/// [GraphQLClient].
@immutable
class AuthToken {
  const AuthToken({required this.accessToken, this.refreshToken});

  final String accessToken;
  final String? refreshToken;
}
