import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

typedef AddTypenameLink = TypenameLink;

/// Middleware [Link] that automatically injects `__typename` selection fields
/// into all GraphQL document AST selection sets.
class TypenameLink extends Link {
  const TypenameLink();

  /// Transformed-document cache, keyed by the original [DocumentNode]'s
  /// identity. The same operation is sent repeatedly with the same document
  /// instance (a generated request's `static final documentNode`, or a
  /// hand-written one resolved through the shared parse cache), so without
  /// this every request re-walks and rebuilds the entire AST for a result
  /// that's identical to last time. Static (not per-instance) since the
  /// transform is a pure function of the input document — safe to share
  /// across every [TypenameLink], and keeps this class `const`-constructible.
  static final _cache = Expando<DocumentNode>('TypenameLink transform cache');

  @override
  Stream<Response> request(Request req, [NextLink? forward]) {
    if (forward == null) {
      throw StateError('TypenameLink cannot be a terminating link.');
    }

    try {
      final originalDoc = req.operation.document;
      final transformedDoc = _cache[originalDoc] ??=
          originalDoc.accept(_AddTypenameVisitor()) as DocumentNode;
      final updatedReq = Request(
        operation: Operation(
          document: transformedDoc,
          operationName: req.operation.operationName,
        ),
        variables: req.variables,
        context: req.context,
      );
      return forward(updatedReq);
    } catch (_) {
      return forward(req);
    }
  }
}

class _AddTypenameVisitor extends TransformingVisitor {
  @override
  DocumentNode visitDocumentNode(DocumentNode node) {
    return DocumentNode(
      definitions: node.definitions
          .map((d) => d.accept(this) as DefinitionNode)
          .toList(),
    );
  }

  @override
  OperationDefinitionNode visitOperationDefinitionNode(
    OperationDefinitionNode node,
  ) {
    return OperationDefinitionNode(
      type: node.type,
      name: node.name,
      variableDefinitions: node.variableDefinitions
          .map((v) => v.accept(this) as VariableDefinitionNode)
          .toList(),
      directives: node.directives
          .map((d) => d.accept(this) as DirectiveNode)
          .toList(),
      selectionSet: node.type == OperationType.subscription
          ? _visitSubscriptionRoot(node.selectionSet)
          : node.selectionSet.accept(this) as SelectionSetNode,
    );
  }

  /// A subscription must select exactly one non-introspection top-level
  /// field, so its root selection set is left alone — only the selections
  /// nested under that field get `__typename`.
  SelectionSetNode _visitSubscriptionRoot(SelectionSetNode root) =>
      SelectionSetNode(
        selections: root.selections
            .map((s) => s.accept(this) as SelectionNode)
            .toList(),
      );

  @override
  SelectionSetNode visitSelectionSetNode(SelectionSetNode node) {
    final hasTypename = node.selections.any(
      (s) => s is FieldNode && s.name.value == '__typename',
    );

    final updatedSelections = node.selections
        .map((s) => s.accept(this) as SelectionNode)
        .toList();

    if (!hasTypename) {
      updatedSelections.add(
        const FieldNode(name: NameNode(value: '__typename')),
      );
    }

    return SelectionSetNode(selections: updatedSelections);
  }

  @override
  FieldNode visitFieldNode(FieldNode node) {
    final selectionSet = node.selectionSet;
    return FieldNode(
      name: node.name,
      alias: node.alias,
      arguments: node.arguments
          .map((a) => a.accept(this) as ArgumentNode)
          .toList(),
      directives: node.directives
          .map((d) => d.accept(this) as DirectiveNode)
          .toList(),
      selectionSet: selectionSet != null
          ? selectionSet.accept(this) as SelectionSetNode
          : null,
    );
  }

  @override
  InlineFragmentNode visitInlineFragmentNode(InlineFragmentNode node) {
    return InlineFragmentNode(
      typeCondition: node.typeCondition,
      directives: node.directives
          .map((d) => d.accept(this) as DirectiveNode)
          .toList(),
      selectionSet: node.selectionSet.accept(this) as SelectionSetNode,
    );
  }

  @override
  FragmentDefinitionNode visitFragmentDefinitionNode(
    FragmentDefinitionNode node,
  ) {
    return FragmentDefinitionNode(
      name: node.name,
      typeCondition: node.typeCondition,
      directives: node.directives
          .map((d) => d.accept(this) as DirectiveNode)
          .toList(),
      selectionSet: node.selectionSet.accept(this) as SelectionSetNode,
    );
  }
}
