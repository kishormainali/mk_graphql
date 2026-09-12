import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:example/graphql/generated/anime.gql.dart';

import 'anime_details_state.dart';

export 'anime_details_state.dart';

@injectable
class AnimeDetailsCubit extends Cubit<AnimeDetailsState> {
  final GraphQLClient _client;

  AnimeDetailsCubit(this._client) : super(const AnimeDetailsState.initial());

  Future<void> load(int id) async {
    emit(const AnimeDetailsState.loading());
    try {
      final data = await _client.getAnimeDetails(id: id);
      final media = data.media;
      if (media == null) {
        emit(const AnimeDetailsState.failure('Anime details not found.'));
      } else {
        emit(AnimeDetailsState.success(media));
      }
    } catch (e) {
      emit(AnimeDetailsState.failure(e.toString()));
    }
  }

  Future<void> refetch(int id) async {
    emit(const AnimeDetailsState.loading());
    try {
      final data = await _client.refetchGetAnimeDetails(id: id);
      final media = data.media;
      if (media != null) {
        emit(AnimeDetailsState.success(media));
      } else {
        emit(const AnimeDetailsState.failure('Anime details not found.'));
      }
    } catch (e) {
      emit(AnimeDetailsState.failure(e.toString()));
    }
  }
}
