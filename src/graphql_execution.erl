-module(graphql_execution).
-author("mrchex").

%% API
-export([
  execute/6
]).

print(Text)-> print(Text, []).
print(Text, Args) -> io:format(Text ++ "~n", Args).

% Operation name can be null
execute(Schema, Document, OperationName, VariableValues, InitialValue, Context)->
  try executor(Schema, Document, OperationName, VariableValues, InitialValue, Context) of
    Result -> Result
  catch
    {error, Type, Msg} ->
      #{error => Msg, type => Type}
  end.


executor(Schema, Document, OperationName, VariableValues, InitialValue, Context)->
  Operation = get_operation(Document, OperationName),
  CoercedVariableValues = coerceVariableValues(Schema, Operation, VariableValues),
  case Operation of
    #{<<"operation">> := <<"query">>} ->
      execute_query(Operation, Schema, CoercedVariableValues, InitialValue, Context);
    #{<<"operation">> := WantedOperation} ->
      throw({error, execute, <<"Currently operation ", WantedOperation/binary, " does not support">>})
  end.

% throw validation error when operation not found or document define multiple
get_operation(Document, OperationName)->
  Definitions = maps:get(<<"definitions">>, Document, []),
  case get_operation_from_definitions(Definitions, OperationName) of
    {ok, Operation} -> Operation;
    {error, Error} -> throw({error, get_operation, Error})
  end.

get_operation_from_definitions(Definitions, OperationName) ->
  case get_operation_from_definitions(Definitions, OperationName, undefined) of
    undefined -> {error, <<"Operation not found">>};
    Operation -> {ok, Operation}
  end.


