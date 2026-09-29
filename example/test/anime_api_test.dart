import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:example/graphql/generated/anime.gql.dart';

void main() {
  group('AniList GraphQL Operations', () {
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
              final variables =
                  data['variables'] as Map<String, dynamic>? ?? {};
              final page = variables['page'] as int? ?? 1;

              // Check if query is GetAnimeDetails
              if (data['query'].toString().contains('query GetAnimeDetails')) {
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
                            'medium': 'https://example.com/aot_m.jpg',
                            'color': '#d28042',
                            '__typename': 'MediaCoverImage',
                          },
                          'bannerImage': 'https://example.com/aot_banner.jpg',
                          'description':
                              'Centuries ago, mankind was almost slaughtered to extinction...',
                          'status': 'FINISHED',
                          'episodes': 25,
                          'duration': 24,
                          'averageScore': 85,
                          'meanScore': 86,
                          'popularity': 560000,
                          'favourites': 65000,
                          'genres': ['Action', 'Drama', 'Fantasy', 'Mystery'],
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

              // Otherwise GetAnimePage
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
                                'medium': 'https://example.com/bebop_m.jpg',
                                'color': '#f1a824',
                                '__typename': 'MediaCoverImage',
                              },
                              'averageScore': 86,
                              'episodes': 26,
                              'status': 'FINISHED',
                              'format': 'TV',
                              'genres': ['Action', 'Adventure', 'Sci-Fi'],
                              '__typename': 'Media',
                            },
                            {
                              'id': 5,
                              'title': {
                                'romaji': 'Cowboy Bebop: Tengoku no Tobira',
                                'english': 'Cowboy Bebop: The Movie',
                                'native': 'カウボーイビバップ 天国の扉',
                                '__typename': 'MediaTitle',
                              },
                              'coverImage': {
                                'large':
                                    'https://example.com/bebop_movie.jpg',
                                'medium':
                                    'https://example.com/bebop_movie_m.jpg',
                                'color': '#e45d3a',
                                '__typename': 'MediaCoverImage',
                              },
                              'averageScore': 82,
                              'episodes': 1,
                              'status': 'FINISHED',
                              'format': 'MOVIE',
                              'genres': ['Action', 'Drama', 'Sci-Fi'],
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
                                'medium': 'https://example.com/trigun_m.jpg',
                                'color': '#cc2b14',
                                '__typename': 'MediaCoverImage',
                              },
                              'averageScore': 82,
                              'episodes': 26,
                              'status': 'FINISHED',
                              'format': 'TV',
                              'genres': [
                                'Action',
                                'Adventure',
                                'Comedy',
                                'Sci-Fi'
                              ],
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

    test('fetches anime page successfully and parses fields', () async {
      final pageData = await client.getAnimePage(page: 1, perPage: 2);

      final page = pageData.page;
      expect(page, isNotNull);
      expect(page!.pageInfo!.total, equals(100));
      expect(page.pageInfo!.hasNextPage, isTrue);

      final mediaList = page.media!;
      expect(mediaList.length, equals(2));
      expect(mediaList[0].title!.english, equals('Cowboy Bebop'));
      expect(mediaList[0].averageScore, equals(86));
      expect(mediaList[0].genres, contains('Action'));
      expect(
          mediaList[1].title!.romaji, equals('Cowboy Bebop: Tengoku no Tobira'));
    });

    test('GraphQLPaginator.page accumulates results automatically', () async {
      final paginator = GraphQLPaginator<GetAnimePageModel, GetAnimePageVars,
          GetAnimePagePageMediaModel>.page(
        client: client,
        initialRequest: GetAnimePageReq(
          variables: const GetAnimePageVars(page: 1, perPage: 2),
        ),
        getItems: (data) =>
            data.page?.media?.whereType<GetAnimePagePageMediaModel>().toList() ??
            [],
        updatePage: (vars, nextPage) => vars.copyWith(page: nextPage),
        initialPage: 1,
        pageSize: 2,
        getPage: (data) => data.page?.pageInfo?.currentPage,
        hasNextPage: (data) => data.page?.pageInfo?.hasNextPage ?? false,
      );

      // Initial state
      expect(paginator.items, isEmpty);
      expect(paginator.hasMore, isTrue);

      // Fetch page 1
      final p1Items = await paginator.loadInitial();
      expect(p1Items.length, equals(2));
      expect(paginator.items.length, equals(2));
      expect(paginator.items[0].id, equals(1));
      expect(paginator.items[1].id, equals(5));
      expect(paginator.hasMore, isTrue);
      expect(page1FetchCount, equals(1));

      // Fetch page 2 (automatically appended to paginator.items)
      final p2Items = await paginator.loadNext();
      expect(p2Items.length, equals(3));
      expect(paginator.items.length, equals(3));
      expect(paginator.items[2].id, equals(6));
      expect(paginator.hasMore, isFalse);
      expect(page2FetchCount, equals(1));

      // Attempting next when hasMore is false returns current list without extra request
      final next = await paginator.loadNext();
      expect(next.length, equals(3));
      expect(page2FetchCount, equals(1));
    });

    test('refetch re-executes query with exact same variables', () async {
      final page1 = await client.getAnimePage(page: 1, perPage: 2);
      expect(page1.page!.media!.length, equals(2));
      expect(page1FetchCount, equals(1));

      // Refetch page 1
      final refetched = await client.refetchGetAnimePage(page: 1, perPage: 2);
      expect(refetched.page!.media!.length, equals(2));
      expect(page1FetchCount, equals(2));
    });

    test('fetches anime details correctly', () async {
      final data = await client.getAnimeDetails(id: 16498);

      final anime = data.media;
      expect(anime, isNotNull);
      expect(anime!.id, equals(16498));
      expect(anime.title!.english, equals('Attack on Titan'));
      expect(anime.title!.romaji, equals('Shingeki no Kyojin'));
      expect(anime.title!.native, equals('進撃の巨人'));
      expect(anime.averageScore, equals(85));
      expect(anime.episodes, equals(25));
      expect(anime.status, equals(MediaStatus.finished));
      expect(
          anime.genres, containsAll(['Action', 'Drama', 'Fantasy', 'Mystery']));
    });
  });
}
