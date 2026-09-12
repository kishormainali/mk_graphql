# AniList Explorer — mk_graphql Example App

A modern, full-featured Flutter application demonstrating end-to-end integration of **`mk_graphql`** and **`mk_graphql_generator`** using the live [AniList GraphQL API](https://graphql.anilist.co), **AutoRoute** for declarative navigation, and **Injectable / GetIt** for dependency injection.

---

## ✨ Features Demonstrated

- 🎬 **AniList GraphQL API**: Real queries against `https://graphql.anilist.co`.
- 🔍 **Schema Introspection CLI**: Schema introspection directly from the endpoint via `dart run mk_graphql_generator:introspect`.
- 🧱 **Flutter BLoC State Management**:
  - `AnimeListBloc` manages page list states, filter parameters, and encapsulates `GraphQLPaginator.page`.
  - `AnimeDetailsCubit` manages single item retrieval and pull-to-refresh.
- 💉 **Clean Dependency Injection**: `GraphQLClient`, `AnimeListBloc`, and `AnimeDetailsCubit` configured with `injectable` and `get_it`.
- 🧭 **Type-Safe Routing**: Multi-screen navigation with `auto_route` (`AnimeListRoute` -> `AnimeDetailsRoute`).
- 📦 **Automated Code Generation**:
  - Strongly typed `@freezed` models, events, states, and variables.
  - Operation-scoped partial models (`GetAnimePagePageMediaModel`, `GetAnimeDetailsMediaModel`).
  - Dart reserved keyword handling (`native` -> `gNative` with `@JsonKey(name: 'native')`).
  - Direct `GraphQLClient` extension methods (`client.getAnimePage(...)`, `client.refetchGetAnimePage(...)`, `client.getAnimeDetails(...)`, `client.getGenres(...)`).
- 📑 **Page-Based Infinite Scroll Pagination in BLoC**:
  - `GraphQLPaginator.page` initialized and managed entirely inside `AnimeListBloc`.
  - Driven by `await emit.forEach(...)` without manual stream subscriptions or intermediate events.
  - Automatic multi-page item accumulation across subsequent fetches.
  - Infinite scroll dispatches `AnimeListEvent.fetchNext()` triggering `paginator.loadNext()`.
  - Reactive state emission forwarding items, loading, and `hasMore` flags to `BlocBuilder`.
- 🔄 **Refetch & Pull-to-Refresh**:
  - `RefreshIndicator` dispatches `AnimeListEvent.refreshed()` triggering `paginator.refetch()` on the list page.
  - `paginator.refetch()` preserves active search and filter variables instead of resetting them.
  - Detail screen pull-to-refresh via `cubit.refetch(id)`.
- 🏷️ **Dynamic Filtering & Search**:
  - Paginator directly applies search, genre, and sort changes via `paginator.applyVariables(...)`.
  - Search preserves active genre filter and sort order; genre filter preserves search query.
  - Horizontal genre chip selector (fetched dynamically via `GetGenres`).
  - Sort order dropdown (Popularity, Score, Trending, Favorites).
- 🪵 **Formatted GraphQL Logging**:
  - ANSI box-formatted logger showing operation names, formatted documents, variables, timing, and error details.

---

## 🚀 Running the Example

### 1. Introspect Schema (Optional)
The schema can be fetched or updated anytime using the CLI (automatically detects `schema_path` from `build.yaml`):
```bash
dart run mk_graphql_generator:introspect \
  --url https://graphql.anilist.co \
  --header "Referer: https://anilist.co/graphiql"
```


### 2. Install Dependencies
```bash
cd example
flutter pub get
```

### 3. Run Code Generation
Generate models, queries, routers, and dependency injection configs:
```bash
dart run build_runner build --delete-conflicting-outputs
```

### 4. Run the App
```bash
flutter run
```

---

## 📂 Architecture & Directory Structure

```
example/
├── lib/
│   ├── di/
│   │   ├── injection.dart             # GetIt dependency injection setup
│   │   └── network_module.dart        # Injectable module registering GraphQLClient
│   ├── features/
│   │   └── anime/
│   │       ├── bloc/
│   │       │   ├── anime_list_event.dart   # Freezed union events (fetchNext, refreshed, filter changes)
│   │       │   ├── anime_list_state.dart   # Freezed UI state (items, loading flags, filters)
│   │       │   ├── anime_list_bloc.dart    # BLoC encapsulating GraphQLPaginator.page
│   │       │   ├── anime_details_state.dart# Freezed state for media details
│   │       │   └── anime_details_cubit.dart# Cubit for detail fetching & pull-to-refresh
│   │       ├── anime_list_page.dart    # Infinite scroll grid, search, filters & pull-to-refresh (BlocBuilder)
│   │       └── anime_details_page.dart # Hero banner, stats, genres & refetch details (BlocBuilder)
│   ├── graphql/
│   │   ├── anime.graphql              # GetAnimePage, GetAnimeDetails, GetGenres operations
│   │   ├── schema.graphql             # AniList GraphQL schema SDL
│   │   └── generated/                 # Generated Freezed models, requests, and client extensions
│   ├── router/
│   │   ├── app_router.dart            # AutoRoute declarations
│   │   └── app_router.gr.dart         # Generated router code
│   └── main.dart                      # App entrypoint with AniList theme
├── test/
│   ├── anime_api_test.dart            # Unit tests for queries, pagination accumulation & refetch
│   ├── anime_bloc_test.dart           # BLoC & Cubit unit tests with GraphQLPaginator
│   └── widget_test.dart               # Widget test verifying app mounting
├── build.yaml                         # mk_graphql_builder configuration
└── pubspec.yaml
```

---

## 🧪 Running Tests

Run the full test suite:

```bash
flutter test
```
