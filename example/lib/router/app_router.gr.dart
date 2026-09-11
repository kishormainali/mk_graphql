// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AutoRouterGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:auto_route/auto_route.dart' as _i6;
import 'package:example/features/continents/continents_page.dart' as _i1;
import 'package:example/features/countries/countries_page.dart' as _i2;
import 'package:example/features/countries/country_details_page.dart' as _i3;
import 'package:example/features/home/home_page.dart' as _i4;
import 'package:example/features/languages/languages_page.dart' as _i5;
import 'package:flutter/material.dart' as _i7;

/// generated route for
/// [_i1.ContinentsPage]
class ContinentsRoute extends _i6.PageRouteInfo<void> {
  const ContinentsRoute({List<_i6.PageRouteInfo>? children})
    : super(ContinentsRoute.name, initialChildren: children);

  static const String name = 'ContinentsRoute';

  static _i6.PageInfo page = _i6.PageInfo(
    name,
    builder: (data) {
      return const _i1.ContinentsPage();
    },
  );
}

/// generated route for
/// [_i2.CountriesPage]
class CountriesRoute extends _i6.PageRouteInfo<void> {
  const CountriesRoute({List<_i6.PageRouteInfo>? children})
    : super(CountriesRoute.name, initialChildren: children);

  static const String name = 'CountriesRoute';

  static _i6.PageInfo page = _i6.PageInfo(
    name,
    builder: (data) {
      return const _i2.CountriesPage();
    },
  );
}

/// generated route for
/// [_i3.CountryDetailsPage]
class CountryDetailsRoute extends _i6.PageRouteInfo<CountryDetailsRouteArgs> {
  CountryDetailsRoute({
    _i7.Key? key,
    required String code,
    List<_i6.PageRouteInfo>? children,
  }) : super(
         CountryDetailsRoute.name,
         args: CountryDetailsRouteArgs(key: key, code: code),
         initialChildren: children,
       );

  static const String name = 'CountryDetailsRoute';

  static _i6.PageInfo page = _i6.PageInfo(
    name,
    builder: (data) {
      final args = data.argsAs<CountryDetailsRouteArgs>();
      return _i3.CountryDetailsPage(key: args.key, code: args.code);
    },
  );
}

class CountryDetailsRouteArgs {
  const CountryDetailsRouteArgs({this.key, required this.code});

  final _i7.Key? key;

  final String code;

  @override
  String toString() {
    return 'CountryDetailsRouteArgs{key: $key, code: $code}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CountryDetailsRouteArgs) return false;
    return key == other.key && code == other.code;
  }

  @override
  int get hashCode => key.hashCode ^ code.hashCode;
}

/// generated route for
/// [_i4.HomePage]
class HomeRoute extends _i6.PageRouteInfo<void> {
  const HomeRoute({List<_i6.PageRouteInfo>? children})
    : super(HomeRoute.name, initialChildren: children);

  static const String name = 'HomeRoute';

  static _i6.PageInfo page = _i6.PageInfo(
    name,
    builder: (data) {
      return const _i4.HomePage();
    },
  );
}

/// generated route for
/// [_i5.LanguagesPage]
class LanguagesRoute extends _i6.PageRouteInfo<void> {
  const LanguagesRoute({List<_i6.PageRouteInfo>? children})
    : super(LanguagesRoute.name, initialChildren: children);

  static const String name = 'LanguagesRoute';

  static _i6.PageInfo page = _i6.PageInfo(
    name,
    builder: (data) {
      return const _i5.LanguagesPage();
    },
  );
}
