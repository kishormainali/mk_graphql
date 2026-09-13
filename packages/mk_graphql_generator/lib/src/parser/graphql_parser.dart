import 'package:gql/ast.dart';
import 'package:gql/language.dart';

class ParsedGraphQLDocument {
  final DocumentNode ast;
  final List<OperationDefinitionNode> operations;
  final List<FragmentDefinitionNode> fragments;
  final List<ObjectTypeDefinitionNode> objectTypes;
  final List<EnumTypeDefinitionNode> enumTypes;
  final List<InputObjectTypeDefinitionNode> inputTypes;
  final List<UnionTypeDefinitionNode> unionTypes;
  final List<InterfaceTypeDefinitionNode> interfaceTypes;
  final List<ScalarTypeDefinitionNode> scalarTypes;

  ParsedGraphQLDocument({
    required this.ast,
    required this.operations,
    required this.fragments,
    required this.objectTypes,
    required this.enumTypes,
    required this.inputTypes,
    required this.unionTypes,
    this.interfaceTypes = const [],
    this.scalarTypes = const [],
  });

  factory ParsedGraphQLDocument.parse(String content) {
    final ast = parseString(content);
    final operations = <OperationDefinitionNode>[];
    final fragments = <FragmentDefinitionNode>[];
    final objectTypes = <ObjectTypeDefinitionNode>[];
    final enumTypes = <EnumTypeDefinitionNode>[];
    final inputTypes = <InputObjectTypeDefinitionNode>[];
    final unionTypes = <UnionTypeDefinitionNode>[];
    final interfaceTypes = <InterfaceTypeDefinitionNode>[];
    final scalarTypes = <ScalarTypeDefinitionNode>[];

    for (final def in ast.definitions) {
      if (def is OperationDefinitionNode) {
        operations.add(def);
      } else if (def is FragmentDefinitionNode) {
        fragments.add(def);
      } else if (def is ObjectTypeDefinitionNode) {
        objectTypes.add(def);
      } else if (def is EnumTypeDefinitionNode) {
        enumTypes.add(def);
      } else if (def is InputObjectTypeDefinitionNode) {
        inputTypes.add(def);
      } else if (def is UnionTypeDefinitionNode) {
        unionTypes.add(def);
      } else if (def is InterfaceTypeDefinitionNode) {
        interfaceTypes.add(def);
      } else if (def is ScalarTypeDefinitionNode) {
        scalarTypes.add(def);
      }
    }

    return ParsedGraphQLDocument(
      ast: ast,
      operations: operations,
      fragments: fragments,
      objectTypes: objectTypes,
      enumTypes: enumTypes,
      inputTypes: inputTypes,
      unionTypes: unionTypes,
      interfaceTypes: interfaceTypes,
      scalarTypes: scalarTypes,
    );
  }
}
