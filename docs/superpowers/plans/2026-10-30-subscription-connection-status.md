# Subscription Connection Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let apps observe the WebSocket/SSE subscription connection (`connecting`, `connected`, `reconnecting`, `disconnected`, `error`) via `GraphQLClient`, so they can show it to the user.

**Architecture:** A small `ConnectionStatusNotifier` (value + broadcast stream) lives in `core/`. Each subscription link owns one and reports into it at its existing transition points. It is keyed by a *source* so `SseLink` (one HTTP stream per subscription) can report an aggregate. `GraphQLClient` finds the notifier through a `ConnectionStatusSource` interface implemented by the three links.

**Tech Stack:** Dart / Flutter, `gql_link`, `dio`, `web_socket_channel`, `flutter_test` (real loopback servers, no mocks — match existing tests).

**Spec:** Agreed in chat 2026-10-30 (no written design doc). Decisions: five statuses; `error` is sticky (`lastError` is kept through `connecting`/`reconnecting`/`error` and cleared only on the next `connected`); initial state `disconnected`; `SseLink` reports an aggregate; no bundled Flutter widget.

## Global Constraints

- Package root for all commands: `packages/mk_graphql`. Run tests with `flutter test <file>`; finish with `flutter analyze` (CI fails on analyzer infos).
- No new dependencies. Use `dart:async` broadcast streams, not rxdart.
- Existing link constructor signatures stay source-compatible (no new required params).
- A custom `subscriptionLink` that doesn't implement `ConnectionStatusSource` is allowed; the client then reports a constant `disconnected`.
- Follow repo style: `///` docs on public API, trailing-comma formatting (`dart format`).

## Review Focus

- A late listener must be able to read the current state (`connectionState`) — the stream does not replay.
- Server closes with 4401/4403 (token refresh path): state goes `error` → `connecting` → `connected`, and `lastError` is still set during `connecting`.
- `autoReconnect: false` + a drop must end in `error` (with the cause), not stay `reconnecting` forever.
- Idle close (no subscribers left) is `disconnected`, never `error`, and must not clear a sticky error that was already reported.
- `dispose()` leaves `disconnected` and closes the stream (no leak, no emit-after-close exception).
- `SseLink` with two subscriptions where one fails and one is open must report `connected`, not `error`.

---

## File Structure

- Create `lib/src/core/connection_status.dart` — enum, state value class, `ConnectionStatusSource`, `ConnectionStatusNotifier`.
- Modify `lib/src/link/transport/websocket_link.dart`, `sse_single_connection_link.dart`, `sse_link.dart` — implement `ConnectionStatusSource`, report transitions.
- Modify `lib/src/client/client.dart` — expose `connectionState` / `connectionStateStream`.
- Modify `lib/mk_graphql.dart` — export the new file.
- Modify `docs/mk_graphql/links.md` (repo root `docs/`) — usage section.
- Tests: create `test/connection_status_test.dart`; extend `test/websocket_link_test.dart`, `test/sse_single_connection_link_test.dart`, `test/sse_link_test.dart`, `test/client_test.dart`.

---

### Task 1: Status types and notifier

**Files:**
- Create: `lib/src/core/connection_status.dart`
- Modify: `lib/mk_graphql.dart` (add `export 'src/core/connection_status.dart';` next to the other `core` exports)
- Test: `test/connection_status_test.dart`

**Interfaces:**
- Produces:
  - `enum SubscriptionConnectionStatus { connecting, connected, reconnecting, disconnected, error }`
  - `class SubscriptionConnectionState { final SubscriptionConnectionStatus status; final Object? lastError; final int attempt; const SubscriptionConnectionState(this.status, {this.lastError, this.attempt = 0}); static const disconnected = SubscriptionConnectionState(SubscriptionConnectionStatus.disconnected); }` with value `==`/`hashCode`/`toString`.
  - `abstract interface class ConnectionStatusSource { ConnectionStatusNotifier get connectionStatus; }`
  - `class ConnectionStatusNotifier`:
    - `SubscriptionConnectionState get value` (starts `SubscriptionConnectionState.disconnected`)
    - `Stream<SubscriptionConnectionState> get stream` (broadcast; emits only when `value` changes; no replay)
    - `void report(Object source, SubscriptionConnectionStatus status, {Object? error})`
    - `void release(Object source)` — forgets a source (treated as `disconnected`)
    - `Future<void> close()` — closes the stream; later `report`/`release` are no-ops.

