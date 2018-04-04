-module(basic_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0]).
-export([dual_store_compare_medium_so/1,
            dual_store_compare_medium_ko/1,
            dual_store_compare_large_so/1,
            dual_store_compare_large_ko/1]).

all() -> [dual_store_compare_medium_so,
            dual_store_compare_medium_ko,
            dual_store_compare_large_so,
            dual_store_compare_large_ko].

-define(ROOT_PATH, "test/").

dual_store_compare_medium_so(_Config) ->
    dual_store_compare_tester(10000, leveled_so).

dual_store_compare_medium_ko(_Config) ->
    dual_store_compare_tester(10000, leveled_ko).

dual_store_compare_large_so(_Config) ->
    dual_store_compare_tester(100000, leveled_so).

dual_store_compare_large_ko(_Config) ->
    dual_store_compare_tester(100000, leveled_ko).




dual_store_compare_tester(InitialKeyCount, StoreType) ->
    % Setup to AAE controllers, each representing the same data.  One store
    % will be split into two three preflists, the other into two.  The 
    % preflists will be mapped as follows:
    % {2, 0} <-> {3, 0}
    % {2, 1} <-> {3, 1} & {3, 2}

    RootPath = reset_filestructure(),
    VnodePath1 = filename:join(RootPath, "vnode1/"),
    VnodePath2 = filename:join(RootPath, "vnode2/"),
    SplitF = fun(_X) -> {leveled_rand:uniform(1000), 1, 0, null} end,
    RPid = self(),
    ReturnFun = fun(R) -> RPid ! {result, R} end,

    {ok, Cntrl1} = 
        aae_controller:aae_start({parallel, StoreType}, 
                                    {true, none}, 
                                    {1, 300}, 
                                    [{2, 0}, {2, 1}], 
                                    VnodePath1, 
                                    SplitF),
    {ok, Cntrl2} = 
        aae_controller:aae_start({parallel, StoreType}, 
                                    {true, none}, 
                                    {1, 300}, 
                                    [{3, 0}, {3, 1}, {3, 2}], 
                                    VnodePath2, 
                                    SplitF),
    
    BKVList = gen_keys([], InitialKeyCount),
    ok = put_keys(Cntrl1, 2, BKVList),
    ok = put_keys(Cntrl2, 3, BKVList),
    
    % Confirm all partitions are aligned as expected using direct access to 
    % the controller

    ok = aae_controller:aae_mergeroot(Cntrl1, 
                                        [{2, 0}, {2, 1}], 
                                        ReturnFun),
    Root1A = start_receiver(),
    ok = aae_controller:aae_mergeroot(Cntrl2, 
                                        [{3, 0}, {3, 1}, {3, 2}], 
                                        ReturnFun),
    Root2A = start_receiver(),
    true = Root1A == Root2A,

    ok = aae_controller:aae_fetchroot(Cntrl1, 
                                        [{2, 0}], 
                                        ReturnFun),
    [{{2, 0}, Root1B}] = start_receiver(),
    ok = aae_controller:aae_fetchroot(Cntrl2, 
                                        [{3, 0}], 
                                        ReturnFun),
    [{{3, 0}, Root2B}] = start_receiver(),
    true = Root1B == Root2B,

    ok = aae_controller:aae_mergeroot(Cntrl1, 
                                        [{2, 1}], 
                                        ReturnFun),
    Root1C = start_receiver(),
    ok = aae_controller:aae_mergeroot(Cntrl2, 
                                        [{3, 1}, {3, 2}], 
                                        ReturnFun),
    Root2C = start_receiver(),
    true = Root1C == Root2C,
    


    % Confirm no dependencies when using different matching AAE exchanges
    RepairFun = fun(_KL) -> null end,  

    {ok, _P1, GUID1} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,0}]}],
                                [{exchange_sendfun(Cntrl2), [{3, 0}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID1]),
    {ExchangeState1, 0} = start_receiver(),
    true = ExchangeState1 == root_compare,

    {ok, _P2, GUID2} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,1}]}],
                                [{exchange_sendfun(Cntrl2), [{3, 1}, {3, 2}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID2]),
    {ExchangeState2, 0} = start_receiver(),
    true = ExchangeState2 == root_compare,

    {ok, _P3, GUID3} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2, 0}, {2,1}]}],
                                [{exchange_sendfun(Cntrl2), 
                                    [{3, 0}, {3, 1}, {3, 2}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID3]),
    {ExchangeState3, 0} = start_receiver(),
    true = ExchangeState3 == root_compare,

    {ok, _P4, GUID4} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,0}]}, 
                                    {exchange_sendfun(Cntrl1), [{2,1}]}],
                                [{exchange_sendfun(Cntrl2), 
                                    [{3, 0}, {3, 1}, {3, 2}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID4]),
    {ExchangeState4, 0} = start_receiver(),
    true = ExchangeState4 == root_compare,


    % Create a discrepancy and discover it through exchange
    BKVListN = gen_keys([], InitialKeyCount + 10, InitialKeyCount),
    _SL = lists:foldl(fun({B, K, _V}, Acc) -> 
                            BK = aae_util:make_binarykey(B, K),
                            Seg = leveled_tictac:keyto_segment48(BK),
                            Seg0 = aae_keystore:generate_treesegment(Seg),
                            io:format("Generate new key B ~w K ~w " ++ 
                                        "for Segment ~w ~w ~w partition ~w ~w~n",
                                        [B, K, Seg0,  Seg0 bsr 8, Seg0 band 255, 
                                        calc_preflist(K, 2), calc_preflist(K, 3)]),
                            [Seg0|Acc]
                        end,
                        [],
                        BKVListN),
    ok = put_keys(Cntrl1, 2, BKVListN),

    {ok, _P6, GUID6} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,0}]}, 
                                    {exchange_sendfun(Cntrl1), [{2,1}]}],
                                [{exchange_sendfun(Cntrl2), 
                                    [{3, 0}, {3, 1}, {3, 2}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID6]),
    {ExchangeState6, 10} = start_receiver(),
    true = ExchangeState6 == clock_compare,

    % Same again, but request a missing partition, and should get same result

    {ok, _P6a, GUID6a} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,0}]}, 
                                    {exchange_sendfun(Cntrl1), [{2,1}]}],
                                [{exchange_sendfun(Cntrl2), 
                                    [{3, 0}, {3, 1}, {3, 2}, {3, 3}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID6a]),
    {ExchangeState6a, 10} = start_receiver(),
    true = ExchangeState6a == clock_compare,

    % Nothing repaired last time.  The deltas are all new keys though, so
    % We can repair by adding them in to the other vnode

    RepairFun0 = repair_fun(BKVListN, Cntrl2, 3),
    {ok, _P7, GUID7} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,0}]}, 
                                    {exchange_sendfun(Cntrl1), [{2,1}]}],
                                [{exchange_sendfun(Cntrl2), 
                                    [{3, 0}, {3, 1}, {3, 2}]}],
                                RepairFun0,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID7]),
    {ExchangeState7, 10} = start_receiver(),
    true = ExchangeState7 == clock_compare,
    
    {ok, _P8, GUID8} = 
        aae_exchange:start([{exchange_sendfun(Cntrl1), [{2,0}]}, 
                                    {exchange_sendfun(Cntrl1), [{2,1}]}],
                                [{exchange_sendfun(Cntrl2), 
                                    [{3, 0}, {3, 1}, {3, 2}]}],
                                RepairFun,
                                ReturnFun),
    io:format("Exchange id ~s~n", [GUID8]),
    {ExchangeState8, 0} = start_receiver(),
    true = ExchangeState8 == root_compare,



    % Shutdown and tidy up
    ok = aae_controller:aae_close(Cntrl1, none),
    ok = aae_controller:aae_close(Cntrl2, none),
    RootPath = reset_filestructure().



