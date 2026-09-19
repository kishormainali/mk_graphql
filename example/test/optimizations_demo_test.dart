import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:example/graphql/generated/anime.gql.dart';

/// Exercises the exact request/response shape the Optimizations demo page
/// relies on (GetAnimeDetailsReq: a wrapper model around a single root-level
/// entity) end to end through a real GraphQLClient, so a regression here
/// fails a test instead of only showing up as a silently-stuck "Loading…"
/// in the UI.
void main() {
  GraphQLClient makeClient() {
    final dio = Dio(BaseOptions());
    dio.httpClientAdapter = _FakeAdapter();
    return GraphQLClient(
      url: 'https://example.com/graphql',
      dio: dio,
      cache: InMemoryCache(),
      defaultFetchPolicy: FetchPolicy.cacheFirst,
      defaultStaleTime: Duration.zero,
    );
  }

  test('watchQuery(GetAnimeDetailsReq) sees the background refetch write',
      () async {
    final client = makeClient();
    final req = const GetAnimeDetailsReq(variables: GetAnimeDetailsVars(id: 1));

    final events = <GetAnimeDetailsModel?>[];
    final sub = client.watchQuery(req).listen(events.add);

    await Future.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    await client.dispose();

    expect(events.length, greaterThanOrEqualTo(2));
    expect(events.last?.media?.title?.romaji, 'Cowboy Bebop');
  });

  test(
      'invalidateQueries(operationNames: ["GetAnimeDetails"]) evicts and '
      'background-refetches the actively-watched GetAnimeDetailsReq',
      () async {
    final client = makeClient();
    final req = const GetAnimeDetailsReq(variables: GetAnimeDetailsVars(id: 1));

    final events = <GetAnimeDetailsModel?>[];
    final sub = client.watchQuery(req).listen(events.add);
    await Future.delayed(const Duration(milliseconds: 200));

    expect(
        client.cache
            .matchingQueryKeys(operationNames: const ['GetAnimeDetails']),
        isNotEmpty,
        reason: 'the cached details query must be discoverable by its '
            'operation name for invalidateQueries(operationNames:) to find '
            'it');

    final eventsBeforeInvalidate = events.length;
    await client.invalidateQueries(
        operationNames: const ['GetAnimeDetails']);
    await Future.delayed(const Duration(milliseconds: 200));

    await sub.cancel();
    await client.dispose();

    expect(events.length, greaterThan(eventsBeforeInvalidate),
        reason: 'invalidateQueries should have triggered a background '
            'refetch that re-emitted to the active watcher');
  });

  test(
      'invalidateQueries(types: ["Media"]) also evicts and '
      'background-refetches the actively-watched GetAnimeDetailsReq — '
      'the generated GetAnimeDetailsModel now round-trips __typename',
      () async {
    final client = makeClient();
    final req = const GetAnimeDetailsReq(variables: GetAnimeDetailsVars(id: 1));

    final events = <GetAnimeDetailsModel?>[];
    final sub = client.watchQuery(req).listen(events.add);
    await Future.delayed(const Duration(milliseconds: 200));

    expect(
        client.cache.matchingQueryKeys(types: const ['Media']),
        isNotEmpty,
        reason: 'the cached details query must be discoverable by the '
            'Media __typename its result touched, for '
            'invalidateQueries(types:) to find it');

    final eventsBeforeInvalidate = events.length;
    await client.invalidateQueries(types: const ['Media']);
    await Future.delayed(const Duration(milliseconds: 200));

    await sub.cancel();
    await client.dispose();

    expect(events.length, greaterThan(eventsBeforeInvalidate),
        reason: 'invalidateQueries should have triggered a background '
            'refetch that re-emitted to the active watcher');
  });
}

class _FakeAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    const body = '''
{"data":{"Media":{"id":1,"title":{"romaji":"Cowboy Bebop","english":"Cowboy Bebop","native":"native","__typename":"MediaTitle"},"bannerImage":"https://example.com/banner.jpg","coverImage":{"extraLarge":"https://example.com/xl.jpg","large":"https://example.com/l.jpg","color":"#e4d1a1","__typename":"MediaCoverImage"},"description":"desc","genres":["Action"],"averageScore":86,"episodes":26,"duration":24,"status":"FINISHED","season":"SPRING","seasonYear":1998,"popularity":222222,"favourites":33333,"__typename":"Media"},"__typename":"Query"}}
''';
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}
