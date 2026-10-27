# Authentication & Token Storage

`GraphQLClient` can manage a login session for you: it attaches the access token to every request, refreshes it when the server rejects it, retries the failed requests, and revokes the session when refreshing isn't possible. The session lives in `TokenStorage.i`, the secure, app-wide singleton from the [`token_storage`](https://pub.dev/packages/token_storage) package (re-exported by `mk_graphql`, so one import covers both).

## The moving parts

| Piece | Role |
|---|---|
| `TokenPair` | One session: `accessToken`, optional `refreshToken`, and `createdAt`/`updatedAt`. What your `refreshCallback` returns and what storage reads back. Comes from `token_storage`. |
| `TokenStorage.i` | From `token_storage`: persists the `TokenPair` in the platform keychain/keystore and notifies a listener about login/logout. Needs `await TokenStorage.init()` once at startup. |
| `GraphQLClient(refreshCallback: ...)` | Turns on session management: header injection, refresh-and-retry, revoke. |
| `GraphQLClient.registerRevokeTokenListener` | App-wide hook for "the session ended" — navigate to login here. |

## `TokenPair`

Defined by `token_storage` (and re-exported from `package:mk_graphql/mk_graphql.dart`):

```dart
TokenPair({
  required String accessToken,
  String? refreshToken,
  DateTime? createdAt,   // defaults to now
  DateTime? updatedAt,   // defaults to now
});
```

| Member | Meaning |
|---|---|
| `accessToken` | Sent on every request (`Authorization: Bearer <token>` by default). |
| `refreshToken` | Handed to `refreshCallback`. With none stored, an unauthorized response revokes the session immediately. |
| `createdAt` | When the session's tokens were first issued (e.g. at login). |
| `updatedAt` | When the tokens were last written — login, then every refresh. |
| `isExpired` | Whether `accessToken` is an expired JWT (its `exp` claim). A token that isn't a JWT counts as expired. |
| `toJson()` / `TokenPair.fromJson` | JSON round-trip. |

Both timestamps default to now, so normally omit them (pass them only if your server reports its own issue times). `TokenPair` is not `const`. On a refresh the client keeps the **stored** `createdAt` and stamps `updatedAt` with the current time, so the timestamps you return from `refreshCallback` don't matter.

## `TokenStorage.i`

Call `await TokenStorage.init()` once before anything else (typically in `main()`, before creating the client). It also wipes credentials on the first launch after a reinstall (iOS keychain items survive an uninstall).

