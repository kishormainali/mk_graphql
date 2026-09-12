import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:example/graphql/generated/anime.gql.dart';

import 'anime_list_event.dart';
import 'anime_list_state.dart';

export 'anime_list_event.dart';
export 'anime_list_state.dart';

@injectable
class AnimeListBloc extends Bloc<AnimeListEvent, AnimeListState> {
  final GraphQLClient _client;

  late final GraphQLPaginator<GetAnimePageModel, GetAnimePageVars,
      GetAnimePagePageMediaModel> _paginator;

  AnimeListBloc(this._client) : super(const AnimeListState()) {
    _initPaginator();

    on<AnimeListStarted>(_onStarted);
    on<AnimeListFetchNext>(_onFetchNext);
    on<AnimeListRefreshed>(_onRefreshed);
    on<AnimeListSearchChanged>(_onSearchChanged);
    on<AnimeListGenreChanged>(_onGenreChanged);
    on<AnimeListSortChanged>(_onSortChanged);
  }

  void _initPaginator() {
    _paginator = GraphQLPaginator<GetAnimePageModel, GetAnimePageVars,
        GetAnimePagePageMediaModel>.page(
      client: _client,
      initialRequest: GetAnimePageReq(
        variables: GetAnimePageVars(
          page: 1,
          perPage: 20,
          search: null,
          genre: null,
          sort: [MediaSort.popularityDesc],
        ),
      ),
      getItems: (data) =>
          data.page?.media?.whereType<GetAnimePagePageMediaModel>().toList() ??
          [],
      updatePage: (vars, nextPage) => vars.copyWith(page: nextPage),
      initialPage: 1,
      pageSize: 20,
      getPage: (data) => data.page?.pageInfo?.currentPage,
      hasNextPage: (data) => data.page?.pageInfo?.hasNextPage ?? false,
    );
  }

  Future<void> _onStarted(
    AnimeListStarted event,
    Emitter<AnimeListState> emit,
  ) async {
    // 1. Fetch available genres
    try {
      final genresData = await _client.getGenres();
      final genres =
          genresData.genreCollection?.whereType<String>().toList() ?? [];
      emit(state.copyWith(
        availableGenres: genres,
        isLoadingGenres: false,
      ));
    } catch (_) {
      emit(state.copyWith(isLoadingGenres: false));
    }

    // 2. Trigger initial load on paginator
    _paginator.loadInitial();

    // 3. Stream paginator states directly into bloc state via emit.forEach
    await emit.forEach<PaginationState<GetAnimePagePageMediaModel>>(
      _paginator.stream,
      onData: (pState) => state.copyWith(
        items: pState.items,
        isLoading: pState.isLoading,
        isLoadingMore: pState.isLoadingMore,
        hasMore: pState.hasMore,
        errorMessage: pState.error?.toString(),
      ),
    );
  }

  Future<void> _onFetchNext(
    AnimeListFetchNext event,
    Emitter<AnimeListState> emit,
  ) async {
    if (_paginator.hasMore && !_paginator.isLoadingMore) {
      await _paginator.loadNext();
    }
  }

  Future<void> _onRefreshed(
    AnimeListRefreshed event,
    Emitter<AnimeListState> emit,
  ) async {
    emit(state.copyWith(
      searchQuery: '',
      selectedGenre: null,
      currentSort: MediaSort.popularityDesc,
    ));
    await _paginator.refetch();
  }

  Future<void> _onSearchChanged(
    AnimeListSearchChanged event,
    Emitter<AnimeListState> emit,
  ) async {
    emit(state.copyWith(searchQuery: event.query));

    // Apply search while preserving active selectedGenre and currentSort!
    await _paginator.applyVariables(
      GetAnimePageVars(
        page: 1,
        perPage: 20,
        search: event.query.trim().isNotEmpty ? event.query.trim() : null,
        genre: state.selectedGenre,
        sort: [state.currentSort],
      ),
    );
  }

  Future<void> _onGenreChanged(
    AnimeListGenreChanged event,
    Emitter<AnimeListState> emit,
  ) async {
    emit(state.copyWith(selectedGenre: event.genre));

    // Apply genre while preserving active searchQuery and currentSort!
    await _paginator.applyVariables(
      GetAnimePageVars(
        page: 1,
        perPage: 20,
        search:
            state.searchQuery.trim().isNotEmpty ? state.searchQuery.trim() : null,
        genre: event.genre,
        sort: [state.currentSort],
      ),
    );
  }

  Future<void> _onSortChanged(
    AnimeListSortChanged event,
    Emitter<AnimeListState> emit,
  ) async {
    emit(state.copyWith(currentSort: event.sort));

    // Apply sort while preserving active searchQuery and selectedGenre!
    await _paginator.applyVariables(
      GetAnimePageVars(
        page: 1,
        perPage: 20,
        search:
            state.searchQuery.trim().isNotEmpty ? state.searchQuery.trim() : null,
        genre: state.selectedGenre,
        sort: [event.sort],
      ),
    );
  }

  @override
  Future<void> close() {
    _paginator.dispose();
    return super.close();
  }
}
