%% -------- Overview ---------
%%

-module(aae_treecache).

-behaviour(gen_server).

-include("include/aae.hrl").


-export([
            init/1,
            handle_call/3,
            handle_cast/2,
            handle_info/2,
            terminate/2,
            code_change/3]).

-export([cache_open/2,
            cache_new/2,
            cache_alter/4,
            cache_root/1,
            cache_leaves/2,
            cache_destroy/1,
            cache_close/1]).

-include_lib("eunit/include/eunit.hrl").

-define(PENDING_EXT, ".pnd").
-define(FINAL_EXT, ".aae").
-define(TREE_SIZE, large).
-define(START_SQN, 1).

-record(state, {save_sqn :: integer(),
                is_restored :: boolean(),
                tree :: leveled_tictac:tictactree(),
                root_path :: list(),
                partition_id :: integer()}).

% -type treecache_state() :: #state{}.

%%%============================================================================
%%% API
%%%============================================================================

-spec cache_open(list(), integer()) -> {boolean(), pid()}.
%% @doc
%% Open a tree cache, using any previously saved one for this tree cache as a 
%% starting point.  Return is_empty boolean as true to indicate if a new cache 
%% was created, as well as the PID of this FSM
cache_open(RootPath, PartitionID) ->
    Opts = [{root_path, RootPath}, {partition_id, PartitionID}],
    {ok, Pid} = gen_server:start(?MODULE, [Opts], []),
    IsRestored = gen_server:call(Pid, is_restored, infinity),
    {IsRestored, Pid}.

-spec cache_new(list(), integer()) -> {ok, pid()}.
%% @doc
%% Open a tree cache, without restoring from file
cache_new(RootPath, PartitionID) ->
    Opts = [{root_path, RootPath}, 
            {partition_id, PartitionID}, 
            {ignore_disk, true}],
    gen_server:start(?MODULE, [Opts], []).

-spec cache_destroy(pid()) -> ok.
%% @doc
%% Close a cache without saving
cache_destroy(AAECache) ->
    gen_server:cast(AAECache, destroy).

-spec cache_close(pid()) -> ok.
%% @doc
%% Close a cache with saving
cache_close(AAECache) ->
    gen_server:call(AAECache, close, 30000).

-spec cache_alter(pid(), binary(), integer(), integer()) -> ok.
%% @doc
%% Change the hash tree to refelct an addition and removal of a hash value
cache_alter(AAECache, Key, CurrentHash, OldHash) -> 
    gen_server:cast(AAECache, {alter, Key, CurrentHash, OldHash}).

-spec cache_root(pid()) -> binary().
%% @doc
%% Fetch the root of the cache tree to compare
cache_root(Pid) -> 
    gen_server:call(Pid, fetch_root, 2000).

-spec cache_leaves(pid(), list(integer())) -> list().
%% @doc
%% Fetch the root of the cache tree to compare
cache_leaves(Pid, BranchIDs) -> 
    gen_server:call(Pid, {fetch_leaves, BranchIDs}, 2000).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([Opts]) ->
    PartitionID = aae_util:get_opt(partition_id, Opts),
    RootPath = aae_util:get_opt(root_path, Opts),
    IgnoreDisk = aae_util:get_opt(ignore_disk, Opts, false),
    RootPath0 = filename:join(RootPath, integer_to_list(PartitionID)) ++ "/",
    {StartTree, SaveSQN, IsRestored} = 
        case IgnoreDisk of 
            true ->
                {leveled_tictac:new_tree(PartitionID, ?TREE_SIZE), 
                    ?START_SQN, 
                    false};
            false ->
                case open_from_disk(RootPath0) of 
                    {none, SQN} ->
                        {leveled_tictac:new_tree(PartitionID, ?TREE_SIZE),
                            SQN, 
                            false};
                    {Tree, SQN} ->
                        {Tree, SQN, true}
                end
        end,
    {ok, #state{save_sqn = SaveSQN, 
                tree = StartTree, 
                is_restored = IsRestored,
                root_path = RootPath0,
                partition_id = PartitionID}}.
    

