// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:dio/dio.dart' as _i361;
import 'package:get_it/get_it.dart' as _i174;
import 'package:injectable/injectable.dart' as _i526;
import 'package:mk_graphql/mk_graphql.dart' as _i901;

import '../features/anime/bloc/anime_details_cubit.dart' as _i256;
import '../features/anime/bloc/anime_list_bloc.dart' as _i960;
import '../features/optimizations/network_activity_monitor.dart' as _i581;
import 'network_module.dart' as _i567;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  Future<_i174.GetIt> init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) async {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final networkModule = _$NetworkModule();
    gh.lazySingleton<_i581.NetworkActivityMonitor>(
      () => _i581.NetworkActivityMonitor(),
    );
    gh.lazySingleton<_i361.Dio>(
      () => networkModule.provideDio(gh<_i581.NetworkActivityMonitor>()),
    );
    await gh.factoryAsync<_i901.GraphQLClient>(
      () => networkModule.provideGraphQLClient(gh<_i361.Dio>()),
      preResolve: true,
    );
    gh.factory<_i256.AnimeDetailsCubit>(
      () => _i256.AnimeDetailsCubit(gh<_i901.GraphQLClient>()),
    );
    gh.factory<_i960.AnimeListBloc>(
      () => _i960.AnimeListBloc(gh<_i901.GraphQLClient>()),
    );
    return this;
  }
}

class _$NetworkModule extends _i567.NetworkModule {}
