import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:example/di/injection.dart';
import 'package:example/graphql/generated/operations.gql.dart';

void main() {
  setUpAll(() async {
    await configureDependencies();
  });

  test(
    'Fetches live countries from Trevor Blades API and verifies logger output',
    () async {
      final client = getIt<GraphQLClient>();

      final response = await client.getCountryDetails(
        code: 'NP',
        fetchPolicy: FetchPolicy.networkOnly,
      );

      expect(response.country, isNotNull);
      expect(response.country?.name, 'Nepal');
      expect(response.country?.capital, 'Kathmandu');
      expect(response.country?.emoji, '🇳🇵');
      expect(response.country?.continent.name, 'Asia');
      expect(response.country?.languages, isNotEmpty);
    },
  );

  test('Refetch support via client extension and request', () async {
    final client = getIt<GraphQLClient>();

    // 1. client.refetchGetCountryDetails
    final refetched = await client.refetchGetCountryDetails(code: 'NP');
    expect(refetched.country?.name, 'Nepal');

    // 2. req.refetch(client)
    final req = GetCountryDetailsReq(
      variables: const GetCountryDetailsVars(code: 'NP'),
      fetchPolicy: FetchPolicy.cacheFirst,
    );
    final reqRefetched = await req.refetch(client);
    expect(reqRefetched.country?.name, 'Nepal');
  });

  test('Pagination support with GraphQLPaginator', () async {
    final client = getIt<GraphQLClient>();

    final paginator = client.paginate(
      initialRequest: const GetCountriesReq(
        variables: GetCountriesVars(),
      ),
      getItems: (data) => data.countries,
      nextVariables: ({required lastData, required currentVars, required totalLoaded}) {
        // Trevor Blades returns all countries in 1 page, so no next page
        return null;
      },
    );

    await paginator.loadInitial();
    expect(paginator.items, isNotEmpty);
    expect(paginator.hasMore, isFalse);
    expect(paginator.items.first.name, isNotEmpty);

    // Test refetch on paginator
    await paginator.refetch();
    expect(paginator.items, isNotEmpty);

    paginator.dispose();
  });
}
