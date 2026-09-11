# mk_graphql

[![pub package](https://img.shields.io/pub/v/mk_graphql.svg)](https://pub.dev/packages/mk_graphql)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A clean, modern, simplified GraphQL client for Dart and Flutter with normalized caching, composable links, typed operation execution, file uploads, SSE, and WebSockets.

📖 **[Full documentation](../../docs/mk_graphql/getting-started.md)** — client API, link pipeline, caching internals, and pagination guides.

---

## ✨ Features

- 🚀 **Composable Link Architecture**: Chain `AuthLink`, `DioLink`, `SseLink`, `WebSocketLink`, `HttpLink`, `BatchLink`, and `TypenameLink`.
- 🔐 **First-Class Authentication**: Automatic 401 handling, thread-safe asynchronous token refreshing, token queueing, and revocation hooks.
- 📡 **Multiple Transports**:
  - **HTTP/REST**: Built-in `DioLink` and standard `HttpLink`.
  - **Server-Sent Events (SSE)**: `SseLink` with live subscription streaming, dynamic auth headers, and 401 refresh retries.
  - **WebSockets**: `WebSocketLink` supporting modern subscriptions.
- 📁 **Multipart File Uploads**: Seamless GraphQL Multipart Request specification compliance for `Upload` / `MultipartFile`.
- 🛑 **Request Cancellation**: Direct integration with Dio's `CancelToken`.
- 💾 **Normalized Caching**: Fast in-memory cache with configurable fetch policies (`cacheFirst`, `networkOnly`, `cacheAndNetwork`, `cacheOnly`, `noCache`).
- ⚡ **Stream & Future APIs**: Choose between single-shot `client.future()` or reactive `client.stream()`.
- 🪵 **Built-in Logging**: Pretty console logging with custom options and privacy masking.

---

## 📦 Installation

Add `mk_graphql` to your `pubspec.yaml`:

```yaml
dependencies:
  mk_graphql: ^1.0.0
```

Then run:

```bash
flutter pub get
```

---

## 🚀 Quick Start

### 1. Initialize the Client

```dart
import 'package:mk_graphql/mk_graphql.dart';

final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  tokenHeader: () async {
    final token = await getStoredToken();
    return token != null ? {'Authorization': 'Bearer $token'} : {};
  },
  onTokenRefresh: (dioLink) async {
    final newToken = await refreshUserToken();
    return newToken != null ? {'Authorization': 'Bearer $newToken'} : null;
  },
);
```

---

### 2. Execute Queries & Mutations

```dart
// Using generated or custom GraphQLRequest
final response = await client.future(myRequest);

if (response.hasErrors) {
  print('Errors: ${response.errors}');
} else {
  print('Data: ${response.data}');
}
```

---

### 3. Subscriptions (SSE or WebSockets)

For Server-Sent Events (SSE):

```dart
final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  sseUrl: 'https://api.example.com/graphql/sse',
  tokenHeader: () async => {'Authorization': 'Bearer $token'},
);

client.stream(mySubscriptionRequest).listen((response) {
  print('Real-time event: ${response.data}');
});
```

---

### 4. Multipart File Uploads

```dart
import 'package:dio/dio.dart';
import 'package:mk_graphql/mk_graphql.dart';

final file = MultipartFile.fromFileSync('/path/to/avatar.png', filename: 'avatar.png');

final uploadReq = UploadAvatarReq(
  variables: UploadAvatarVars(file: file),
);

final result = await client.future(uploadReq);
```

---

### 5. Request Cancellation with `CancelToken`

```dart
final cancelToken = CancelToken();

// Cancel after 2 seconds or when user navigates away
Future.delayed(const Duration(seconds: 2), () {
  cancelToken.cancel('User navigated away');
});

try {
  final response = await client.future(myRequest, cancelToken: cancelToken);
} on RequestCancelledException catch (e) {
  print('Request was cancelled: ${e.message}');
}
```

---

## 📚 Full Documentation

See [docs/mk_graphql](../../docs/mk_graphql/getting-started.md) for the client API, link pipeline, caching, and pagination guides — and [docs/mk_graphql_generator](../../docs/mk_graphql_generator/getting-started.md) for the code generator.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
