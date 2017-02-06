-include_lib("eunit/include/eunit.hrl").

-module(graphql_test).
-author("mrchex").


recursion_nesting_test()->
  Document = <<"{
    nest {
      info
      nest {
        info
        nest {
          nest {
            info
          }
        }
      }
    }
  }">>,

  ?assertEqual( #{
    % TODO: fix sorting?
    data => [{<<"nest">>,
      [{<<"nest">>,
        [{<<"nest">>,
          [{<<"nest">>,
            [{<<"info">>,
              <<"information does not availiable">>}]}]},
          {<<"info">>,<<"information does not availiable">>}]},
        {<<"info">>,<<"information does not availiable">>}]}], errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{}) ).


arguments_valid_passing_test() ->
  Document = <<"{
    arg(hello: \"world\") {
      greatings_for
    }
  }">>,

  ?assertEqual( #{
    data => [
      {<<"arg">>, [
        {<<"greatings_for">>, <<"world">>}
      ]}
    ],
    errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{}) ).


default_argument_passing_test() ->
  Document = <<"{ arg { greatings_for } }">>,
  ?assertEqual(#{
    data => [
      {<<"arg">>, [
        {<<"greatings_for">>, <<"default value">>}
      ]}
    ],
    errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{})).

% is correnct this test? If in schema arguments defined - need it pass to the resolver or not?
no_arguments_passing_test() ->
  Document = <<"{ arg_without_defaults { arguments_count } }">>,
  ?assertEqual(#{
    data => [
      {<<"arg_without_defaults">>, [
        {<<"arguments_count">>, 0}
      ]}
    ],
    errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{})).

map_support_default_resolver_test() ->
  Document = <<"{ hello }">>,
  ?assertEqual(#{
    data => [
      {<<"hello">>, <<"world">>}
    ],
    errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{<<"hello">> => <<"world">>})).

proplists_support_default_resolver_test() ->
  Document = <<"{ hello }">>,
  ?assertEqual(#{
    data => [
      {<<"hello">>, <<"proplists">>}
    ],
    errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, [{<<"hello">>, <<"proplists">>}])).

support_for_boolean_types_test() ->
  Document = <<"{ arg_bool(bool: true) }">>,
  ?assertEqual(#{
    data => [
      {<<"arg_bool">>, true}
    ],
    errors => []
  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{})).

invalid_argument_type_test() ->
  Document = <<"{
    arg(id: \"test\"){
      id
    }
  }">>,
  ?assertEqual(#{error => <<"Variable 'id' must be integer">>, type => args_validation},
    graphql:execute(graphql_test_schema:schema_root(), Document, #{})).

not_null_variable_test() ->
  Document = <<"{
    nn_arg{
      nn_id
    }
  }">>,
  ?assertEqual(#{error => <<"Variable: 'nn_id' can't be null">>, type => args_validation},
    graphql:execute(graphql_test_schema:schema_root(), Document, #{})).

query_variables_test() ->
  Document = <<"
  query($id: Integer) {
    arg(id: $id){
      id
    }
  }">>,
  Variables = #{<<"id">> => 1},
  ?assertEqual(
    #{data => [{<<"arg">>,[{<<"id">>,1}]}],errors => []},
    graphql:execute(graphql_test_schema:schema_root(), Document, Variables, #{}, undefined)).

query_variables_not_provided_test() ->
  Document = <<"
  query($id: Integer) {
    arg(id: $id){
      id
    }
  }">>,
  ?assertEqual(
    #{error => <<"Variable 'id'can't be null, must be Integer">>, type => args_validation},
    graphql:execute(graphql_test_schema:schema_root(), Document, #{})).
%%default_resolver_must_pass_own_arguments_to_child_test() ->
%%  Document = <<"{
%%    arg:arg_without_resolver(argument: \"ok\") {
%%      argument
%%    }
%%  }">>,
%%
%%  ?assertEqual(#{
%%    data => #{
%%      <<"arg">> => #{
%%        <<"argument">> => <<"ok">>
%%      }
%%    },
%%    errors => []
%%  }, graphql:execute(graphql_test_schema:schema_root(), Document, #{})).



%%receiver(I)->
%%  case I of
%%    0 -> ok;
%%    _ -> receive
%%      {ololo, ok, _} ->
%%        receiver(I-1)
%%    end
%%  end.
%%
%%ololo() ->
%%
%%  %%  Sync results:
%%  %%    Time start: {12,28,41}
%%  %%    Time end: {12,34,10}
%%  %%    Operations performed: 1000000
%%
%%  %% Async results:
%%  %%    Time start: {12,40,37}
%%  %%    Time end: {12,40,39}
%%  %%    Operations performed: 10000
%%
%%  %% with io:format
%%  %%    Time start: {12,41,15}
%%  %%    Time end: {12,44,20}
%%  %%    Operations performed: 1000000
%%
%%  %% without io:format
%%  %%    Time start: {12,41,15}
%%  %%    Time end: {12,44,20}
%%  %%    Operations performed: 1000000
%%
%%  TimeStart = time(),
%%  CountIterations = 1000000,
%%  Self = self(),
%%
%%  lists:foreach(fun(I) ->
%%    io:format("["),
%%    spawn(fun() ->
%%      ok = ololo(CountIterations, Self)
%%    end),
%%
%%    receiver(CountIterations),
%%    io:format("~p]", [I])
%%  end, lists:seq(0, 1000)),
%%
%%  TimeEnd = time(),
%%  io:format("~n~nTime start: ~p~nTime end: ~p~nOperations performed: ~p~n", [TimeStart, TimeEnd, CountIterations]).
%%
%%ololo(0, _)-> ok;
%%ololo(I, Pid)->
%%  spawn(fun() ->
%%
%%    Document = <<"{
%%      nest {
%%        info
%%        nest {
%%          info
%%          nest {
%%            nest {
%%              info
%%            }
%%          }
%%        }
%%      }
%%    }">>,
%%    graphql:execute(graphql_test_schema:schema_root(), Document, #{}),
%%
%%    Pid ! {ololo, ok, I}
%%  end),
%%  ololo(I-1, Pid).
