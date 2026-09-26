# Client Request/Caching Optimizations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `mk_graphql`'s `GraphQLClient`/`Cache` closer to TanStack Query's request/cache behavior — in-flight request dedup, stale-while-revalidate caching (stale by default) with automatic GC, query invalidation, retry-with-backoff, app-driven refetch triggers, and a `hive_ce`-backed persistent cache.

**Architecture:** Every feature is additive on top of the existing `Cache`/`GraphQLRequest`/`GraphQLClient` classes in `packages/mk_graphql/lib/src/`. A shared canonical request key (`computeRequestKey`) and a new client-side active-watcher registry (`_activeQueries`) are the two pieces of shared infrastructure everything else (dedup, GC, invalidation, refetch triggers) is built on. `HiveCache` wraps `InMemoryCache` as a write-through persistence layer rather than reimplementing normalization against Hive directly.

**Tech Stack:** Dart/Flutter, `dio`, `gql`/`gql_link`, `hive_ce` (new dependency), `flutter_test`.

**Spec:** [docs/superpowers/specs/2026-09-17-client-caching-optimizations-design.md](../specs/2026-09-17-client-caching-optimizations-design.md)

## Global Constraints

- All new client/request fields default to values that either preserve existing behavior (`defaultCacheTime: null` = no GC) or are explicitly called out as an intentional behavior change (`defaultStaleTime: Duration.zero` — cacheFirst now always background-revalidates; approved by user 2026-09-17).
- Dedup and default auto-retry apply to queries and subscriptions only, never mutations, unless a request explicitly sets `retry` on a mutation.
- No new abstract `Cache`/`GraphQLRequest` method may break existing implementers without a corresponding update in this plan — every existing subclass (test fixtures, `CompositeGraphQLRequest`, the generator's `freezedRequestClass`) must be updated in the same task that changes the base class.
- Every task ends green: `flutter test packages/mk_graphql` (and `dart test packages/mk_graphql_generator` for generator tasks) must pass before moving to the next task.

---

## Task 1: Shared request key + `Cache` interface additions (`writtenAt`, `matchingQueryKeys`)

**Files:**
- Create: `packages/mk_graphql/lib/src/core/request_key.dart`
- Modify: `packages/mk_graphql/lib/src/cache/cache.dart`
- Modify: `packages/mk_graphql/lib/src/cache/in_memory_cache.dart`
- Modify: `packages/mk_graphql/lib/mk_graphql.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Produces: `String computeRequestKey(GraphQLRequest request)` (top-level function); `Cache.writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request) → DateTime?`; `Cache.matchingQueryKeys({List<String>? operationNames, List<String>? types}) → Iterable<String>`.

- [ ] **Step 1: Write the failing tests**

Add to the `InMemoryCache Tests` group in `packages/mk_graphql/test/client_test.dart`:

```dart
    test('writtenAt is null before any write and set after writeQuery', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      expect(cache.writtenAt(req), isNull);

      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));
      final writtenAt = cache.writtenAt(req);
      expect(writtenAt, isNotNull);
      expect(DateTime.now().difference(writtenAt!).inSeconds, lessThan(5));
    });

    test('matchingQueryKeys matches by operationName and by typename', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));

      expect(
        cache.matchingQueryKeys(operationNames: ['Test']),
        isNotEmpty,
      );
      expect(
        cache.matchingQueryKeys(operationNames: ['SomethingElse']),
        isEmpty,
      );
      expect(cache.matchingQueryKeys(), isEmpty,
          reason: 'no operationNames or types given → no matches');
    });

    test('evict clears writtenAt bookkeeping for the evicted query', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));
      expect(cache.writtenAt(req), isNotNull);

      cache.evictQuery(req);
      expect(cache.writtenAt(req), isNull);
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "InMemoryCache Tests"`
Expected: FAIL — `writtenAt`/`matchingQueryKeys` are not defined on `Cache`/`InMemoryCache`.

- [ ] **Step 3: Create `request_key.dart`**

```dart
import 'dart:convert';
import 'request.dart';

/// Canonical identity for a [GraphQLRequest]: same operation, same document
/// text, and same variables (regardless of map key insertion order) all map
/// to the same key. Shared by [InMemoryCache]'s query storage keys, the
/// in-flight request dedup map, and the active-watcher registry on
/// [GraphQLClient] so all three agree on request identity.
String computeRequestKey(GraphQLRequest request) {
  final vars = request.toJsonVars(request.variables);
  final sortedVars = _canonicalJson(vars);
  return '${request.operationName}:${request.document.hashCode}:$sortedVars';
}

String _canonicalJson(dynamic value) {
  if (value is Map) {
    final sortedKeys = value.keys.map((e) => e.toString()).toList()..sort();
    final buffer = StringBuffer('{');
    for (var i = 0; i < sortedKeys.length; i++) {
      if (i > 0) buffer.write(',');
      final k = sortedKeys[i];
      buffer.write('"$k":${_canonicalJson(value[k])}');
    }
    buffer.write('}');
    return buffer.toString();
  } else if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  } else {
    return jsonEncode(value);
  }
}
```

- [ ] **Step 4: Add the two new methods to the `Cache` interface**

In `packages/mk_graphql/lib/src/cache/cache.dart`, add imports and methods:

```dart
import 'dart:async';
import '../core/request.dart';

typedef KeyGetter = String? Function(Map<String, dynamic> data);

/// Interface for normalized GraphQL cache implementations.
abstract class Cache {
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void writeQuery<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  );

  Map<String, dynamic>? readFragment({
    required String id,
    required String fragmentName,
  });

  void writeFragment({
    required String id,
    required Map<String, dynamic> data,
  });

  void evict(String key);

  /// Evicts the cached root query record corresponding to [request].
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void clear();

  Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  );

  void removeOptimistic(String requestId);

  /// When [request]'s result was last written to cache, or `null` if it has
  /// never been written (or was evicted since).
  DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request);

  /// Query keys (as tracked internally, e.g. by [computeRequestKey]) whose
  /// operation name is in [operationNames] and/or whose cached result
  /// touched a `__typename` in [types]. Returns no keys when both are
  /// omitted.
  Iterable<String> matchingQueryKeys({
    List<String>? operationNames,
    List<String>? types,
  });
}
```

- [ ] **Step 5: Update `InMemoryCache` to track timestamps/typenames and use the shared key helper**

In `packages/mk_graphql/lib/src/cache/in_memory_cache.dart`:

```dart
import 'dart:async';
import '../core/request.dart';
import '../core/request_key.dart';
import 'cache.dart';
import 'record_source.dart';

/// Normalized in-memory cache store.
class InMemoryCache implements Cache {
  final RecordSource _store = RecordSource();
  final Map<String, RecordSource> _optimisticLayers = {};
  final KeyGetter _keyGetter;

  final Map<String, DateTime> _writtenAt = {};
  final Map<String, Set<String>> _queryTypenames = {};

  final _watchers = <String, Set<StreamController<dynamic>>>{};

  InMemoryCache({KeyGetter? keyGetter})
      : _keyGetter = keyGetter ?? defaultKeyGetter;

  static String? defaultKeyGetter(Map<String, dynamic> data) {
    if (data.containsKey('__typename')) {
      final typename = data['__typename'];
      if (data.containsKey('id') && data['id'] != null) {
        return '$typename:${data['id']}';
      }
      if (data.containsKey('_id') && data['_id'] != null) {
        return '$typename:${data['_id']}';
      }
    }
    return null;
  }

  @override
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    final queryKey = 'ROOT_QUERY:${computeRequestKey(request)}';
    final rootRecord = _getRecord(queryKey);
    if (rootRecord == null) return null;

