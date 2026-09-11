import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';
import 'package:mk_graphql/mk_graphql.dart';

@module
abstract class NetworkModule {
  @lazySingleton
  Dio provideDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
  }

  @lazySingleton
  GraphQLClient provideGraphQLClient(Dio dio) {
    return GraphQLClient(
      url: 'https://countries.trevorblades.com/graphql',
      dio: dio,
      cache: InMemoryCache(),
      defaultFetchPolicy: FetchPolicy.cacheFirst,
      loggerOptions: const LoggerOptions(
        requestHeader: false,
        responseHeader: false,
        useAnsiColors: false,
      ),
    );
  }
}
