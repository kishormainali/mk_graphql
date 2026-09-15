import 'package:gql/ast.dart';
import 'package:gql/language.dart';

/// Caches the printed query-string form of a [DocumentNode], keyed by object
/// identity rather than value equality — [DocumentNode] equality is a deep
/// structural comparison (see `package:gql`'s `Node.==`), which costs about
/// as much as the print itself, so it would defeat the point as a cache key.
///
/// Identity works well here because the common paths reuse one instance per
/// operation: `mk_graphql_generator`-generated requests hold a `static
/// final` [DocumentNode] per operation, and hand-written ones are parsed
/// once via `GraphQLClient.getParsedDocument`/[documentCache] and reused —
/// so the same instance recurs on every call of that operation, and
/// [TypenameLink]'s own identity-keyed transform cache means even the
/// `__typename`-injected document is a stable, reused instance. A document
/// built fresh on every call (uncommon) simply never hits the cache, same
/// cost as calling [printNode] directly.
final _cache = Expando<String>('mk_graphql printNode cache');

/// Returns `printNode(document)`, computed once per distinct [document]
/// instance.
String printDocumentCached(DocumentNode document) =>
    _cache[document] ??= printNode(document);