    try {
      final denormalized = _denormalize(rootRecord);
      return request.parseData(denormalized);
    } catch (_) {
      return null;
    }
  }

  @override
  void writeQuery<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    final key = computeRequestKey(request);
    final queryKey = 'ROOT_QUERY:$key';
    final json = _dataToJson(data);

    if (json is Map<String, dynamic>) {
      final normalized = _normalize(json);
      _store.set(queryKey, normalized);
      _writtenAt[key] = DateTime.now();
      _queryTypenames[key] = _collectTypenames(json);
      _notifyWatchers(request);
    }
  }

  @override
  Map<String, dynamic>? readFragment({
    required String id,
    required String fragmentName,
  }) {
    final record = _getRecord(id);
    if (record == null) return null;
    return _denormalize(record);
  }

  @override
  void writeFragment({
    required String id,
    required Map<String, dynamic> data,
  }) {
    final normalized = _normalize(data);
    _store.set(id, normalized);
  }

  @override
  void evict(String key) {
    _store.delete(key);
    if (key.startsWith('ROOT_QUERY:')) {
      final requestKey = key.substring('ROOT_QUERY:'.length);
      _writtenAt.remove(requestKey);
      _queryTypenames.remove(requestKey);
    }
  }

  @override
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    final queryKey = 'ROOT_QUERY:${computeRequestKey(request)}';
    evict(queryKey);
    _notifyWatchers(request);
  }

  @override
  void clear() {
    _store.clear();
    _optimisticLayers.clear();
    _writtenAt.clear();
    _queryTypenames.clear();
  }

  @override
  Stream<TData?> watchQuery<TData, TVars>(
      GraphQLRequest<TData, TVars> request) {
    final key = computeRequestKey(request);
    final controller = StreamController<TData?>.broadcast();

    _watchers
        .putIfAbsent(key, () => {})
        .add(controller as StreamController<dynamic>);

    controller.onCancel = () {
      _watchers[key]?.remove(controller);
      if (_watchers[key]?.isEmpty ?? false) {
        _watchers.remove(key);
      }
    };

    // Emit initial value
    final initialData = readQuery(request);
    controller.add(initialData);

    return controller.stream;
  }

  @override
  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    final layer = RecordSource();
    final queryKey = 'ROOT_QUERY:${computeRequestKey(request)}';
    final json = _dataToJson(data);

    if (json is Map<String, dynamic>) {
      final normalized = _normalize(json);
      layer.set(queryKey, normalized);
      _optimisticLayers[request.requestId] = layer;
      _notifyWatchers(request);
    }
  }

  @override
  void removeOptimistic(String requestId) {
    if (_optimisticLayers.containsKey(requestId)) {
      _optimisticLayers.remove(requestId);
    }
  }

  @override
  DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request) =>
      _writtenAt[computeRequestKey(request)];

  @override
  Iterable<String> matchingQueryKeys({
    List<String>? operationNames,
    List<String>? types,
  }) {
    if (operationNames == null && types == null) return const [];
    return _writtenAt.keys.where((key) {
      final opMatch = operationNames != null &&
          operationNames.any((name) => key.startsWith('$name:'));
      final typeMatch = types != null &&
          (_queryTypenames[key]?.any(types.contains) ?? false);
      return opMatch || typeMatch;
    }).toList();
  }

  Map<String, dynamic>? _getRecord(String key) {
    // Check optimistic layers first (most recent to oldest)
    for (final layer in _optimisticLayers.values.toList().reversed) {
      final opt = layer.get(key);
      if (opt != null) return opt;
    }
    return _store.get(key);
  }

  Map<String, dynamic> _normalize(Map<String, dynamic> json) {
    final result = <String, dynamic>{};

    json.forEach((key, value) {
      result[key] = _normalizeValue(value);
    });

    final entityKey = _keyGetter(json);
    if (entityKey != null) {
      _store.set(entityKey, result);
      return RecordSource.makeRef(entityKey);
    }

    return result;
  }

  dynamic _normalizeValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      final entityKey = _keyGetter(value);
      final normalizedMap = _normalize(value);
      if (entityKey != null) {
        return RecordSource.makeRef(entityKey);
      }
      return normalizedMap;
    } else if (value is List) {
      return value.map(_normalizeValue).toList();
    }
    return value;
  }

  dynamic _denormalize(dynamic value) {
    if (RecordSource.isRef(value)) {
      final id = RecordSource.getRefId(value);
      final refRecord = _getRecord(id);
      if (refRecord == null) return null;
      return _denormalize(refRecord);
    } else if (value is Map<String, dynamic>) {
      final map = <String, dynamic>{};
      value.forEach((k, v) {
        map[k] = _denormalize(v);
      });
      return map;
    } else if (value is List) {
      return value.map(_denormalize).toList();
    }
    return value;
  }

  dynamic _dataToJson(dynamic data) {
    if (data == null) return null;
    try {
      return (data as dynamic).toJson();
    } catch (_) {
      return data;
    }
  }

  Set<String> _collectTypenames(dynamic json) {
    final result = <String>{};
    void walk(dynamic value) {
      if (value is Map) {
        final t = value['__typename'];
        if (t is String) result.add(t);
        value.values.forEach(walk);
      } else if (value is List) {
        value.forEach(walk);
      }
    }

    walk(json);
    return result;
  }

  void _notifyWatchers(GraphQLRequest request) {
    final key = computeRequestKey(request);
    final controllers = _watchers[key];
    if (controllers != null && controllers.isNotEmpty) {
      final data = readQuery(request);
      for (final controller in controllers) {
        controller.add(data);
      }
    }
  }
}
```

Note: `_canonicalJson`/`_requestKey` are fully removed from this file — `computeRequestKey` replaces them.

- [ ] **Step 6: Export the new file from the package barrel**

In `packages/mk_graphql/lib/mk_graphql.dart`, add under the `src/core/*` export block:

```dart
export 'src/core/request_key.dart';
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS (including the pre-existing `Deterministic canonical cache key ordering for variables` test, which now exercises `computeRequestKey` indirectly through `InMemoryCache`).

- [ ] **Step 8: Commit**

```bash
git add packages/mk_graphql/lib/src/core/request_key.dart packages/mk_graphql/lib/src/cache/cache.dart packages/mk_graphql/lib/src/cache/in_memory_cache.dart packages/mk_graphql/lib/mk_graphql.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(cache): extract shared request key, add writtenAt/matchingQueryKeys to Cache"
```

---

## Task 2: `GraphQLRequest` new fields (`staleTime`, `cacheTime`, `retry`, `refetchInterval`) + `RetryOptions`

**Files:**
- Create: `packages/mk_graphql/lib/src/core/retry_options.dart`
- Modify: `packages/mk_graphql/lib/src/core/request.dart`
- Modify: `packages/mk_graphql/lib/src/client/composite_request.dart`
- Modify: `packages/mk_graphql/lib/mk_graphql.dart`
- Modify (test fixtures): `packages/mk_graphql/test/client_test.dart`, `packages/mk_graphql/test/pagination_and_refetch_test.dart`, `packages/mk_graphql/test/validation_error_test.dart`

**Interfaces:**
- Consumes: none new.
- Produces: `RetryOptions` class (`maxAttempts`, `initialDelay`, `backoffMultiplier`, `retryIf`, `RetryOptions.none`, `shouldRetry(Object error)`, `delayForAttempt(int attempt)`); four new nullable fields on `GraphQLRequest`: `staleTime`, `cacheTime`, `retry`, `refetchInterval` — consumed by Tasks 4–8.

- [ ] **Step 1: Create `retry_options.dart`**

```dart
import 'error.dart';

/// Configures automatic retry-with-backoff for a query/subscription (and,
/// when explicitly set on the request, a mutation) on transient network
/// failures.
class RetryOptions {
  /// Total attempts including the first — `1` means "no retry".
  final int maxAttempts;

  /// Delay before the first retry (attempt 2). Subsequent retries multiply
  /// this by [backoffMultiplier] for each additional attempt.
  final Duration initialDelay;

  final double backoffMultiplier;

  /// Overrides the default transient-failure classification. Receives the
  /// mapped [GraphQLException] (via [GraphQLExceptionExtension]) for the
  /// failed attempt.
  final bool Function(Object error)? retryIf;

  const RetryOptions({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.backoffMultiplier = 2.0,
    this.retryIf,
  });

  /// A single attempt, no retry — pass this to a request to opt a query out
  /// of the client's `defaultRetry`.
  static const RetryOptions none = RetryOptions(maxAttempts: 1);

  bool shouldRetry(Object error) {
    if (retryIf != null) return retryIf!(error);
    return error is NetworkException || error is TimeoutException;
  }

  Duration delayForAttempt(int attempt) {
    if (attempt <= 1) return initialDelay;
    var multiplier = 1.0;
    for (var i = 1; i < attempt; i++) {
      multiplier *= backoffMultiplier;
    }
    return Duration(
        milliseconds: (initialDelay.inMilliseconds * multiplier).round());
  }
}
```

- [ ] **Step 2: Add the four new fields to `GraphQLRequest`**

In `packages/mk_graphql/lib/src/core/request.dart`, add the import and fields/constructor params:

```dart
import 'package:dio/dio.dart';
import 'package:gql/ast.dart';
import 'document_cache.dart';
import 'error_policy.dart';
import 'fetch_policy.dart';
import 'retry_options.dart';

/// Represents an immutable typed GraphQL request.
///
/// Extend this class to define a specific operation. The code generator
/// produces concrete subclasses automatically from `.graphql`/`.gql` files.
abstract class GraphQLRequest<TData, TVars> {
  // ---- Abstract interface ---------------------------------------------------

  String get document;

  DocumentNode get documentNode => getParsedDocument(document);

  String get operationName;

  TVars get variables;

  Map<String, dynamic> toJsonVars(TVars vars);

  TData parseData(Map<String, dynamic> json);

  // ---- Optional per-request knobs ------------------------------------------

  final FetchPolicy? fetchPolicy;

  final ErrorPolicy? errorPolicy;

  final Map<String, String>? headers;

  final TData? optimisticResponse;

  final CancelToken? cancelToken;

  /// Overrides [GraphQLClient.defaultStaleTime] for this request. Governs
  /// how long cached data returned by [FetchPolicy.cacheFirst] is
  /// considered fresh before a background network revalidation is
  /// triggered — an active [GraphQLClient.watchQuery] subscription also
  /// revalidates immediately on attach when the cached value is already
  /// stale.
  final Duration? staleTime;

  /// Overrides [GraphQLClient.defaultCacheTime]. How long this query's
  /// cache entry survives after its last active [GraphQLClient.watchQuery]
  /// subscriber cancels, before being garbage-collected. `null` (the
  /// default) means "never garbage-collect".
  final Duration? cacheTime;

  /// Overrides [GraphQLClient.defaultRetry]. `null` uses the client default
  /// (queries/subscriptions retry automatically, mutations never do); pass
  /// [RetryOptions.none] to disable retry, or a [RetryOptions] to opt a
  /// mutation into retry.
  final RetryOptions? retry;

  /// While this request has an active [GraphQLClient.watchQuery]
  /// subscriber, triggers a background network refetch every
  /// [refetchInterval]. `null` (the default) disables interval polling.
  final Duration? refetchInterval;

  final String? _requestId;

  String get requestId => _requestId ?? identityHashCode(this).toString();

  const GraphQLRequest({
    this.fetchPolicy,
    this.errorPolicy,
    this.headers,
    this.optimisticResponse,
    this.cancelToken,
    this.staleTime,
    this.cacheTime,
    this.retry,
    this.refetchInterval,
    String? requestId,
  }) : _requestId = requestId;

  GraphQLRequest<TData, TVars> copyWithRequest({
    TVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    TData? optimisticResponse,
  });

  GraphQLRequest<TData, TVars> copyWithFetchPolicy(FetchPolicy policy) =>
      copyWithRequest(fetchPolicy: policy);

  GraphQLRequest<TData, TVars> copyWithErrorPolicy(ErrorPolicy policy) =>
      copyWithRequest(errorPolicy: policy);
}
```

(`copyWithRequest`'s parameter list is unchanged — the four new fields follow the same pattern as `requestId`: settable at construction, preserved by every `copyWithRequest` override via `this.<field>`, not independently overridable through `copyWithRequest`.)

- [ ] **Step 3: Update every existing `GraphQLRequest` subclass to thread the new fields through**

In `packages/mk_graphql/test/client_test.dart`, update `_TestReq`:

```dart
class _TestReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestReq(
    this.variables, {
    super.requestId,
    super.cancelToken,
    super.fetchPolicy,
    super.errorPolicy,
    super.headers,
    super.optimisticResponse,
    super.staleTime,
    super.cacheTime,
    super.retry,
    super.refetchInterval,
  });

  @override
  String get document => 'query Test { user { id name } }';

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _TestReq(
        variables ?? this.variables,
        fetchPolicy: fetchPolicy ?? this.fetchPolicy,
        errorPolicy: errorPolicy ?? this.errorPolicy,
        headers: headers ?? this.headers,
        cancelToken: cancelToken ?? this.cancelToken,
        optimisticResponse: optimisticResponse ?? this.optimisticResponse,
        requestId: requestId,
        staleTime: staleTime,
        cacheTime: cacheTime,
        retry: retry,
        refetchInterval: refetchInterval,
      );
}
```

Update `_PreparsedDocReq.copyWithRequest` in the same file (it ignores most override params already, so it only needs its constructor call left as-is — it has no named constructor params to add since it takes only `variables`, and preserving `staleTime`/etc. isn't meaningful for this throwaway fixture used purely to test document-identity, not policy fields):

```dart
  @override
  _PreparsedDocReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _PreparsedDocReq(variables ?? this.variables);
```
(No change needed — left as documentation that this fixture intentionally doesn't carry these fields.)

Update `_CustomVarsReq` (same file) constructor and `copyWithRequest`:

```dart
class _CustomVarsReq extends GraphQLRequest<_TestData, Map<String, dynamic>> {
  @override
  final Map<String, dynamic> variables;

  _CustomVarsReq(this.variables, {super.fetchPolicy, super.errorPolicy});

  @override
  String get document => 'query TestCustom { user { id name } }';

  @override
  String get operationName => 'TestCustom';

  @override
  Map<String, dynamic> toJsonVars(Map<String, dynamic> vars) => vars;

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _CustomVarsReq copyWithRequest({
    Map<String, dynamic>? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _CustomVarsReq(
        variables ?? this.variables,
        fetchPolicy: fetchPolicy ?? this.fetchPolicy,
        errorPolicy: errorPolicy ?? this.errorPolicy,
      );
}
```
(Unchanged — this fixture never sets the new fields, so there's nothing to preserve.)

In `packages/mk_graphql/test/pagination_and_refetch_test.dart`, update `_PageReq`:

```dart
class _PageReq extends GraphQLRequest<_PageData, _PageVars> {
  @override
  final _PageVars variables;

  _PageReq(
    this.variables, {
    super.fetchPolicy,
    super.errorPolicy,
    super.requestId,
    super.cancelToken,
    super.headers,
    super.optimisticResponse,
    super.staleTime,
    super.cacheTime,
    super.retry,
    super.refetchInterval,
  });

  @override
  String get document =>
      'query GetItems(\$offset: Int, \$limit: Int) { items }';

  @override
  String get operationName => 'GetItems';

  @override
  Map<String, dynamic> toJsonVars(_PageVars vars) => vars.toJson();

  @override
  _PageData parseData(Map<String, dynamic> json) => _PageData.fromJson(json);

  @override
  _PageReq copyWithRequest({
    _PageVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _PageData? optimisticResponse,
  }) {
    return _PageReq(
      variables ?? this.variables,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
      errorPolicy: errorPolicy ?? this.errorPolicy,
      headers: headers ?? this.headers,
      cancelToken: cancelToken ?? this.cancelToken,
      optimisticResponse: optimisticResponse ?? this.optimisticResponse,
      requestId: requestId,
      staleTime: staleTime,
      cacheTime: cacheTime,
      retry: retry,
      refetchInterval: refetchInterval,
    );
  }
}
```

`packages/mk_graphql/test/validation_error_test.dart`'s `_TestReq` (lines 20-52) only ever sets `fetchPolicy` (its constructor doesn't even accept `headers`/`cancelToken`/`optimisticResponse`/`requestId`) and its `copyWithRequest` only forwards `fetchPolicy`:

```dart
class _TestReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestReq(this.variables, {super.fetchPolicy});

  @override
  String get document =>
      'mutation CreateUser(\$email: String!) { createUser(email: \$email) { id } }';

  @override
  String get operationName => 'CreateUser';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) {
    return _TestReq(
      variables ?? this.variables,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
    );
  }
}
```
No change needed here — since this fixture never sets `staleTime`/`cacheTime`/`retry`/`refetchInterval` (they're absent from its constructor entirely, so always `null` on every instance), there is nothing for its `copyWithRequest` to lose or preserve. Leave the file as-is.

- [ ] **Step 4: Update `CompositeGraphQLRequest`**

In `packages/mk_graphql/lib/src/client/composite_request.dart`:

```dart
import 'package:dio/dio.dart';
import '../core/error_policy.dart';
import '../core/fetch_policy.dart';
import '../core/request.dart';
import '../core/retry_options.dart';

/// Combines multiple [GraphQLRequest] instances into a single composed request.
///
/// Useful for batching several operations into one network round-trip when
/// used with [BatchLink].
class CompositeGraphQLRequest
    extends GraphQLRequest<Map<String, dynamic>, Map<String, dynamic>> {
  final List<GraphQLRequest> requests;

  CompositeGraphQLRequest(
    this.requests, {
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    Duration? staleTime,
    Duration? cacheTime,
    RetryOptions? retry,
    Duration? refetchInterval,
  }) : super(
          fetchPolicy: fetchPolicy,
          errorPolicy: errorPolicy,
          headers: headers,
          staleTime: staleTime,
          cacheTime: cacheTime,
          retry: retry,
          refetchInterval: refetchInterval,
          requestId: requests.map((r) => r.requestId).join('_'),
        );

  @override
  String get document => requests.map((r) => r.document).join('\n');

  @override
  String get operationName => requests.map((r) => r.operationName).join('_');

  @override
  Map<String, dynamic> get variables => {
        for (final r in requests) r.operationName: r.toJsonVars(r.variables),
      };

  @override
  Map<String, dynamic> toJsonVars(Map<String, dynamic> vars) => vars;

  @override
  Map<String, dynamic> parseData(Map<String, dynamic> json) => {
        for (final r in requests)
          r.operationName: r.parseData(
            json.containsKey(r.operationName)
                ? json[r.operationName] as Map<String, dynamic>
                : json,
          ),
      };

  @override
  CompositeGraphQLRequest copyWithRequest({
    Map<String, dynamic>? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    Map<String, dynamic>? optimisticResponse,
  }) {
    return CompositeGraphQLRequest(
      requests,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
      errorPolicy: errorPolicy ?? this.errorPolicy,
      headers: headers ?? this.headers,
      staleTime: staleTime,
      cacheTime: cacheTime,
      retry: retry,
      refetchInterval: refetchInterval,
    );
  }
}
```

- [ ] **Step 5: Export `RetryOptions`**

In `packages/mk_graphql/lib/mk_graphql.dart`, add:

```dart
export 'src/core/retry_options.dart';
```

- [ ] **Step 6: Run the full test suite to verify nothing broke**

Run: `flutter test packages/mk_graphql`
Expected: PASS — this task only adds optional fields and threads them through; no behavior changes yet.

- [ ] **Step 7: Commit**

```bash
git add packages/mk_graphql/lib/src/core/retry_options.dart packages/mk_graphql/lib/src/core/request.dart packages/mk_graphql/lib/src/client/composite_request.dart packages/mk_graphql/lib/mk_graphql.dart packages/mk_graphql/test/client_test.dart packages/mk_graphql/test/pagination_and_refetch_test.dart packages/mk_graphql/test/validation_error_test.dart
git commit -m "feat(core): add staleTime/cacheTime/retry/refetchInterval to GraphQLRequest"
```

---

## Task 3: Request deduplication (queries/subscriptions only)

**Files:**
- Modify: `packages/mk_graphql/lib/src/client/client.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `computeRequestKey` (Task 1).
- Produces: private `GraphQLClient._requestThroughPipeline(GraphQLRequest req, gql.Request gqlReq, {required bool skipDedup}) → Stream<gql.Response>`, replacing the direct `_pipeline.request(gqlReq)` call inside `_executeNetworkRequest`.

- [ ] **Step 1: Write the failing test**

Add to the `GraphQLClient` group in `packages/mk_graphql/test/client_test.dart`:

```dart
    test(
        'deduplicates concurrent identical queries into a single network call',
        () async {
      var callCount = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        callCount++;
      }));

      final results = await Future.wait([
        for (var i = 0; i < 5; i++) client.future(_TestReq(const _TestVars('1'))),
      ]);

      expect(callCount, equals(1),
          reason: 'identical concurrent queries must share one network call');
      expect(results, hasLength(5));
    });

    test('mutations are never deduplicated, even with identical variables',
        () async {
      var callCount = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        callCount++;
      }));

      await Future.wait([
        for (var i = 0; i < 3; i++)
          client.future(_TestMutationReq(const _TestVars('1'))),
      ]);

      expect(callCount, equals(3),
          reason: 'mutations must each hit the network independently');
    });

    test('a request with an explicit cancelToken is never deduplicated',
        () async {
      var callCount = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        callCount++;
      }));

      await Future.wait([
        client.future(_TestReq(const _TestVars('1'),
            cancelToken: CancelToken())),
        client.future(_TestReq(const _TestVars('1'),
            cancelToken: CancelToken())),
      ]);

      expect(callCount, equals(2));
    });
```

Add the supporting test doubles near `_CapturingLink` in the same file:

```dart
class _CountingLink extends Link {
  final void Function() onRequest;
  _CountingLink(this.onRequest);

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    onRequest();
    yield const gql.Response(data: {'id': '1', 'name': 'Dedup'}, response: {});
  }
}
```

Add a mutation variant of `_TestReq` (dedup must not apply to it) right after `_TestReq`:

```dart
class _TestMutationReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestMutationReq(this.variables);

  @override
  String get document => 'mutation Test { user { id name } }';

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestMutationReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _TestMutationReq(variables ?? this.variables);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "deduplicates|never deduplicated|explicit cancelToken"`
Expected: FAIL — `callCount` is `5`/`3` respectively (each call currently hits the network), and the third test currently passes already but is captured here for regression coverage once dedup exists.

- [ ] **Step 3: Add the dedup map and helper to `GraphQLClient`**

In `packages/mk_graphql/lib/src/client/client.dart`, add a field near `_pipeline`:

```dart
  final Link _pipeline;
  final Cache cache;
  final FetchPolicy defaultFetchPolicy;
  final ErrorPolicy defaultErrorPolicy;
  final LoggerOptions loggerOptions;

  /// In-flight query/subscription network calls keyed by [computeRequestKey]
  /// — concurrent identical calls share one entry instead of each starting
  /// a separate pipeline request. Mutations and any request with an
  /// explicit [CancelToken] are never entered here (see
  /// [_requestThroughPipeline]).
  final Map<String, Stream<gql.Response>> _inFlight = {};
```

Add `import '../core/request_key.dart';` alongside the other core imports.

Add the helper method and the `_isMutation` classifier near `_isSubscription`:

```dart
  static bool _isSubscription(gql.Request req) {
    final defs =
        req.operation.document.definitions.whereType<OperationDefinitionNode>();
    if (req.operation.operationName != null) {
      final match =
          defs.where((d) => d.name?.value == req.operation.operationName);
      if (match.isNotEmpty) {
        return match.first.type == OperationType.subscription;
      }
    }
    return defs.any((d) => d.type == OperationType.subscription);
  }

  static bool _isMutation(gql.Request req) {
    final defs =
        req.operation.document.definitions.whereType<OperationDefinitionNode>();
    if (req.operation.operationName != null) {
      final match =
          defs.where((d) => d.name?.value == req.operation.operationName);
      if (match.isNotEmpty) {
        return match.first.type == OperationType.mutation;
      }
    }
    return defs.any((d) => d.type == OperationType.mutation);
  }

  /// Routes [gqlReq] through [_pipeline], deduplicating concurrent identical
  /// queries/subscriptions (never mutations, never a request carrying an
  /// explicit [CancelToken] — see [_inFlight]'s doc comment) via
  /// [_inFlight].
  Stream<gql.Response> _requestThroughPipeline(
    GraphQLRequest req,
    gql.Request gqlReq, {
    required bool skipDedup,
  }) {
    if (skipDedup || _isMutation(gqlReq)) {
      return _pipeline.request(gqlReq);
    }

    final key = computeRequestKey(req);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final controller = StreamController<gql.Response>.broadcast();
    _inFlight[key] = controller.stream;

    _pipeline.request(gqlReq).listen(
      controller.add,
      onError: (Object e, StackTrace st) {
        _inFlight.remove(key);
        controller.addError(e, st);
      },
      onDone: () {
        _inFlight.remove(key);
        controller.close();
      },
    );

    return controller.stream;
  }
```

- [ ] **Step 4: Wire it into `_executeNetworkRequest`**

Replace the `await for (final res in _pipeline.request(gqlReq))` line inside `_executeNetworkRequest` (in the same file):

```dart
      final gqlReq = gql.Request(
        operation: gql.Operation(
          document: req.documentNode,
          operationName: req.operationName,
        ),
        variables:
            req.variables != null ? req.toJsonVars(req.variables) : const {},
        context: context,
      );

      await for (final res in _requestThroughPipeline(
        req,
        gqlReq,
        skipDedup: effectiveCancelToken != null,
      )) {
        yield GraphQLResponse<TData>(
          data: res.data != null ? req.parseData(res.data!) : null,
          errors: mapGraphQLErrors(res.errors),
          source: ResponseSource.network,
        );
      }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(client): deduplicate concurrent identical query network calls"
```

---

## Task 4: Retry with backoff

**Files:**
- Modify: `packages/mk_graphql/lib/src/client/client.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `RetryOptions` (Task 2), `_requestThroughPipeline` (Task 3), `_isMutation` (Task 3).
- Produces: `GraphQLClient.defaultRetry` (`RetryOptions?`, constructor param, default `null`); retry loop inside `_executeNetworkRequest`.

- [ ] **Step 1: Add `defaultStaleTime`/`defaultCacheTime`/`defaultRetry` fields to `GraphQLClient` and thread them through both constructors**

In `packages/mk_graphql/lib/src/client/client.dart`, add the field declarations next to the existing ones:

```dart
  final FetchPolicy defaultFetchPolicy;
  final ErrorPolicy defaultErrorPolicy;
  final LoggerOptions loggerOptions;
  final Duration defaultStaleTime;
  final Duration? defaultCacheTime;
  final RetryOptions? defaultRetry;
```

Add `import '../core/retry_options.dart';` near the other core imports.

Update the private constructor `GraphQLClient._` to accept and assign them:

```dart
  GraphQLClient._({
    required this.cache,
    required this.defaultFetchPolicy,
    required this.defaultErrorPolicy,
    required this.loggerOptions,
    required this.defaultStaleTime,
    required this.defaultCacheTime,
    required this.defaultRetry,
    required Dio? ownedDio,
    required Link pipeline,
  })  : _ownedDio = ownedDio,
        _pipeline = pipeline;
```

Update the public factory `GraphQLClient({...})` to accept the three new named parameters (with `defaultStaleTime` defaulting to `Duration.zero` per the spec's behavior change) and pass them into `GraphQLClient._(...)`:

```dart
    /// Fetch policy for the client
    FetchPolicy defaultFetchPolicy = FetchPolicy.noCache,

    /// Error policy for the client
    ErrorPolicy defaultErrorPolicy = ErrorPolicy.none,

    /// How long cached data is considered fresh before FetchPolicy.cacheFirst
    /// triggers a background revalidation, and before an active watchQuery
    /// subscription revalidates on attach. Defaults to Duration.zero (always
    /// stale — every cacheFirst hit background-refetches, matching TanStack
    /// Query's default). Override per-request via GraphQLRequest.staleTime.
    Duration defaultStaleTime = Duration.zero,

    /// How long a query's cache entry survives after its last active
    /// watchQuery subscriber cancels before being garbage-collected. Null
    /// (the default) disables GC entirely — matches today's behavior.
    /// Override per-request via GraphQLRequest.cacheTime.
    Duration? defaultCacheTime,

    /// Automatic retry-with-backoff for queries/subscriptions on transient
    /// network failures. Null (the default) disables auto-retry. Mutations
    /// never use this — a mutation only retries if it sets its own
    /// GraphQLRequest.retry.
    RetryOptions? defaultRetry,

    /// Logger Options
    LoggerOptions loggerOptions = const LoggerOptions(),
  }) {
```
and in the `return GraphQLClient._(...)` call:
```dart
    return GraphQLClient._(
      cache: cache ?? InMemoryCache(),
      defaultFetchPolicy: defaultFetchPolicy,
      defaultErrorPolicy: defaultErrorPolicy,
      defaultStaleTime: defaultStaleTime,
      defaultCacheTime: defaultCacheTime,
      defaultRetry: defaultRetry,
      loggerOptions: loggerOptions,
      ownedDio: dio == null ? dioInstance : null,
      pipeline: _buildPipeline(...),
    );
```
(`...` stands for the existing, unchanged `_buildPipeline(...)` argument list already in the file — do not remove any of its existing arguments.)

Also update `GraphQLClient.fromLink` to accept and forward the same three fields:

```dart
  GraphQLClient.fromLink(
    Link link, {
    Cache? cache,
    this.defaultFetchPolicy = FetchPolicy.noCache,
    this.defaultErrorPolicy = ErrorPolicy.none,
    this.loggerOptions = const LoggerOptions(),
    this.defaultStaleTime = Duration.zero,
    this.defaultCacheTime,
    this.defaultRetry,
  })  : cache = cache ?? InMemoryCache(),
        _ownedDio = null,
        _pipeline = link;
```

- [ ] **Step 2: Run the existing suite to confirm this compiles cleanly with no behavior change yet**

Run: `flutter test packages/mk_graphql`
Expected: PASS — these are new fields with defaults; nothing calls into retry/staleTime logic yet (Tasks 4's retry loop and Task 5's `cacheFirst` change come next).

- [ ] **Step 3: Write the failing tests**

Add to the `GraphQLClient` group in `packages/mk_graphql/test/client_test.dart`:

```dart
    test('retries a query on NetworkException up to maxAttempts, then succeeds',
        () async {
      var attempts = 0;
      final client = GraphQLClient.fromLink(
        _FlakyLink(failTimes: 2, onAttempt: () => attempts++),
        defaultRetry: const RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 1),
        ),
      );

      final result = await client.future(_TestReq(const _TestVars('1')));
      expect(attempts, equals(3));
      expect(result.name, equals('Recovered'));
    });

    test('exhausts retries and surfaces the final failure', () async {
      var attempts = 0;
      final client = GraphQLClient.fromLink(
        _FlakyLink(failTimes: 10, onAttempt: () => attempts++),
        defaultRetry: const RetryOptions(
          maxAttempts: 2,
          initialDelay: Duration(milliseconds: 1),
        ),
      );

      await expectLater(
        client.future(_TestReq(const _TestVars('1'))),
        throwsA(isA<NetworkException>()),
      );
      expect(attempts, equals(2));
    });

    test('mutations never auto-retry by default, even with defaultRetry set',
        () async {
      var attempts = 0;
      final client = GraphQLClient.fromLink(
        _FlakyLink(failTimes: 10, onAttempt: () => attempts++),
        defaultRetry: const RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 1),
        ),
      );

      await expectLater(
        client.future(_TestMutationReq(const _TestVars('1'))),
        throwsA(isA<NetworkException>()),
      );
      expect(attempts, equals(1));
    });
```

Add the supporting fake link near `_ServerExceptionOnceLink`:

```dart
/// Throws a [NetworkException]-mapping [DioException] the first [failTimes]
/// calls, then succeeds.
class _FlakyLink extends Link {
  final int failTimes;
  final void Function() onAttempt;
  int _calls = 0;
  _FlakyLink({required this.failTimes, required this.onAttempt});

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    onAttempt();
    _calls++;
    if (_calls <= failTimes) {
      throw dio.DioException(
        requestOptions: dio.RequestOptions(path: '/graphql'),
        type: dio.DioExceptionType.connectionError,
      );
    }
    yield const gql.Response(
        data: {'id': '1', 'name': 'Recovered'}, response: {});
  }
}
```

These tests call `GraphQLClient.fromLink(...)` with a `defaultRetry:` argument, which Step 1 already added support for.

- [ ] **Step 4: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "retries a query|exhausts retries|mutations never auto-retry"`
Expected: FAIL — `_executeNetworkRequest` has no retry loop yet, so `_FlakyLink`'s thrown exception propagates immediately after one attempt.

- [ ] **Step 5: Add the retry loop to `_executeNetworkRequest`**

Replace the whole method body in `packages/mk_graphql/lib/src/client/client.dart`:

```dart
  Stream<GraphQLResponse<TData>> _executeNetworkRequest<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) async* {
    final effectiveCancelToken = cancelToken ?? req.cancelToken;
    var context = gql.Context().withEntry(
      gql.HttpLinkHeaders(headers: req.headers ?? {}),
    );
    if (effectiveCancelToken != null) {
      context = context.withEntry(
        DioLinkCancelTokenContextEntry(effectiveCancelToken),
      );
    }

    final gqlReq = gql.Request(
      operation: gql.Operation(
        document: req.documentNode,
        operationName: req.operationName,
      ),
      variables:
          req.variables != null ? req.toJsonVars(req.variables) : const {},
      context: context,
    );

    final retryOptions =
        req.retry ?? (_isMutation(gqlReq) ? null : defaultRetry);

    var attempt = 1;
    while (true) {
      try {
        await for (final res in _requestThroughPipeline(
          req,
          gqlReq,
          skipDedup: effectiveCancelToken != null,
        )) {
          yield GraphQLResponse<TData>(
            data: res.data != null ? req.parseData(res.data!) : null,
            errors: mapGraphQLErrors(res.errors),
            source: ResponseSource.network,
          );
        }
        return;
      } catch (e) {
        final mapped = GraphQLExceptionExtension.fromLinkException(e);
        final canRetry = retryOptions != null &&
            attempt < retryOptions.maxAttempts &&
            retryOptions.shouldRetry(mapped);
        if (!canRetry) {
          yield GraphQLResponse<TData>(
            linkException: mapped,
            source: ResponseSource.network,
          );
          return;
        }
        await Future<void>.delayed(retryOptions.delayForAttempt(attempt));
        attempt++;
      }
    }
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(client): add retry-with-backoff for queries/subscriptions"
```

---

## Task 5: Stale-while-revalidate in `cacheFirst`

**Files:**
- Modify: `packages/mk_graphql/lib/src/client/client.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `cache.writtenAt` (Task 1), `req.staleTime`/`defaultStaleTime` (Tasks 2/4).
- Produces: updated `cacheFirst` branch of `GraphQLClient.request()`.

- [ ] **Step 1: Write the failing tests**

Add a new group to `packages/mk_graphql/test/client_test.dart`:

```dart
  group('Stale-while-revalidate (cacheFirst)', () {
    test(
        'default staleTime (Duration.zero): a cache hit emits cached data '
        'immediately and also background-refetches', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst);

      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final responses = await client.request(req).toList();
      expect(responses.first.data?.name, equals('Cached'));
      expect(responses.first.source, equals(ResponseSource.cache));
      expect(responses.first.loading, isTrue,
          reason: 'default staleTime means the cache hit is always stale');
      expect(networkCalls, equals(1),
          reason: 'stale cache hit must trigger a background network refetch');
    });

    test('explicit staleTime, still fresh: no network call at all', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst,
          staleTime: const Duration(minutes: 5));

      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final responses = await client.request(req).toList();
      expect(responses, hasLength(1));
      expect(responses.single.loading, isFalse);
      expect(networkCalls, equals(0));
    });

    test('explicit staleTime, expired: cache emission then network emission',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst,
          staleTime: const Duration(milliseconds: 1));

      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final responses = await client.request(req).toList();
      expect(responses, hasLength(2));
      expect(responses[0].source, equals(ResponseSource.cache));
      expect(responses[0].loading, isTrue);
      expect(responses[1].source, equals(ResponseSource.network));
      expect(networkCalls, equals(1));
    });

    test('cache miss always fetches from network regardless of staleTime',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst,
          staleTime: const Duration(minutes: 5));

      final responses = await client.request(req).toList();
      expect(responses, hasLength(1));
      expect(responses.single.source, equals(ResponseSource.network));
      expect(networkCalls, equals(1));
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "Stale-while-revalidate"`
Expected: FAIL — `cacheFirst` currently never background-refetches on a cache hit.

- [ ] **Step 3: Update the `cacheFirst` branch in `request()`**

In `packages/mk_graphql/lib/src/client/client.dart`, replace the `case FetchPolicy.cacheFirst:` branch inside `request()`:

```dart
      case FetchPolicy.cacheFirst:
        final cached = cache.readQuery(req);
        if (cached == null) {
          yield* _fetchFromNetwork(req, cancelToken: cancelToken);
          break;
        }
        final staleTime = req.staleTime ?? defaultStaleTime;
        final writtenAt = cache.writtenAt(req);
        final isFresh = writtenAt != null &&
            DateTime.now().difference(writtenAt) < staleTime;
        yield GraphQLResponse<TData>(
          data: cached,
          source: ResponseSource.cache,
          loading: !isFresh,
        );
        if (isFresh) break;
        yield* _fetchFromNetwork(req, cancelToken: cancelToken);
        break;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(client): cacheFirst background-revalidates by default (staleTime: 0)"
```

---

## Task 6: Active-watcher registry, `watchQuery` rewrite, `cacheTime` GC, `refetchInterval`

**Files:**
- Modify: `packages/mk_graphql/lib/src/client/client.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `computeRequestKey`, `cache.writtenAt`, `cache.evictQuery`, `req.cacheTime`/`defaultCacheTime`, `req.refetchInterval`, `req.staleTime`/`defaultStaleTime`.
- Produces: private `GraphQLClient._activeQueries` registry + `_ActiveQuery`; private `Future<void> _backgroundRefetch<TData, TVars>(GraphQLRequest<TData, TVars> req)`; rewritten `watchQuery` (same public signature: `Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> req)`) — consumed by Tasks 7 and 8.

- [ ] **Step 1: Write the failing tests**

Add a new group to `packages/mk_graphql/test/client_test.dart`:

```dart
  group('watchQuery: staleness, GC, refetchInterval', () {
    test('watchQuery triggers a background refetch on attach when stale',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Old'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(networkCalls, equals(1),
          reason: 'default staleTime is zero, so attaching a watcher to '
              'already-cached data must background-refetch it');
      await sub.cancel();
    });

    test(
        'watchQuery does not refetch on attach when staleTime keeps the '
        'cached value fresh', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Fresh'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(networkCalls, equals(0));
      await sub.cancel();
    });

    test(
        'cacheTime evicts the cache entry after the last watcher cancels, '
        'once the timer elapses', () async {
      final client = GraphQLClient.fromLink(_CountingLink(() {}));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          cacheTime: const Duration(milliseconds: 20));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(client.cache.readQuery(req), isNotNull,
          reason: 'not evicted yet — cacheTime has not elapsed');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(client.cache.readQuery(req), isNull);
    });

    test('a resubscribe before cacheTime elapses cancels the pending GC',
        () async {
      final client = GraphQLClient.fromLink(_CountingLink(() {}));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          cacheTime: const Duration(milliseconds: 20));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub1 = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub1.cancel();

      final sub2 = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(client.cache.readQuery(req), isNotNull,
          reason: 'resubscribing before the GC timer fired must cancel it');
      await sub2.cancel();
    });

    test('refetchInterval refetches on schedule and stops after cancel',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          refetchInterval: const Duration(milliseconds: 15));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      final callsAtCancel = networkCalls;

      expect(callsAtCancel, greaterThanOrEqualTo(2));

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(networkCalls, equals(callsAtCancel),
          reason: 'the interval timer must stop once the watcher cancels');
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "watchQuery: staleness"`
Expected: FAIL — `watchQuery` currently just delegates to `cache.watchQuery` with no orchestration.

- [ ] **Step 3: Add the registry and rewrite `watchQuery`**

In `packages/mk_graphql/lib/src/client/client.dart`, add near the `_inFlight` field:

```dart
  /// Tracks queries with at least one active [watchQuery] subscriber —
  /// shared by staleness-on-attach, `cacheTime` GC, `refetchInterval`
  /// polling, [invalidateQueries], and [notifyReconnected]/
  /// [notifyAppResumed].
  final Map<String, _ActiveQuery> _activeQueries = {};
```

Add the `_ActiveQuery` class at the bottom of the file, alongside the other top-level helpers:

```dart
class _ActiveQuery {
  _ActiveQuery(this.latestRequest);
  GraphQLRequest latestRequest;
  int refCount = 0;
  Timer? gcTimer;
  Timer? refetchIntervalTimer;
}
```

Replace the existing `watchQuery` method:

```dart
  /// Watches query cache reactively. Also orchestrates the client-driven
  /// behaviors that only make sense for an *active* subscriber: a
  /// background revalidation on attach when the cached value is already
  /// stale, `refetchInterval` polling while subscribed, and `cacheTime`
  /// garbage collection once the last subscriber cancels.
  Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> req) {
    final key = computeRequestKey(req);
    final active = _activeQueries.putIfAbsent(key, () => _ActiveQuery(req));
    active.latestRequest = req;

    StreamSubscription<TData?>? cacheSub;
    late StreamController<TData?> controller;

    controller = StreamController<TData?>.broadcast(
      onListen: () {
        active.refCount++;
        active.gcTimer?.cancel();
        active.gcTimer = null;

        cacheSub = cache.watchQuery(req).listen(controller.add);

        final staleTime = req.staleTime ?? defaultStaleTime;
        final writtenAt = cache.writtenAt(req);
        final isStale = writtenAt == null ||
            DateTime.now().difference(writtenAt) >= staleTime;
        if (isStale) {
          unawaited(_backgroundRefetch(req));
        }

        final interval = req.refetchInterval;
        if (interval != null) {
          active.refetchIntervalTimer = Timer.periodic(
              interval, (_) => unawaited(_backgroundRefetch(req)));
        }
      },
      onCancel: () async {
        await cacheSub?.cancel();
        active.refCount--;
        active.refetchIntervalTimer?.cancel();
        active.refetchIntervalTimer = null;

        if (active.refCount <= 0) {
          final cacheTime = req.cacheTime ?? defaultCacheTime;
          if (cacheTime != null) {
            active.gcTimer = Timer(cacheTime, () {
              _activeQueries.remove(key);
              cache.evictQuery(active.latestRequest);
            });
          } else {
            _activeQueries.remove(key);
          }
        }
      },
    );

    return controller.stream;
  }

  /// Runs [req] as a `networkOnly` fetch purely to refresh the cache — used
  /// by staleness-on-attach, `refetchInterval`, [invalidateQueries], and
  /// [notifyReconnected]/[notifyAppResumed]. Failures are swallowed: none
  /// of those callers initiated this fetch directly, so there is no
  /// `Future` of theirs to fail — the cache simply keeps its last-good
  /// value and any active `watchQuery` stream doesn't update.
  Future<void> _backgroundRefetch<TData, TVars>(
    GraphQLRequest<TData, TVars> req,
  ) async {
    try {
      await for (final _ in _fetchFromNetwork(
        req.copyWithFetchPolicy(FetchPolicy.networkOnly),
      )) {}
    } catch (_) {
      // Swallowed by design — see doc comment above.
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(client): active-watcher registry driving staleness, GC, refetchInterval"
```

---

## Task 7: `notifyReconnected` / `notifyAppResumed`

**Files:**
- Modify: `packages/mk_graphql/lib/src/client/client.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `_activeQueries` and `_backgroundRefetch` (Task 6).
- Produces: `Future<void> notifyReconnected()`, `Future<void> notifyAppResumed()` (public methods on `GraphQLClient`).

- [ ] **Step 1: Write the failing test**

Add to `packages/mk_graphql/test/client_test.dart`, inside a new group:

```dart
  group('notifyReconnected / notifyAppResumed', () {
    test('notifyReconnected refetches only currently active watched queries',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final watchedReq = _TestReq(const _TestVars('watched'),
          staleTime: const Duration(minutes: 5));
      final unwatchedReq = _TestReq(const _TestVars('unwatched'),
          staleTime: const Duration(minutes: 5));
      client.cache
          .writeQuery(watchedReq, const _TestData(id: '1', name: 'A'));
      client.cache
          .writeQuery(unwatchedReq, const _TestData(id: '2', name: 'B'));

      final sub = client.watchQuery(watchedReq).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final callsAfterAttach = networkCalls;
      expect(callsAfterAttach, equals(0),
          reason: 'fresh staleTime, no reconnect yet — no refetch');

      await client.notifyReconnected();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(networkCalls, equals(1),
          reason: 'only the watched query refetches on reconnect');
      await sub.cancel();
    });

    test('notifyAppResumed behaves the same as notifyReconnected', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'A'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await client.notifyAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(networkCalls, equals(1));
      await sub.cancel();
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "notifyReconnected"`
Expected: FAIL — `notifyReconnected`/`notifyAppResumed` don't exist yet.

- [ ] **Step 3: Add the two methods**

In `packages/mk_graphql/lib/src/client/client.dart`, add near `watchQuery`:

```dart
  /// Triggers a background `networkOnly` refetch for every currently
  /// active [watchQuery] subscription — call this from your app's
  /// connectivity listener (e.g. `connectivity_plus`) when the device
  /// regains network connectivity.
  Future<void> notifyReconnected() => _refetchActiveQueries();

  /// Triggers a background `networkOnly` refetch for every currently
  /// active [watchQuery] subscription — call this from your app's
  /// lifecycle observer (e.g.
  /// `WidgetsBindingObserver.didChangeAppLifecycleState(resumed)`).
  Future<void> notifyAppResumed() => _refetchActiveQueries();

  Future<void> _refetchActiveQueries() => Future.wait([
        for (final active in _activeQueries.values)
          if (active.refCount > 0) _backgroundRefetch(active.latestRequest),
      ]);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(client): add notifyReconnected/notifyAppResumed refetch triggers"
```

---

## Task 8: `invalidateQueries`

**Files:**
- Modify: `packages/mk_graphql/lib/src/client/client.dart`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `cache.matchingQueryKeys` (Task 1), `cache.evict` (existing), `_activeQueries`/`_backgroundRefetch` (Task 6).
- Produces: `Future<void> invalidateQueries({List<String>? operationNames, List<String>? types, bool refetchActive = true})`.

- [ ] **Step 1: Write the failing tests**

Add a `_TypedData`/`_TypedTestReq` fixture pair near `_TestReq` in `packages/mk_graphql/test/client_test.dart` — unlike `_TestData` (whose `.toJson()` never includes `__typename`), this one always does, so it can exercise type-based invalidation:

```dart
class _TypedData {
  final String? id;
  final String? name;
  const _TypedData({this.id, this.name});
  factory _TypedData.fromJson(Map<String, dynamic> json) =>
      _TypedData(id: json['id'] as String?, name: json['name'] as String?);
  Map<String, dynamic> toJson() =>
      {'__typename': 'User', 'id': id, 'name': name};
}

class _TypedTestReq extends GraphQLRequest<_TypedData, _TestVars> {
  @override
  final _TestVars variables;
  _TypedTestReq(this.variables);

  @override
  String get document => 'query TypedTest { user { id name } }';

  @override
  String get operationName => 'TypedTest';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TypedData parseData(Map<String, dynamic> json) => _TypedData.fromJson(json);

  @override
  _TypedTestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TypedData? optimisticResponse,
  }) =>
      _TypedTestReq(variables ?? this.variables);
}
```

Add a new group to the same file:

```dart
  group('invalidateQueries', () {
    test('invalidates by operationNames: active watcher gets refetched data',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Old'));

      final emissions = <_TestData?>[];
      final sub = client.watchQuery(req).listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(emissions.single?.name, equals('Old'));

      await client.invalidateQueries(operationNames: ['Test']);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(networkCalls, equals(1));
      expect(emissions.last?.name, equals('Dedup'),
          reason: '_CountingLink always returns name "Dedup"');
      await sub.cancel();
    });

    test(
        'invalidates by types: matches only queries whose cached result '
        'touched that typename', () async {
      final client = GraphQLClient.fromLink(_CountingLink(() {}));

      final untypedReq = _TestReq(const _TestVars('1'));
      client.cache
          .writeQuery(untypedReq, const _TestData(id: '1', name: 'Alice'));

      final typedReq = _TypedTestReq(const _TestVars('2'));
      client.cache
          .writeQuery(typedReq, const _TypedData(id: '2', name: 'Bob'));

      await client.invalidateQueries(types: ['User'], refetchActive: false);

      expect(client.cache.readQuery(typedReq), isNull,
          reason: 'evicted because its cached JSON included __typename: User');
      expect(client.cache.readQuery(untypedReq), isNotNull,
          reason: '_TestData.toJson() carries no __typename, so it must '
              'not match a type-based invalidation');
    });

    test(
        'an inactive (unwatched) match is evicted but not refetched — no '
        'network call', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Old'));

      await client.invalidateQueries(operationNames: ['Test']);

      expect(networkCalls, equals(0));
      expect(client.cache.readQuery(req), isNull);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/client_test.dart -N "invalidateQueries"`
Expected: FAIL — `invalidateQueries` doesn't exist yet.

- [ ] **Step 3: Add `invalidateQueries`**

In `packages/mk_graphql/lib/src/client/client.dart`, add near `notifyReconnected`:

```dart
  /// Evicts every cached query matching [operationNames] and/or [types]
  /// (a query matches if its operation name is in [operationNames], or if
  /// its cached result touched a `__typename` in [types]). When
  /// [refetchActive] (default `true`), a matching query with at least one
  /// active [watchQuery] subscriber is immediately background-refetched so
  /// that subscriber's stream updates in place; a match with no active
  /// subscriber is simply evicted and refetched lazily on next read.
  Future<void> invalidateQueries({
    List<String>? operationNames,
    List<String>? types,
    bool refetchActive = true,
  }) async {
    final keys = cache.matchingQueryKeys(
      operationNames: operationNames,
      types: types,
    );

    final refetches = <Future<void>>[];
    for (final key in keys) {
      cache.evict('ROOT_QUERY:$key');
      final active = _activeQueries[key];
      if (refetchActive && active != null && active.refCount > 0) {
        refetches.add(_backgroundRefetch(active.latestRequest));
      }
    }
    await Future.wait(refetches);
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/client_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/test/client_test.dart
git commit -m "feat(client): add invalidateQueries by operationName and typename"
```

---

## Task 9: `HiveCache` + `GraphQLClient.create` async factory

**Files:**
- Create: `packages/mk_graphql/lib/src/cache/hive_cache.dart`
- Create: `packages/mk_graphql/test/hive_cache_test.dart`
- Modify: `packages/mk_graphql/lib/src/cache/in_memory_cache.dart` (add `exportAll`/`seed`)
- Modify: `packages/mk_graphql/lib/src/client/client.dart` (add `GraphQLClient.create`)
- Modify: `packages/mk_graphql/lib/mk_graphql.dart`
- Modify: `packages/mk_graphql/pubspec.yaml`
- Test: `packages/mk_graphql/test/client_test.dart`

**Interfaces:**
- Consumes: `InMemoryCache` (existing), `Cache` interface (Task 1).
- Produces: `InMemoryCache.exportAll() → Map<String, Map<String, dynamic>>`, `InMemoryCache.seed(Map<String, Map<String, dynamic>>)`; `HiveCache` class implementing `Cache` with `static Future<HiveCache> open({required String boxName, KeyGetter? keyGetter, void Function(Object, StackTrace)? onPersistError})` and `Future<void> close()`; `static Future<GraphQLClient> create({..., FutureOr<Cache>? cache, ...})`.

- [ ] **Step 1: Add the `hive_ce` dependency**

Run:
```bash
cd packages/mk_graphql && flutter pub add hive_ce
```
This resolves and pins the latest compatible version in `packages/mk_graphql/pubspec.yaml` automatically — do not hand-write a version constraint.

- [ ] **Step 2: Add `exportAll`/`seed` to `InMemoryCache`**

In `packages/mk_graphql/lib/src/cache/in_memory_cache.dart`, add near the bottom of the class body (private helpers section):

```dart
  /// Dumps the entire normalized record store — never includes optimistic
  /// layers. Used only by [HiveCache] to mirror state to disk.
  Map<String, Map<String, dynamic>> exportAll() => _store.toMap();

  /// Bulk-loads [records] into the store. Used only by [HiveCache.open] to
  /// hydrate a fresh [InMemoryCache] from a previously persisted box,
  /// before any reads/writes happen. Does not populate `writtenAt`/typename
  /// bookkeeping for the seeded entries — a freshly hydrated query is
  /// treated as never-written (so, with the default `staleTime: 0`, it is
  /// immediately eligible for one background revalidation per process
  /// start; a configured `staleTime` will similarly not treat hydrated data
  /// as "fresh" until it is re-written by a live network response).
  void seed(Map<String, Map<String, dynamic>> records) {
    for (final entry in records.entries) {
      _store.set(entry.key, entry.value);
    }
  }
```

- [ ] **Step 3: Create `HiveCache`**

```dart
import 'dart:async';
import 'package:hive_ce/hive_ce.dart';
import '../core/request.dart';
import 'cache.dart';
import 'in_memory_cache.dart';

/// A [Cache] that persists the normalized record store to a Hive [Box] so
/// it survives app restarts, while keeping every read/write on the fast
/// in-memory [InMemoryCache] path — the box is only a durable mirror,
/// updated in the background after each mutation.
///
/// Hive must already be initialized by the app (e.g. via `hive_ce_flutter`'s
/// `Hive.initFlutter()`, or plain `hive_ce`'s `Hive.init(path)`) before
/// calling [open] — this package stays storage-path-agnostic, consistent
/// with it never touching Flutter lifecycle/connectivity APIs elsewhere.
class HiveCache implements Cache {
  HiveCache._(this._delegate, this._box, this._onPersistError);

  final InMemoryCache _delegate;
  final Box<Map> _box;
  final void Function(Object error, StackTrace stackTrace)? _onPersistError;

  bool _persistScheduled = false;

  /// Opens (creating if needed) the Hive box named [boxName], hydrates a
  /// fresh [InMemoryCache] from its contents, and returns a ready
  /// [HiveCache].
  static Future<HiveCache> open({
    required String boxName,
    KeyGetter? keyGetter,
    void Function(Object error, StackTrace stackTrace)? onPersistError,
  }) async {
    final box = await Hive.openBox<Map>(boxName);
    final delegate = InMemoryCache(keyGetter: keyGetter);
    final seedData = <String, Map<String, dynamic>>{
      for (final key in box.keys)
        key as String: Map<String, dynamic>.from(box.get(key)!),
    };
    delegate.seed(seedData);
    return HiveCache._(delegate, box, onPersistError);
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    Future.microtask(() async {
      _persistScheduled = false;
      try {
        final snapshot = _delegate.exportAll();
        await _box.clear();
        await _box.putAll(snapshot);
      } catch (e, st) {
        _onPersistError?.call(e, st);
      }
    });
  }

  @override
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) =>
      _delegate.readQuery(request);

  @override
  void writeQuery<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    _delegate.writeQuery(request, data);
    _schedulePersist();
  }

  @override
  Map<String, dynamic>? readFragment({
    required String id,
    required String fragmentName,
  }) =>
      _delegate.readFragment(id: id, fragmentName: fragmentName);

  @override
  void writeFragment({
    required String id,
    required Map<String, dynamic> data,
  }) {
    _delegate.writeFragment(id: id, data: data);
    _schedulePersist();
  }

  @override
  void evict(String key) {
    _delegate.evict(key);
    _schedulePersist();
  }

  @override
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    _delegate.evictQuery(request);
    _schedulePersist();
  }

  @override
  void clear() {
    _delegate.clear();
    _schedulePersist();
  }

  @override
  Stream<TData?> watchQuery<TData, TVars>(
          GraphQLRequest<TData, TVars> request) =>
      _delegate.watchQuery(request);

  @override
  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) =>
      _delegate.recordOptimistic(request, data);

  @override
  void removeOptimistic(String requestId) =>
      _delegate.removeOptimistic(requestId);

  @override
  DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request) =>
      _delegate.writtenAt(request);

  @override
  Iterable<String> matchingQueryKeys({
    List<String>? operationNames,
    List<String>? types,
  }) =>
      _delegate.matchingQueryKeys(
          operationNames: operationNames, types: types);

  /// Closes the underlying Hive box. Call when the [GraphQLClient] that
  /// owns this cache is disposed.
  Future<void> close() => _box.close();
}
```

- [ ] **Step 4: Add `GraphQLClient.create`**

In `packages/mk_graphql/lib/src/client/client.dart`, add near the existing `GraphQLClient({...})` factory (same file, after it):

```dart
  /// Async counterpart to the default [GraphQLClient] factory — awaits
  /// [cache] (so `cache: HiveCache.open(boxName: '...')` can be passed
  /// directly, without a separate `await` statement) before building the
  /// client. Every other parameter is identical to the sync factory.
  static Future<GraphQLClient> create({
    required String url,
    String? wsUrl,
    String? sseUrl,
    Link? subscriptionLink,
    Dio? dio,
    Map<String, String>? defaultHeaders,
    TokenHeaderCallback? accessTokenHeader,
    TokenHeaderCallback? refreshTokenHeader,
    IsTokenExpiredCallback? isTokenExpired,
    IsUnauthorizedCallback? isUnauthorized,
    OnRevokeTokenCallback? onRevokeToken,
    RefreshCallback? refreshCallback,
    bool addTypename = true,
    FutureOr<Cache>? cache,
    FetchPolicy defaultFetchPolicy = FetchPolicy.noCache,
    ErrorPolicy defaultErrorPolicy = ErrorPolicy.none,
    Duration defaultStaleTime = Duration.zero,
    Duration? defaultCacheTime,
    RetryOptions? defaultRetry,
    LoggerOptions loggerOptions = const LoggerOptions(),
  }) async {
    final resolvedCache = await (cache ?? InMemoryCache());
    return GraphQLClient(
      url: url,
      wsUrl: wsUrl,
      sseUrl: sseUrl,
      subscriptionLink: subscriptionLink,
      dio: dio,
      defaultHeaders: defaultHeaders,
      accessTokenHeader: accessTokenHeader,
      refreshTokenHeader: refreshTokenHeader,
      isTokenExpired: isTokenExpired,
      isUnauthorized: isUnauthorized,
      onRevokeToken: onRevokeToken,
      refreshCallback: refreshCallback,
      addTypename: addTypename,
      cache: resolvedCache,
      defaultFetchPolicy: defaultFetchPolicy,
      defaultErrorPolicy: defaultErrorPolicy,
      defaultStaleTime: defaultStaleTime,
      defaultCacheTime: defaultCacheTime,
      defaultRetry: defaultRetry,
      loggerOptions: loggerOptions,
    );
  }
```

- [ ] **Step 5: Export `HiveCache`**

In `packages/mk_graphql/lib/mk_graphql.dart`, add under the `src/cache/*` export block:

```dart
export 'src/cache/hive_cache.dart';
```

- [ ] **Step 6: Write the failing tests**

Create `packages/mk_graphql/test/hive_cache_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:mk_graphql/mk_graphql.dart';

class _TestVars {
  final String id;
  const _TestVars(this.id);
  Map<String, dynamic> toJson() => {'id': id};
}

class _TestData {
  final String? id;
  final String? name;
  const _TestData({this.id, this.name});
  factory _TestData.fromJson(Map<String, dynamic> json) =>
      _TestData(id: json['id'] as String?, name: json['name'] as String?);
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class _TestReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestReq(this.variables, {super.requestId});

  @override
  String get document => 'query Test { user { id name } }';

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _TestReq(variables ?? this.variables, requestId: requestId);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_cache_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('writeQuery persists and a reopened box hydrates the same data',
      () async {
    final req = _TestReq(const _TestVars('1'));

    final cache1 = await HiveCache.open(boxName: 'gql_cache_test');
    cache1.writeQuery(req, const _TestData(id: '1', name: 'Alice'));
    expect(cache1.readQuery(req)?.name, equals('Alice'));
    await Future<void>.delayed(Duration.zero); // let the microtask persist
    await cache1.close();

    final cache2 = await HiveCache.open(boxName: 'gql_cache_test');
    expect(cache2.readQuery(req)?.name, equals('Alice'));
    await cache2.close();
  });

  test('evict removes the entry from both the in-memory store and the box',
      () async {
    final req = _TestReq(const _TestVars('1'));
    final cache = await HiveCache.open(boxName: 'gql_cache_evict_test');
    cache.writeQuery(req, const _TestData(id: '1', name: 'Alice'));
    await Future<void>.delayed(Duration.zero);

    cache.evictQuery(req);
    await Future<void>.delayed(Duration.zero);
    await cache.close();

    final reopened = await HiveCache.open(boxName: 'gql_cache_evict_test');
    expect(reopened.readQuery(req), isNull);
    await reopened.close();
  });

  test('optimistic writes never reach the box', () async {
    final req = _TestReq(const _TestVars('1'), requestId: 'req_1');
    final cache = await HiveCache.open(boxName: 'gql_cache_optimistic_test');
    cache.recordOptimistic(req, const _TestData(id: '1', name: 'Optimistic'));
    expect(cache.readQuery(req)?.name, equals('Optimistic'));
    await Future<void>.delayed(Duration.zero);
    await cache.close();

    final reopened =
        await HiveCache.open(boxName: 'gql_cache_optimistic_test');
    expect(reopened.readQuery(req), isNull,
        reason: 'optimistic data must never be persisted');
    await reopened.close();
  });

  test('onPersistError is invoked, not thrown, when the box write fails',
      () async {
    final req = _TestReq(const _TestVars('1'));
    Object? capturedError;
    final cache = await HiveCache.open(
      boxName: 'gql_cache_error_test',
      onPersistError: (e, st) => capturedError = e,
    );

    // Force the underlying box into a state where persisting fails.
    final box = await Hive.openBox<Map>('gql_cache_error_test');
    await box.close();

    expect(
      () => cache.writeQuery(req, const _TestData(id: '1', name: 'Alice')),
      returnsNormally,
    );
    await Future<void>.delayed(Duration.zero);
    expect(capturedError, isNotNull);
  });
}
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `flutter test packages/mk_graphql/test/hive_cache_test.dart`
Expected: FAIL to compile — `HiveCache`/`hive_ce` don't exist until Steps 1–5 land; run this step only after Steps 1–5, then confirm the tests fail for behavioral reasons if any typo exists, otherwise proceed straight to Step 8 since Steps 1–5 already implement the feature these tests check. (If following strict TDD ordering, write this test file immediately after Step 2 and before Step 3, confirm it fails to resolve `HiveCache`, then implement Step 3 onward.)

- [ ] **Step 8: Run tests to verify they pass**

Run: `flutter test packages/mk_graphql/test/hive_cache_test.dart`
Expected: PASS.

- [ ] **Step 9: Run the full suite**

Run: `flutter test packages/mk_graphql`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add packages/mk_graphql/lib/src/cache/hive_cache.dart packages/mk_graphql/lib/src/cache/in_memory_cache.dart packages/mk_graphql/lib/src/client/client.dart packages/mk_graphql/lib/mk_graphql.dart packages/mk_graphql/pubspec.yaml packages/mk_graphql/test/hive_cache_test.dart
git commit -m "feat(cache): add hive_ce-backed HiveCache and GraphQLClient.create async factory"
```

---

## Task 10: Generator support for the four new `GraphQLRequest` fields

**Files:**
- Modify: `packages/mk_graphql_generator/lib/src/generator/dart_codegen.dart`
- Test: `packages/mk_graphql_generator/test/generator_test.dart`

**Interfaces:**
- Consumes: `RetryOptions`, `staleTime`/`cacheTime`/`retry`/`refetchInterval` (Task 2) — exported from `mk_graphql.dart`, already imported by generated files the same way `FetchPolicy`/`ErrorPolicy` are.
- Produces: updated `freezedRequestClass(...)` emission — every generated request class's factory constructor and `copyWithRequest` now carry the four new fields.

- [ ] **Step 1: Write the failing test**

Add to `packages/mk_graphql_generator/test/generator_test.dart`, right after the existing `'ErrorPolicy is included in request constructor, copyWithRequest, and client extensions'` test:

```dart
    test(
        'staleTime/cacheTime/retry/refetchInterval are included in request '
        'constructor and copyWithRequest', () {
      const query = '''
        query GetSimpleItem {
          getItem(id: "123") {
            id
          }
        }
      ''';

      final bundle = GeneratorOrchestrator.generateForGraphQLFile(
        content: query,
        inputPath: 'lib/graphql/operations.graphql',
        schemaContent: conventionSchema,
        schemaPath: 'lib/graphql/schema.graphql',
      );

      final req =
          bundle.files['generated/get_simple_item/get_simple_item_req.dart']!;
      expect(req, contains('Duration? staleTime,'));
      expect(req, contains('Duration? cacheTime,'));
      expect(req, contains('RetryOptions? retry,'));
      expect(req, contains('Duration? refetchInterval,'));
      expect(req, contains('staleTime: staleTime ?? this.staleTime,'));
      expect(req, contains('cacheTime: cacheTime ?? this.cacheTime,'));
      expect(req, contains('retry: retry ?? this.retry,'));
      expect(req,
          contains('refetchInterval: refetchInterval ?? this.refetchInterval,'));
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/mk_graphql_generator/test/generator_test.dart -N "staleTime/cacheTime/retry/refetchInterval"`
Expected: FAIL — none of these strings appear in generated output yet.

- [ ] **Step 3: Update `freezedRequestClass` in `dart_codegen.dart`**

In `packages/mk_graphql_generator/lib/src/generator/dart_codegen.dart`, update the factory constructor's `optionalParameters`:

```dart
      Constructor((c) => c
        ..constant = true
        ..factory = true
        ..redirect = refer('_$reqClassName')
        ..optionalParameters.addAll([
          _namedParam('variables', type: varsClassName, required: true),
          _namedParam('fetchPolicy', type: 'FetchPolicy?'),
          _namedParam('errorPolicy', type: 'ErrorPolicy?'),
          _namedParam('headers', type: 'Map<String, String>?'),
          _namedParam('cancelToken', type: 'CancelToken?'),
          _namedParam('optimisticResponse', type: '$modelClassName?'),
          _namedParam('staleTime', type: 'Duration?'),
          _namedParam('cacheTime', type: 'Duration?'),
          _namedParam('retry', type: 'RetryOptions?'),
          _namedParam('refetchInterval', type: 'Duration?'),
        ])),
```

Update `copyWithRequest`'s `optionalParameters` and body:

```dart
      Method((m) => m
        ..annotations.add(refer('override'))
        ..returns = refer(reqClassName)
        ..name = 'copyWithRequest'
        ..optionalParameters.addAll([
          _namedParam('variables', type: '$varsClassName?'),
          _namedParam('fetchPolicy', type: 'FetchPolicy?'),
          _namedParam('errorPolicy', type: 'ErrorPolicy?'),
          _namedParam('headers', type: 'Map<String, String>?'),
          _namedParam('cancelToken', type: 'CancelToken?'),
          _namedParam('optimisticResponse', type: '$modelClassName?'),
        ])
        ..body = _exprBody('''copyWith(
          variables: variables ?? this.variables,
          fetchPolicy: fetchPolicy ?? this.fetchPolicy,
          errorPolicy: errorPolicy ?? this.errorPolicy,
          headers: headers ?? this.headers,
          cancelToken: cancelToken ?? this.cancelToken,
          optimisticResponse: optimisticResponse ?? this.optimisticResponse,
          staleTime: staleTime ?? this.staleTime,
          cacheTime: cacheTime ?? this.cacheTime,
          retry: retry ?? this.retry,
          refetchInterval: refetchInterval ?? this.refetchInterval,
        )''')),
```

(`copyWithRequest`'s own parameter list is intentionally left unchanged — like `requestId`, these four are preserved automatically via freezed's `copyWith` reading `this.staleTime` etc. since they're not parameters the caller overrides through `copyWithRequest`; freezed's generated `copyWith` still accepts them as optional named params on the underlying class, which the `this.field` default expression reads from.)

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/mk_graphql_generator/test/generator_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full generator test suite**

Run: `dart test packages/mk_graphql_generator`
Expected: PASS — confirms no other golden-output test broke.

- [ ] **Step 6: Commit**

```bash
git add packages/mk_graphql_generator/lib/src/generator/dart_codegen.dart packages/mk_graphql_generator/test/generator_test.dart
git commit -m "feat(generator): emit staleTime/cacheTime/retry/refetchInterval on generated requests"
```

---

## Task 11: Documentation updates

**Files:**
- Modify: `docs/mk_graphql/caching.md`
- Modify: `docs/mk_graphql/client-and-requests.md`
- Modify: `packages/mk_graphql/README.md`
- Modify: `packages/mk_graphql/CHANGELOG.md` (create the "Unreleased"/next-version entry if the file uses that convention — read it first to match its existing format)

No tests (documentation-only task) — verify by reading the rendered files back.

- [ ] **Step 1: Update `docs/mk_graphql/caching.md`**

Read the current file first (already reviewed above — it documents the `Cache` interface and the `FetchPolicy` table). Add:
1. `writtenAt`/`matchingQueryKeys` to the reproduced `Cache` interface code block.
2. A new `## Stale-while-revalidate` section documenting: `defaultStaleTime`/`defaultCacheTime` on `GraphQLClient`, `staleTime`/`cacheTime` on `GraphQLRequest`, the **default-is-stale** behavior change (`cacheFirst` background-refetches by default; explicitly set `staleTime` to opt back into "serve cache, never auto-revalidate"), and that `cacheTime` GC only runs while unset defaults to "never GC".
3. A new `## Query invalidation` section documenting `client.invalidateQueries({operationNames, types, refetchActive})` with a short example (e.g. invalidating a list query by type after a mutation).
4. A new `## Refetch triggers` section documenting `notifyReconnected`/`notifyAppResumed`/`refetchInterval`, with a short `connectivity_plus`-style wiring example.
5. A new `## Persistent cache: HiveCache` section documenting `HiveCache.open(boxName: ...)`, that it requires `Hive.initFlutter()`/`Hive.init(path)` to have run first, write-through semantics, and that optimistic writes are never persisted.

- [ ] **Step 2: Update `docs/mk_graphql/client-and-requests.md`**

Read the current file first. Add:
1. `staleTime`/`cacheTime`/`retry`/`refetchInterval` to the documented `GraphQLRequest` fields table/section.
2. A `## Retry with backoff` section documenting `RetryOptions`, `GraphQLClient(defaultRetry: ...)`, `GraphQLRequest.retry`, the query-vs-mutation default split, and `RetryOptions.none`.
3. A `## Request deduplication` short note: concurrent identical queries share one network call automatically; mutations and cancel-token-bearing requests never dedup.
4. Document `GraphQLClient.create({...})` next to the existing constructor docs, noting it's needed when passing a `HiveCache.open(...)` (or any other `Future<Cache>`) as `cache`.

- [ ] **Step 3: Update `packages/mk_graphql/README.md`**

Add a short bullet to the `## ✨ Features` list, e.g.:
```markdown
- ⚡ **Smart Query Optimizations**: Automatic in-flight request deduplication, opt-out-of stale-while-revalidate caching with GC, `invalidateQueries`, retry-with-backoff, and reconnect/interval refetch triggers — TanStack-Query-style client behavior.
- 💽 **Optional Persistent Cache**: `HiveCache` (backed by `hive_ce`) persists the normalized cache across app restarts as a drop-in `Cache` implementation.
```
And update the `## 🚀 Step-by-Step Integration` → `### 1. Initialize GraphQLClient` example's comment about `defaultFetchPolicy` to mention `defaultStaleTime`/`defaultCacheTime`/`defaultRetry` exist, pointing at the full docs.

- [ ] **Step 4: Update the changelog**

Read `packages/mk_graphql/CHANGELOG.md` first to match its existing entry format (version header style, bullet style). Add an entry (under the next unreleased/dev version — match whatever the file's current top entry convention is) covering:
- New: request deduplication, `staleTime`/`cacheTime` + GC, `invalidateQueries`, `RetryOptions`/`defaultRetry`, `notifyReconnected`/`notifyAppResumed`/`refetchInterval`, `HiveCache`, `GraphQLClient.create`.
- **Breaking**: `FetchPolicy.cacheFirst` now background-revalidates on every cache hit by default (`defaultStaleTime` changed from "always fresh once cached" to `Duration.zero`) — set an explicit `staleTime` to keep the old behavior.

- [ ] **Step 5: Commit**

```bash
git add docs/mk_graphql/caching.md docs/mk_graphql/client-and-requests.md packages/mk_graphql/README.md packages/mk_graphql/CHANGELOG.md
git commit -m "docs: document request/caching optimizations and the cacheFirst staleTime default change"
```

---

## Self-review notes (for the executor)

- Task ordering is a strict dependency chain: 1 → 2 → 3 → 4 → 5 → 6 → 7/8 (7 and 8 can run in either order, both depend only on 6) → 9 → 10 → 11. Do not reorder.
- Every task that touches `client.dart` re-reads the current state of the file (via the harness's own file-state tracking) before editing — the code blocks above show the target state of each modified region, not always the full file; apply them as targeted edits to the named regions, not wholesale file replacement, except where a step explicitly says "replace the whole method body."
- Task 9, Step 7's TDD ordering note is intentional: `HiveCache` is unusual in that the test file cannot even parse until the feature exists (unlike every other task, where the test merely fails at runtime). Follow the parenthetical instruction — write the test file right after Step 2, confirm it fails to resolve `HiveCache`/`hive_ce` imports, then proceed through Steps 3–5 before returning to run it.
