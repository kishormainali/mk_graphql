import 'package:gql/ast.dart';
import 'package:gql/language.dart';

/// Formats a GraphQL [DocumentNode] AST into clean, standard-compliant GraphQL string.
String formatGraphQL(DocumentNode doc) {
  final formatter = _GraphQLAstFormatter();
  return formatter.formatDocument(doc);
}

/// Parses and formats a raw GraphQL string into clean, properly-indented GraphQL.
String formatGraphQLString(String source) {
  final doc = parseString(source);
  return formatGraphQL(doc);
}

class _GraphQLAstFormatter {
  static const String _indentStep = '  ';

  String _indent(int level) => _indentStep * level;

  String formatDocument(DocumentNode doc) {
    if (doc.definitions.isEmpty) return '';

    final buffer = StringBuffer();
    for (var i = 0; i < doc.definitions.length; i++) {
      final def = doc.definitions[i];
      _formatDefinition(buffer, def);

      if (i < doc.definitions.length - 1) {
        buffer.writeln();
        buffer.writeln();
      } else {
        buffer.writeln();
      }
    }
    return buffer.toString();
  }

  void _formatDefinition(StringBuffer buf, DefinitionNode def) {
    if (def is SchemaDefinitionNode) {
      _formatSchemaDefinition(buf, def);
    } else if (def is ObjectTypeDefinitionNode) {
      _formatObjectType(buf, def);
    } else if (def is InterfaceTypeDefinitionNode) {
      _formatInterfaceType(buf, def);
    } else if (def is UnionTypeDefinitionNode) {
      _formatUnionType(buf, def);
    } else if (def is EnumTypeDefinitionNode) {
      _formatEnumType(buf, def);
    } else if (def is InputObjectTypeDefinitionNode) {
      _formatInputObjectType(buf, def);
    } else if (def is ScalarTypeDefinitionNode) {
      _formatScalarType(buf, def);
    } else if (def is DirectiveDefinitionNode) {
      _formatDirectiveDefinition(buf, def);
    } else if (def is OperationDefinitionNode) {
      _formatOperation(buf, def);
    } else if (def is FragmentDefinitionNode) {
      _formatFragment(buf, def);
    } else if (def is ObjectTypeExtensionNode) {
      _formatObjectTypeExtension(buf, def);
    } else if (def is InterfaceTypeExtensionNode) {
      _formatInterfaceTypeExtension(buf, def);
    } else if (def is UnionTypeExtensionNode) {
      _formatUnionTypeExtension(buf, def);
    } else if (def is EnumTypeExtensionNode) {
      _formatEnumTypeExtension(buf, def);
    } else if (def is InputObjectTypeExtensionNode) {
      _formatInputObjectTypeExtension(buf, def);
    } else if (def is ScalarTypeExtensionNode) {
      _formatScalarTypeExtension(buf, def);
    } else {
      // Fallback to printNode for any unrecognized custom definition
      buf.write(printNode(def).trimRight());
    }
  }

  void _writeDescription(StringBuffer buf, StringValueNode? desc, int indentLevel) {
    if (desc == null) return;
    final val = desc.value;
    if (val.trim().isEmpty) return;
    final pad = _indent(indentLevel);

    if (desc.isBlock || val.contains('\n')) {
      buf.writeln('$pad"""');
      for (final line in val.split('\n')) {
        buf.writeln('$pad${line.trimRight()}');
      }
      buf.writeln('$pad"""');
    } else {
      final escaped = val.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      buf.writeln('$pad"$escaped"');
    }
  }

  void _formatSchemaDefinition(StringBuffer buf, SchemaDefinitionNode node) {
    buf.write('schema');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    buf.writeln(' {');
    for (final op in node.operationTypes) {
      final opName = op.operation.name;
      buf.writeln('  $opName: ${op.type.name.value}');
    }
    buf.write('}');
  }

  void _formatObjectType(StringBuffer buf, ObjectTypeDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('type ${node.name.value}');
    if (node.interfaces.isNotEmpty) {
      buf.write(' implements ${node.interfaces.map((i) => i.name.value).join(' & ')}');
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.fields.isNotEmpty) {
      buf.writeln(' {');
      _formatFields(buf, node.fields, 1);
      buf.write('}');
    }
  }

  void _formatObjectTypeExtension(StringBuffer buf, ObjectTypeExtensionNode node) {
    buf.write('extend type ${node.name.value}');
    if (node.interfaces.isNotEmpty) {
      buf.write(' implements ${node.interfaces.map((i) => i.name.value).join(' & ')}');
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.fields.isNotEmpty) {
      buf.writeln(' {');
      _formatFields(buf, node.fields, 1);
      buf.write('}');
    }
  }