reset_filestructure() ->
    reset_filestructure(0, ?ROOT_PATH).
    
reset_filestructure(Wait, RootPath) ->
    io:format("Waiting ~w ms to give a chance for all file closes " ++
                 "to complete~n", [Wait]),
    timer:sleep(Wait),
    clear_all(RootPath),
    RootPath.

clear_all(RootPath) ->
    ok = filelib:ensure_dir(RootPath),
    {ok, FNs} = file:list_dir(RootPath),
    FoldFun =
        fun(FN) ->
            case filelib:is_file(FN) of 
                true ->
                    file:delete(filename:join(RootPath, FN));
                false ->
                    case filelib:is_dir(FN) of 
                        true ->
                            clear_all(filename:join(RootPath, FN));
                        false ->
                            % Root Path
                            ok
                    end
            end
        end,
    lists:foreach(FoldFun, FNs).


gen_keys(KeyList, Count) ->
    gen_keys(KeyList, Count, 0).

gen_keys(KeyList, Count, Floor) when Count == Floor ->
    KeyList;
gen_keys(KeyList, Count, Floor) ->
    Bucket = integer_to_binary(Count rem 5),  
    Key = list_to_binary(string:right(integer_to_list(Count), 6, $0)),
    VersionVector = add_randomincrement([]),
    gen_keys([{Bucket, Key, VersionVector}|KeyList], 
                Count - 1,
                Floor).

