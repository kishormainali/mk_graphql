# mk_graphql

A modern, streamlined, high-performance GraphQL ecosystem for Dart & Flutter.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.6+-0175C2.svg?logo=dart)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.27+-02569B.svg?logo=flutter)](https://flutter.dev)

`mk_graphql` provides a complete GraphQL toolchain:
- **`mk_graphql`**: Lightweight runtime client with normalized caching, composable links (HTTP, SSE, WebSockets, Uploads, Auth), robust error handling (with field-level validation errors), refetch, and automatic pagination.
- **`mk_graphql_generator`**: Blazing-fast `build_runner` code generator producing immutable Freezed models, typed operation requests, and convenient client extension methods with automatic partial model naming (`{Type}PartialModel`), reserved keyword mapping (`g{Keyword}`), and schema-driven type resolution.

---

## Packages

| Package | Version | Description |
|---|---|---|
| [`mk_graphql`](packages/mk_graphql) | [![pub](https://img.shields.io/pub/v/mk_graphql.svg)](https://pub.dev/packages/mk_graphql) | Runtime GraphQL client, links, cache, and pagination. |
| [`mk_graphql_generator`](packages/mk_graphql_generator) | [![pub](https://img.shields.io/pub/v/mk_graphql_generator.svg)](https://pub.dev/packages/mk_graphql_generator) | Codegen builder for Freezed models, requests, and client extensions. |

---

## 🚀 Step-by-Step Integration Guide

Follow these steps to integrate `mk_graphql` into your Flutter or Dart application.

### Step 1: Add Dependencies

Add the runtime packages to `dependencies` and the generator tools to `dev_dependencies` in your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  mk_graphql: ^1.0.1
  freezed_annotation: ^3.1.0
  json_annotation: ^4.12.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  mk_graphql_generator: ^1.0.1
  build_runner: ^2.16.0
  freezed: ^4.0.1
  json_serializable: ^6.14.1
```

Run:
```bash
flutter pub get
```

---

### Step 2: Add Your GraphQL Schema

Place your GraphQL schema file in your project under `lib/` (e.g. `lib/graphql/schema.graphql`):

```graphql
# lib/graphql/schema.graphql
type Query {
  user(id: ID!): User
  countries(filter: CountryFilterInput): [Country!]!
}

type Mutation {
  updateUser(id: ID!, name: String!): User!
}

type User {
  id: ID!
  name: String!
  email: String!
  avatar: String
}

input CountryFilterInput {
  code: StringQueryOperatorInput
}

input StringQueryOperatorInput {
  eq: String
}

type Country {
  code: ID!
  name: String!
  capital: String
  emoji: String!
}
```

---

### Step 3: Write GraphQL Operations

Write standard `.graphql` or `.gql` queries, mutations, or subscriptions anywhere under `lib/`:

```graphql
# lib/features/countries/get_countries.graphql
query GetCountries($filter: CountryFilterInput) {
  countries(filter: $filter) {
    code
    name
    capital
    emoji
  }
}
```

```graphql
# lib/features/user/get_user.graphql
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
    email
  }
}
```

---

### Step 4: Configure `build.yaml` (Optional)

Create a `build.yaml` file in the root of your app to customize paths, custom scalars, or caching:

```yaml
targets:
  $default:
    builders:
      mk_graphql_generator:mk_graphql_builder:
        options:
          # Custom path to your schema (default: auto-detected schema.graphql)
          schema_path: lib/graphql/schema.graphql
          
          # Custom shared output directory (default: lib/shared/generated)
          shared_dir: lib/shared/generated
          
          # Enable two-tier disk + memory generator caching for speed
          cache: true
          
          # Map custom GraphQL scalars to Dart types
          scalars:
            DateTime: DateTime
            UUID: String
            Upload: MultipartFile
```

---

### Step 5: Run the Code Generator

Run `build_runner` to generate all typed models, requests, and client extensions:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Or watch for continuous compilation while developing:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

This generates:
- **Shared Models**: `lib/shared/generated/models/` containing schema models.
- **Partial Models**: Named `${Type}PartialModel` (e.g. `CountryPartialModel`) when a query requests a specific subset of schema fields.
- **Enums & Inputs**: Strongly typed `@JsonValue` enums and `@freezed` input classes.
- **Operation Requests**: `GetCountriesReq`, `GetUserReq` with serialization and parsing built-in.
- **Client Extensions**: Strongly typed methods directly on `GraphQLClient` (e.g. `client.getCountries(...)`, `client.getUser(...)`).

---

### Step 6: Initialize `GraphQLClient`

Instantiate `GraphQLClient` (or register it via `get_it`/`injectable`):

```dart
import 'package:mk_graphql/mk_graphql.dart';

final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  
  // Optional: SSE or WebSocket URL for real-time subscriptions
  // sseUrl: 'https://api.example.com/graphql/sse',
  // wsUrl: 'wss://api.example.com/graphql',

  // Optional: Dynamic token header
  tokenHeader: () async {
    final token = await secureStorage.read(key: 'jwt');
    return token != null ? {'Authorization': 'Bearer $token'} : {};
  },

  // Optional: Proactive or 401 token refresh callback
  onTokenRefresh: (dioLink) async {
    final refreshedToken = await authService.refresh();
    return refreshedToken != null ? {'Authorization': 'Bearer $refreshedToken'} : null;
  },

  // Default fetch policy (cacheFirst, networkOnly, cacheAndNetwork, noCache)
  defaultFetchPolicy: FetchPolicy.cacheFirst,
  
  // Default error policy (none, ignore, all)
  defaultErrorPolicy: ErrorPolicy.none,
);
```

---

### Step 7: Execute Operations

You have two clean options to execute requests:

#### Option A: Using Generated Client Extensions
```dart
// Generated extension method directly on client
final data = await client.getCountries(
  filter: const CountryFilterInput(
    code: StringQueryOperatorInput(eq: 'NP'),
  ),
);

for (final country in data.countries) {
  print('${country.emoji} ${country.name}');
}
```

#### Option B: Using Generated Request Objects
```dart
final req = GetCountriesReq(
  variables: const GetCountriesVars(
    filter: CountryFilterInput(
      code: StringQueryOperatorInput(eq: 'NP'),
    ),
  ),
);

// Single future execution:
final data = await client.future(req);

// Direct request execution extension:
final data2 = await req.execute(client);

// Reactive stream (emits cache first, then network on cacheAndNetwork):
final stream = client.stream(req);
```

---

### Step 8: Refetch Queries

Easily bypass cache with `networkOnly` and update the cached data in-place:

```dart
// Using client method
final freshData = await client.refetch(req);

// Or using request extension
final freshData2 = await req.refetch(client);

// Or using generated client extension
final freshData3 = await client.refetchGetCountries(filter: filter);
```

---

### Step 9: Automatic Pagination (No Manual Append Needed)

`mk_graphql` automatically concatenates next-page items and updates the cache without requiring manual `[...current, ...next]` list concatenation.

#### Method A: Using `GraphQLPaginator`
```dart
final paginator = client.paginateOffset(
  initialRequest: req,
  getItems: (data) => data.countries,
  updateOffset: (vars, offset, limit) => vars.copyWith(offset: offset, limit: limit),
  limit: 20,
);

// Load first page (returns List<TItem> directly)
final initialItems = await paginator.loadInitial();

// Load next page (automatically accumulates and returns the complete list)
final accumulatedItems = await paginator.loadNext();

// Stream items reactively
paginator.itemsStream.listen((items) {
  print('Total items loaded: ${items.length}');
});

// Or automatically fetch all remaining pages
final allItems = await paginator.loadAll(maxPages: 10);
```

#### Method B: Using `client.fetchMore` or `req.fetchMore`
```dart
// Automatically merges next page lists and updates cache under reqPage1
final mergedData = await client.fetchMore(
  originalRequest: reqPage1,
  nextRequest: reqPage2,
);

// Or via request extension:
final mergedData2 = await reqPage1.fetchMore(client, nextRequest: reqPage2);

// Watchers on reqPage1 automatically receive the combined items:
client.watchQuery(reqPage1).listen((combinedData) {
  print('Combined count: ${combinedData?.countries.length}');
});
```

---

### Step 10: Validation Error Handling

When backend GraphQL servers (Apollo, Lighthouse/Laravel, NestJS, Spring DGS) return validation failures:

```dart
try {
  await client.future(createPostReq);
} on ValidationException catch (e) {
  // Field-level error map: {'email': ['Email already taken'], 'title': ['Too short']}
  print(e.validationErrors);

  // Helper methods
  if (e.hasError('email')) {
    final emailError = e.getFirstError('email');
    print('Email error: $emailError');
  }
} on UnAuthorizedException {
  // Handle auth logout / login redirect
} on GraphQLException catch (e) {
  // Generic GraphQL server error
  print('Error: ${e.message}');
}
```

---

## 📚 Documentation

For in-depth guides, see the [docs/ directory](docs/README.md):
- [Getting Started with mk_graphql](docs/mk_graphql/getting-started.md)
- [Client, Requests & ErrorPolicy](docs/mk_graphql/client-and-requests.md)
- [Normalized Cache & Optimistic UI](docs/mk_graphql/caching.md)
- [Link Pipeline (Auth, SSE, WS, Uploads)](docs/mk_graphql/links.md)
- [Pagination Guide](docs/mk_graphql/pagination.md)
- [Getting Started with Generator](docs/mk_graphql_generator/getting-started.md)
- [Generator Configuration & Scalars](docs/mk_graphql_generator/configuration.md)
- [Generated Models & Partial Types](docs/mk_graphql_generator/generated-output.md)

---

## 💡 Example App

A full Flutter example using Trevor Blades Countries GraphQL API, AutoRoute, and Injectable is located in [`example/`](example/).

To run the example:
```bash
cd example
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

---

## 📄 License

This repository is licensed under the [MIT License](packages/mk_graphql/LICENSE).
