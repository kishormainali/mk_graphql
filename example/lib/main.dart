import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:mk_graphql/mk_graphql.dart';

import 'di/injection.dart';
import 'router/app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // mk_graphql's HiveCache stays storage-path-agnostic, so the app owns
  // Hive's lifecycle — this must run before configureDependencies(), which
  // opens the box via HiveCache.open().
  await Hive.initFlutter();
  await configureDependencies();
  runApp(const AniListApp());
}

class AniListApp extends StatefulWidget {
  const AniListApp({super.key});

  @override
  State<AniListApp> createState() => _AniListAppState();
}

class _AniListAppState extends State<AniListApp> with WidgetsBindingObserver {
  final _appRouter = AppRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Pauses/resumes mk_graphql's opportunistic background refetches
  // (staleness-on-attach, refetchInterval polling, invalidateQueries,
  // notifyReconnected) with the app's own foreground/background state, so a
  // backgrounded app doesn't keep waking the radio to refresh screens
  // nobody can see — see docs/mk_graphql/caching.md#pausing-background-refetches-notifyapppaused.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final client = getIt<GraphQLClient>();
    switch (state) {
      case AppLifecycleState.resumed:
        client.notifyAppResumed();
      case AppLifecycleState.paused:
        client.notifyAppPaused();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

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
