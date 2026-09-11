# mk_graphql_generator

[![pub package](https://img.shields.io/pub/v/mk_graphql_generator.svg)](https://pub.dev/packages/mk_graphql_generator)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An ultra-fast, intelligent `build_runner` code generator for [`mk_graphql`](https://pub.dev/packages/mk_graphql). Generates immutable Freezed variables, response models scoped precisely to each query's selection, typed operation requests, and client extensions from `.graphql` / `.gql` files.

📖 **[Full documentation](../../docs/mk_graphql_generator/getting-started.md)** — getting started, `build.yaml` configuration, generated file layout, and the rules for when a response model is shared vs. generated per-operation.

---

## ✨ Features

- ⚡ **Lightning-Fast Generation**: Two-tier caching (memory + disk) with microsecond output path computation so `build_runner` never hangs.
- ❄️ **Modern Freezed Models**: Generates `@freezed` models and `@JsonSerializable` classes for all GraphQL queries, mutations, subscriptions, inputs, and models.
- 🎯 **Direct GraphQLClient Extensions**: Generates typed methods on `GraphQLClient` like `client.getUser(...)` and `client.getUserStream(...)`.
- 🛑 **Dio CancelToken Support**: Generated requests and client extensions natively accept `CancelToken? cancelToken`.
- 📁 **GraphQL Multipart Uploads**: Full support for `Upload` scalar mapped to `MultipartFile`.
- 🧩 **Configurable Architecture**: Easily configure custom schema SDL locations and shared output directories.

---

## 📦 Installation

Add `mk_graphql` to your dependencies, and `mk_graphql_generator` and `build_runner` to your `dev_dependencies`:

```yaml
dependencies:
  mk_graphql: ^1.0.0
  freezed_annotation: ^3.1.0
  json_annotation: ^4.12.0

dev_dependencies:
  mk_graphql_generator: ^1.0.0
  build_runner: ^2.16.0
  freezed: ^4.0.1
  json_serializable: ^6.14.1
```

---

## 🚀 Usage

### 1. Define your Schema & Operations

Create `lib/schema.graphql`:

```graphql
type User {
  id: ID!
  name: String!
  avatar: String
}

type Query {
  user(id: ID!): User
}
```

Create an operation in `lib/features/user/get_user.graphql`:

```graphql
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
  }
}
```

### 2. Run Code Generation

```bash
dart run build_runner build --delete-conflicting-outputs
```

Or for development:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

### 3. Use Generated Code

```dart
import 'package:mk_graphql/mk_graphql.dart';
import 'package:my_app/features/user/generated/get_user.gql.dart';

final client = GraphQLClient(url: 'https://api.example.com/graphql');

// Using generated request:
final response = await client.future(
  GetUserReq(variables: const GetUserVars(id: '123')),
);

// Or using generated client extension method:
final userModel = await client.getUser(
  id: '123',
  cancelToken: cancelToken,
);
```

---

## ⚙️ Configuration (`build.yaml`)

You can customize the generator by configuring `build.yaml` in your project root:

```yaml
targets:
  $default:
    builders:
      mk_graphql_generator:
        options:
          # Path to your GraphQL schema (defaults to auto-detecting schema.graphql)
          schema_path: lib/api/schema.graphql
          
          # Directory where shared models, inputs, enums, and schema utilities are saved
          shared_dir: lib/shared/generated
          
          # Enable/disable two-tier generation caching (default: true)
          cache: true
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
