import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:example/graphql/generated/anime.gql.dart';

part 'anime_list_event.freezed.dart';

@freezed
abstract class AnimeListEvent with _$AnimeListEvent {
  const factory AnimeListEvent.started() = AnimeListStarted;
  const factory AnimeListEvent.fetchNext() = AnimeListFetchNext;
  const factory AnimeListEvent.refreshed() = AnimeListRefreshed;
  const factory AnimeListEvent.searchChanged(String query) = AnimeListSearchChanged;
  const factory AnimeListEvent.genreChanged(String? genre) = AnimeListGenreChanged;
  const factory AnimeListEvent.sortChanged(MediaSort sort) = AnimeListSortChanged;
}