| Member | Description |
|---|---|
| `init()` | Static. Call once at startup, before any other member. |
| `saveToken(TokenPair)` | Persists a new session (**login**). Notifies the listener with the pair. |
| `updateToken(TokenPair)` | Persists a **refreshed** pair. **Does not notify the listener.** |
| `clearToken()` | Clears the stored pair (**logout/revoke**). Notifies the listener with `null`. |
| `token` | The stored `TokenPair?` — `null` when logged out. |
| `accessToken` / `refreshToken` | Convenience getters for the two token strings (`null` when absent). |
| `hasToken` / `isTokenExpired` | Whether a pair is stored / whether its access token is an expired JWT (`null` when none). |
| `setTokenListener(listener)` | Sets a `void Function(TokenPair?)` — receives the new pair on `saveToken`, `null` on `clearToken`. **Replaces** any previous listener. |
| `removeTokenListener()` | Removes the listener. |
| `put` / `get` / `putObject` / `getObject` / `remove` / `clearAll` / `watchKey` | Generic secure key-value storage; see the [`token_storage` docs](https://pub.dev/packages/token_storage). |

### Which write notifies listeners

| Call | Use it for | Listeners |
|---|---|---|
| `saveToken` | Login / a brand-new session | called with the new pair |
| `updateToken` | A token refresh | **not called** |
| `clearToken` | Logout / revoke | called with `null` |

A refresh is deliberately silent. If you rebuild your router (or any auth-dependent UI) from `setTokenListener`, a refresh must not look like a login — the user hasn't changed, only the token has. The client uses `updateToken` for its own refreshes, and every request reads the token from storage at send time, so the very next request already carries the new token.

If you need to react to a refresh (for example to reconnect a websocket with the new token), read `TokenStorage.i.token` at the point you need it and compare `updatedAt` — there is no refresh notification.

## Session lifecycle

```dart
// 0. Once, at startup, before creating the client.
await TokenStorage.init();

// 1. Configure once. The client reads/writes TokenStorage.i itself.
final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  refreshCallback: (refreshClient, refreshToken) async {
    final res = await refreshClient.future(RefreshMutation(...));
    return TokenPair(
      accessToken: res.accessToken,
      refreshToken: res.refreshToken,
    );
  },
);

// 2. React to login/logout (e.g. drive the router).
TokenStorage.i.setTokenListener((token) {
  router.replaceAll([token == null ? const LoginRoute() : const HomeRoute()]);
});

// 3. Login: store the session from your login mutation.
await TokenStorage.i.saveToken(TokenPair(
  accessToken: data.accessToken,
  refreshToken: data.refreshToken,
));

// 4. Logout.
await TokenStorage.i.clearToken();
```

### What happens on an unauthorized response

1. `AuthLink` classifies the failure (default: `UNAUTHORIZED`/`UNAUTHENTICATED`/401 → refresh; `FORBIDDEN`/403 → revoke; override with `isUnauthorized`). See [Link Pipeline: `AuthLink`](links.md#authlink).
2. On **refresh**, the client reads the stored refresh token and calls `refreshCallback(refreshClient, refreshToken)` — once, however many requests failed at the same time; the rest wait for it.
3. If it returns a `TokenPair`, the client calls `TokenStorage.i.updateToken(...)` (silent, keeping the stored `createdAt`) and retries the failed requests once with the new access token.
4. If it returns `null` or throws, **or** no refresh token is stored, **or** the failure classified as revoke, the session is revoked:
   - `TokenStorage.i.clearToken()` runs → `setTokenListener` listeners receive `null`
   - `onRevokeToken` (if passed) is called
   - every `GraphQLClient.registerRevokeTokenListener` listener fires

   The real cause still reaches the caller as a thrown exception — see [Errors](client-and-requests.md#errors--validation).

By default step 2 waits for `refreshCallback` indefinitely. If your refresh endpoint can hang, pass `GraphQLClient(refreshTimeout: const Duration(seconds: 10))` (or whatever fits your API) to treat a refresh that takes too long as a failed one — same outcome as it throwing, the session is revoked — instead of blocking every request queued behind it forever.

### Two listener families

| Listener | Fires on | Not on |
|---|---|---|
| `TokenStorage.i.setTokenListener` | login (`saveToken`), logout/revoke (`clearToken`) | refresh |
| `GraphQLClient.registerRevokeTokenListener` | revoke only (refresh failed, no refresh token, `AuthFailure.revoke`) | login, refresh, a manual `clearToken()` |

Use `setTokenListener` for "the auth state changed" and `registerRevokeTokenListener` for "the server ended my session". On an explicit logout call `clearToken()`; add `AuthLink.notifyRevokeToken()` if your app also relies on the revoke listeners for that path.

## Customizing headers

The access-token header defaults to `Authorization: Bearer <token>`. Override it with `accessTokenHeader`, which receives the stored token as its argument (it is only invoked when a token exists):

```dart
GraphQLClient(
  url: endpoint,
  accessTokenHeader: (token) => {'X-Auth': token},
  refreshCallback: ...,
);
```

`refreshTokenHeader` has no default — the refresh token already reaches your endpoint as `refreshCallback`'s second argument. Pass it only if the refresh endpoint expects the token as a header on requests made through `refreshClient`.

## Checking for a session

`client.isAuthenticated` is `true` when `TokenStorage.i` holds an access token. It reflects what is *stored*, not whether the server still accepts it.

## Subscriptions

- **SSE (`sseUrl`)** goes through `AuthLink` like any HTTP request: a 401/403 refreshes (single-flight) and retries once.
- **WebSocket (`wsUrl`)** authenticates once per connection, in `connection_init`. The payload is built from `accessTokenHeader` on every (re)connect, after the same `isTokenExpired` check and refresh as HTTP requests, so a reconnect never resends a stale token. If a later subscribe resolves a different token (e.g. after a refresh), the socket is replaced and active subscriptions are resent on it.
- `subscribe` is sent only after the server's `connection_ack` (servers that authenticate in `connection_init` close the socket with `4401` otherwise). `WebSocketLink(connectionAckTimeout: ...)` bounds the wait (default 10s, then the socket is dropped and reconnected); `null` skips the wait for a server that never acks. `maxConnectionAge` optionally opens a fresh socket for a subscribe once the current one is older than that.
- A server that rejects the connection with close code `4401` or `4403` is treated as HTTP 401: `AuthLink` refreshes the token and re-subscribes once; if the refresh fails the session is revoked (`onRevokeToken`, listeners), same as for queries.

## Storage details

- Storage is implemented by [`token_storage`](https://pub.dev/packages/token_storage) on top of `flutter_secure_storage`: the whole pair is stored as one JSON entry in a namespace private to that package, so `clearAll()`/the fresh-install wipe never touch your own secure storage.
- `TokenStorage` is a singleton with no injection point — in tests, call `FlutterSecureStorage.setMockInitialValues({})` and then `await TokenStorage.init()` (with an in-memory `SharedPreferencesAsyncPlatform`, since `init()` uses `shared_preferences` for the fresh-install flag).
- `token_storage` requires Dart 3.9 / Flutter 3.35 or newer.
