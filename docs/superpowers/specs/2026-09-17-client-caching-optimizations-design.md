# Client Request/Caching Optimizations (TanStack-Query-style) — Design

Status: approved by user 2026-09-17. Ready for implementation planning.

## Goal

Bring `mk_graphql`'s `GraphQLClient`/`Cache` closer to TanStack Query's request/cache
behavior: in-flight request deduplication, opt-in stale-while-revalidate caching with
automatic garbage collection, a query invalidation API, retry-with-backoff for
transient network failures, app-driven refetch triggers (reconnect/resume/interval),
and an optional `hive_ce`-backed persistent cache.

All of this is additive to the existing `Cache`/`FetchPolicy`/`GraphQLRequest`/
`GraphQLClient` surface. Nothing here changes default behavior for existing callers
unless they opt in to a new parameter.

## Non-goals

- Changing the normalized-cache data model (`RecordSource`, entity key format) beyond
  what's needed to track per-query timestamps and typenames.
- Building a generic pluggable persister interface for arbitrary storage backends —
  only `hive_ce` is implemented. (The `Cache` interface itself stays storage-agnostic,
  so a future persister is still possible without redesign.)
- Any Flutter-lifecycle/connectivity plumbing (`WidgetsBindingObserver`,
  `connectivity_plus` integration) — the client exposes hooks; wiring them to OS
  signals is the app's responsibility, consistent with `mk_graphql` staying
  Flutter-lifecycle-agnostic elsewhere.
- Retrying/deduplicating subscriptions' long-lived streams (dedup/retry apply to
  queries; mutations never auto-retry or dedup; subscriptions are out of scope for
  both — they already have their own reconnect semantics in `WebSocketLink`/`SseLink`).
- A UI-facing "isFetching"/"isStale" observable API — `watchQuery` keeps returning
  `Stream<TData?>` as today; call sites that need loading state already use
  `client.stream()`/`GraphQLResponse.loading`.

## Design

### 1. Request key (shared foundation)

`InMemoryCache._requestKey` already computes a canonical key:
`'${req.operationName}:${req.document.hashCode}:$sortedVars'`. This becomes a shared
top-level helper (`lib/src/core/request_key.dart`, `String computeRequestKey(GraphQLRequest req)`)
used by:
- `InMemoryCache` (replacing its private `_requestKey`, unchanged behavior)
- the in-flight dedup map (§2)
- the active-watcher registry (§4)

No change to the key format — this is a pure extraction so multiple subsystems agree
on identity without duplicating the logic.

### 2. Request deduplication (queries only)

In `GraphQLClient`, add `final Map<String, Stream<gql.Response>> _inFlight = {}`.

In `_executeNetworkRequest`, before calling `_pipeline.request(gqlReq)`:
- Skip dedup entirely for mutations (detected the same way `_isSubscription` detects
  subscriptions — a sibling `_isMutation` helper) and whenever `cancelToken`/
  `req.cancelToken` is set (a caller who wants explicit cancellation of *their* call
  shouldn't be silently attached to someone else's in-flight request).
- Compute `key = computeRequestKey(req)`.
- If `_inFlight[key]` exists, listen to that shared broadcast stream instead of
  starting a new pipeline call.
