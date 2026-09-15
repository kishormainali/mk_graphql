import 'package:gql/ast.dart';
import 'package:gql/language.dart';

/// Process-wide cache of parsed [DocumentNode]s keyed by raw document text —
/// shared by `GraphQLClient.getParsedDocument` and the default
/// `GraphQLRequest.documentNode` implementation so a given query string is
/// only ever parsed once, however many client instances or request objects
/// reference it.
final Map<String, DocumentNode> documentCache = {};

/// Returns the cached [DocumentNode] for [document], parsing it only on
/// first access.
DocumentNode getParsedDocument(String document) =>
    documentCache.putIfAbsent(document, () => parseString(document));