**Aggregation rule** (a single source is the trivial case): across all sources, the aggregate status is the first that applies: any `connected` → `connected`; any `reconnecting` → `reconnecting`; any `connecting` → `connecting`; any `error` → `error`; otherwise `disconnected`. `attempt` = max `attempt` of `reconnecting` sources, else 0. A source's `attempt` increments on each consecutive `reconnecting` report and resets on any other status. `lastError`: set to `error` whenever a non-null `error` is passed (also with `reconnecting`); cleared only when the aggregate becomes `connected`; otherwise kept.

- [ ] **Step 1: Write failing tests** in `test/connection_status_test.dart`:
  - `starts disconnected`: `ConnectionStatusNotifier().value == SubscriptionConnectionState.disconnected`.
  - `reconnecting counts attempts and keeps error`: report(a, reconnecting, error: 'x') twice → `value.attempt == 2`, `value.lastError == 'x'`; then report(a, connecting) → `lastError == 'x'`, `attempt == 0`.
  - `connected clears lastError`: after the above, report(a, connected) → `lastError == null`.
  - `error is sticky through connecting`: report(a, error, error: 'e'); report(a, connecting) → status `connecting`, `lastError == 'e'`.
  - `aggregates across sources`: a=connected, b=error → `connected`; release(a) → `error`; release(b) → `disconnected`.
  - `stream emits only changes`: collect `stream`; report(a, connecting) twice, then connected → emitted statuses `[connecting, connected]` (use `await Future.delayed(Duration.zero)` before asserting).
  - `close ends stream and ignores later reports`: after `close()`, `report` doesn't throw and the stream `done` fired.

- [ ] **Step 2: Run** `flutter test test/connection_status_test.dart` — Expected: FAIL (file/types missing).

- [ ] **Step 3: Implement** `lib/src/core/connection_status.dart` per the Interfaces block and aggregation rule. Keep a `Map<Object, SubscriptionConnectionState>` of per-source state plus a `_lastError`; recompute the aggregate on every `report`/`release`, and `add` to a `StreamController.broadcast()` only if it differs from `value`.

- [ ] **Step 4: Run** the same test — Expected: PASS. Also `flutter analyze` clean.

- [ ] **Step 5: Commit**
```bash
git add lib/src/core/connection_status.dart lib/mk_graphql.dart test/connection_status_test.dart
git commit -m "feat(status): add subscription connection status types and notifier"
```

---

### Task 2: WebSocketLink reports status

**Files:**
- Modify: `lib/src/link/transport/websocket_link.dart`
- Test: `test/websocket_link_test.dart` (new `group('WebSocketLink connection status', ...)`, same loopback `HttpServer` + `WebSocketTransformer.upgrade` style as the existing groups)

**Interfaces:**
- Consumes: `ConnectionStatusNotifier.report/release/close`, `ConnectionStatusSource` (Task 1).
- Produces: `WebSocketLink implements ConnectionStatusSource` with `final ConnectionStatusNotifier connectionStatus = ConnectionStatusNotifier();`.

Transitions (the source key is `this`; add a private `_report(status, {Object? error})` helper):
- `_doConnect`, after the `_isDisposed` check: `connecting` only when `_reconnectAttempt == 0` (a retry was already reported as `reconnecting`).
- `connection_ack` branch of `_onMessage`: `connected`.
- `_scheduleReconnect({Object? cause})`: when it actually schedules → `reconnecting` with `error: cause`. When it returns early because `!autoReconnect` or `_isDisposed` → `error` with `cause` (autoReconnect off), and when the only reason is `_activeSubscriptions.isEmpty` → `disconnected`. An already-active timer is a no-op. Thread `cause` from `_onError(error)` (the error) and `_onDone` (a string like `'WebSocket closed with code $closeCode'`).
- `_failAll(error)`: `error` with that error (covers 4401/4403, fatal codes, `connection_error`, `RevokeTokenException`).
- `_scheduleIdleClose` callback after its `_dropConnection()`: `disconnected`.
- `dispose()`: `disconnected`, then `await connectionStatus.close()` as the last step.

