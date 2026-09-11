import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../router/app_router.gr.dart';

@RoutePage()
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AutoTabsScaffold(
      routes: const [CountriesRoute(), ContinentsRoute(), LanguagesRoute()],
      bottomNavigationBuilder: (_, tabsRouter) {
        return NavigationBar(
          selectedIndex: tabsRouter.activeIndex,
          onDestinationSelected: tabsRouter.setActiveIndex,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.public_outlined),
              selectedIcon: Icon(Icons.public),
              label: 'Countries',
            ),
            NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Continents',
            ),
            NavigationDestination(
              icon: Icon(Icons.translate_outlined),
              selectedIcon: Icon(Icons.translate),
              label: 'Languages',
            ),
          ],
        );
      },
    );
  }
}
