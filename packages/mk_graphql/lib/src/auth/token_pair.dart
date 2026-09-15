import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

@immutable
class TokenPair extends Equatable {
  const TokenPair({
    required this.accessToken,
    this.refreshToken,
  });

  final String accessToken;
  final String? refreshToken;

  @override
  List<Object?> get props => [accessToken, refreshToken];
}