- [ ] **Step 1: Write failing tests** (each collects `link.connectionStatus.stream` statuses into a list):
  - `connects: connecting then connected` — server acks `connection_init` with `{"type":"connection_ack"}`; subscribe; expect `[connecting, connected]`.
  - `drop then reconnect: reconnecting then connected, lastError kept while reconnecting` — server acks, then closes socket 1006-style (`socket.close()`) on first connection, acks the second; expect `[connecting, connected, reconnecting, connected]`; during `reconnecting` `value.lastError != null`; after final `connected`, `lastError == null`.
  - `4401 close is error and sticky through next connecting` — server closes first socket with `socket.close(4401)`; expect last status `error`, `lastError` is a `ServerException` with `statusCode == 401`; then start a new subscription against a server that acks → states `connecting` (with `lastError` still set) then `connected` (`lastError == null`).
  - `autoReconnect false: drop ends in error` — `autoReconnect: false`, server closes immediately → final status `error`, not `reconnecting`.
  - `idle close is disconnected` — `idleCloseDelay: 50ms`, cancel the only subscription → final `disconnected`.
  - `dispose leaves disconnected and closes the stream` — after `await link.dispose()`, `value.status == disconnected` and the stream's `done` future completes.

- [ ] **Step 2: Run** `flutter test test/websocket_link_test.dart --plain-name "connection status"` — Expected: FAIL (no `connectionStatus`).

- [ ] **Step 3: Implement** the transitions above in `websocket_link.dart`. Reporting must never throw into the existing flow (the notifier ignores reports after `close`).

- [ ] **Step 4: Run** the full `flutter test test/websocket_link_test.dart` — Expected: all PASS (existing groups unchanged).

- [ ] **Step 5: Commit**
```bash
git add lib/src/link/transport/websocket_link.dart test/websocket_link_test.dart
git commit -m "feat(status): report WebSocketLink connection status"
```

---

### Task 3: SseSingleConnectionLink reports status

**Files:**
- Modify: `lib/src/link/transport/sse_single_connection_link.dart`
- Test: `test/sse_single_connection_link_test.dart` (reuse the file's `_Server`; add what's needed to make it drop a stream, e.g. a `closeStreams()` helper that closes every `streams` response)

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `SseSingleConnectionLink implements ConnectionStatusSource`, `final ConnectionStatusNotifier connectionStatus = ConnectionStatusNotifier();`.

Transitions inside `_loop` (source key `this`):
- Top of each `while` iteration: `connecting` when `attempt == 0`, else `reconnecting` with `error: failure` from the previous iteration (the delay branch below reports it, see next bullet).
- Right after `_openStream` returns (where `_streamOpen = true`): `connected`.
- Before the backoff `Future.delayed`: `reconnecting` with `error: failure` (null failure = server closed the stream; pass `'SSE stream closed'`).
- `_failAll(error)` (all call sites, including max attempts and non-retryable): `error` with that error. Put the report inside `_failAll` itself.
- `_loop`'s outer `finally`: if `_isDisposed` or `_ops.isEmpty`, and `connectionStatus.value.status != error` → `disconnected`.
- `dispose()`: `disconnected`, then `await connectionStatus.close()` last.

- [ ] **Step 1: Write failing tests:**
  - `connects: connecting then connected` — one subscription against `_Server`; expect `[connecting, connected]`.
  - `stream drop: reconnecting then connected` — close the server's stream mid-subscription; expect `[..., reconnecting, connected]`, and `lastError == null` after the final `connected`.
  - `exhausted retries is error and sticky` — `maxReconnectAttempts: 1`, short intervals, server answers `PUT` with 503 → final status `error` with `lastError != null`.
  - `last subscription cancelled is disconnected, not error` — after cancel (and idle close) final status `disconnected` and `lastError == null`.
  - `dispose leaves disconnected and closes the stream`.

- [ ] **Step 2: Run** `flutter test test/sse_single_connection_link_test.dart` — Expected: new tests FAIL.

- [ ] **Step 3: Implement** the transitions above.