  void _formatInterfaceType(StringBuffer buf, InterfaceTypeDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('interface ${node.name.value}');
    if (node.interfaces.isNotEmpty) {
      buf.write(' implements ${node.interfaces.map((i) => i.name.value).join(' & ')}');
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.fields.isNotEmpty) {
      buf.writeln(' {');
      _formatFields(buf, node.fields, 1);
      buf.write('}');
    }
  }

  void _formatInterfaceTypeExtension(StringBuffer buf, InterfaceTypeExtensionNode node) {
    buf.write('extend interface ${node.name.value}');
    if (node.interfaces.isNotEmpty) {
      buf.write(' implements ${node.interfaces.map((i) => i.name.value).join(' & ')}');
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.fields.isNotEmpty) {
      buf.writeln(' {');
      _formatFields(buf, node.fields, 1);
      buf.write('}');
    }
  }

  void _formatFields(StringBuffer buf, List<FieldDefinitionNode> fields, int indentLevel) {
    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      final isComplex = (field.description != null && field.description!.value.trim().isNotEmpty) ||
          field.args.any((a) => a.description != null && a.description!.value.trim().isNotEmpty) ||
          field.args.length > 2;

      if (i > 0 && isComplex) {
        buf.writeln();
      }

      _formatFieldDefinition(buf, field, indentLevel);

      if (i < fields.length - 1 && isComplex) {
        buf.writeln();
      }
    }
  }

  void _formatFieldDefinition(StringBuffer buf, FieldDefinitionNode node, int indentLevel) {
    _writeDescription(buf, node.description, indentLevel);
    final pad = _indent(indentLevel);
    buf.write('$pad${node.name.value}');

    if (node.args.isNotEmpty) {
      final hasArgDescriptions =
          node.args.any((a) => a.description != null && a.description!.value.trim().isNotEmpty);
      final inlineArgs = node.args
          .map((a) => _formatInputValue(a, indentLevel: 0, includeDescription: false))
          .join(', ');
      final inlineCandidate = '($inlineArgs)';

      if (!hasArgDescriptions &&
          node.args.length <= 2 &&
          (pad.length + node.name.value.length + inlineCandidate.length <= 80)) {
        buf.write(inlineCandidate);
      } else {
        buf.writeln('(');
        for (var i = 0; i < node.args.length; i++) {
          final arg = node.args[i];
          _writeDescription(buf, arg.description, indentLevel + 1);
          final argPad = _indent(indentLevel + 1);
          buf.write('$argPad${arg.name.value}: ${_formatType(arg.type)}');
          if (arg.defaultValue != null) {
            buf.write(' = ${_formatValue(arg.defaultValue!)}');
          }
          if (arg.directives.isNotEmpty) {
            buf.write(' ${_formatDirectives(arg.directives)}');
          }
          buf.writeln();
        }
        buf.write('$pad)');
      }
    }

    buf.write(': ${_formatType(node.type)}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    buf.writeln();
  }

  void _formatUnionType(StringBuffer buf, UnionTypeDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('union ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.types.isNotEmpty) {
      final typesStr = node.types.map((t) => t.name.value).join(' | ');
      if (typesStr.length > 60) {
        buf.writeln(' =');
        for (final t in node.types) {
          buf.writeln('  | ${t.name.value}');
        }
      } else {
        buf.write(' = $typesStr');
      }
    }
  }

  void _formatUnionTypeExtension(StringBuffer buf, UnionTypeExtensionNode node) {
    buf.write('extend union ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.types.isNotEmpty) {
      buf.write(' = ${node.types.map((t) => t.name.value).join(' | ')}');
    }
  }

  void _formatEnumType(StringBuffer buf, EnumTypeDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('enum ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    buf.writeln(' {');

    final hasAnyDescriptions =
        node.values.any((v) => v.description != null && v.description!.value.trim().isNotEmpty);

    for (var i = 0; i < node.values.length; i++) {
      final val = node.values[i];
      if (hasAnyDescriptions && i > 0) {
        buf.writeln();
      }
      _writeDescription(buf, val.description, 1);
      final pad = _indent(1);
      buf.write('$pad${val.name.value}');
      if (val.directives.isNotEmpty) {
        buf.write(' ${_formatDirectives(val.directives)}');
      }
      buf.writeln();
    }
    buf.write('}');
  }

  void _formatEnumTypeExtension(StringBuffer buf, EnumTypeExtensionNode node) {
    buf.write('extend enum ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    buf.writeln(' {');
    for (final val in node.values) {
      final pad = _indent(1);
      buf.write('$pad${val.name.value}');
      if (val.directives.isNotEmpty) {
        buf.write(' ${_formatDirectives(val.directives)}');
      }
      buf.writeln();
    }
    buf.write('}');
  }

  void _formatInputObjectType(StringBuffer buf, InputObjectTypeDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('input ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.fields.isNotEmpty) {
      buf.writeln(' {');
      final hasAnyDescriptions =
          node.fields.any((f) => f.description != null && f.description!.value.trim().isNotEmpty);

      for (var i = 0; i < node.fields.length; i++) {
        final field = node.fields[i];
        if (hasAnyDescriptions && i > 0) {
          buf.writeln();
        }
        _writeDescription(buf, field.description, 1);
        final pad = _indent(1);
        buf.write('$pad${field.name.value}: ${_formatType(field.type)}');
        if (field.defaultValue != null) {
          buf.write(' = ${_formatValue(field.defaultValue!)}');
        }
        if (field.directives.isNotEmpty) {
          buf.write(' ${_formatDirectives(field.directives)}');
        }
        buf.writeln();
      }
      buf.write('}');
    }
  }

  void _formatInputObjectTypeExtension(StringBuffer buf, InputObjectTypeExtensionNode node) {
    buf.write('extend input ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    if (node.fields.isNotEmpty) {
      buf.writeln(' {');
      for (final field in node.fields) {
        final pad = _indent(1);
        buf.write('$pad${field.name.value}: ${_formatType(field.type)}');
        if (field.defaultValue != null) {
          buf.write(' = ${_formatValue(field.defaultValue!)}');
        }
        buf.writeln();
      }
      buf.write('}');
    }
  }

  void _formatScalarType(StringBuffer buf, ScalarTypeDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('scalar ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
  }

  void _formatScalarTypeExtension(StringBuffer buf, ScalarTypeExtensionNode node) {
    buf.write('extend scalar ${node.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
  }

  void _formatDirectiveDefinition(StringBuffer buf, DirectiveDefinitionNode node) {
    _writeDescription(buf, node.description, 0);
    buf.write('directive @${node.name.value}');
    if (node.args.isNotEmpty) {
      buf.writeln('(');
      for (final arg in node.args) {
        _writeDescription(buf, arg.description, 1);
        final pad = _indent(1);
        buf.write('$pad${arg.name.value}: ${_formatType(arg.type)}');
        if (arg.defaultValue != null) {
          buf.write(' = ${_formatValue(arg.defaultValue!)}');
        }
        buf.writeln();
      }
      buf.write(')');
    }
    if (node.repeatable) {
      buf.write(' repeatable');
    }
    final locations = node.locations.map(_formatDirectiveLocation).join(' | ');
    buf.write(' on $locations');
  }

  void _formatOperation(StringBuffer buf, OperationDefinitionNode node) {
    final opType = node.type.name;
    if (node.name == null && node.variableDefinitions.isEmpty && node.directives.isEmpty) {
      buf.writeln('{');
      _formatSelectionSet(buf, node.selectionSet, 1);
      buf.write('}');
      return;
    }

    buf.write(opType);
    if (node.name != null) {
      buf.write(' ${node.name!.value}');
    }
    if (node.variableDefinitions.isNotEmpty) {
      if (node.variableDefinitions.length <= 2) {
        final vars = node.variableDefinitions.map(_formatVariableDefinition).join(', ');
        if (vars.length <= 60) {
          buf.write('($vars)');
        } else {
          buf.writeln('(');
          for (final v in node.variableDefinitions) {
            buf.writeln('  ${_formatVariableDefinition(v)}');
          }
          buf.write(')');
        }
      } else {
        buf.writeln('(');
        for (final v in node.variableDefinitions) {
          buf.writeln('  ${_formatVariableDefinition(v)}');
        }
        buf.write(')');
      }
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    buf.writeln(' {');
    _formatSelectionSet(buf, node.selectionSet, 1);
    buf.write('}');
  }

  void _formatFragment(StringBuffer buf, FragmentDefinitionNode node) {
    buf.write('fragment ${node.name.value} on ${node.typeCondition.on.name.value}');
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    buf.writeln(' {');
    _formatSelectionSet(buf, node.selectionSet, 1);
    buf.write('}');
  }

  void _formatSelectionSet(StringBuffer buf, SelectionSetNode set, int indentLevel) {
    for (final sel in set.selections) {
      if (sel is FieldNode) {
        final pad = _indent(indentLevel);
        buf.write(pad);
        if (sel.alias != null) {
          buf.write('${sel.alias!.value}: ');
        }
        buf.write(sel.name.value);
        if (sel.arguments.isNotEmpty) {
          final args = sel.arguments
              .map((a) => '${a.name.value}: ${_formatValue(a.value)}')
              .join(', ');
          buf.write('($args)');
        }
        if (sel.directives.isNotEmpty) {
          buf.write(' ${_formatDirectives(sel.directives)}');
        }
        if (sel.selectionSet != null) {
          buf.writeln(' {');
          _formatSelectionSet(buf, sel.selectionSet!, indentLevel + 1);
          buf.writeln('$pad}');
        } else {
          buf.writeln();
        }
      } else if (sel is FragmentSpreadNode) {
        final pad = _indent(indentLevel);
        buf.write('$pad...${sel.name.value}');
        if (sel.directives.isNotEmpty) {
          buf.write(' ${_formatDirectives(sel.directives)}');
        }
        buf.writeln();
      } else if (sel is InlineFragmentNode) {
        final pad = _indent(indentLevel);
        buf.write('$pad...');
        if (sel.typeCondition != null) {
          buf.write(' on ${sel.typeCondition!.on.name.value}');
        }
        if (sel.directives.isNotEmpty) {
          buf.write(' ${_formatDirectives(sel.directives)}');
        }
        buf.writeln(' {');
        _formatSelectionSet(buf, sel.selectionSet, indentLevel + 1);
        buf.writeln('$pad}');
      }
    }
  }

  String _formatInputValue(InputValueDefinitionNode node,
      {required int indentLevel, required bool includeDescription}) {
    final buf = StringBuffer();
    if (includeDescription) {
      _writeDescription(buf, node.description, indentLevel);
    }
    final pad = _indent(indentLevel);
    buf.write('$pad${node.name.value}: ${_formatType(node.type)}');
    if (node.defaultValue != null) {
      buf.write(' = ${_formatValue(node.defaultValue!)}');
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    return buf.toString();
  }

  String _formatVariableDefinition(VariableDefinitionNode node) {
    final buf = StringBuffer('\$${node.variable.name.value}: ${_formatType(node.type)}');
    final defVal = node.defaultValue?.value;
    if (defVal != null) {
      buf.write(' = ${_formatValue(defVal)}');
    }
    if (node.directives.isNotEmpty) {
      buf.write(' ${_formatDirectives(node.directives)}');
    }
    return buf.toString();
  }


  String _formatType(TypeNode node) {
    if (node is NamedTypeNode) {
      return '${node.name.value}${node.isNonNull ? '!' : ''}';
    } else if (node is ListTypeNode) {
      return '[${_formatType(node.type)}]${node.isNonNull ? '!' : ''}';
    }
    return '';
  }

  String _formatValue(ValueNode node) {
    if (node is VariableNode) {
      return '\$${node.name.value}';
    } else if (node is IntValueNode) {
      return node.value;
    } else if (node is FloatValueNode) {
      return node.value;
    } else if (node is StringValueNode) {
      if (node.isBlock) {
        return '"""\n${node.value}\n"""';
      }
      final escaped = node.value
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r')
          .replaceAll('\t', r'\t');
      return '"$escaped"';
    } else if (node is BooleanValueNode) {
      return node.value ? 'true' : 'false';
    } else if (node is EnumValueNode) {
      return node.name.value;
    } else if (node is ListValueNode) {
      return '[${node.values.map(_formatValue).join(', ')}]';
    } else if (node is ObjectValueNode) {
      return '{${node.fields.map((f) => '${f.name.value}: ${_formatValue(f.value)}').join(', ')}}';
    } else if (node is NullValueNode) {
      return 'null';
    }
    return '';
  }

  String _formatDirectives(List<DirectiveNode> directives) {
    return directives.map((d) {
      if (d.arguments.isEmpty) {
        return '@${d.name.value}';
      }
      final args = d.arguments.map((a) => '${a.name.value}: ${_formatValue(a.value)}').join(', ');
      return '@${d.name.value}($args)';
    }).join(' ');
  }

  String _formatDirectiveLocation(DirectiveLocation loc) {
    final name = loc.name;
    final result = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      final char = name[i];
      if (i > 0 && char == char.toUpperCase() && char != char.toLowerCase()) {
        result.write('_${char.toUpperCase()}');
      } else {
        result.write(char.toUpperCase());
      }
    }
    return result.toString();
  }
}
