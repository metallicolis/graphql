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
      print("Error in ~p! Msg: ~p", [Type, Msg]),
      #{error => Msg, type => Type}
  end.


executor(Schema, Document, OperationName, VariableValues, InitialValue, Context)->
  Operation = get_operation(Document, OperationName),
  CoercedVariableValues = coerceVariableValues(Schema, Operation, VariableValues),
  case Operation of
    #{operation := query} ->
      execute_query(Operation, Schema, CoercedVariableValues, InitialValue, Context);
    #{operation := WantedOperation} ->
      throw({error, execute, <<"Currently operation ", WantedOperation/binary, " does not support">>})
  end.

% throw validation error when operation not found or document define multiple
get_operation(Document, OperationName)->
  Definitions = maps:get(definitions, Document, []),
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
get_operation_from_definitions([#{kind := 'OperationDefinition', operation := OperationName} = Operation|Tail], null, _)->
  get_operation_from_definitions(Tail, OperationName, Operation);
% when we meet another operation that named like we already founded
get_operation_from_definitions([#{kind := 'OperationDefinition', operation := OperationName}|_], OperationName, _)->
  {error, <<"Document defines multiple operations, otherwise the document is expected to only contain a single operation">>};
get_operation_from_definitions([_|Tail], OperationName, Operation)->
  get_operation_from_definitions(Tail, OperationName, Operation).


% TODO: implement me http://facebook.github.io/graphql/#CoerceVariableValues()
coerceVariableValues(_Schema, #{<<"variableDefinitions">> := null}, _VariableValues)->
  #{};
coerceVariableValues(_Schema, #{<<"variableDefinitions">> := VariableDefinitions}, VariableValues)->
  CoercedValues = lists:foldl(fun(Variable, CoercedValues0) ->
    VariableName = coerce_variable_values_get_variable_name(Variable),
    print("~p: Variable: ~p", [?LINE, Variable]),
    VariableType = case Variable of
                     #{<<"type">> := #{<<"kind">> := <<"NonNullType">>,
                       <<"type">> := #{<<"name">> := #{<<"value">> := TypeName}}}} ->
                       {not_null, get_variable_type(TypeName)};
                     #{<<"type">> := #{<<"kind">> := <<"ListType">>,
                       <<"type">> := #{<<"name">> := #{<<"value">> := TypeName}}}} ->
                       {list, get_variable_type(TypeName)};
                     #{<<"type">> := #{<<"name">> := #{<<"value">> := TypeName}}} ->
                       get_variable_type(TypeName)
                   end,
    print("~p: Variable: ~p", [?LINE, Variable]),
    DefaultValueAndType = case maps:get(<<"defaultValue">>, Variable) of
                     null ->
                       null;
                     #{<<"kind">> := <<"ListValue">>, <<"values">> := Values} ->
                       Type =
                       Values0 = lists:map(fun(V) ->
                         maps:get(<<"value">>, V)
                       end, Values),
                       {Values0, VariableType};
                     #{<<"value">> := Value, <<"kind">> := Type} ->
                       {Value, Type}
                   end,
    print("~p: DefaultValueAndType: ~p", [?LINE, DefaultValueAndType]),
    case get_and_check_variable(VariableName, VariableValues, DefaultValueAndType, VariableType) of
      no_result ->
        CoercedValues0#{};
      Result ->
        CoercedValues0#{VariableName => Result}
    end
  end, #{}, VariableDefinitions),
  CoercedValues.

get_variable_type(Type) ->
  case Type of
    <<"Integer">> ->
      integer;
    <<"String">> ->
      string;
    <<"Boolean">> ->
      boolean;
    <<"Float">> ->
      float
  end.

coerce_variable_values_get_variable_name(#{<<"variable">> := #{<<"name">> := #{<<"value">> := Value}}}) ->
  Value.

get_and_check_variable(VariableName, VariableValues, DefaultValueAndType, Type) ->
  case maps:find(VariableName, VariableValues) of
    error ->
      case DefaultValueAndType of
        {Value, _Type} ->
          Value;
        null ->
          case Type of
            {not_null, _} ->
              ErrorMsg = <<"Variable: '", VariableName/binary, "' can't be null">>,
              throw({error, args_validation, ErrorMsg});
            _ ->
              no_result
          end
      end;
    {ok, Value} ->
      Type0 = case Type of
        {not_null, _} when Value =:= null ->
          ErrorMsg = <<"Variable: '", VariableName/binary, "' can't be null">>,
          throw({error, args_validation, ErrorMsg});
        {not_null, T} ->
          T;
        T ->
          T
      end,
      check_variable_or_argument_type(Value, Type0, VariableName)
  end.


check_variable_or_argument_type(null, _Type, VariableName) ->
  ErrorMsg = <<"Variable '", VariableName/binary, "'can't be null">>,
  throw({error, args_validation, ErrorMsg});
check_variable_or_argument_type(Value, integer, VariableName) ->
  Value0 = parse_numeric(Value, VariableName, integer),
  check_type(Value0, fun erlang:is_integer/1, VariableName, <<"Integer">>);
check_variable_or_argument_type(Value, float, VariableName) ->
  Value0 = parse_numeric(Value, VariableName, float),
  check_type(Value0, fun erlang:is_float/1, VariableName, <<"Float">>);
check_variable_or_argument_type(Value, boolean, VariableName) ->
  check_type(Value, fun erlang:is_boolean/1, VariableName, <<"Bool">>);
check_variable_or_argument_type(Value, string, VariableName) ->
  check_type(Value, fun erlang:is_binary/1, VariableName, <<"String">>);
check_variable_or_argument_type(Value, {list, Type}, VariableName) ->
  lists:map(fun(V) ->
    check_variable_or_argument_type(V, Type, VariableName)
    end, Value);
check_variable_or_argument_type(_Value, Type, VariableName) ->
  print("~p: Type: ~p", [?LINE, Type]),
  ErrorMsg = <<"Unsupported type for variable ", VariableName/binary>>,
  throw({error, args_validation, ErrorMsg}).

parse_numeric(Value, _VariableName, _Type) when is_number(Value)->
  Value;
parse_numeric(Value, VariableName, integer) ->
  try binary_to_integer(Value) of
    Value0 ->
      Value0
  catch
    error:_ ->
      ErrorMsg = <<"Variable '", VariableName/binary, "' isn't Integer">>,
      throw({error, args_validation, ErrorMsg})
  end;
parse_numeric(Value, VariableName, float) ->
  try binary_to_float(Value) of
    Value0 ->
      Value0
  catch
    error:_ ->
      ErrorMsg = <<"Variable '", VariableName/binary, "' isn't Float">>,
      throw({error, args_validation, ErrorMsg})
  end.

check_type(Value, Fun, VariableName, Type) ->
  case Fun(Value) of
    true ->
      Value;
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
    ArgumentType = case graphql_schema:get_argument_type(ArgumentDefinition) of
                     [Type] ->
                       {list, Type};
                     Type ->
                       Type
                   end,
    DefaultValue = graphql_schema:get_argument_default(ArgumentDefinition),

    % 5 of http://facebook.github.io/graphql/#sec-Coercing-Field-Arguments
    Value = case ArgumentValues of
      null ->
        [];
      _ ->
        get_field_argument_by_name(ArgumentName, ArgumentValues)
    end,
    Result = case Value of
      [] ->
        get_and_check_argument_value(ArgumentName, #{}, DefaultValue, ArgumentType);
      [#{<<"name">> := #{<<"value">> := ArgumentName}, <<"value">> := #{<<"value">> := Value0}}] ->
        get_and_check_argument_value(ArgumentName, #{ArgumentName => Value0}, DefaultValue, ArgumentType);
      [#{<<"name">> := #{<<"value">> := ArgumentName}, <<"value">> := #{<<"values">> := Values}}] ->
        Values0 = lists:map(fun(V) ->
          maps:get(<<"value">>, V)
        end, Values),
        get_and_check_argument_value(ArgumentName, #{ArgumentName => Values0}, DefaultValue, ArgumentType);
      [#{<<"value">> := #{<<"kind">> := <<"Variable">>}}] ->
        get_and_check_argument_value(ArgumentName, VariableValues, DefaultValue, ArgumentType)
    end,
    CoercedValues#{ArgumentName => Result}
  end, #{}, ArgumentDefinitions).

get_and_check_argument_value(ArgumentName, VariableValues, DefaultValue, ArgumentType) ->
  Type = case ArgumentType of
           {not_null, T} ->
             T;
           T ->
             T
         end,
  case maps:find(ArgumentName, VariableValues) of
    {ok, Value} ->
      check_variable_or_argument_type(Value, Type, ArgumentName);
    error ->
      case DefaultValue of
        null ->
          case ArgumentType of
            {not_null, _} ->
              ErrorMsg = <<"Variable: '", ArgumentName/binary, "' can't be null">>,
              throw({error, args_validation, ErrorMsg});
            _ ->
              null
          end;
        Value ->
          check_variable_or_argument_type(Value, Type, ArgumentName)
      end
  end.

get_field_argument_by_name(ArgumentName, ArgumentValues)->
  lists:filtermap(fun(X) ->
    case X of
      #{<<"value">> := #{<<"name">> := #{<<"value">> := ArgumentName}}} ->
        {true, X};
      #{<<"name">> := #{<<"value">> := ArgumentName }} ->
        {true, X};
      _ ->
        false
    end
  end, ArgumentValues).

% http://facebook.github.io/graphql/#sec-Executing-Operations
execute_query(Query, Schema, VariableValues, InitialValue, Context) ->
  QueryType = maps:get(query, Schema),
  SelectionSet = maps:get(selectionSet, Query),
%%  Data = execute_selection_set(SelectionSet, QueryType, InitialValue, VariableValues, Context),
  Parallel = false,
  {T, Data} = timer:tc(fun execute_selection_set/6, [SelectionSet, QueryType, InitialValue, VariableValues, Context, Parallel]),
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
    #{value := FieldName} = maps:get(name, lists:nth(1, Fields)),
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
  Selections = maps:get(selections, SelectionSet),
  lists:foldl(fun(Selection, GroupedFields)->
    case Selection of
      #{kind := 'Field'} -> % 3.c
        ResponseKey = get_response_key_from_selection(Selection),
        GroupForResponseKey = proplists:get_value(ResponseKey, GroupedFields, []),

        [
          {ResponseKey, [Selection|GroupForResponseKey]}
          | GroupedFields
        ]
    end
  end, [], Selections).

get_response_key_from_selection(#{alias := #{value := Key}}) -> Key;
get_response_key_from_selection(#{name := #{value := Key}}) -> Key.

executeField(ObjectType, ObjectValue, [Field|_]=Fields, FieldType, VariableValues, Context)->
  ArgumentValues = coerceArgumentValues(ObjectType, Field, VariableValues),
  FieldName = get_field_name(Field),
  case resolveFieldValue(ObjectType, ObjectValue, FieldName, ArgumentValues, Context) of
    {ResolvedValue, OverwritenContext} ->
      completeValue(FieldType, Fields, ResolvedValue, VariableValues, OverwritenContext);
    ResolvedValue ->
      completeValue(FieldType, Fields, ResolvedValue, VariableValues, Context)
  end.


get_field_name(#{name := #{value := FieldName}}) -> FieldName.

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
          lists:map(fun(ResultItem) ->
            completeValue(InnerType, Fields, ResultItem, VariablesValues, Context)
          end, Result)
      end;
    {object, ObjectTypeFun} ->
      case Result of
        null -> null;
        _ ->
          ObjectType = ObjectTypeFun(),
          SubSelectionSet = mergeSelectionSet(Fields),
          execute_selection_set(#{selections => SubSelectionSet}, ObjectType, Result, VariablesValues, Context)
      end;
    _ -> Result
  end.

mergeSelectionSet(Fields)->
  lists:foldl(fun(Field, SelectionSet) ->
    FieldSelectionSet = maps:get(selectionSet, Field, null),
    case FieldSelectionSet of
      null -> SelectionSet;
      #{selections := Selections} -> SelectionSet ++ Selections
    end
  end, [], Fields).