- [ ] **Step 4: Run** the full file — Expected: all PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/src/link/transport/sse_single_connection_link.dart test/sse_single_connection_link_test.dart
git commit -m "feat(status): report SseSingleConnectionLink connection status"
```

---

### Task 4: SseLink reports an aggregate

**Files:**
- Modify: `lib/src/link/transport/sse_link.dart`
- Test: `test/sse_link_test.dart`

**Interfaces:**
- Consumes: Task 1 types (the `source` argument of `report`/`release` is what makes the aggregate work).
- Produces: `SseLink implements ConnectionStatusSource`, `final ConnectionStatusNotifier connectionStatus = ConnectionStatusNotifier();`.

Only *subscription* operations report (`isSubscription` in `_run`); queries/mutations through this link are ignored. Use the per-request `CancelToken` (`token` in `request`) as the source key:
- `_run`, before each `_connect` attempt: `connecting` when `attempt == 0`, else `reconnecting`.
- When `_connect` yields its first response, or the HTTP response is accepted (status < 300): `connected`. Simplest correct spot: inside `_run`'s `await for` loop on the first yielded response *and* — so a quiet-but-open stream shows `connected` — right after `_connect` obtains a 2xx `dioResponse` (pass a callback or report from `_connect`, whichever is the smaller diff).
- Before the backoff delay: `reconnecting` with `error: failure` (null failure → `'SSE stream closed without completing'`).
- Non-retryable failure / max attempts exceeded (the `rethrow`/`throw` paths): `error` with that error.
- Subscription ends (stream `complete`, cancel via `onCancel`): `connectionStatus.release(token)`.
- `dispose()`: release nothing extra, but `await connectionStatus.close()` after closing the owned client.

- [ ] **Step 1: Write failing tests** (loopback `HttpServer` streaming `text/event-stream`, as the existing tests do):
  - `open subscription is connected; cancelling it is disconnected`.
  - `aggregate: one failing and one open subscription reports connected` — second subscription hits a path/state where the server returns 500 with `maxReconnectAttempts: 0`; while the first stays open, `value.status == connected`.
  - `all subscriptions failed is error with lastError`.
  - `queries do not affect status` — a `query` through the link leaves `value.status == disconnected`.

- [ ] **Step 2: Run** `flutter test test/sse_link_test.dart` — Expected: new tests FAIL.

- [ ] **Step 3: Implement** the reports above.

- [ ] **Step 4: Run** the full file — Expected: all PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/src/link/transport/sse_link.dart test/sse_link_test.dart
git commit -m "feat(status): report SseLink aggregate connection status"
```

---

### Task 5: Client API and docs

**Files:**
- Modify: `lib/src/client/client.dart` (`_buildPipeline`, the default factory, `GraphQLClient._`, `fromLink`)
- Modify: `docs/mk_graphql/links.md` (repo root)
- Test: `test/client_test.dart`

**Interfaces:**
- Consumes: `ConnectionStatusSource`, `SubscriptionConnectionState` (Task 1) and the three links (Tasks 2–4).
- Produces on `GraphQLClient`:
  - `SubscriptionConnectionState get connectionState`
  - `Stream<SubscriptionConnectionState> get connectionStateStream`
  - `GraphQLClient.fromLink(..., {ConnectionStatusSource? connectionStatusSource})` — new optional param.

Wiring: `_buildPipeline` currently returns `Link`; change it to return `({Link pipeline, ConnectionStatusSource? statusSource})` where `statusSource` is `subLink` if `subLink is ConnectionStatusSource` (covers a user-supplied `subscriptionLink` that implements it). Pass it to `GraphQLClient._` as a new `ConnectionStatusSource? connectionStatusSource` field. Getters read `_connectionStatusSource?.connectionStatus`, falling back to a constant `SubscriptionConnectionState.disconnected` and `const Stream.empty()`. Update every caller of `_buildPipeline` (grep it). `dispose()` needs no change — `_pipeline.dispose()` already disposes the links.

- [ ] **Step 1: Write failing tests** in `test/client_test.dart`:
  - `connectionState is disconnected before any subscription` for a client built with `wsUrl: 'ws://127.0.0.1:1'` (nothing connects until a subscription starts).
  - `connectionStateStream reports connecting then connected` — client with `wsUrl` pointing at a loopback server that acks; subscribe through the client's existing subscription API; expect `connecting`, `connected` on `connectionStateStream`.
  - `no subscription link: connectionState is disconnected and stream is empty` (client with only `url`).
  - `custom subscriptionLink implementing ConnectionStatusSource is surfaced` (a tiny test link class holding a notifier).

- [ ] **Step 2: Run** `flutter test test/client_test.dart --plain-name "connection"` — Expected: FAIL.

- [ ] **Step 3: Implement** the wiring and getters (with `///` docs saying the stream does not replay — read `connectionState` for the current value).

- [ ] **Step 4: Docs** — add a "Connection status" section to `docs/mk_graphql/links.md`: the five statuses and what each means, sticky `lastError`, `SseLink` aggregate, and a ~10-line `StreamBuilder<SubscriptionConnectionState>` example using `initialData: client.connectionState`.

- [ ] **Step 5: Run everything** — `flutter test` then `flutter analyze` — Expected: all tests pass, no analyzer issues.

- [ ] **Step 6: Commit**
```bash
git add lib/src/client/client.dart docs/mk_graphql/links.md test/client_test.dart
git commit -m "feat(status): expose connectionState on GraphQLClient"
```
