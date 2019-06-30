part of '../analysis.dart';

const _comparisonOperators = [
  TokenType.equal,
  TokenType.doubleEqual,
  TokenType.exclamationEqual,
  TokenType.lessMore,
  TokenType.and,
  TokenType.or,
  TokenType.less,
  TokenType.lessEqual,
  TokenType.more,
  TokenType.moreEqual
];

class TypeResolver {
  final Map<Typeable, ResolveResult> _results = {};

  ResolveResult _cache<T extends Typeable>(
      ResolveResult Function(T param) resolver, T typeable) {
    if (_results.containsKey(typeable)) {
      return _results[typeable];
    }

    final calculated = resolver(typeable);
    if (calculated.type != null) {
      _results[typeable] = calculated;
    }
    return calculated;
  }

  ResolveResult resolveOrInfer(Typeable t) {
    if (t is Column) {
      return resolveColumn(t);
    } else if (t is Variable) {
      return inferType(t);
    } else if (t is Expression) {
      return resolveExpression(t);
    }

    throw StateError('Unknown typeable $t');
  }

  ResolveResult justResolve(Typeable t) {
    if (t is Column) {
      return resolveColumn(t);
    } else if (t is Expression) {
      return resolveExpression(t);
    }

    throw StateError('Unknown typeable $t');
  }

  ResolveResult resolveColumn(Column column) {
    return _cache((column) {
      if (column is TableColumn) {
        // todo probably needs to be nullable when coming from a join?
        return ResolveResult(column.type);
      } else if (column is ExpressionColumn) {
        return resolveExpression(column.expression);
      }

      throw StateError('Unknown column $column');
    }, column);
  }

  ResolveResult resolveExpression(Expression expr) {
    return _cache((expr) {
      if (expr is Literal) {
        return resolveLiteral(expr);
      } else if (expr is UnaryExpression) {
        return resolveExpression(expr.inner);
      } else if (expr is Parentheses) {
        return resolveExpression(expr.expression);
      } else if (expr is Variable) {
        return const ResolveResult.needsContext();
      } else if (expr is Reference) {
        return resolveColumn(expr.resolved as Column);
      } else if (expr is FunctionExpression) {
        return resolveFunctionCall(expr);
      } else if (expr is IsExpression) {
        return const ResolveResult(ResolvedType.bool());
      } else if (expr is BinaryExpression) {
        final operator = expr.operator.type;
        if (_comparisonOperators.contains(operator)) {
          return const ResolveResult(ResolvedType.bool());
        } else {
          final type = _encapsulate(expr.childNodes.cast(),
              [BasicType.int, BasicType.real, BasicType.text, BasicType.blob]);
          return ResolveResult(type);
        }
      } else if (expr is BetweenExpression) {
        return const ResolveResult(ResolvedType.bool());
      } else if (expr is CaseExpression) {
        return resolveExpression(expr.whens.first.then);
      } else if (expr is SubQuery) {
        final columns = expr.select.resultSet.resolvedColumns;
        if (columns.length != 1) {
          // select queries _must_ have exactly one column
          return const ResolveResult.unknown();
        } else {
          return justResolve(columns.single);
        }
      }

      throw StateError('Unknown expression $expr');
    }, expr);
  }

  ResolveResult resolveLiteral(Literal l) {
    return _cache((l) {
      if (l is StringLiteral) {
        return ResolveResult(
            ResolvedType(type: l.isBinary ? BasicType.blob : BasicType.text));
      } else if (l is NumericLiteral) {
        if (l is BooleanLiteral) {
          return const ResolveResult(ResolvedType.bool());
        } else {
          return ResolveResult(
              ResolvedType(type: l.isInt ? BasicType.int : BasicType.real));
        }
      } else if (l is NullLiteral) {
        return const ResolveResult(
            ResolvedType(type: BasicType.nullType, nullable: true));
      }

      throw StateError('Unknown literal $l');
    }, l);
  }