put_keys(_Cntrl, _Nval, []) ->
    ok;
put_keys(Cntrl, Nval, [{Bucket, Key, VersionVector}|Tail]) ->
    ok = aae_controller:aae_put(Cntrl, 
                                calc_preflist(Key, Nval), 
                                Bucket, 
                                Key, 
                                VersionVector, 
                                none, 
                                <<>>),
    put_keys(Cntrl, Nval, Tail).

add_randomincrement(Clock) ->
    RandIncr = leveled_rand:uniform(100),
    RandNode = lists:nth(leveled_rand:uniform(9), 
                            ["a", "b", "c", "d", "e", "f", "g", "h", "i"]),
    UpdClock = 
        case lists:keytake(RandNode, 1, Clock) of 
            false ->
                [{RandNode, RandIncr}|Clock];
            {value, {RandNode, Incr0}, Rest} ->
                [{RandNode, Incr0 + RandIncr}|Rest]
        end,
    lists:usort(UpdClock).

calc_preflist(Key, 2) ->
    case erlang:phash2(Key) band 3 of 
        0 ->
            {2, 0};
        _ ->
            {2, 1}
    end;
calc_preflist(Key, 3) ->
    case erlang:phash2(Key) band 3 of 
        0 ->
            {3, 0};
        1 ->
            {3, 1};
        _ ->
            {3, 2}
    end.

start_receiver() ->
    receive
        {result, Reply} ->
            Reply 
    end.


exchange_sendfun(Cntrl) ->
    SendFun = 
        fun(Msg, Preflists, Colour) ->
            RPid = self(),
            ReturnFun = 
                fun(R) -> 
                    io:format("Preparing reply to ~w for msg ~w colour ~w~n", 
                                [RPid, Msg, Colour]),
                    aae_exchange:reply(RPid, R, Colour)
                end,
            case Msg of 
                fetch_root ->
                    aae_controller:aae_mergeroot(Cntrl, 
                                                    Preflists, 
                                                    ReturnFun);
                {fetch_branches, BranchIDs} ->
                    aae_controller:aae_mergebranches(Cntrl, 
                                                        Preflists, 
                                                        BranchIDs, 
                                                        ReturnFun);
                {fetch_clocks, SegmentIDs} ->
                    aae_controller:aae_fetchclocks(Cntrl,
                                                        Preflists,
                                                        SegmentIDs,
                                                        ReturnFun)
            end
        end,
    SendFun.

repair_fun(SourceList, Cntrl, NVal) ->
    Lookup = lists:map(fun({B, K, V}) -> {{B, K}, V} end, SourceList),
    RepairFun = 
        fun(BucketKeyL) ->
            FoldFun =
                fun(BucketKeyT, Acc) -> 
                    {{B0, K0}, V0} = lists:keyfind(BucketKeyT, 1, Lookup),
                    [{B0, K0, V0}|Acc]
                end,
            KVL = lists:foldl(FoldFun, [], BucketKeyL),
            ok = put_keys(Cntrl, NVal, KVL)
        end,
    RepairFun.