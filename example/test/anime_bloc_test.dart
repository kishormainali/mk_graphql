import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:example/features/anime/bloc/anime_details_cubit.dart';
import 'package:example/features/anime/bloc/anime_list_bloc.dart';
import 'package:example/graphql/generated/anime.gql.dart';

void main() {
  group('AnimeListBloc & AnimeDetailsCubit with GraphQLPaginator', () {
    late Dio dio;
    late GraphQLClient client;
    int page1FetchCount = 0;
    int page2FetchCount = 0;

    setUp(() {
      page1FetchCount = 0;
      page2FetchCount = 0;
      dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final data = options.data;
            if (data is Map<String, dynamic>) {
              final queryStr = data['query'].toString();
              final variables =
                  data['variables'] as Map<String, dynamic>? ?? {};

              // 1. GetGenres
              if (queryStr.contains('query GetGenres')) {
                return handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': {
                        'GenreCollection': [
                          'Action',
                          'Adventure',
                          'Comedy',
                          'Drama',
                          'Fantasy',
                          'Sci-Fi'
                        ],
                      }
                    },
                  ),
                );
              }

              // 2. GetAnimeDetails
              if (queryStr.contains('query GetAnimeDetails')) {
                return handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': {
                        'Media': {
                          'id': 16498,
                          'title': {
                            'romaji': 'Shingeki no Kyojin',
                            'english': 'Attack on Titan',
                            'native': '進撃の巨人',
                            '__typename': 'MediaTitle',
                          },
                          'coverImage': {
                            'extraLarge': 'https://example.com/aot_xl.jpg',
                            'large': 'https://example.com/aot_l.jpg',
                            'color': '#d28042',
                            '__typename': 'MediaCoverImage',
                          },
                          'bannerImage': 'https://example.com/aot_banner.jpg',
                          'description': 'Description of AoT',
                          'status': 'FINISHED',
                          'episodes': 25,
                          'duration': 24,
                          'averageScore': 85,
                          'favourites': 65000,
                          'genres': ['Action', 'Drama', 'Fantasy'],
                          'season': 'SPRING',
                          'seasonYear': 2013,
                          'format': 'TV',
                          '__typename': 'Media',
                        }
                      }
                    },
                  ),
                );
              }

              // 3. GetAnimePage
              final page = variables['page'] as int? ?? 1;
              if (page == 1) {
                page1FetchCount++;
                return handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': {
                        'Page': {
                          'pageInfo': {
                            'total': 100,
                            'currentPage': 1,
                            'lastPage': 5,
                            'hasNextPage': true,
                            'perPage': 2,
                            '__typename': 'PageInfo',
                          },
                          'media': [
                            {
                              'id': 1,
                              'title': {
                                'romaji': 'Cowboy Bebop',
                                'english': 'Cowboy Bebop',
                                'native': 'カウボーイビバップ',
                                '__typename': 'MediaTitle',
                              },
                              'coverImage': {
                                'large': 'https://example.com/bebop.jpg',
                                'extraLarge': 'https://example.com/bebop_xl.jpg',
                                'color': '#f1a824',
                                '__typename': 'MediaCoverImage',
                              },
                              'averageScore': 86,
                              'episodes': 26,
                              'status': 'FINISHED',
                              'format': 'TV',
                              'genres': ['Action', 'Sci-Fi'],
                              '__typename': 'Media',
                            },
                            {
                              'id': 5,
                              'title': {
                                'romaji': 'Cowboy Bebop Movie',
                                'english': 'Cowboy Bebop The Movie',
                                'native': '天国の扉',
                                '__typename': 'MediaTitle',
                              },
                              'coverImage': {
                                'large': 'https://example.com/bebop_m.jpg',
                                'color': '#e45d3a',
                                '__typename': 'MediaCoverImage',
                              },
                              'averageScore': 82,
                              'episodes': 1,
                              'status': 'FINISHED',
                              'format': 'MOVIE',
                              'genres': ['Action'],
                              '__typename': 'Media',
                            },
                          ],
                          '__typename': 'Page',
                        }
                      }
                    },
                  ),
                );
              } else if (page == 2) {
                page2FetchCount++;
                return handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': {
                        'Page': {
                          'pageInfo': {
                            'total': 100,
                            'currentPage': 2,
                            'lastPage': 5,
                            'hasNextPage': false,
                            'perPage': 1,
                            '__typename': 'PageInfo',
                          },
                          'media': [
                            {
                              'id': 6,
                              'title': {
                                'romaji': 'Trigun',
                                'english': 'Trigun',
                                'native': 'トライガン',
                                '__typename': 'MediaTitle',
                              },
                              'coverImage': {
                                'large': 'https://example.com/trigun.jpg',
                                'color': '#cc2b14',
                                '__typename': 'MediaCoverImage',
                              },
                              'averageScore': 82,
                              'episodes': 26,
                              'status': 'FINISHED',
                              'format': 'TV',
                              'genres': ['Action', 'Sci-Fi'],
                              '__typename': 'Media',
                            },
                          ],
                          '__typename': 'Page',
                        }
                      }
                    },
                  ),
                );
              }
            }
            return handler.next(options);
          },
        ),
      );

      client = GraphQLClient(
        url: 'https://graphql.anilist.co',
        dio: dio,
        defaultFetchPolicy: FetchPolicy.networkOnly,
      );
    });

    test('AnimeListBloc initializes with GraphQLPaginator and handles pagination',
        () async {
      final bloc = AnimeListBloc(client);

      // Start bloc
      bloc.add(const AnimeListEvent.started());

      // Wait for initial page 1 & genres to load
      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) =>
              s.items.length == 2 &&
              s.availableGenres.isNotEmpty &&
              !s.isLoading &&
              s.hasMore),
        ),
      );

      expect(bloc.state.items.length, equals(2));
      expect(bloc.state.items[0].id, equals(1));
      expect(bloc.state.items[1].id, equals(5));
      expect(page1FetchCount, equals(1));

      // Fetch page 2 via bloc event
      bloc.add(const AnimeListEvent.fetchNext());

      // Wait for accumulation: 2 + 1 = 3 items
      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) =>
              s.items.length == 3 &&
              !s.isLoadingMore &&
              !s.hasMore),
        ),
      );

      expect(bloc.state.items.length, equals(3));
      expect(bloc.state.items[2].id, equals(6));
      expect(page2FetchCount, equals(1));

      // Pull to refresh: resets to page 1
      bloc.add(const AnimeListEvent.refreshed());

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) => s.items.length == 2 && !s.isLoading),
        ),
      );

      expect(page1FetchCount, equals(2));

      await bloc.close();
    });

    test('AnimeListBloc searchChanged restarts paginator via emit.forEach',
        () async {
      final bloc = AnimeListBloc(client);

      bloc.add(const AnimeListEvent.started());

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) => s.items.length == 2 && !s.isLoading),
        ),
      );

      bloc.add(const AnimeListEvent.searchChanged('Bebop'));

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) =>
              s.searchQuery == 'Bebop' && s.items.isNotEmpty && !s.isLoading),
        ),
      );

      expect(bloc.state.searchQuery, equals('Bebop'));

      await bloc.close();
    });

    test(
        'AnimeListBloc preserves filter while searching and preserves search while filtering',
        () async {
      final bloc = AnimeListBloc(client);

      bloc.add(const AnimeListEvent.started());

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) => s.items.length == 2 && !s.isLoading),
        ),
      );

      // 1. Select a genre filter
      bloc.add(const AnimeListEvent.genreChanged('Sci-Fi'));

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) =>
              s.selectedGenre == 'Sci-Fi' && !s.isLoading),
        ),
      );
      expect(bloc.state.selectedGenre, equals('Sci-Fi'));

      // 2. Type search query — verify selectedGenre is NOT reset
      bloc.add(const AnimeListEvent.searchChanged('Cowboy'));

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) =>
              s.searchQuery == 'Cowboy' &&
              s.selectedGenre == 'Sci-Fi' &&
              !s.isLoading),
        ),
      );
      expect(bloc.state.selectedGenre, equals('Sci-Fi'));
      expect(bloc.state.searchQuery, equals('Cowboy'));

      // 3. Change sort — verify search and genre are NOT reset
      bloc.add(const AnimeListEvent.sortChanged(MediaSort.scoreDesc));

      await expectLater(
        bloc.stream,
        emitsThrough(
          predicate<AnimeListState>((s) =>
              s.currentSort == MediaSort.scoreDesc &&
              s.searchQuery == 'Cowboy' &&
              s.selectedGenre == 'Sci-Fi' &&
              !s.isLoading),
        ),
      );
      expect(bloc.state.currentSort, equals(MediaSort.scoreDesc));
      expect(bloc.state.selectedGenre, equals('Sci-Fi'));
      expect(bloc.state.searchQuery, equals('Cowboy'));

      await bloc.close();
    });

    blocTest<AnimeDetailsCubit, AnimeDetailsState>(
      'AnimeDetailsCubit loads anime details successfully',
      build: () => AnimeDetailsCubit(client),
      act: (cubit) => cubit.load(16498),
      expect: () => [
        const AnimeDetailsState.loading(),
        predicate<AnimeDetailsState>((state) {
          return state.maybeWhen(
            success: (media) =>
                media.id == 16498 &&
                media.title?.english == 'Attack on Titan' &&
                media.status == MediaStatus.finished,
            orElse: () => false,
          );
        }),
      ],
    );

    blocTest<AnimeDetailsCubit, AnimeDetailsState>(
      'AnimeDetailsCubit refetches anime details successfully',
      build: () => AnimeDetailsCubit(client),
      act: (cubit) async {
        await cubit.load(16498);
        await cubit.refetch(16498);
      },
      expect: () => [
        const AnimeDetailsState.loading(),
        predicate<AnimeDetailsState>((state) =>
            state.maybeWhen(success: (_) => true, orElse: () => false)),
        const AnimeDetailsState.loading(),
        predicate<AnimeDetailsState>((state) => state.maybeWhen(
            success: (media) => media.id == 16498, orElse: () => false)),
      ],
    );
  });
}
