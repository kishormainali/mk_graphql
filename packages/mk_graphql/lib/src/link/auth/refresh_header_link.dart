import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

import 'package:token_storage/token_storage.dart';
import 'auth_types.dart';

/// Attaches a refresh-token header callback's headers (e.g. `Authorization:
/// Bearer <refreshToken>`) to every request sent through `AuthLink`'s
/// internal refresh client, so the refresh HTTP call carries the refresh
/// token without the app's `RefreshCallback` having to build it manually.
class RefreshHeaderLink extends Link {
  const RefreshHeaderLink(this.refreshTokenHeader);

  final TokenHeaderCallback refreshTokenHeader;

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    assert(forward != null, 'RefreshHeaderLink cannot be a terminating link.');
    final token = await TokenStorage.i.refreshToken;
    if (token == null) {
      yield* forward!(req);
      return;
    }
    final headers = await refreshTokenHeader(token);
    if (headers.isEmpty) {
      yield* forward!(req);
      return;
    }
    final contextHeaders =
        req.context.entry<HttpLinkHeaders>()?.headers ?? const {};
    final mergedHeaders = Map<String, String>.from(contextHeaders)
      ..addAll(headers);
    yield* forward!(
        req.withContextEntry(HttpLinkHeaders(headers: mergedHeaders)));
  }
}
