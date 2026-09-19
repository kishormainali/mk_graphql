// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AutoRouterGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:auto_route/auto_route.dart' as _i4;
import 'package:example/features/anime/anime_details_page.dart' as _i1;
import 'package:example/features/anime/anime_list_page.dart' as _i2;
import 'package:example/features/optimizations/optimizations_page.dart' as _i3;
import 'package:flutter/material.dart' as _i5;

/// generated route for
/// [_i1.AnimeDetailsPage]
class AnimeDetailsRoute extends _i4.PageRouteInfo<AnimeDetailsRouteArgs> {
  AnimeDetailsRoute({
    _i5.Key? key,
    required int id,
    List<_i4.PageRouteInfo>? children,
  }) : super(
         AnimeDetailsRoute.name,
         args: AnimeDetailsRouteArgs(key: key, id: id),
         rawPathParams: {'id': id},
         initialChildren: children,
       );

  static const String name = 'AnimeDetailsRoute';

  static _i4.PageInfo page = _i4.PageInfo(
    name,
    builder: (data) {
      final pathParams = data.inheritedPathParams;
      final args = data.argsAs<AnimeDetailsRouteArgs>(
        orElse: () => AnimeDetailsRouteArgs(id: pathParams.getInt('id')),
      );
      return _i1.AnimeDetailsPage(key: args.key, id: args.id);
    },
  );
}

class AnimeDetailsRouteArgs {
  const AnimeDetailsRouteArgs({this.key, required this.id});

  final _i5.Key? key;

  final int id;

  @override
  String toString() {
    return 'AnimeDetailsRouteArgs{key: $key, id: $id}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AnimeDetailsRouteArgs) return false;
    return key == other.key && id == other.id;
  }

  @override
  int get hashCode => key.hashCode ^ id.hashCode;
}

/// generated route for
/// [_i2.AnimeListPage]
class AnimeListRoute extends _i4.PageRouteInfo<void> {
  const AnimeListRoute({List<_i4.PageRouteInfo>? children})
    : super(AnimeListRoute.name, initialChildren: children);

  static const String name = 'AnimeListRoute';

  static _i4.PageInfo page = _i4.PageInfo(
    name,
    builder: (data) {
      return const _i2.AnimeListPage();
    },
  );
}

/// generated route for
/// [_i3.OptimizationsPage]
class OptimizationsRoute extends _i4.PageRouteInfo<void> {
  const OptimizationsRoute({List<_i4.PageRouteInfo>? children})
    : super(OptimizationsRoute.name, initialChildren: children);

  static const String name = 'OptimizationsRoute';

  static _i4.PageInfo page = _i4.PageInfo(
    name,
    builder: (data) {
      return const _i3.OptimizationsPage();
    },
  );
}
