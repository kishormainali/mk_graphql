# Authentication & Token Storage

`GraphQLClient` can manage a login session for you: it attaches the access token to every request, refreshes it when the server rejects it, retries the failed requests, and revokes the session when refreshing isn't possible. The session lives in `TokenStorage.i`, a secure, app-wide singleton.

## The moving parts

| Piece | Role |
|---|---|
| `TokenPair` | One session: `accessToken`, optional `refreshToken`, and `createdAt`/`updatedAt`. What your `refreshCallback` returns and what storage reads back. |
| `TokenStorage.i` | Persists the `TokenPair` in the platform keychain/keystore (`flutter_secure_storage`) and notifies listeners about login/logout. |
| `GraphQLClient(refreshCallback: ...)` | Turns on session management: header injection, refresh-and-retry, revoke. |
| `GraphQLClient.registerRevokeTokenListener` | App-wide hook for "the session ended" — navigate to login here. |

## `TokenPair`

```dart
const TokenPair({
  required String accessToken,
  String? refreshToken,
  DateTime? createdAt,
  DateTime? updatedAt,
});
```

| Field | Meaning |
|---|---|
| `accessToken` | Sent on every request (`Authorization: Bearer <token>` by default). |
| `refreshToken` | Handed to `refreshCallback`. With none stored, an unauthorized response revokes the session immediately. |
| `createdAt` | When the session's tokens were first issued. **Preserved across refreshes.** |
| `updatedAt` | When the tokens were last written — login, then every refresh. |

You normally leave both timestamps `null`: `TokenStorage` stamps them (login: both = now; refresh: `updatedAt` = now, `createdAt` kept). Pass them explicitly only if your server reports its own issue times. `TokenPair` is `Equatable` over all four fields. A session stored before timestamps existed reads back with both `null`; its next refresh backfills `createdAt`.

## `TokenStorage.i`

| Member | Description |
|---|---|
| `saveToken(TokenPair)` | Persists a new session (**login**). Notifies listeners with the access token. |
| `updateToken(TokenPair)` | Persists a **refreshed** pair. Keeps `createdAt`, sets `updatedAt` to now. **Does not notify listeners.** |
| `deleteToken()` | Clears the tokens and both timestamps (**logout/revoke**). Notifies listeners with `null`. |
| `getToken()` | The stored `TokenPair?` — `null` when logged out. |
| `accessToken` / `refreshToken` | Convenience getters for the two token strings (`null` when absent). |
| `setTokenListener(listener)` | Adds a `void Function(String?)` — receives the new access token on `saveToken`, `null` on `deleteToken`. Can be called more than once. |
| `removeTokenListener()` | Removes every listener added with `setTokenListener`. |
| `clearOnInstall()` | Call once at startup: wipes credentials on the first launch after a reinstall (iOS keychain items survive uninstall). Never notifies listeners. |

### Which write notifies listeners

| Call | Use it for | Listeners |
|---|---|---|
| `saveToken` | Login / a brand-new session | called with the access token |
| `updateToken` | A token refresh | **not called** |
| `deleteToken` | Logout / revoke | called with `null` |

A refresh is deliberately silent. If you rebuild your router (or any auth-dependent UI) from `setTokenListener`, a refresh must not look like a login — the user hasn't changed, only the token has. The client uses `updateToken` for its own refreshes, and every request reads the token from storage at send time, so the very next request already carries the new token.

If you need to react to a refresh (for example to reconnect a websocket with the new token), read `TokenStorage.i.getToken()` at the point you need it and compare `updatedAt` — there is no refresh notification.

## Session lifecycle

```dart
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
TokenStorage.i.setTokenListener((accessToken) {
  router.replaceAll([accessToken == null ? const LoginRoute() : const HomeRoute()]);
});

// 3. Login: store the session from your login mutation.
await TokenStorage.i.saveToken(
  TokenPair(accessToken: data.accessToken, refreshToken: data.refreshToken),
);

// 4. Logout.
await TokenStorage.i.deleteToken();
```

### What happens on an unauthorized response

1. `AuthLink` classifies the failure (default: `UNAUTHORIZED`/`UNAUTHENTICATED`/401 → refresh; `FORBIDDEN`/403 → revoke; override with `isUnauthorized`). See [Link Pipeline: `AuthLink`](links.md#authlink).
2. On **refresh**, the client reads the stored refresh token and calls `refreshCallback(refreshClient, refreshToken)` — once, however many requests failed at the same time; the rest wait for it.
3. If it returns a `TokenPair`, the client calls `TokenStorage.i.updateToken(...)` (silent) and retries the failed requests once with the new access token.
4. If it returns `null` or throws, **or** no refresh token is stored, **or** the failure classified as revoke, the session is revoked:
   - `TokenStorage.i.deleteToken()` runs → `setTokenListener` listeners receive `null`
   - `onRevokeToken` (if passed) is called
   - every `GraphQLClient.registerRevokeTokenListener` listener fires

   The real cause still reaches the caller as a thrown exception — see [Errors](client-and-requests.md#errors--validation).

By default step 2 waits for `refreshCallback` indefinitely. If your refresh endpoint can hang, pass `GraphQLClient(refreshTimeout: const Duration(seconds: 10))` (or whatever fits your API) to treat a refresh that takes too long as a failed one — same outcome as it throwing, the session is revoked — instead of blocking every request queued behind it forever.

### Two listener families

| Listener | Fires on | Not on |
|---|---|---|
| `TokenStorage.i.setTokenListener` | login (`saveToken`), logout/revoke (`deleteToken`) | refresh |
| `GraphQLClient.registerRevokeTokenListener` | revoke only (refresh failed, no refresh token, `AuthFailure.revoke`) | login, refresh, a manual `deleteToken()` |

Use `setTokenListener` for "the auth state changed" and `registerRevokeTokenListener` for "the server ended my session". On an explicit logout call `deleteToken()`; add `AuthLink.notifyRevokeToken()` if your app also relies on the revoke listeners for that path.

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

## Storage details

- Access token, refresh token and the two timestamps are separate secure-storage entries (`__access_token__`, `__refresh_token_key__`, `__token_created_at__`, `__token_updated_at__`). Timestamps are stored as UTC ISO-8601 strings and read back as UTC `DateTime`s.
- iOS: `KeychainAccessibility.first_unlock`, not synchronized to iCloud. Android: default `AndroidOptions`.
- `TokenStorage` is a singleton with no injection point — in tests, use `FlutterSecureStorage.setMockInitialValues({})` to reset it.
