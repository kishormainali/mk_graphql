import 'package:flutter/material.dart';

import 'di/injection.dart';
import 'router/app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  runApp(const AniListApp());
}

class AniListApp extends StatefulWidget {
  const AniListApp({super.key});

  @override
  State<AniListApp> createState() => _AniListAppState();
}

class _AniListAppState extends State<AniListApp> {
  final _appRouter = AppRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'AniList mk_graphql Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3DB4F2),
        scaffoldBackgroundColor: const Color(0xFF0B1622),
        cardTheme: CardThemeData(
          color: const Color(0xFF151F2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1622),
          elevation: 0,
        ),
      ),
      routerConfig: _appRouter.config(),
    );
  }
}
