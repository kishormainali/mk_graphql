import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:example/graphql/generated/anime.gql.dart';

part 'anime_list_state.freezed.dart';

@freezed
abstract class AnimeListState with _$AnimeListState {
  const factory AnimeListState({
    @Default([]) List<GetAnimePagePageMediaModel> items,
    @Default(true) bool isLoading,
    @Default(false) bool isLoadingMore,
    @Default(true) bool hasMore,
    String? errorMessage,
    @Default('') String searchQuery,
    String? selectedGenre,
    @Default(MediaSort.popularityDesc) MediaSort currentSort,
    @Default([]) List<String> availableGenres,
    @Default(true) bool isLoadingGenres,
  }) = _AnimeListState;
}