handle_call(is_restored, _From, State) ->
    {reply, State#state.is_restored, State};
handle_call(fetch_root, _From, State) ->
    {reply, leveled_tictac:fetch_root(State#state.tree), State};
handle_call({fetch_leaves, BranchIDs}, _From, State) ->
    {reply, leveled_tictac:fetch_leaves(State#state.tree, BranchIDs), State};
handle_call(close, _From, State) ->
    save_to_disk(State#state.root_path, 
                    State#state.save_sqn, 
                    State#state.tree),
    {stop, normal, ok, State}.

handle_cast({alter, Key, CurrentHash, OldHash}, State) ->
    BinExtractFun = 
        fun(K, {CH, OH}) ->
            RemoveH = 
                case {CH, OH} of 
                    {0, _} ->
                        % Remove - treat like adding abcking
                        OH;
                    {_, 0} ->
                        % Add 
                        0;
                    _ ->
                        % Alter - need to account for hashing with key
                        % to rmeove the original
                        OH bxor leveled_tictac:keyto_segment32(K)
                end,
            {K, {is_hash, CH bxor RemoveH}}
        end,
    Tree0 = 
        leveled_tictac:add_kv(State#state.tree, 
                                Key, 
                                {CurrentHash, OldHash}, 
                                BinExtractFun),
    {noreply, State#state{tree = Tree0}};
handle_cast(destroy, State) ->
    aae_util:log("C0004", [State#state.partition_id], logs()),
    {stop, normal, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec save_to_disk(list(), integer(), leveled_tictac:tictactree()) -> ok.
%% @doc
%% Save the TreeCache to disk, with a checksum so thatit can be 
%% validated on read.
save_to_disk(RootPath, SaveSQN, TreeCache) ->
    Serialised = term_to_binary(leveled_tictac:export_tree(TreeCache)),
    CRC32 = erlang:crc32(Serialised),
    ok = filelib:ensure_dir(RootPath),
    PendingName = integer_to_list(SaveSQN) ++ ?PENDING_EXT,
    aae_util:log("C0003", [RootPath, PendingName], logs()),
    ok = file:write_file(filename:join(RootPath, PendingName),
                            <<CRC32:32/integer, Serialised/binary>>,
                            [raw]),
    file:rename(filename:join(RootPath, PendingName), 
                    form_cache_filename(RootPath, SaveSQN)).

-spec open_from_disk(list()) -> {leveled_tictac:tictactree()|none, integer()}.
%% @doc
%% Open most recently saved TicTac tree cache file on disk, deleting all 
%% others both used and unused - to save an out of date tree from being used
%% following a subsequent crash
open_from_disk(RootPath) ->
    ok = filelib:ensure_dir(RootPath),
    {ok, Filenames} = file:list_dir(RootPath),
    FileFilterFun = 
        fun(FN, FinalFiles) ->
            case filename:extension(FN) of 
                ?PENDING_EXT ->
                    aae_util:log("C0001", [FN], logs()),
                    ok = file:delete(FN),
                    FinalFiles;
                ?FINAL_EXT ->
                    BaseFN = 
                        filename:basename(filename:rootname(FN, ?FINAL_EXT)),
                    [list_to_integer(BaseFN)|FinalFiles];
                _ ->
                    FinalFiles
            end 
        end,
    SQNList = 
        lists:reverse(lists:sort(lists:foldl(FileFilterFun, [], Filenames))),
    case SQNList of 
        [] ->
            {none, 1};
        [HeadSQN|Tail] ->
            DeleteFun = 
                fun(SQN) -> 
                    ok = file:delete(form_cache_filename(RootPath, SQN)) 
                end,
            lists:foreach(DeleteFun, Tail), 
            FileToUse = form_cache_filename(RootPath, HeadSQN),
            {ok, <<CRC32:32/integer, STC/binary>>} = file:read_file(FileToUse),
            case erlang:crc32(STC) of 
                CRC32 ->
                    ok = file:delete(FileToUse),
                    {leveled_tictac:import_tree(binary_to_term(STC)), 
                        HeadSQN +  1};
                _ ->
                    aae_util:log("C0002", [FileToUse], logs()),
                    {none, 1}
            end
    end.


-spec form_cache_filename(list(), integer()) -> list().
%% @doc
%% Return the cache filename by combining the Root Path with the SQN
form_cache_filename(RootPath, SaveSQN) ->
    filename:join(RootPath, integer_to_list(SaveSQN) ++ ?FINAL_EXT).


%%%============================================================================
%%% log definitions
%%%============================================================================

-spec logs() -> list(tuple()).
%% @doc
%% Define log lines for this module
logs() ->
    [{"C0001", {info, "Pending filename ~w found and will delete"}},
        {"C0002", {warn, "CRC wonky in file ~w"}},
        {"C0003", {info, "Saving tree cache to path ~s and filename ~s"}},
        {"C0004", {info, "Destroying tree cache for partition ~w"}}].

%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

clean_subdir(DirPath) ->
    case filelib:is_dir(DirPath) of
        true ->
            {ok, Files} = file:list_dir(DirPath),
            lists:foreach(fun(FN) ->
                                File = filename:join(DirPath, FN),
                                ok = file:delete(File),
                                io:format("Success deleting ~s~n", [File])
                                end,
                            Files);
        false ->
            ok
    end.

clean_saveopen_test() ->
    RootPath = "test/cache0/",
    clean_subdir(RootPath),
    Tree0 = leveled_tictac:new_tree(test),
    Tree1 = 
        leveled_tictac:add_kv(Tree0, 
                                <<"K1">>, <<"V1">>, 
                                fun(K, V) -> {K, V} end),
    Tree2 = 
        leveled_tictac:add_kv(Tree1, 
                                <<"K2">>, <<"V2">>, 
                                fun(K, V) -> {K, V} end),
    ok = save_to_disk(RootPath, 1, Tree1),
    ok = save_to_disk(RootPath, 2, Tree2),
    {Tree3, SaveSQN} = open_from_disk(RootPath),
    ?assertMatch(3, SaveSQN),
    ?assertMatch([], leveled_tictac:find_dirtyleaves(Tree2, Tree3)),
    ?assertMatch({none, 1}, open_from_disk(RootPath)).


simple_test() ->
    RootPath = "test/cache1/",
    PartitionID = 99,
    clean_subdir(RootPath ++ "/" ++ integer_to_list(PartitionID)),
    GenerateKeyFun =
        fun(I) ->
            Key = <<"Key", I:32/integer>>,
            Value = random:uniform(100000),
            <<Hash:32/integer, _Rest/binary>> =
                crypto:hash(md5, <<Value:32/integer>>),
            {Key, Hash}
        end,

    InitialKeys = lists:map(GenerateKeyFun, lists:seq(1,100)),
    AlternateKeys = lists:map(GenerateKeyFun, lists:seq(61, 80)),
    RemoveKeys = lists:map(GenerateKeyFun, lists:seq(81, 100)),

    {ok, AAECache0} = cache_new(RootPath, PartitionID),
    AddFun = 
        fun(CachePid) ->
            fun({K, H}) ->
                cache_alter(CachePid, K, H, 0)
            end
        end,
    AlterFun =
        fun(CachePid) -> 
            fun({K, H}) ->
                {K, OH} = lists:keyfind(K, 1, InitialKeys),
                io:format("Alter ~w to ~w for ~w~n", [OH, H, K]),
                cache_alter(CachePid, K, H, OH)
            end
        end,
    RemoveFun = 
        fun(CachePid) ->
            fun({K, _H}) ->
                {K, OH} = lists:keyfind(K, 1, InitialKeys),
                cache_alter(CachePid, K, 0, OH)
            end
        end,
    
    lists:foreach(AddFun(AAECache0), InitialKeys),
    
    ok = cache_close(AAECache0),

    {true, AAECache1} = cache_open(RootPath, PartitionID),
    
    lists:foreach(AlterFun(AAECache1), AlternateKeys),
    lists:foreach(RemoveFun(AAECache1), RemoveKeys),

    %% Now build the equivalent outside of the process
    %% Accouting up-fron for the removals and the alterations
    KHL0 = lists:sublist(InitialKeys, 60) ++ AlternateKeys,
    DirectAddFun =
        fun({K, H}, TreeAcc) ->
            leveled_tictac:add_kv(TreeAcc, 
                                    K, H, 
                                    fun(Key, Value) -> 
                                        {Key, {is_hash, Value}} 
                                    end)
        end,
    CompareTree = 
        lists:foldl(DirectAddFun, 
                        leveled_tictac:new_tree(raw, ?TREE_SIZE), 
                        KHL0),
    CompareRoot = leveled_tictac:fetch_root(CompareTree),
    Root = cache_root(AAECache1),
    ?assertMatch(Root, CompareRoot),


    ok = cache_destroy(AAECache1).



-endif.