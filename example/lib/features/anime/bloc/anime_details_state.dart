import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:example/graphql/generated/anime.gql.dart';

part 'anime_details_state.freezed.dart';

@freezed
abstract class AnimeDetailsState with _$AnimeDetailsState {
  const factory AnimeDetailsState.initial() = _Initial;
  const factory AnimeDetailsState.loading() = _Loading;
  const factory AnimeDetailsState.success(GetAnimeDetailsMediaModel media) =
      _Success;
  const factory AnimeDetailsState.failure(String error) = _Failure;
}
