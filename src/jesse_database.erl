%%%=============================================================================
%% Copyright 2012- Klarna AB
%% Copyright 2015- AUTHORS
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc Schema definitions cache handling.
%%
%% All the schema definitions are stored in an ETS table for quick access during
%% validation. This module provides an interface for: 1) updating of schema
%% definitions in runtime; 2) getting of a schema definition by a key. When
%% an update is ordered, the update function checks a schema definition file
%% timestamp and compares it to a timestamp for the same schema in the `cache',
%% so, it will never update a schema in the database if the definition file
%% was not updated.
%% @end
%%%=============================================================================

-module(jesse_database).

%% API
-export([ add/3
        , add_uri/1
        , add_path/3
        , load/1
        , load_uri/1
        , load_all/0
        , delete/1
        ]).

-export_type([ error/0
             , store_result/0
             ]).

-type error() :: {error, error_reason()}.
-type error_reason() :: { 'database_error'
                        , Key :: string()
                        , 'schema_not_found' | 'unknown_uri_scheme'
                        }.

-type store_result() :: ok | [store_fail()].
-type store_fail()   :: {file:filename(), file:date_time(), reason()}.
-type reason()       :: term().

-define(JESSE_ETS, jesse_ets).

-include_lib("kernel/include/file.hrl").
-include("jesse_schema_validator.hrl").

%%% API
%% @doc Adds a schema definition `Schema' to the internal storage associated
%% with the key `Key'. It will overwrite an existing schema with the same key if
%% there is any.
-spec add( Key           :: string()
         , Schema        :: jesse:json_term()
         , ValidationFun :: fun((any()) -> boolean())
         ) -> store_result().
add(Key0, Schema, ValidationFun) ->
  Key = jesse_state:canonical_path(Key0, Key0),
  SchemaInfos = [{Key, 0, Schema}],
  store_schemas(SchemaInfos, ValidationFun).

%% @doc Add a schema definition to the internal storage identified by a URI Key.
%% Supported URI schemes are file:, http: and https:. If this fails, an
%% exception will be thrown.
-spec add_uri(Key :: string()) -> store_result().
add_uri("file://" ++ _ = Key) ->
  add_file_uri(Key);
add_uri("http://" ++ _ = Key) ->
  add_http_uri(Key);
add_uri("https://" ++ _ = Key) ->
  add_http_uri(Key);
add_uri(Key) ->
  throw({database_error, Key, unknown_uri_scheme}).

%% @doc Add schema definitions from all the files from directory `Dir', each
%% being validated by `ValidationFun', and stored in the internal storage.
%%
%% The file modification time will also be stored, to skip unnecessary updates.
%%
%% Schema definitions are stored in the format that `ParseFun' returns.
%%
%% NOTE: it's impossible to automatically update schema definitions added by
%%       add/2. The only way to update those is to use add/2 again with the new
%%       definition.
-spec add_path( Path          :: string()
              , ParseFun      :: fun((binary()) -> jesse:json_term())
              , ValidationFun :: fun((any()) -> boolean())
              ) -> store_result().
add_path(Path0, ParseFun, ValidationFun) ->
  "file://" ++ Path = jesse_state:canonical_path(Path0, "file:"),
  SchemaInfos = get_schema_infos(list_outdated(Path), ParseFun),
  store_schemas(SchemaInfos, ValidationFun).

%% @doc Loads a schema definition associated with, or sourced with the key `Key'
%% from the internal storage. If there is no such key in the storage, an
%% exception will be thrown.
-spec load(Key :: string()) -> jesse:json_term() | no_return().
load(Key0) ->
  Key = jesse_state:canonical_path(Key0, Key0),
  Table = create_table(table_name()),
  case ets:match_object(Table, {'_', Key, '_', '_'}) of
    %% ID
    [{_SourceKey, Key, _Mtime, Schema}] ->
      Schema;
    [] ->
      SourceKey = Key,
      case ets:match_object(Table, {SourceKey, '_', '_', '_'}) of
        %% Source (URI)
        [{SourceKey, _Key, _Mtime, Schema}] ->
          Schema;
        _ ->
          throw({database_error, Key, schema_not_found})
      end
  end.

%% @doc Loads a schema definition associated with, or sourced with the key `Key'
%% from the internal storage. If there is no such key in the storage, it will
%% try to fetch and add one to the internal storage if the Key uses the file:,
%% http: or https: URI scheme. If this fails as well, an exception will be
%% thrown.
-spec load_uri(Key :: string()) -> jesse:json_term() | no_return().
load_uri(Key) ->
  try
    load(Key)
  catch
    throw:{database_error, Key, schema_not_found} ->
      add_uri(Key),
      load(Key)
  end.

%% @doc Loads all schemas in the internal storage.
-spec load_all() -> [tuple()].
load_all() ->
  Table = create_table(table_name()),
  ets:tab2list(Table).

%% @doc Deletes a schema definition from the internal storage associated with,
%% or sourced with the key `Key'.
-spec delete(Key :: string()) -> ok.
delete(Key0) ->
  Key = jesse_state:canonical_path(Key0, Key0),
  Table = create_table(table_name()),
  SourceKey = Key,
  ets:match_delete(Table, {SourceKey, '_', '_', '_'}),
  ets:match_delete(Table, {'_', Key, '_', '_'}),
  ok.

%%% Internal functions
%% @doc Creates ETS table for internal cache if it does not exist yet,
%% otherwise the name of the table is returned.
%% @private
create_table(TableName) ->
  case table_exists(TableName) of
    true ->
      ok;
    false ->
      ets:new(TableName, [set, public, named_table])
  end,
  TableName.

%% @doc Checks if ETS table with name `TableName' exists.
%% @private
table_exists(TableName) ->
  ets:info(TableName) =/= undefined.