% TODO: has no spec result: when expented only one operation given first
% FIXME: http://facebook.github.io/graphql/#sec-Executing-Requests
get_operation_from_definitions([], _, Operation)-> Operation;
% when we first meet operation - continue with what name
get_operation_from_definitions([#{<<"kind">> := <<"OperationDefinition">>, <<"operation">> := OperationName} = Operation|Tail], null, _)->
  get_operation_from_definitions(Tail, OperationName, Operation);
% when we meet another operation that named like we already founded
get_operation_from_definitions([#{<<"kind">> := <<"OperationDefinition">>, <<"operation">> := OperationName}|_], OperationName, _)->
  {error, <<"Document defines multiple operations, otherwise the document is expected to only contain a single operation">>};
get_operation_from_definitions([_|Tail], OperationName, Operation)->
  get_operation_from_definitions(Tail, OperationName, Operation).


% TODO: implement me http://facebook.github.io/graphql/#CoerceVariableValues()
coerceVariableValues(_Schema, #{<<"variableDefinitions">> := null}, _VariableValues)->
  #{};
coerceVariableValues(_Schema, #{<<"variableDefinitions">> := VariableDefinitions}, VariableValues)->
  CoercedValues = lists:foldl(fun(Variable, CoercedValues0) ->
    VariableName = maps:get(<<"value">>, maps:get(<<"name">>, maps:get(<<"variable">>, Variable))),
    VariableType = case Variable of
                     #{<<"type">> := #{<<"kind">> := <<"NonNullType">>, <<"type">> := Type0}} ->

                       #{
                         <<"kind">> => <<"NonNullType">>,
                         <<"type">> => maps:get(<<"value">>, maps:get(<<"name">>, Type0))
                       };
                     #{<<"type">> := Type0} ->
                       #{
                         <<"kind">> => <<"NamedType">>,
                         <<"type">> => maps:get(<<"value">>, maps:get(<<"name">>, Type0))
                       }
                   end,
    DefaultValue = maps:get(<<"defaultValue">>, Variable),
    case VariableType of
      #{<<"kind">> := <<"NonNullType">>, <<"type">> := Type} ->
        tryGetNonNullableValue(VariableName, VariableValues, CoercedValues0, DefaultValue, Type);
      #{<<"kind">> := _, <<"type">> := Type} ->
        tryGetValue(VariableName, VariableValues, CoercedValues0, DefaultValue, Type)
    end
  end, #{}, VariableDefinitions),
  CoercedValues.

tryGetNonNullableValue(VariableName, VariableValues, CoercedValues0, DefaultValue, Type) ->
  case maps:find(VariableName, VariableValues) of
    NullOrError when NullOrError =:= error orelse NullOrError =:= {ok, null} ->
      case DefaultValue of
        null ->
          ErrorMsg = <<"Variable '", VariableName/binary, "' can't be null">>,
          throw({error, args_validation, ErrorMsg});
        Value ->
          checkValueType(Value, Type, VariableName, CoercedValues0)
      end;
    {ok, Value} ->
      checkValueType(Value, Type, VariableName, CoercedValues0)
  end.

tryGetValue(VariableName, VariableValues, CoercedValues0, DefaultValue, Type) ->
  print("DefaultValue: ~p", [DefaultValue]),
  case maps:find(VariableName, VariableValues) of
    NullOrError when NullOrError =:= error orelse NullOrError =:= {ok, null} ->
      case DefaultValue of
        null ->
          CoercedValues0#{VariableName => null};
        Value ->
          checkValueType(Value, Type, VariableName, CoercedValues0)
      end;
    {ok, Value} ->
      checkValueType(Value, Type, VariableName, CoercedValues0)
  end.

checkValueType(Value, Type, VariableName, CoercedValues0) ->
  case Type of
    <<"Integer">> ->
      Value0 = tryParseInteger(Value, VariableName),
      checkType(Value0, fun erlang:is_integer/1, VariableName, CoercedValues0, <<"Integer">>);
    <<"Bool">> ->
      checkType(Value, fun erlang:is_boolean/1, VariableName, CoercedValues0, <<"Bool">>);
    <<"String">> ->
      checkType(Value, fun erlang:is_binary/1, VariableName, CoercedValues0, <<"String">>);
    <<"Float">> ->
      Value0 = tryParseFloat(Value, VariableName),
      checkType(Value, fun erlang:is_float/1, VariableName, CoercedValues0, <<"String">>);
    UnsuportedType ->
      ErrorMsg = <<"Unsupported type: ", UnsuportedType/binary, " of the variable ", VariableName/binary>>,
      throw({error, args_validation, ErrorMsg})
  end.

tryParseInteger(Value, VariableName) ->
  case is_integer(Value) of
    true ->
      Value;
    false ->
      case string:to_integer(binary_to_list(Value)) of
        {error, no_integer} ->
          ErrorMsg = <<"Variable '", VariableName/binary, "' must be Integer">>,
          throw({error, args_validation, ErrorMsg});
        {Int, _Rest} ->
          Int
      end
  end.

tryParseFloat(Value, VariableName) ->
  case is_float(Value) of
    true ->
      Value;
    false ->
      case string:to_float(binary_to_list(Value)) of
        {error, no_integer} ->
          ErrorMsg = <<"Variable '", VariableName/binary, "' must be Integer">>,
          throw({error, args_validation, ErrorMsg});
        {Int, _Rest} ->
          Int
      end
  end.

checkType(Value, Fun, VariableName, CoercedValues0, Type) ->
  case Fun(Value) of
    true ->
      CoercedValues0#{VariableName => Value};
    false ->
      ErrorMsg = <<"Variable '", VariableName/binary, "' must be ", Type/binary>>,
      throw({error, args_validation, ErrorMsg})
  end.


% TODO: complete me http://facebook.github.io/graphql/#CoerceArgumentValues()
coerceArgumentValues(ObjectType, Field, VariableValues) ->
  ArgumentValues = maps:get(<<"arguments">>, Field),
  FieldName = get_field_name(Field),
  ArgumentDefinitions = graphql_schema:get_argument_definitions(FieldName, ObjectType),
  maps:fold(fun(ArgumentName, ArgumentDefinition, CoercedValues) ->
    ArgumentType = graphql_schema:get_argument_type(ArgumentDefinition),
    DefaultValue = graphql_schema:get_argument_default(ArgumentDefinition),

    % 5 of http://facebook.github.io/graphql/#sec-Coercing-Field-Arguments
    Value = case ArgumentValues of
      null ->
        #{};
      _ ->
        get_field_argument_by_name(ArgumentName, ArgumentValues)
    end,
    case Value of
      #{<<"name">> := VariableName, <<"type">> := <<"Variable">>} ->
        case ArgumentType of
          {not_null, Type} ->
            tryGetNonNullableValue(VariableName, VariableValues, CoercedValues, DefaultValue, Type);
          {allow_null, Type} ->
            tryGetValue(VariableName, VariableValues, CoercedValues, DefaultValue, Type)
        end;
      #{} ->
        case ArgumentType of
          {not_null, Type} ->
            tryGetNonNullableValue(ArgumentName, ArgumentValues, CoercedValues, DefaultValue, Type);
          {allow_null, Type} ->
            tryGetValue(ArgumentName, ArgumentValues, CoercedValues, DefaultValue, Type)
        end
    end
  end, #{}, ArgumentDefinitions).

get_field_argument_by_name(ArgumentName, ArgumentValues)->
  case lists:filtermap(fun(X) ->
    case X of
      #{<<"value">> := #{<<"name">> := #{<<"value">> := ArgumentName}}} ->
        {true, X};
      #{<<"name">> := #{<<"value">> := ArgumentName }} ->
        {true, X};
      _ ->
        false
    end
  end, ArgumentValues) of
    [] ->
      #{};
    [#{<<"value">> := Value}] ->
      #{
        <<"type">> => maps:get(<<"kind">>, Value),
        <<"name">> => ArgumentName
      }
  end.


% http://facebook.github.io/graphql/#sec-Executing-Operations
execute_query(Query, Schema, VariableValues, InitialValue, Context) ->
  QueryType = maps:get(query, Schema),
  SelectionSet = maps:get(<<"selectionSet">>, Query),
%%  Data = execute_selection_set(SelectionSet, QueryType, InitialValue, VariableValues, Context),
  {T, Data} = timer:tc(fun execute_selection_set/6, [SelectionSet, QueryType, InitialValue, VariableValues, Context, true]),
  io:format("EXECUTE SELECTION SET TIMER: ~p~n", [T]),
  #{
    data => Data,
    errors => []
  }.

% http://facebook.github.io/graphql/#sec-Executing-Selection-Sets
execute_selection_set(SelectionSet, ObjectType, ObjectValue, VariableValues, Context)->
  execute_selection_set(SelectionSet, ObjectType, ObjectValue, VariableValues, Context, false).

execute_selection_set(SelectionSet, ObjectType, ObjectValue, VariableValues, Context, Parallel)->
  GroupedFieldSet = collect_fields(ObjectType, SelectionSet, VariableValues),

  MapFun = fun({ResponseKey, Fields})->
    % 6.3 - 3.a. Let fieldName be the name of the first entry in fields.
    #{<<"value">> := FieldName} = maps:get(<<"name">>, lists:nth(1, Fields)),
    Field = case graphql_schema:get_field(FieldName, ObjectType) of
      undefined ->
        ErrorMsg = <<
          "Field `", FieldName/binary,
          "` does not exist in ObjectType `",
          (graphql_schema:get_name(ObjectType))/binary, "`"
        >>,
        throw({error, validation_error, ErrorMsg});
      Field0 -> Field0
    end,

    % TODO: Must be implemented when we learn why its needed and what the point of use case
    % TODO: c.If fieldType is null:
    % TODO:    i.Continue to the next iteration of groupedFieldSet.
    FieldType = graphql_schema:get_field_type(Field),

    ResponseValue = executeField(ObjectType, ObjectValue, Fields, FieldType, VariableValues, Context),
    {ResponseKey, ResponseValue}

  end,

  case Parallel of
    true -> graphql:upmap(MapFun, GroupedFieldSet, 5000);
    false -> lists:map(MapFun, GroupedFieldSet)
  end.

% TODO: does not support directives and fragments(3.a, 3.b, 3.d, 3.e): http://facebook.github.io/graphql/#CollectFields()
collect_fields(ObjectType, SelectionSet, VariableValues) ->
  Selections = maps:get(<<"selections">>, SelectionSet),
  lists:foldl(fun(Selection, GroupedFields)->
    case Selection of
      #{<<"kind">> := <<"Field">>} -> % 3.c
        ResponseKey = get_response_key_from_selection(Selection),
        GroupForResponseKey = proplists:get_value(ResponseKey, GroupedFields, []),

        [
          {ResponseKey, [Selection|GroupForResponseKey]}
          | GroupedFields
        ]
    end
  end, [], Selections).

get_response_key_from_selection(#{<<"alias">> := null, <<"name">> := #{<<"value">> := Key}}) -> Key;
get_response_key_from_selection(#{<<"alias">> := #{<<"value">> := Key}}) -> Key.

executeField(ObjectType, ObjectValue, [Field|_]=Fields, FieldType, VariableValues, Context)->
  ArgumentValues = coerceArgumentValues(ObjectType, Field, VariableValues),
  FieldName = get_field_name(Field),
  case resolveFieldValue(ObjectType, ObjectValue, FieldName, ArgumentValues, Context) of
    {ResolvedValue, OverwritenContext} ->
      completeValue(FieldType, Fields, ResolvedValue, VariableValues, OverwritenContext);
    ResolvedValue ->
      completeValue(FieldType, Fields, ResolvedValue, VariableValues, Context)
  end.


get_field_name(#{<<"name">> := #{<<"value">> := FieldName}}) -> FieldName.

%%get_field_arguments(Field)->
%%  case maps:get(<<"arguments">>, Field) of
%%    null -> [];
%%    Args -> Args
%%  end.
%%
%%find_argument(_, []) -> undefined;
%%find_argument(ArgumentName, [#{<<"name">> := #{ <<"value">> := ArgumentName }} = Arg|_])-> Arg;
%%find_argument(ArgumentName, [_|Tail])-> find_argument(ArgumentName, Tail).

resolveFieldValue(ObjectType, ObjectValue, FieldName, ArgumentValues, Context)->
  Resolver = graphql_schema:get_field_resolver(FieldName, ObjectType),
  case erlang:fun_info(Resolver, arity) of
    {arity, 2} -> Resolver(ObjectValue, ArgumentValues);
    {arity, 3} -> Resolver(ObjectValue, ArgumentValues, Context)
  end.

% TODO: complete me http: //facebook.github.io/graphql/#CompleteValue()
completeValue(FieldType, Fields, Result, VariablesValues, Context)->
  case FieldType of
    [InnerType] ->
      case is_list(Result) of
        false -> throw({error, result_validation, <<"Non list result for list field type">>});
        true ->
          graphql:upmap_ordered(fun(ResultItem) ->
            completeValue(InnerType, Fields, ResultItem, VariablesValues, Context)
          end, Result, 5000)
      end;
    {object, ObjectTypeFun} ->
      ObjectType = ObjectTypeFun(),
      SubSelectionSet = mergeSelectionSet(Fields),
      execute_selection_set(#{<<"selections">> => SubSelectionSet}, ObjectType, Result, VariablesValues, Context);

    _ -> Result
  end.

mergeSelectionSet(Fields)->
  lists:foldl(fun(Field, SelectionSet) ->
    FieldSelectionSet = maps:get(<<"selectionSet">>, Field, null),
    case FieldSelectionSet of
      null -> SelectionSet;
      #{<<"selections">> := Selections} -> SelectionSet ++ Selections
    end
  end, [], Fields).