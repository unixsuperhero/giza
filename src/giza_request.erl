-module(giza_request).

-include("giza.hrl").
-include("giza_internal.hrl").

-export([send/1]).

send(Query) ->
  case connect(Query) of
    {ok, Sock} ->
      case write_command(Sock, Query) of
        ok ->
          write_query(Sock, Query),
          %% Throw away command version in response
          gen_tcp:recv(Sock, 4),
          {ok, Result} = gen_tcp:recv(Sock, 4),
          gen_tcp:close(Sock),
          giza_proto_util:binary_to_number(Result, 32);
        CommandError ->
         CommandError
      end;
    ConnectError ->
      ConnectError
  end.

%% Internal functions
write_query(Sock, Query) ->
  {Bytes, Size} =  query_to_bytes(Query),
  giza_proto_util:write_number(Sock, Size, 32),
  gen_tcp:send(Sock, Bytes).

query_to_bytes(Query) ->
  Commands = query_to_commands(Query),
  commands_to_bytes(Commands, 0, []).

query_to_commands(Query) ->
  [{32, 1}, %% Number of queries
   {32, Query#giza_query.offset},
   {32, Query#giza_query.limit},
   {32, Query#giza_query.mode},
   {32, Query#giza_query.ranker},
   {32, Query#giza_query.sort},
   {string, Query#giza_query.sort_by},
   {string, Query#giza_query.query_string},
   %% query weights
   {32, 0},
   {string, Query#giza_query.index},
   {32, 0},
   {32, Query#giza_query.min_id},
   {32, Query#giza_query.max_id},
   %% Filter count
   {32, 0},
   {32, Query#giza_query.group_fun},
   {string, Query#giza_query.group_by},
   %% Max matches
   {32, 1000},
   {string, Query#giza_query.group_sort},
   %% Cutoff
   {32, 0},
   %% Retry count
   {32, 5},
   %% Retry wait
   {32, 5},
   %% Group distinct
   {32, 0},
   %% Disable geo searching
   {32, 0},
   %% Index weights
   {32, 0},
   %% Max query time -- essentially unlimited
   {32, 0},
   %% Field weights
   {32, 0},
   %% Comment
   {string, ?EMPTY_STRING}].

commands_to_bytes([], FinalSize, Accum) ->
  {lists:reverse(Accum), FinalSize};
commands_to_bytes([{Type, Value}|T], CurrentSize, Accum) when is_number(Type) ->
  Bytes = giza_proto_util:convert_number(Value, Type),
  commands_to_bytes(T, CurrentSize + size(Bytes), [Bytes|Accum]);
commands_to_bytes([{string, String}|T], CurrentSize, Accum) ->
  [Size, String] = giza_proto_util:convert_string(String),
  commands_to_bytes(T, CurrentSize + size(Size) + size(String), [[Size, String]|Accum]).

write_command(Sock, Query) ->
  giza_proto_util:write_number(Sock, Query#giza_query.command, 16),
  giza_proto_util:write_number(Sock, Query#giza_query.command_version, 16).

connect(Query) ->
  case gen_tcp:connect(Query#giza_query.host,
                       Query#giza_query.port,
                       [binary, {packet, raw},
                        {active, false}]) of
    {ok, Sock} ->
      case verify_version(Sock) of
        ok ->
          giza_proto_util:write_number(Sock, ?SPHINX_MAJOR_PROTO, 32),
          {ok, Sock};
        VerifyError ->
          gen_tcp:close(Sock),
          VerifyError
      end;
    ConnectError ->
      ConnectError
  end.

verify_version(Sock) ->
  {ok, RawVersion} = gen_tcp:recv(Sock, 4),
  case giza_proto_util:binary_to_number(RawVersion, 32, true) of
    ?SPHINX_MAJOR_PROTO ->
      ok;
    BadVersion ->
      {error, {bad_version, BadVersion}}
  end.