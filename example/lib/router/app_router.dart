import 'package:auto_route/auto_route.dart';

import 'app_router.gr.dart';

@AutoRouterConfig(replaceInRouteName: 'Page,Route')
class AppRouter extends RootStackRouter {
  @override
  RouteType get defaultRouteType => const RouteType.material();

  @override
  List<AutoRoute> get routes => [
    AutoRoute(page: AnimeListRoute.page, initial: true),
    AutoRoute(page: AnimeDetailsRoute.page, path: '/anime/:id'),
    AutoRoute(page: OptimizationsRoute.page, path: '/optimizations'),
  ];
}
