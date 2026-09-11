import 'package:auto_route/auto_route.dart';

import 'app_router.gr.dart';

@AutoRouterConfig(replaceInRouteName: 'Page,Route')
class AppRouter extends RootStackRouter {
  @override
  RouteType get defaultRouteType => const RouteType.material();

  @override
  List<AutoRoute> get routes => [
    AutoRoute(
      page: HomeRoute.page,
      initial: true,
      children: [
        AutoRoute(page: CountriesRoute.page, initial: true),
        AutoRoute(page: ContinentsRoute.page),
        AutoRoute(page: LanguagesRoute.page),
      ],
    ),
    AutoRoute(page: CountryDetailsRoute.page),
  ];
}