- Otherwise start the pipeline call, wrap it as a broadcast stream, store it in
  `_inFlight[key]`, and remove the entry (via `whenComplete`/`doneOnCancel`-style
  cleanup on the stream's done/error) once it finishes.

This sits below cache-policy branching (`_fetchFromNetwork`) so it collapses the
actual network round trip regardless of which `FetchPolicy` branch triggered it —
e.g. two widgets both doing `cacheAndNetwork` on the same query in the same frame
still only hit the network once.

### 3. Stale-while-revalidate + GC

**Staleness defaults to on** (this intentionally changes `cacheFirst`'s current
behavior — see "Behavior change" callout below). **GC stays opt-in**, since eviction
is a separate, lower-stakes concern from staleness.

**New fields:**
- `GraphQLClient`: `Duration defaultStaleTime = Duration.zero`, `Duration? defaultCacheTime`
  (`null` — GC off, current behavior preserved).
- `GraphQLRequest`: `Duration? staleTime`, `Duration? cacheTime` (override the client
  defaults when set — a request can opt back into "never auto-revalidate" with
  `staleTime: null` being indistinguishable from "use client default," so a request
  that truly wants to disable revalidation sets `staleTime: const Duration(days: 36500)`
  or similar effectively-infinite value; added to `copyWithRequest`).

**Behavior change:** with `defaultStaleTime` now `Duration.zero` instead of `null`,
every `cacheFirst` cache hit is considered stale by default — it still returns the
cached value instantly (no UI-visible delay), but now *also* immediately kicks off a
background network refetch to revalidate it, the same way `cacheAndNetwork` always
has. This matches TanStack Query's own default (`staleTime: 0`). Apps that want the
old "serve cache, never auto-revalidate" behavior for a given query set an explicit
`staleTime` (e.g. `Duration(minutes: 5)`, or a very large value to opt out entirely).
This is called out as a breaking change in the changelog/migration notes for the
release that ships it (see "Manual follow-ups").

**Cache changes (`InMemoryCache`):**
- Track `Map<String, DateTime> _writtenAt` — set in `writeQuery`, read via a new
  `Cache` method `DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request)`.
- No change to `readQuery`/`writeQuery` semantics otherwise.

**Client changes (`request()` method, `cacheFirst` branch):**
```
case FetchPolicy.cacheFirst:
  final cached = cache.readQuery(req);
  if (cached == null) {
    yield* _fetchFromNetwork(req, cancelToken: cancelToken);
    break;
  }
  final staleTime = req.staleTime ?? defaultStaleTime; // defaults to Duration.zero
  final writtenAt = cache.writtenAt(req);
  final isFresh = writtenAt != null &&
      DateTime.now().difference(writtenAt) < staleTime;
  yield GraphQLResponse(data: cached, source: ResponseSource.cache, loading: !isFresh);
  if (isFresh) break;
  // stale (the default, unless staleTime is explicitly raised): fall through to a
  // background network refetch, same emission shape as cacheAndNetwork
  yield* _fetchFromNetwork(req, cancelToken: cancelToken);
  break;
```
(An explicit `staleTime` large enough to outlast the cache entry's age reproduces
today's `cacheFirst` — cache hit short-circuits, no network call. With no override,
the new `Duration.zero` default means `isFresh` is `false` as soon as any time has
passed since the write, so cache hits background-refetch immediately — see "Behavior
change" above.)

`cacheAndNetwork` is unchanged (it already always backgrounds a network fetch);
`staleTime` only affects GC eligibility for it, not its emission shape.

**GC (`cacheTime`):** driven by the active-watcher registry (§4). When a query's
watcher refcount drops to 0:
- If `cacheTime` (per-request or client default) is set, start a `Timer(cacheTime, ...)`
  that calls `cache.evictQuery(req)` unless a new watcher subscribes first (timer is
  canceled on resubscribe).
- If `cacheTime` is unset, no timer — cache entry lives until explicitly evicted/
  invalidated, exactly like today.

### 4. Active-watcher registry (shared foundation for §3 GC, §5 invalidation, §6 refetch triggers)

`GraphQLClient` gains a private registry:
```dart
final Map<String, _ActiveQuery> _activeQueries = {};

class _ActiveQuery {
  GraphQLRequest latestRequest;
  int refCount = 0;
  Timer? gcTimer;
  Timer? refetchIntervalTimer;
}
```

`GraphQLClient.watchQuery` is rewritten from a one-line delegate into the
orchestration point:
1. Compute `key = computeRequestKey(req)`.
2. On first listen: register/increment `_activeQueries[key]` (creating the entry,
   canceling any pending GC timer, storing `req` as `latestRequest`), start a
   `refetchInterval` timer if `req.refetchInterval` is set (fires a `networkOnly`
   background refetch, same helper as invalidation/reconnect use — see below).
3. Return `cache.watchQuery(req)` merged with the same staleness check as §3 (if the
   currently cached value is stale per `staleTime`, kick a background refetch
   immediately when the watcher attaches, in addition to on invalidation/reconnect).
4. On cancel: decrement refcount; at 0, cancel `refetchIntervalTimer` and start the
   GC timer from §3 if `cacheTime` is configured; remove the registry entry entirely
   if no `cacheTime` (nothing to GC, no reason to keep the record).

A private helper `Future<void> _backgroundRefetch(GraphQLRequest req)` centralizes
"run `_fetchFromNetwork` with `FetchPolicy.networkOnly`, ignore/log the result since
the cache write + existing `cache.watchQuery` stream is what actually propagates it" —
used by §3 staleness, §5 invalidation, and §6 reconnect/resume/interval alike.

### 5. Query invalidation

```dart
Future<void> invalidateQueries({
  List<String>? operationNames,
  List<String>? types,
  bool refetchActive = true,
});
```
on `GraphQLClient`.

**Cache changes:** `InMemoryCache` additionally tracks
`Map<String, Set<String>> _queryTypenames` — populated in `_normalize` during
`writeQuery` by collecting every `__typename` value encountered while walking the
response JSON for that query key. Exposed via a new `Cache` method operating on the
raw key strings already known to the client via the registry:
`Iterable<String> matchingQueryKeys({List<String>? operationNames, List<String>? types})`
implemented against `_writtenAt.keys` (operation-name match: key starts with
`'$operationName:'`) and `_queryTypenames` (type match: set contains the typename).

**Client-side `invalidateQueries`:**
1. Ask `cache.matchingQueryKeys(operationNames: ..., types: ...)` for the set of
   affected keys.
2. For each key: `cache.evict('ROOT_QUERY:$key')` (immediate — next `cacheFirst`/
   `cacheOnly` read misses).
3. If `refetchActive` and `_activeQueries[key]` exists (refcount > 0), call
   `_backgroundRefetch(_activeQueries[key]!.latestRequest)` — the resulting network
   write repopulates the cache and flows through the existing watcher stream, so
   active UI updates without the app re-issuing the query itself.
4. Inactive matches are left evicted, refetched lazily whenever next read — no wasted
   network calls for queries nobody is watching.

### 6. Retry with backoff

```dart
class RetryOptions {
  final int maxAttempts;       // default 3
  final Duration initialDelay; // default 200ms
  final double backoffMultiplier; // default 2.0
  final bool Function(Object error)? retryIf; // default: transient network errors only
  const RetryOptions({...});
}
```

- `GraphQLClient`: `RetryOptions? defaultRetry` — applied automatically to queries
  and left `null` (no retry) for mutations unless the request overrides it.
- `GraphQLRequest`: `RetryOptions? retry` — overrides the client default per request;
  passing `RetryOptions(maxAttempts: 1)` (or a dedicated `RetryOptions.none`) disables
  retry for an otherwise-retrying query, and setting any non-null `RetryOptions` on a
  mutation opts that mutation into retry.
- Default `retryIf` matches connection errors / timeouts / 5xx (via
  `GraphQLExceptionExtension`'s existing exception classification) — never retries on
  4xx/validation errors, since those won't succeed on retry.

**Implementation:** a loop inside `_executeNetworkRequest` around the existing
`_pipeline.request(gqlReq)` call (not a `Link`), because it needs to know the
operation kind (query vs mutation) and the resolved per-request `RetryOptions` — both
already available at that call site via `req`. On a retryable failure, wait
`initialDelay * backoffMultiplier^(attempt-1)`, then retry; the dedup map (§2) is
correctly scoped to the *outer* call for this, since retries happen inside a single
`_executeNetworkRequest` invocation, not as separate dedup-tracked calls.

### 7. Refetch triggers

- `Future<void> notifyReconnected()` / `Future<void> notifyAppResumed()` on
  `GraphQLClient`: iterate `_activeQueries.values` (refcount > 0) and call
  `_backgroundRefetch` for each — both are thin, semantically-named wrappers around
  the same "refetch everything currently watched" behavior, kept as two names so call
  sites read clearly (`connectivity_plus` listener → `notifyReconnected()`;
  `WidgetsBindingObserver.didChangeAppLifecycleState(resumed)` → `notifyAppResumed()`).
- `GraphQLRequest.refetchInterval` (`Duration?`, default `null`): when set and the
  request has an active watcher (§4 step 2), a periodic `Timer` calls
  `_backgroundRefetch` every interval; canceled when the watcher count drops to 0.

### 8. Hive-backed persistent cache

**New dependency:** `hive_ce: ^<latest>` in `packages/mk_graphql/pubspec.yaml`
(`hive_ce_flutter` only if its `initFlutter()` path helper turns out necessary for
non-web platforms — confirmed during implementation, not a design blocker).

**`lib/src/cache/hive_cache.dart`:**
```dart
class HiveCache implements Cache {
  HiveCache._(this._delegate, this._box, this._onPersistError);

  final InMemoryCache _delegate;
  final Box<Map> _box;
  final void Function(Object error, StackTrace st)? _onPersistError;

  static Future<HiveCache> open({
    required String boxName,
    KeyGetter? keyGetter,
    void Function(Object error, StackTrace st)? onPersistError,
  }) async {
    final box = await Hive.openBox<Map>(boxName);
    final delegate = InMemoryCache(keyGetter: keyGetter);
    delegate.seed({
      for (final k in box.keys) k as String: Map<String, dynamic>.from(box.get(k)!),
    });
    return HiveCache._(delegate, box, onPersistError);
  }

  // Every Cache method delegates to `_delegate` for the synchronous read/write,
  // then mirrors the mutation into `_box` as a fire-and-forget Future guarded by
  // _onPersistError. e.g.:
  @override
  void writeQuery<TData, TVars>(GraphQLRequest<TData, TVars> request, TData data) {
    _delegate.writeQuery(request, data);
    _persistChangedRecords();
  }
  ...
}
```

- `InMemoryCache` gains two internal (not part of the public `Cache` interface, but
  `@visibleForTesting`/package-private-ish) methods used only by `HiveCache`:
  `Map<String, Map<String, dynamic>> exportAll()` (dumps `RecordSource.toMap()`, which
  already exists) and `void seed(Map<String, Map<String, dynamic>> records)` (bulk-
  loads before any reads/writes happen, used once during `open`).
- **Write path:** rather than diffing which specific records changed on every
  mutation, `HiveCache` persists by calling `_delegate.exportAll()` and writing it to
  the box via `_box.putAll(...)` after each mutating call, debounced with a
  microtask/`Future.microtask` so multiple synchronous mutations in the same tick
  coalesce into one disk write. This trades a bit of write amplification for
  correctness-by-construction (no risk of the persisted copy drifting from the
  in-memory `RecordSource`'s ref-normalization).
- **Eviction/clear:** `evict`, `evictQuery`, `clear` call through to `_delegate` then
  mirror onto `_box` (`_box.delete(key)` / `_box.clear()`), same debounced-write path
  for delete-in-bulk isn't needed since deletes are already targeted.
- **Optimistic layers:** `recordOptimistic`/`removeOptimistic` delegate to
  `_delegate` only — never touch `_box` (ephemeral by design).
- **GC (§3) and invalidation (§5):** operate through the `Cache` interface as normal
  (`evictQuery`, `writtenAt`, `matchingQueryKeys`), so they transparently persist/
  depersist through `HiveCache` with no extra code in `GraphQLClient`.

**Client wiring — new async factory:**
```dart
static Future<GraphQLClient> create({
  required String url,
  // ...all the same named parameters as the existing sync factory...
  FutureOr<Cache>? cache,
}) async {
  final resolvedCache = await (cache ?? InMemoryCache());
  return GraphQLClient(/* ...existing sync factory, cache: resolvedCache... */);
}
```
Lets apps write `cache: HiveCache.open(boxName: 'gql_cache')` directly as the
`FutureOr<Cache>` argument without a separate `await` statement. The existing sync
`GraphQLClient(...)` factory is unchanged and keeps working for `InMemoryCache` or a
`HiveCache` the caller already opened/awaited themselves.

## Error handling

- Dedup: an error on the shared in-flight stream propagates to every listener (same
  as today's per-caller behavior) and clears the `_inFlight` entry so the next call
  starts fresh.
- Retry: exhausting `maxAttempts` yields the final attempt's error through the normal
  `GraphQLResponse.linkException`/`GraphQLException` path — no new exception type.
- Hive persistence failures never surface as `Cache`-interface exceptions (the
  interface is synchronous); they're reported only via `onPersistError`, defaulting to
  a silent no-op if the caller doesn't supply one, so a full disk or permission error
  degrades to "cache is effectively in-memory-only for this session," not a crash.
- `invalidateQueries`/`notifyReconnected`/`notifyAppResumed` background refetches
  that fail are swallowed at the `_backgroundRefetch` level (logged via the existing
  `LoggerLink`/`loggerOptions` machinery already in the pipeline) rather than thrown —
  callers didn't initiate these refetches directly and have no `Future` to catch
  against; an active `watchQuery` stream simply doesn't update, cache keeps the last-
  good value.

## Testing

Extend `packages/mk_graphql/test/`:
- `client_test.dart`: dedup (N concurrent `future()`/`stream()` calls on the same
  query → 1 pipeline invocation, asserted via a counting fake `Link`); mutations never
  dedup even with identical variables; retry respects `maxAttempts`/backoff timing
  (use `fake_async`-style control) and mutation opt-in default.
- new `stale_while_revalidate_test.dart`: default (`staleTime` unset →
  `Duration.zero`) `cacheFirst` cache hit emits cached data immediately *and* triggers
  a background network refetch; explicit `staleTime` set and still fresh → cache-only,
  no network call; explicit `staleTime` expired → cache emission followed by network
  emission; `cacheTime` GC evicts after last watcher cancels + timer fires, and is
  canceled by a resubscribe before it fires.
- new `invalidate_queries_test.dart`: invalidate by `operationNames`, by `types`, and
  both; active watcher receives a refetched value; inactive match is evicted but not
  refetched (no network call asserted).
- new `refetch_triggers_test.dart`: `notifyReconnected`/`notifyAppResumed` refetch
  only active watched queries; `refetchInterval` fires on schedule and stops after the
  watcher cancels.
- new `hive_cache_test.dart`: round-trip write → close/reopen box → data still present
  (hydration); `writeQuery`/`evict`/`clear` mirror correctly to the box; optimistic
  writes never appear in the box; `onPersistError` is invoked (not thrown) when the
  box write fails (simulate via a box double or a closed box).

## Manual follow-ups (not performed by this implementation)

No external accounts, publish config, or generator changes are required, but the
release that ships this must call out in `CHANGELOG.md`/release notes that
`FetchPolicy.cacheFirst` now background-refetches on every cache hit by default
(§3's `defaultStaleTime = Duration.zero` change) — apps that relied on `cacheFirst`
never re-hitting the network need to set an explicit `staleTime` to keep that
behavior. (`mk_graphql_generator`'s generated `GraphQLRequest`
subclasses gain `staleTime`/`cacheTime`/`retry`/`refetchInterval` fields automatically
via the existing `copyWithRequest` pattern the generator already emits — verify this
during implementation, but it's not expected to need generator template changes beyond
adding the new constructor parameters.)