%% @doc Stores information on schema definitions `SchemaInfos' in the internal
%% storage. Uses `ValidationFun' to validate each schema definition before it
%% is stored. Returns `ok' in case if all the
%% schemas passed the validation and were stored, otherwise a list of invalid
%% entries is returned.
%% @private
store_schemas(SchemaInfos, ValidationFun) ->
  {Fails, _} = lists:foldl( fun store_schema/2
                          , {[], ValidationFun}
                          , SchemaInfos
                          ),
  case Fails of
    [] ->
      ok;
    Fails ->
      Fails
  end.

%% @private
store_schema(SchemaInfo, {Acc, ValidationFun}) ->
  {SourceKey, Mtime, Schema} = SchemaInfo,
  case ValidationFun(Schema) of
    true ->
      Object = { SourceKey
               , get_schema_id(Schema)
               , Mtime
               , Schema
               },
      Table = create_table(table_name()),
      ets:insert(Table, Object),
      {Acc, ValidationFun};
    false ->
      {[SchemaInfo | Acc], ValidationFun}
  end.

%% @doc Returns a list of schema files in `Path' which have outdated
%% cache entries.
%% @private
list_outdated(Path) ->
  case { list_dir(Path)
       , table_exists(table_name())
       } of
    {[] = Files, _TableExists} ->
      Files;
    {Files, false} ->
      Files;
    {Files, _TableExists} ->
      lists:filter(fun is_outdated/1, Files)
  end.

%% @doc Recursively lists all regular files from a directory `Dir`.
%% @private
list_dir(Dir) ->
  filelib:fold_files( Dir
                    , "^.+$" %% Allow any regular file.
                    , true
                    , fun(Path, Acc) -> [Path | Acc] end
                    , []
                    ).

%% @doc Checks if a schema file `Filename' has an outdated cache entry.
%% @private
is_outdated(File) ->
  SourceKey = "file://" ++ File,
  case ets:match_object(table_name(), {SourceKey, '_', '_', '_'}) of
    [] ->
      true;
    [{SourceKey, _Key, Mtime, _Schema}] ->
      {ok, #file_info{mtime = CurrentMtime}} = file:read_file_info(File),
      CurrentMtime > Mtime
  end.

%% @doc Loads schema definitions from a list of files `Files' located in
%% directory `Path', and parses each of entry by the given parse
%% function `ParseFun'. Silently ignores subdirectories.
%% @private
get_schema_infos(Files, ParseFun) ->
  {SchemaInfos, ParseFun} = lists:foldl( fun get_schema_info/2
                                       , {[], ParseFun}
                                       , Files
                                       ),
  SchemaInfos.

%% @private
get_schema_info(File, {Acc, ParseFun}) ->
  SourceKey = "file://" ++ filename:absname(File),
  {ok, SchemaBin} = file:read_file(File),
  Schema0 = try_parse(ParseFun, SchemaBin),
  Schema = case jesse_json_path:value(<<"id">>, Schema0, undefined) of
             undefined ->
               [ {<<"id">>, unicode:characters_to_binary(SourceKey)}
                 | Schema0
               ];
             _ ->
               Schema0
           end,
  {ok, #file_info{mtime = Mtime}} = file:read_file_info(File),
  {[{SourceKey, Mtime, Schema} | Acc], ParseFun}.

%% @doc Returns value of "id" field from json object `Schema', assuming that
%% the given json object has such a field, otherwise returns undefined.
%% @private
-spec get_schema_id(Schema :: jesse:json_term()) -> string() | undefined.
get_schema_id(Schema) ->
  case jesse_json_path:value(?ID, Schema, undefined) of
    undefined ->
      undefined;
    Id ->
      erlang:binary_to_list(Id)
  end.

%% @private
add_file_uri(Key0) ->
  Key = jesse_state:canonical_path(Key0, Key0),
  "file://" ++ File = Key,
  {ok, Body} = file:read_file(File),
  {ok, #file_info{mtime = Mtime}} = file:read_file_info(File),
  Schema = jsx:decode(Body),
  SchemaInfos = [{Key, Mtime, Schema}],
  ValidationFun = fun jesse_lib:is_json_object/1,
  store_schemas(SchemaInfos, ValidationFun).

%% @private
add_http_uri(Key0) ->
  Key = jesse_state:canonical_path(Key0, Key0),
  {ok, Response} = httpc:request(get, {Key, []}, [], [{body_format, binary}]),
  {{_Line, 200, _}, Headers, Body} = Response,
  Schema = jsx:decode(Body),
  SchemaInfos = [{Key, get_http_mtime(Headers), Schema}],
  ValidationFun = fun jesse_lib:is_json_object/1,
  store_schemas(SchemaInfos, ValidationFun).

%% @private
get_http_mtime(Headers) ->
  case proplists:get_value("last-modified", Headers) of
    undefined ->
      0;
    Date ->
      httpd_util:convert_request_date(Date)
  end.

%% @doc Wraps up calls to a third party json parser.
%% @private
try_parse(ParseFun, SchemaBin) ->
  try
    ParseFun(SchemaBin)
  catch
    _:Error ->
      {parse_error, Error}
  end.

%% @doc Returns a name of ETS table which is used for the internal cache.
%% Could be rewritten to use a configuration parameter instead of a hardcoded
%% value.
%% @private
table_name() ->
  ?JESSE_ETS.