  ResolveResult resolveFunctionCall(FunctionExpression call) {
    return _cache((FunctionExpression call) {
      List<Typeable> parameters;
      final sqlParameters = call.parameters;
      if (sqlParameters is ExprFunctionParameters) {
        parameters = sqlParameters.parameters;
      } else if (sqlParameters is StarFunctionParameter) {
        parameters = call.scope.availableColumns;
      }

      final firstNullable = justResolve(parameters.first).nullable;
      final anyNullable = parameters.map(justResolve).any((r) => r.nullable);

      switch (call.name.toLowerCase()) {
        case 'round':
          // if there is only one param, returns an int. otherwise real
          if (parameters.length == 1) {
            return ResolveResult(
                ResolvedType(type: BasicType.int, nullable: firstNullable));
          } else {
            return ResolveResult(
                ResolvedType(type: BasicType.real, nullable: anyNullable));
          }
          break;
        case 'sum':
          final firstType = justResolve(parameters.first);
          if (firstType.type?.type == BasicType.int) {
            return firstType;
          } else {
            return ResolveResult(ResolvedType(
                type: BasicType.real, nullable: firstType.nullable));
          }
          break; // can't happen, though
        case 'lower':
        case 'ltrim':
        case 'printf':
        case 'replace':
        case 'rtrim':
        case 'substr':
        case 'trim':
        case 'upper':
        case 'group_concat':
          return ResolveResult(
              ResolvedType(type: BasicType.text, nullable: firstNullable));
        case 'date':
        case 'time':
        case 'datetime':
        case 'julianday':
        case 'strftime':
        case 'char':
        case 'hex':
        case 'quote':
        case 'soundex':
        case 'sqlite_compileoption_set':
        case 'sqlite_version':
        case 'typeof':
          return const ResolveResult(ResolvedType(type: BasicType.text));
        case 'changes':
        case 'last_insert_rowid':
        case 'random':
        case 'sqlite_compileoption_used':
        case 'total_changes':
        case 'count':
          return const ResolveResult(ResolvedType(type: BasicType.int));
        case 'instr':
        case 'length':
        case 'unicode':
          return ResolveResult(
              ResolvedType(type: BasicType.int, nullable: anyNullable));
        case 'randomblob':
        case 'zeroblob':
          return const ResolveResult(ResolvedType(type: BasicType.blob));
        case 'total':
        case 'avg':
          return const ResolveResult(ResolvedType(type: BasicType.real));
        case 'abs':
        case 'likelihood':
        case 'likely':
        case 'unlikely':
          return justResolve(parameters.first);
        case 'coalesce':
        case 'ifnull':
          return ResolveResult(_encapsulate(parameters,
              [BasicType.int, BasicType.real, BasicType.text, BasicType.blob]));
        case 'nullif':
          return justResolve(parameters.first).withNullable(true);
        case 'max':
          return ResolveResult(_encapsulate(parameters, [
            BasicType.int,
            BasicType.real,
            BasicType.text,
            BasicType.blob
          ])).withNullable(true);
        case 'min':
          return ResolveResult(_encapsulate(parameters, [
            BasicType.blob,
            BasicType.text,
            BasicType.int,
            BasicType.real
          ])).withNullable(true);
      }

      throw StateError('Unknown function: ${call.name}');
    }, call);
  }

  ResolveResult inferType(Expression e) {
    return _cache<Expression>((e) {
      final parent = e.parent;
      if (parent is Expression) {
        final result = _argumentType(parent, e);
        if (result.needsContext) {
          return inferType(parent);
        } else {
          return result;
        }
      } else if (parent is Limit) {
        return const ResolveResult(ResolvedType(type: BasicType.int));
      } else if (parent is SetComponent) {
        return resolveColumn(parent.column.resolved as Column);
      }

      return const ResolveResult.unknown();
    }, e);
  }

  ResolveResult _argumentType(Expression parent, Expression argument) {
    if (parent is IsExpression ||
        parent is BinaryExpression ||
        parent is BetweenExpression ||
        parent is CaseExpression) {
      final relevant = parent.childNodes
          .lastWhere((node) => node is Expression && node != argument);
      return resolveExpression(relevant as Expression);
    } else if (parent is Parentheses || parent is UnaryExpression) {
      return const ResolveResult.needsContext();
    } else if (parent is FunctionExpression) {
      return resolveFunctionCall(parent);
    }

    throw StateError('Cannot infer argument type: $parent');
  }

  /// Returns the type of an expression in [expressions] that has the highest
  /// order in [types].
  ResolvedType _encapsulate(
      Iterable<Typeable> expressions, List<BasicType> types) {
    final argTypes = expressions
        .map((expr) => justResolve(expr).type)
        .where((t) => t != null);
    final type = types.lastWhere((t) => argTypes.any((arg) => arg.type == t));
    final notNull = argTypes.any((t) => !t.nullable);

    return ResolvedType(type: type, nullable: !notNull);
  }
}

/// Result of resolving a type. This can either have the resolved [type] set,
/// or it can inform the called that it [needsContext] to resolve the type
/// properly. Failure to resolve the type will have the [unknown] flag set.
///
/// When you see a [ResolveResult] that is unknown or needs context in the
/// final AST returned by [SqlEngine.analyze], assume that the type cannot be
/// determined.
class ResolveResult {
  /// The resolved type.
  final ResolvedType type;

  /// Whether more context is needed to resolve the type. Used internally by the
  /// analyze.
  final bool needsContext;

  /// Whether type resolution failed.
  final bool unknown;

  const ResolveResult(this.type)
      : needsContext = false,
        unknown = false;
  const ResolveResult.needsContext()
      : type = null,
        needsContext = true,
        unknown = false;
  const ResolveResult.unknown()
      : type = null,
        needsContext = false,
        unknown = true;

  bool get nullable => type?.nullable ?? true;

  /// Copies the result with the [nullable] information, if there is one. If
  /// there isn't, the failure state will be copied into the new
  /// [ResolveResult].
  ResolveResult withNullable(bool nullable) {
    if (type != null) {
      return ResolveResult(type.withNullable(nullable));
    } else if (needsContext != null) {
      return const ResolveResult.needsContext();
    } else {
      return const ResolveResult.unknown();
    }
  }

  @override
  bool operator ==(other) {
    return identical(this, other) ||
        other is ResolveResult &&
            other.type == type &&
            other.needsContext == needsContext &&
            other.unknown == unknown;
  }

  @override
  int get hashCode => type.hashCode + needsContext.hashCode + unknown.hashCode;

  @override
  String toString() {
    if (type != null) {
      return 'ResolveResult: $type';
    } else {
      return 'ResolveResult(needsContext: $needsContext, unknown: $unknown)';
    }
  }
}