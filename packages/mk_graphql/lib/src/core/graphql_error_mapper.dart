import 'package:gql_exec/gql_exec.dart' as gql_exec;

import 'error.dart';

/// Shared helpers for parsing/mapping GraphQL error payloads — used by
/// [GraphQLExceptionExtension], `GraphQLClient`, and `AuthLink`'s
/// unauthorized-detection so this convention lives in one place instead of
/// being reimplemented per call site.

/// Extracts and upper-cases `extensions['code']`, or `null` if absent.
String? extractErrorCode(Map<String, dynamic>? extensions) =>
    extensions?['code']?.toString().toUpperCase();

/// Converts a single `gql_exec` [gql_exec.GraphQLError] (the raw wire-level
/// error yielded by the link pipeline) into this package's own
/// [GraphQLError] (the typed, public-facing error shape returned from
/// `GraphQLResponse`/thrown `GraphQLException`s).
GraphQLError mapGraphQLError(gql_exec.GraphQLError error) => GraphQLError(
  message: error.message,
  locations: error.locations
      ?.map((l) => GraphQLErrorLocation(line: l.line, column: l.column))
      .toList(),
  path: error.path?.cast<Object>(),
  extensions: error.extensions,
);

/// Maps a list of `gql_exec` errors to this package's [GraphQLError]s,
/// preserving `null`.
List<GraphQLError>? mapGraphQLErrors(List<gql_exec.GraphQLError>? errors) =>
    errors?.map(mapGraphQLError).toList();
