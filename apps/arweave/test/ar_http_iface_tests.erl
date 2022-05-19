-module(ar_http_iface_tests).

-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(ar_test_node, [start/1, slave_stop/0, slave_start/1, connect_to_slave/0,
		get_tx_anchor/0, disconnect_from_slave/0, wait_until_height/1,
		wait_until_receives_txs/1, sign_tx/2, post_tx_json_to_master/1,
		assert_slave_wait_until_receives_txs/1, slave_wait_until_height/1,
		read_block_when_stored/1, read_block_when_stored/2, master_peer/0, slave_peer/0,
		slave_mine/0, assert_slave_wait_until_height/1, slave_call/3,
		assert_post_tx_to_master/1, assert_post_tx_to_slave/1]).
-import(ar_test_fork, [test_on_fork/3]).

addresses_with_checksums_test_() ->
	{timeout, 60, fun test_addresses_with_checksum/0}.

test_addresses_with_checksum() ->
	{_, Pub} = Wallet = ar_wallet:new(),
	{_, Pub2} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(100), <<>>},
			{ar_wallet:to_address(Pub2), ?AR(100), <<>>}]),
	start(B0),
	slave_start(B0),
	connect_to_slave(),
	Address19 = crypto:strong_rand_bytes(19),
	Address65 = crypto:strong_rand_bytes(65),
	Address20 = crypto:strong_rand_bytes(20),
	Address32 = ar_wallet:to_address(Pub2),
	TX = sign_tx(Wallet, #{ last_tx => get_tx_anchor() }),
	{JSON} = ar_serialize:tx_to_json_struct(TX),
	JSON2 = proplists:delete(<<"target">>, JSON),
	TX2 = sign_tx(Wallet, #{ last_tx => get_tx_anchor(), target => Address32 }),
	{JSON3} = ar_serialize:tx_to_json_struct(TX2),
	InvalidPayloads = [
		[{<<"target">>, <<":">>} | JSON2],
		[{<<"target">>, << <<":">>/binary, (ar_util:encode(<< 0:32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (ar_util:encode(Address19))/binary, <<":">>/binary,
				(ar_util:encode(<< (erlang:crc32(Address19)):32 >> ))/binary >>} | JSON2],
		[{<<"target">>, << (ar_util:encode(Address65))/binary, <<":">>/binary,
				(ar_util:encode(<< (erlang:crc32(Address65)):32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (ar_util:encode(Address32))/binary, <<":">>/binary,
				(ar_util:encode(<< 0:32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (ar_util:encode(Address20))/binary, <<":">>/binary,
				(ar_util:encode(<< 1:32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (ar_util:encode(Address32))/binary, <<":">>/binary,
				(ar_util:encode(<< (erlang:crc32(Address32)):32 >>))/binary,
				<<":">>/binary >>} | JSON2],
		[{<<"target">>, << (ar_util:encode(Address32))/binary, <<":">>/binary >>} | JSON3]
	],
	lists:foreach(
		fun(Struct) ->
			Payload = ar_serialize:jsonify({Struct}),
			?assertMatch({ok, {{<<"400">>, _}, _, <<"Invalid JSON.">>, _, _}},
					post_tx_json_to_master(Payload))
		end,
		InvalidPayloads
	),
	ValidPayloads = [
		[{<<"target">>, << (ar_util:encode(Address32))/binary, <<":">>/binary,
				(ar_util:encode(<< (erlang:crc32(Address32)):32 >>))/binary >>} | JSON3],
		JSON
	],
	lists:foreach(
		fun(Struct) ->
			Payload = ar_serialize:jsonify({Struct}),
			?assertMatch({ok, {{<<"200">>, _}, _, <<"OK">>, _, _}},
					post_tx_json_to_master(Payload))
		end,
		ValidPayloads
	),
	assert_slave_wait_until_receives_txs([TX, TX2]),
	ar_node:mine(),
	[{H, _, _} | _] = slave_wait_until_height(1),
	B = read_block_when_stored(H),
	ChecksumAddr = << (ar_util:encode(Address32))/binary, <<":">>/binary,
			(ar_util:encode(<< (erlang:crc32(Address32)):32 >>))/binary >>,
	?assertEqual(2, length(B#block.txs)),
	Balance = get_balance(ar_util:encode(Address32)),
	?assertEqual(Balance, get_balance(ChecksumAddr)),
	LastTX = get_last_tx(ar_util:encode(Address32)),
	?assertEqual(LastTX, get_last_tx(ChecksumAddr)),
	Price = get_price(ar_util:encode(Address32)),
	?assertEqual(Price, get_price(ChecksumAddr)),
	ServeTXTarget = maps:get(<<"target">>, jiffy:decode(get_tx(TX2#tx.id), [return_maps])),
	?assertEqual(ar_util:encode(TX2#tx.target), ServeTXTarget).

get_balance(EncodedAddr) ->
	Peer = master_peer(),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		ar_http:req(#{
			method => get,
			peer => Peer,
			path => "/wallet/" ++ binary_to_list(EncodedAddr) ++ "/balance",
			headers => [{<<"X-P2p-Port">>, integer_to_binary(Port)}]
		}),
	binary_to_integer(Reply).

get_last_tx(EncodedAddr) ->
	Peer = master_peer(),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		ar_http:req(#{
			method => get,
			peer => Peer,
			path => "/wallet/" ++ binary_to_list(EncodedAddr) ++ "/last_tx",
			headers => [{<<"X-P2p-Port">>, integer_to_binary(Port)}]
		}),
	Reply.

get_price(EncodedAddr) ->
	Peer = master_peer(),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		ar_http:req(#{
			method => get,
			peer => Peer,
			path => "/price/0/" ++ binary_to_list(EncodedAddr),
			headers => [{<<"X-P2p-Port">>, integer_to_binary(Port)}]
		}),
	binary_to_integer(Reply).

get_tx(ID) ->
	Peer = master_peer(),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		ar_http:req(#{
			method => get,
			peer => Peer,
			path => "/tx/" ++ binary_to_list(ar_util:encode(ID)),
			headers => [{<<"X-P2p-Port">>, integer_to_binary(Port)}]
		}),
	Reply.

%% @doc Ensure that server info can be retreived via the HTTP interface.
get_info_test() ->
	disconnect_from_slave(),
	start(no_block),
	?assertEqual(<<?NETWORK_NAME>>, ar_http_iface_client:get_info({127, 0, 0, 1, 1984}, name)),
	?assertEqual({<<"release">>, ?RELEASE_NUMBER},
			ar_http_iface_client:get_info({127, 0, 0, 1, 1984}, release)),
	?assertEqual(?CLIENT_VERSION, ar_http_iface_client:get_info({127, 0, 0, 1, 1984}, version)),
	?assertEqual(0, ar_http_iface_client:get_info({127, 0, 0, 1, 1984}, peers)),
	ar_util:do_until(
		fun() ->
			1 == ar_http_iface_client:get_info({127, 0, 0, 1, 1984}, blocks)
		end,
		100,
		2000
	),
	?assertEqual(0, ar_http_iface_client:get_info({127, 0, 0, 1, 1984}, height)).

%% @doc Ensure that transactions are only accepted once.
single_regossip_test() ->
	start(no_block),
	slave_start(no_block),
	TX = ar_tx:new(),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		ar_http_iface_client:send_tx_json({127, 0, 0, 1, 1984}, TX#tx.id,
				ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX)))
	),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1983}, TX#tx.id,
				ar_serialize:tx_to_binary(TX))
	),
	?assertMatch(
		{ok, {{<<"208">>, _}, _, _, _, _}},
		ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1983}, TX#tx.id,
				ar_serialize:tx_to_binary(TX))
	),
	?assertMatch(
		{ok, {{<<"208">>, _}, _, _, _, _}},
		ar_http_iface_client:send_tx_json({127, 0, 0, 1, 1983}, TX#tx.id,
				ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX)))
	).

%% @doc Test that nodes sending too many requests are temporarily blocked: (a) GET.
node_blacklisting_get_spammer_test() ->
	{ok, Config} = application:get_env(arweave, config),
	{RequestFun, ErrorResponse} = get_fun_msg_pair(get_info),
	node_blacklisting_test_frame(
		RequestFun,
		ErrorResponse,
		Config#config.requests_per_minute_limit div 2 + 1,
		1
	).

%% @doc Test that nodes sending too many requests are temporarily blocked: (b) POST.
node_blacklisting_post_spammer_test() ->
	{ok, Config} = application:get_env(arweave, config),
	{RequestFun, ErrorResponse} = get_fun_msg_pair(send_tx_binary),
	NErrors = 11,
	NRequests = Config#config.requests_per_minute_limit div 2 + NErrors,
	node_blacklisting_test_frame(RequestFun, ErrorResponse, NRequests, NErrors).

%% @doc Given a label, return a fun and a message.
-spec get_fun_msg_pair(atom()) -> {fun(), any()}.
get_fun_msg_pair(get_info) ->
	{ fun(_) ->
			ar_http_iface_client:get_info({127, 0, 0, 1, 1984})
		end
	, info_unavailable};
get_fun_msg_pair(send_tx_binary) ->
	{ fun(_) ->
			InvalidTX = (ar_tx:new())#tx{ owner = <<"key">>, signature = <<"invalid">> },
			case ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984},
					InvalidTX#tx.id, ar_serialize:tx_to_binary(InvalidTX)) of
				{ok,
					{{<<"429">>, <<"Too Many Requests">>}, _,
						<<"Too Many Requests">>, _, _}} ->
					too_many_requests;
				_ -> ok
			end
		end
	, too_many_requests}.

%% @doc Frame to test spamming an endpoint.
%% TODO: Perform the requests in parallel. Just changing the lists:map/2 call
%% to an ar_util:pmap/2 call fails the tests currently.
-spec node_blacklisting_test_frame(fun(), any(), non_neg_integer(), non_neg_integer()) -> ok.
node_blacklisting_test_frame(RequestFun, ErrorResponse, NRequests, ExpectedErrors) ->
	slave_stop(),
	ar_blacklist_middleware:reset(),
	ar_rate_limiter:off(),
	Responses = lists:map(RequestFun, lists:seq(1, NRequests)),
	?assertEqual(length(Responses), NRequests),
	ar_blacklist_middleware:reset(),
	ByResponseType = count_by_response_type(ErrorResponse, Responses),
	Expected = #{
		error_responses => ExpectedErrors,
		ok_responses => NRequests - ExpectedErrors
	},
	?assertEqual(Expected, ByResponseType),
	ar_rate_limiter:on().

%% @doc Count the number of successful and error responses.
count_by_response_type(ErrorResponse, Responses) ->
	count_by(
		fun
			(Response) when Response == ErrorResponse -> error_responses;
			(_) -> ok_responses
		end,
		Responses
	).

%% @doc Count the occurances in the list based on the predicate.
count_by(Pred, List) ->
	maps:map(fun (_, Value) -> length(Value) end, group(Pred, List)).

%% @doc Group the list based on the key generated by Grouper.
group(Grouper, Values) ->
	group(Grouper, Values, maps:new()).

group(_, [], Acc) ->
	Acc;
group(Grouper, [Item | List], Acc) ->
	Key = Grouper(Item),
	Updater = fun (Old) -> [Item | Old] end,
	NewAcc = maps:update_with(Key, Updater, [Item], Acc),
	group(Grouper, List, NewAcc).

%% @doc Check that balances can be retreived over the network.
get_balance_test() ->
	{_Priv1, Pub1} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub1), 10000, <<>>}]),
	{_Node, _} = start(B0),
	Addr = binary_to_list(ar_util:encode(ar_wallet:to_address(Pub1))),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet/" ++ Addr ++ "/balance"
		}),
	?assertEqual(10000, binary_to_integer(Body)),
	RootHash = binary_to_list(ar_util:encode(B0#block.wallet_list)),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet_list/" ++ RootHash ++ "/" ++ Addr ++ "/balance"
		}),
	ar_node:mine(),
	wait_until_height(1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet_list/" ++ RootHash ++ "/" ++ Addr ++ "/balance"
		}).

get_wallet_list_in_chunks_test() ->
	{_Priv1, Pub1} = ar_wallet:new(),
	[B0] = ar_weave:init([{Addr = ar_wallet:to_address(Pub1), 10000, <<>>}]),
	{_Node, _} = start(B0),
	NonExistentRootHash = binary_to_list(ar_util:encode(crypto:strong_rand_bytes(32))),
	{ok, {{<<"404">>, _}, _, <<"Root hash not found.">>, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet_list/" ++ NonExistentRootHash
		}),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet_list/" ++ binary_to_list(ar_util:encode(B0#block.wallet_list))
		}),
	?assertEqual(
		#{ next_cursor => last, wallets => [{Addr, {10000, <<>>}}] },
		binary_to_term(Body)
	).

%% @doc Test that heights are returned correctly.
get_height_test() ->
	[B0] = ar_weave:init([], ?DEFAULT_DIFF, ?AR(1)),
	{_Node, _} = start(B0),
	0 = ar_http_iface_client:get_height({127, 0, 0, 1, 1984}),
	ar_node:mine(),
	wait_until_height(1),
	1 = ar_http_iface_client:get_height({127, 0, 0, 1, 1984}).

%% @doc Test that last tx associated with a wallet can be fetched.
get_last_tx_single_test() ->
	{_Priv1, Pub1} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub1), 10000, <<"TEST_ID">>}]),
	start(B0),
	Addr = binary_to_list(ar_util:encode(ar_wallet:to_address(Pub1))),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet/" ++ Addr ++ "/last_tx"
		}),
	?assertEqual(<<"TEST_ID">>, ar_util:decode(Body)).

%% @doc Check that we can qickly get the local time from the peer.
get_time_test() ->
	Now = os:system_time(second),
	{ok, {Min, Max}} = ar_http_iface_client:get_time({127, 0, 0, 1, 1984}, 10 * 1000),
	?assert(Min < Now),
	?assert(Now < Max).

%% @doc Ensure that blocks can be received via a hash.
get_block_by_hash_test() ->
	[B0] = ar_weave:init([]),
	start(B0),
	{_Peer, B1, _Time, _Size} = ar_http_iface_client:get_block_shadow([{127, 0, 0, 1, 1984}],
			B0#block.indep_hash),
	?assertEqual(B0#block{ hash_list = unset, size_tagged_txs = unset }, B1).

%% @doc Ensure that blocks can be received via a height.
get_block_by_height_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	wait_until_height(0),
	{_Peer, B1, _Time, _Size} = ar_http_iface_client:get_block_shadow(
			[{127, 0, 0, 1, 1984}], 0),
	?assertEqual(
		B0#block{ hash_list = unset, wallet_list = not_set, size_tagged_txs = unset },
		B1#block{ wallet_list = not_set }
	).

get_current_block_test_() ->
	{timeout, 10, fun test_get_current_block/0}.

test_get_current_block() ->
	[B0] = ar_weave:init([]),
	{_Node, _} = start(B0),
	ar_util:do_until(
		fun() -> B0#block.indep_hash == ar_node:get_current_block_hash() end,
		100,
		2000
	),
	Peer = {127, 0, 0, 1, 1984},
	BI = ar_http_iface_client:get_block_index([Peer]),
	{_Peer, B1, _Time, _Size} = ar_http_iface_client:get_block_shadow([Peer], hd(BI)),
	?assertEqual(B0#block{ hash_list = unset, size_tagged_txs = unset }, B1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{method => get, peer => {127, 0, 0, 1, 1984}, path => "/block/current"}),
	?assertEqual(
		B0#block.indep_hash,
		(ar_serialize:json_struct_to_block(Body))#block.indep_hash
	).

%% @doc Test that the various different methods of GETing a block all perform
%% correctly if the block cannot be found.
get_non_existent_block_test() ->
	[B0] = ar_weave:init([]),
	start(B0),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{method => get, peer => {127, 0, 0, 1, 1984},
				path => "/block/height/100"}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{method => get, peer => {127, 0, 0, 1, 1984},
				path => "/block2/height/100"}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{method => get, peer => {127, 0, 0, 1, 1984},
				path => "/block/hash/abcd"}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{method => get, peer => {127, 0, 0, 1, 1984},
				path => "/block2/hash/abcd"}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/block/height/101/wallet_list"
		}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/block/hash/abcd/wallet_list"
		}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/block/height/101/hash_list"
		}),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/block/hash/abcd/hash_list"
		}).

%% @doc A test for retrieving format=2 transactions from HTTP API.
get_format_2_tx_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	DataRoot = (ar_tx:generate_chunk_tree(#tx{ data = <<"DATA">> }))#tx.data_root,
	ValidTX = #tx{ id = TXID } = (ar_tx:new(<<"DATA">>))#tx{ format = 2, data_root = DataRoot },
	InvalidDataRootTX = #tx{ id = InvalidTXID } = (ar_tx:new(<<"DATA">>))#tx{ format = 2 },
	EmptyTX = #tx{ id = EmptyTXID } = (ar_tx:new())#tx{ format = 2 },
	EncodedTXID = binary_to_list(ar_util:encode(TXID)),
	EncodedInvalidTXID = binary_to_list(ar_util:encode(InvalidTXID)),
	EncodedEmptyTXID = binary_to_list(ar_util:encode(EmptyTXID)),
	ar_http_iface_client:send_tx_json({127, 0, 0, 1, 1984}, ValidTX#tx.id,
			ar_serialize:jsonify(ar_serialize:tx_to_json_struct(ValidTX))),
	{ok, {{<<"400">>, _}, _, <<"The attached data is split in an unknown way.">>, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx",
			body => ar_serialize:jsonify(ar_serialize:tx_to_json_struct(InvalidDataRootTX))
		}),
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984},
			InvalidDataRootTX#tx.id,
			ar_serialize:tx_to_binary(InvalidDataRootTX#tx{ data = <<>> })),
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984}, EmptyTX#tx.id,
			ar_serialize:tx_to_binary(EmptyTX)),
	wait_until_receives_txs([ValidTX, EmptyTX, InvalidDataRootTX]),
	ar_node:mine(),
	wait_until_height(1),
	%% Ensure format=2 transactions can be retrieved over the HTTP
	%% interface with no populated data, while retaining info on all other fields.
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ EncodedTXID
		}),
	?assertEqual(ValidTX#tx{ data = <<>>, data_size = 4 }, ar_serialize:json_struct_to_tx(Body)),
	%% Ensure data can be fetched for format=2 transactions via /tx/[ID]/data.
	{ok, Data} = wait_until_syncs_tx_data(TXID),
	?assertEqual(ar_util:encode(<<"DATA">>), Data),
	{ok, {{<<"200">>, _}, _, InvalidData, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ EncodedInvalidTXID ++ "/data"
		}),
	?assertEqual(<<>>, InvalidData),
	%% Ensure /tx/[ID]/data works for format=2 transactions when the data is empty.
	{ok, {{<<"200">>, _}, _, <<>>, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ EncodedEmptyTXID ++ "/data"
		}),
	%% Ensure data can be fetched for format=2 transactions via /tx/[ID]/data.html.
	{ok, {{<<"200">>, _}, Headers, HTMLData, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ EncodedTXID ++ "/data.html"
		}),
	?assertEqual(<<"DATA">>, HTMLData),
	?assertEqual(
		[{<<"content-type">>, <<"text/html">>}],
		proplists:lookup_all(<<"content-type">>, Headers)
	).

get_format_1_tx_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	TX = #tx{ id = TXID } = ar_tx:new(<<"DATA">>),
	EncodedTXID = binary_to_list(ar_util:encode(TXID)),
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984}, TX#tx.id,
			ar_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	ar_node:mine(),
	wait_until_height(1),
	{ok, Body} =
		ar_util:do_until(
			fun() ->
				case ar_http:req(#{
					method => get,
					peer => {127, 0, 0, 1, 1984},
					path => "/tx/" ++ EncodedTXID
				}) of
					{ok, {{<<"404">>, _}, _, _, _, _}} ->
						false;
					{ok, {{<<"200">>, _}, _, Payload, _, _}} ->
						{ok, Payload}
				end
			end,
			100,
			2000
		),
	?assertEqual(TX, ar_serialize:json_struct_to_tx(Body)).

%% @doc Test adding transactions to a block.
add_external_tx_with_tags_test() ->
	[B0] = ar_weave:init([]),
	{_Node, _} = start(B0),
	TX = ar_tx:new(<<"DATA">>),
	TaggedTX =
		TX#tx {
			tags =
				[
					{<<"TEST_TAG1">>, <<"TEST_VAL1">>},
					{<<"TEST_TAG2">>, <<"TEST_VAL2">>}
				]
		},
	ar_http_iface_client:send_tx_json({127, 0, 0, 1, 1984}, TaggedTX#tx.id,
			ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TaggedTX))),
	wait_until_receives_txs([TaggedTX]),
	ar_node:mine(),
	wait_until_height(1),
	[B1Hash | _] = ar_node:get_blocks(),
	B1 = read_block_when_stored(B1Hash),
	TXID = TaggedTX#tx.id,
	?assertEqual([TXID], B1#block.txs),
	?assertEqual(TaggedTX, ar_storage:read_tx(hd(B1#block.txs))).

%% @doc Test getting transactions
find_external_tx_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	TX = ar_tx:new(<<"DATA">>),
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984}, TX#tx.id,
			ar_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	ar_node:mine(),
	wait_until_height(1),
	{ok, FoundTXID} =
		ar_util:do_until(
			fun() ->
				case ar_http_iface_client:get_tx([{127, 0, 0, 1, 1984}], TX#tx.id, maps:new()) of
					not_found ->
						false;
					TX ->
						{ok, TX#tx.id}
				end
			end,
			100,
			1000
		),
	?assertEqual(FoundTXID, TX#tx.id).

add_block_with_invalid_hash_test_() ->
	{timeout, 20, fun test_add_block_with_invalid_hash/0}.

test_add_block_with_invalid_hash() ->
	[B0] = ar_weave:init([], ar_retarget:switch_to_linear_diff(10)),
	start(B0),
	{_Slave, _} = slave_start(B0),
	slave_mine(),
	BI = assert_slave_wait_until_height(1),
	Peer = {127, 0, 0, 1, 1984},
	B1Shadow =
		(slave_call(ar_storage, read_block, [hd(BI)]))#block{
			hash_list = [B0#block.indep_hash]
		},
	%% Try to post an invalid block. This triggers a ban in ar_blacklist_middleware.
	InvalidH = crypto:strong_rand_bytes(48),
	ok = ar_events:subscribe(block),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		send_new_block(Peer, B1Shadow#block{ indep_hash = InvalidH, nonce = <<>> })),
	receive
		{event, block, {rejected, invalid_hash, InvalidH, Peer}} ->
			ok
		after 500 ->
			?assert(false, "Did not receive the rejected block event (invalid_hash).")
	end,
	%% Verify the IP address of self is NOT banned in ar_blacklist_middleware.
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(
			Peer, B1Shadow#block{ indep_hash = crypto:strong_rand_bytes(48) })),
	ar_blacklist_middleware:reset(),
	%% The valid block with the ID from the failed attempt can still go through.
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B1Shadow)),
	%% Try to post the same block again.
	?assertMatch({ok, {{<<"208">>, _}, _, _, _, _}}, send_new_block(Peer, B1Shadow)),
	%% Correct hash, but invalid PoW.
	B2Shadow = B1Shadow#block{ reward_addr = crypto:strong_rand_bytes(32) },
	InvalidH2 = ar_block:indep_hash(B2Shadow),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		send_new_block(Peer, B2Shadow#block{ indep_hash = InvalidH2 })),
	receive
		{event, block, {rejected, invalid_pow, InvalidH2, Peer}} ->
			ok
		after 500 ->
			?assert(false, "Did not receive the rejected block event "
					"(invalid_pow).")
	end,
	?assertMatch(
		{ok, {{<<"403">>, _}, _, <<"IP address blocked due to previous request.">>, _, _}},
		send_new_block(
			Peer,
			B1Shadow#block{indep_hash = crypto:strong_rand_bytes(48) }
		)
	),
	ar_blacklist_middleware:reset().

add_external_block_with_invalid_timestamp_pre_fork_2_6_test_() ->
	test_on_fork(height_2_6, infinity,
			fun test_add_external_block_with_invalid_timestamp_pre_fork_2_6/0).

test_add_external_block_with_invalid_timestamp_pre_fork_2_6() ->
	ar_blacklist_middleware:reset(),
	[B0] = ar_weave:init([]),
	start(B0),
	{_Slave, _} = slave_start(B0),
	slave_mine(),
	BI = assert_slave_wait_until_height(1),
	Peer = {127, 0, 0, 1, 1984},
	B1Shadow =
		(slave_call(ar_storage, read_block, [hd(BI)]))#block{
			hash_list = [B0#block.indep_hash]
		},
	%% Expect the timestamp too far from the future to be rejected.
	FutureTimestampTolerance = ?JOIN_CLOCK_TOLERANCE * 2 + ?CLOCK_DRIFT_MAX,
	TooFarFutureTimestamp = os:system_time(second) + FutureTimestampTolerance + 3,
	B2Shadow = update_block_timestamp(B1Shadow, TooFarFutureTimestamp),
	ok = ar_events:subscribe(block),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B2Shadow)),
	H = B2Shadow#block.indep_hash,
	receive
		{event, block, {rejected, invalid_timestamp, H, Peer}} ->
			ok
		after 500 ->
			?assert(false, "Did not receive the rejected block event (invalid_timestamp).")
	end,
	%% Expect the timestamp from the future within the tolerance interval to be accepted.
	OkFutureTimestamp = os:system_time(second) + FutureTimestampTolerance - 3,
	B3Shadow = update_block_timestamp(B1Shadow, OkFutureTimestamp),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B3Shadow)),
	%% Expect the timestamp far from the past to be rejected.
	PastTimestampTolerance = lists:sum([?JOIN_CLOCK_TOLERANCE * 2, ?CLOCK_DRIFT_MAX]),
	TooFarPastTimestamp = B0#block.timestamp - PastTimestampTolerance - 3,
	B4Shadow = update_block_timestamp(B1Shadow, TooFarPastTimestamp),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B4Shadow)),
	H2 = B4Shadow#block.indep_hash,
	receive
		{event, block, {rejected, invalid_timestamp, H2, Peer}} ->
			ok
		after 500 ->
			?assert(false, "Did not receive the rejected block event (invalid_timestamp).")
	end,
	%% Expect the block with a timestamp from the past within the tolerance interval
	%% to be accepted.
	OkPastTimestamp = B0#block.timestamp - PastTimestampTolerance + 3,
	B5Shadow = update_block_timestamp(B1Shadow, OkPastTimestamp),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B5Shadow)),
	%% Wait a little bit, before the height_2_6 mock is removed.
	%% Otherwise, the node may crash trying to validate the new block
	%% with the previous block not having a packing_2_6_threshold field.
	timer:sleep(1000).

add_external_block_with_invalid_timestamp_test_() ->
	{timeout, 20, fun test_add_external_block_with_invalid_timestamp/0}.

test_add_external_block_with_invalid_timestamp() ->
	ar_blacklist_middleware:reset(),
	[B0] = ar_weave:init([]),
	start(B0),
	{_Slave, _} = slave_start(B0),
	slave_mine(),
	BI = assert_slave_wait_until_height(1),
	Peer = {127, 0, 0, 1, 1984},
	B1Shadow =
		(slave_call(ar_storage, read_block, [hd(BI)]))#block{
			hash_list = [B0#block.indep_hash]
		},
	%% Expect the timestamp too far from the future to be rejected.
	FutureTimestampTolerance = ?JOIN_CLOCK_TOLERANCE * 2 + ?CLOCK_DRIFT_MAX,
	TooFarFutureTimestamp = os:system_time(second) + FutureTimestampTolerance + 3,
	B2Shadow = update_block_timestamp(B1Shadow, TooFarFutureTimestamp),
	ok = ar_events:subscribe(block),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B2Shadow)),
	H = B2Shadow#block.indep_hash,
	receive
		{event, block, {rejected, invalid_timestamp, H, Peer}} ->
			ok
		after 500 ->
			?assert(false, "Did not receive the rejected block event (invalid_timestamp)")
	end,
	%% Expect the timestamp from the future within the tolerance interval to be accepted.
	OkFutureTimestamp = os:system_time(second) + FutureTimestampTolerance - 3,
	B3Shadow = update_block_timestamp(B1Shadow, OkFutureTimestamp),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B3Shadow)),
	%% Expect the timestamp too far behind the previous timestamp to be rejected.
	PastTimestampTolerance = lists:sum([?JOIN_CLOCK_TOLERANCE * 2, ?CLOCK_DRIFT_MAX]),
	TooFarPastTimestamp = B0#block.timestamp - PastTimestampTolerance - 1,
	B4Shadow = update_block_timestamp(B1Shadow, TooFarPastTimestamp),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B4Shadow)),
	H2 = B4Shadow#block.indep_hash,
	receive
		{event, block, {rejected, invalid_timestamp, H2, Peer}} ->
			ok
		after 500 ->
			?assert(false, "Did not receive the rejected block event "
					"(invalid_timestamp).")
	end,
	OkPastTimestamp = B0#block.timestamp - PastTimestampTolerance + 1,
	B5Shadow = update_block_timestamp(B1Shadow, OkPastTimestamp),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}}, send_new_block(Peer, B5Shadow)).

update_block_timestamp(B, Timestamp) ->
	#block{
		height = Height,
		nonce = Nonce,
		previous_block = PrevH,
		poa = #poa{ chunk = Chunk }
	} = B,
	B2 = B#block{ timestamp = Timestamp },
	BDS = ar_block:generate_block_data_segment(B2),
	{H0, _Entropy} = ar_mine:spora_h0_with_entropy(BDS, Nonce, Height),
	B3 = B2#block{ hash = element(1, ar_mine:spora_solution_hash(PrevH, Timestamp, H0, Chunk,
			Height)) },
	B3#block{ indep_hash = ar_block:indep_hash(B3) }.

%% @doc Post a tx to the network and ensure that last_tx call returns the ID of last tx.
add_tx_and_get_last_test() ->
	{Priv1, Pub1} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub1), ?AR(10000), <<>>}]),
	{_Node, _} = start(B0),
	{_Priv2, Pub2} = ar_wallet:new(),
	TX = ar_tx:new(ar_wallet:to_address(Pub2), ?AR(1), ?AR(9000), <<>>),
	SignedTX = ar_tx:sign_v1(TX, Priv1, Pub1),
	ID = SignedTX#tx.id,
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984}, SignedTX#tx.id,
			ar_serialize:tx_to_binary(SignedTX)),
	wait_until_receives_txs([SignedTX]),
	ar_node:mine(),
	wait_until_height(1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet/"
					++ binary_to_list(ar_util:encode(ar_wallet:to_address(Pub1)))
					++ "/last_tx"
		}),
	?assertEqual(ID, ar_util:decode(Body)).

%% @doc Post a tx to the network and ensure that its subfields can be gathered
get_subfields_of_tx_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	TX = ar_tx:new(<<"DATA">>),
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984}, TX#tx.id,
			ar_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	ar_node:mine(),
	wait_until_height(1),
	{ok, Body} = wait_until_syncs_tx_data(TX#tx.id),
	Orig = TX#tx.data,
	?assertEqual(Orig, ar_util:decode(Body)).

%% @doc Correctly check the status of pending is returned for a pending transaction
get_pending_tx_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	TX = ar_tx:new(<<"DATA1">>),
	ar_http_iface_client:send_tx_json({127, 0, 0, 1, 1984}, TX#tx.id,
			ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX))),
	wait_until_receives_txs([TX]),
	{ok, {{<<"202">>, _}, _, Body, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ binary_to_list(ar_util:encode(TX#tx.id))
		}),
	?assertEqual(<<"Pending">>, Body).

%% @doc Mine a transaction into a block and retrieve it's binary body via HTTP.
get_tx_body_test() ->
	[B0] = ar_weave:init(random_wallets()),
	{_Node, _} = start(B0),
	TX = ar_tx:new(<<"TEST DATA">>),
	assert_post_tx_to_master(TX),
	ar_node:mine(),
	wait_until_height(1),
	{ok, Data} = wait_until_syncs_tx_data(TX#tx.id),
	?assertEqual(<<"TEST DATA">>, ar_util:decode(Data)).

random_wallets() ->
	{_, Pub} = ar_wallet:new(),
	[{ar_wallet:to_address(Pub), ?AR(10000), <<>>}].

get_txs_by_send_recv_test_() ->
	{timeout, 60, fun() ->
		{Priv1, Pub1} = ar_wallet:new(),
		{Priv2, Pub2} = ar_wallet:new(),
		{_Priv3, Pub3} = ar_wallet:new(),
		TX = ar_tx:new(Pub2, ?AR(1), ?AR(9000), <<>>),
		SignedTX = ar_tx:sign_v1(TX, Priv1, Pub1),
		TX2 = ar_tx:new(Pub3, ?AR(1), ?AR(500), <<>>),
		SignedTX2 = ar_tx:sign_v1(TX2, Priv2, Pub2),
		[B0] = ar_weave:init([{ar_wallet:to_address(Pub1), ?AR(10000), <<>>}]),
		{_Node, _} = start(B0),
		assert_post_tx_to_master(SignedTX),
		ar_node:mine(),
		wait_until_height(1),
		assert_post_tx_to_master(SignedTX2),
		ar_node:mine(),
		wait_until_height(2),
		QueryJSON = ar_serialize:jsonify(
			ar_serialize:query_to_json_struct(
					{'or',
						{'equals',
							<<"to">>,
							ar_util:encode(TX#tx.target)},
						{'equals',
							<<"from">>,
							ar_util:encode(TX#tx.target)}
					}
				)
			),
		{ok, {_, _, Res, _, _}} =
			ar_http:req(#{
				method => post,
				peer => {127, 0, 0, 1, 1984},
				path => "/arql",
				body => QueryJSON
			}),
		TXs = ar_serialize:dejsonify(Res),
		?assertEqual(true,
			lists:member(
				SignedTX#tx.id,
				lists:map(
					fun ar_util:decode/1,
					TXs
				)
			)),
		?assertEqual(true,
			lists:member(
				SignedTX2#tx.id,
				lists:map(
					fun ar_util:decode/1,
					TXs
				)
			))
	end}.

get_tx_status_test_() ->
	{timeout, 20, fun test_get_tx_status/0}.

test_get_tx_status() ->
	[B0] = ar_weave:init([]),
	{_Node, _} = start(B0),
	TX = (ar_tx:new())#tx{ tags = [{<<"TestName">>, <<"TestVal">>}] },
	assert_post_tx_to_master(TX),
	FetchStatus = fun() ->
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ binary_to_list(ar_util:encode(TX#tx.id)) ++ "/status"
		})
	end,
	?assertMatch({ok, {{<<"202">>, _}, _, <<"Pending">>, _, _}}, FetchStatus()),
	ar_node:mine(),
	wait_until_height(1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} = FetchStatus(),
	{Res} = ar_serialize:dejsonify(Body),
	BI = ar_node:get_block_index(),
	?assertEqual(
		#{
			<<"block_height">> => length(BI) - 1,
			<<"block_indep_hash">> => ar_util:encode(element(1, hd(BI))),
			<<"number_of_confirmations">> => 1
		},
		maps:from_list(Res)
	),
	ar_node:mine(),
	wait_until_height(2),
	ar_util:do_until(
		fun() ->
			{ok, {{<<"200">>, _}, _, Body2, _, _}} = FetchStatus(),
			{Res2} = ar_serialize:dejsonify(Body2),
			#{
				<<"block_height">> => length(BI) - 1,
				<<"block_indep_hash">> => ar_util:encode(element(1, hd(BI))),
				<<"number_of_confirmations">> => 2
			} == maps:from_list(Res2)
		end,
		200,
		5000
	),
	%% Create a fork which returns the TX to mempool.
	{_Slave, _} = slave_start(B0),
	connect_to_slave(),
	slave_mine(),
	assert_slave_wait_until_height(1),
	slave_mine(),
	assert_slave_wait_until_height(2),
	slave_mine(),
	wait_until_height(3),
	?assertMatch({ok, {{<<"202">>, _}, _, _, _, _}}, FetchStatus()).

post_unsigned_tx_test_() ->
	{timeout, 20, fun post_unsigned_tx/0}.

post_unsigned_tx() ->
	{_, Pub} = Wallet = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(5000), <<>>}]),
	{_Node, _} = start(B0),
	%% Generate a wallet and receive a wallet access code.
	{ok, {{<<"421">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet"
		}),
	{ok, Config} = application:get_env(arweave, config),
	application:set_env(arweave, config,
			Config#config{ internal_api_secret = <<"correct_secret">> }),
	{ok, {{<<"421">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet",
			headers => [{<<"X-Internal-Api-Secret">>, <<"incorrect_secret">>}]
		}),
	{ok, {{<<"200">>, <<"OK">>}, _, CreateWalletBody, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/wallet",
			headers => [{<<"X-Internal-Api-Secret">>, <<"correct_secret">>}]
		}),
	application:set_env(arweave, config, Config#config{ internal_api_secret = not_set }),
	{CreateWalletRes} = ar_serialize:dejsonify(CreateWalletBody),
	[WalletAccessCode] = proplists:get_all_values(<<"wallet_access_code">>, CreateWalletRes),
	[Address] = proplists:get_all_values(<<"wallet_address">>, CreateWalletRes),
	%% Top up the new wallet.
	TopUpTX = ar_tx:sign_v1((ar_tx:new())#tx {
		owner = Pub,
		target = ar_util:decode(Address),
		quantity = ?AR(1),
		reward = ?AR(1)
	}, Wallet),
	{ok, {{<<"200">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx",
			body => ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TopUpTX))
		}),
	wait_until_receives_txs([TopUpTX]),
	ar_node:mine(),
	wait_until_height(1),
	%% Send an unsigned transaction to be signed with the generated key.
	TX = (ar_tx:new())#tx{reward = ?AR(1)},
	UnsignedTXProps = [
		{<<"last_tx">>, TX#tx.last_tx},
		{<<"target">>, TX#tx.target},
		{<<"quantity">>, integer_to_binary(TX#tx.quantity)},
		{<<"data">>, TX#tx.data},
		{<<"reward">>, integer_to_binary(TX#tx.reward)},
		{<<"wallet_access_code">>, WalletAccessCode}
	],
	{ok, {{<<"421">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/unsigned_tx",
			body => ar_serialize:jsonify({UnsignedTXProps})
		}),
	application:set_env(arweave, config,
			Config#config{ internal_api_secret = <<"correct_secret">> }),
	{ok, {{<<"421">>, _}, _, _, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/unsigned_tx",
			headers => [{<<"X-Internal-Api-Secret">>, <<"incorrect_secret">>}],
			body => ar_serialize:jsonify({UnsignedTXProps})
		}),
	{ok, {{<<"200">>, <<"OK">>}, _, Body, _, _}} =
		ar_http:req(#{
			method => post,
			peer => {127, 0, 0, 1, 1984},
			path => "/unsigned_tx",
			headers => [{<<"X-Internal-Api-Secret">>, <<"correct_secret">>}],
			body => ar_serialize:jsonify({UnsignedTXProps})
		}),
	application:set_env(arweave, config, Config#config{ internal_api_secret = not_set }),
	{Res} = ar_serialize:dejsonify(Body),
	TXID = proplists:get_value(<<"id">>, Res),
	timer:sleep(200),
	ar_node:mine(),
	wait_until_height(2),
	{ok, {_, _, GetTXBody, _, _}} =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ binary_to_list(TXID) ++ "/status"
		}),
	{GetTXRes} = ar_serialize:dejsonify(GetTXBody),
	?assertMatch(
		#{
			<<"number_of_confirmations">> := 1
		},
		maps:from_list(GetTXRes)
	).

get_wallet_txs_test_() ->
	{timeout, 10, fun() ->
		{_, Pub = { _, Owner}} = ar_wallet:new(),
		WalletAddress = binary_to_list(ar_util:encode(ar_wallet:to_address(Pub))),
		[B0] = ar_weave:init([{ar_wallet:to_address(Pub), 10000, <<>>}]),
		{_Node, _} = start(B0),
		{ok, {{<<"200">>, <<"OK">>}, _, Body, _, _}} =
			ar_http:req(#{
				method => get,
				peer => {127, 0, 0, 1, 1984},
				path => "/wallet/" ++ WalletAddress ++ "/txs"
			}),
		TXs = ar_serialize:dejsonify(Body),
		%% Expect the wallet to have no transactions
		?assertEqual([], TXs),
		%% Sign and post a transaction and expect it to appear in the wallet list
		TX = (ar_tx:new())#tx{ owner = Owner },
		{ok, {{<<"200">>, <<"OK">>}, _, _, _, _}} =
			ar_http:req(#{
				method => post,
				peer => {127, 0, 0, 1, 1984},
				path => "/tx",
				body => ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX))
			}),
		wait_until_receives_txs([TX]),
		ar_node:mine(),
		[{H, _, _} | _] = wait_until_height(1),
		%% Wait until the storage is updated before querying for wallet's transactions.
		read_block_when_stored(H),
		{ok, {{<<"200">>, <<"OK">>}, _, GetOneTXBody, _, _}} =
			ar_http:req(#{
				method => get,
				peer => {127, 0, 0, 1, 1984},
				path => "/wallet/" ++ WalletAddress ++ "/txs"
			}),
		OneTX = ar_serialize:dejsonify(GetOneTXBody),
		?assertEqual([ar_util:encode(TX#tx.id)], OneTX),
		%% Expect the same when the TX is specified as the earliest TX
		{ok, {{<<"200">>, <<"OK">>}, _, GetOneTXAgainBody, _, _}} =
			ar_http:req(#{
				method => get,
				peer => {127, 0, 0, 1, 1984},
				path => "/wallet/" ++ WalletAddress ++ "/txs/" ++ binary_to_list(ar_util:encode(TX#tx.id))
			}),
		OneTXAgain = ar_serialize:dejsonify(GetOneTXAgainBody),
		?assertEqual([ar_util:encode(TX#tx.id)], OneTXAgain),
		%% Add one more TX and expect it to be appended to the wallet list
		SecondTX = (ar_tx:new())#tx{ owner = Owner, last_tx = TX#tx.id },
		{ok, {{<<"200">>, <<"OK">>}, _, _, _, _}} =
			ar_http:req(#{
				method => post,
				peer => {127, 0, 0, 1, 1984},
				path => "/tx",
				body => ar_serialize:jsonify(ar_serialize:tx_to_json_struct(SecondTX))
			}),
		wait_until_receives_txs([SecondTX]),
		ar_node:mine(),
		wait_until_height(2),
		{ok, {{<<"200">>, <<"OK">>}, _, GetTwoTXsBody, _, _}} =
			ar_http:req(#{
				method => get,
				peer => {127, 0, 0, 1, 1984},
				path => "/wallet/" ++ WalletAddress ++ "/txs"
			}),
		Expected = [ar_util:encode(SecondTX#tx.id), ar_util:encode(TX#tx.id)],
		?assertEqual(Expected, ar_serialize:dejsonify(GetTwoTXsBody)),
		%% Specify the second TX as the earliest and expect the first one to be excluded
		{ok, {{<<"200">>, <<"OK">>}, _, GetSecondTXBody, _, _}} =
			ar_http:req(#{
				method => get,
				peer => {127, 0, 0, 1, 1984},
				path => "/wallet/" ++ WalletAddress ++ "/txs/" ++ binary_to_list(ar_util:encode(SecondTX#tx.id))
			}),
		OneSecondTX = ar_serialize:dejsonify(GetSecondTXBody),
		?assertEqual([ar_util:encode(SecondTX#tx.id)], OneSecondTX)
	end}.

get_wallet_deposits_test_() ->
	{timeout, 10, fun() ->
		%% Create a wallet to transfer tokens to
		{_, PubTo} = ar_wallet:new(),
		WalletAddressTo = binary_to_list(ar_util:encode(ar_wallet:to_address(PubTo))),
		%% Create a wallet to transfer tokens from
		{_, PubFrom = { _, OwnerFrom }} = ar_wallet:new(),
		[B0] = ar_weave:init([
			{ar_wallet:to_address(PubTo), 0, <<>>},
			{ar_wallet:to_address(PubFrom), 200, <<>>}
		]),
		{_Node, _} = start(B0),
		GetTXs = fun(EarliestDeposit) ->
			BasePath = "/wallet/" ++ WalletAddressTo ++ "/deposits",
			Path = 	BasePath ++ "/" ++ EarliestDeposit,
			{ok, {{<<"200">>, <<"OK">>}, _, Body, _, _}} =
				ar_http:req(#{
					method => get,
					peer => {127, 0, 0, 1, 1984},
					path => Path
				}),
			ar_serialize:dejsonify(Body)
		end,
		%% Expect the wallet to have no incoming transfers
		?assertEqual([], GetTXs("")),
		%% Send some Winston to WalletAddressTo
		FirstTX = (ar_tx:new())#tx{
			owner = OwnerFrom,
			target = ar_wallet:to_address(PubTo),
			quantity = 100
		},
		PostTX = fun(T) ->
			{ok, {{<<"200">>, <<"OK">>}, _, _, _, _}} =
				ar_http:req(#{
					method => post,
					peer => {127, 0, 0, 1, 1984},
					path => "/tx",
					body => ar_serialize:jsonify(ar_serialize:tx_to_json_struct(T))
				})
		end,
		PostTX(FirstTX),
		wait_until_receives_txs([FirstTX]),
		ar_node:mine(),
		wait_until_height(1),
		%% Expect the endpoint to report the received transfer
		?assertEqual([ar_util:encode(FirstTX#tx.id)], GetTXs("")),
		%% Send some more Winston to WalletAddressTo
		SecondTX = (ar_tx:new())#tx{
			owner = OwnerFrom,
			target = ar_wallet:to_address(PubTo),
			last_tx = FirstTX#tx.id,
			quantity = 100
		},
		PostTX(SecondTX),
		wait_until_receives_txs([SecondTX]),
		ar_node:mine(),
		wait_until_height(2),
		%% Expect the endpoint to report the received transfer
		?assertEqual(
			[ar_util:encode(SecondTX#tx.id), ar_util:encode(FirstTX#tx.id)],
			GetTXs("")
		),
		%% Specify the first tx as the earliest, still expect to get both txs
		?assertEqual(
			[ar_util:encode(SecondTX#tx.id), ar_util:encode(FirstTX#tx.id)],
			GetTXs(ar_util:encode(FirstTX#tx.id))
		),
		%% Specify the second tx as the earliest, expect to get only it
		?assertEqual(
			[ar_util:encode(SecondTX#tx.id)],
			GetTXs(ar_util:encode(SecondTX#tx.id))
		)
	end}.

%% @doc Ensure the HTTP client stops fetching data from an endpoint when its data size
%% limit is exceeded.
get_error_of_data_limit_test() ->
	[B0] = ar_weave:init(),
	{_Node, _} = start(B0),
	Limit = 1460,
	TX = ar_tx:new(<< <<0>> || _ <- lists:seq(1, Limit * 2) >>),
	ar_http_iface_client:send_tx_binary({127, 0, 0, 1, 1984}, TX#tx.id,
			ar_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	ar_node:mine(),
	wait_until_height(1),
	{ok, _} = wait_until_syncs_tx_data(TX#tx.id),
	Resp =
		ar_http:req(#{
			method => get,
			peer => {127, 0, 0, 1, 1984},
			path => "/tx/" ++ binary_to_list(ar_util:encode(TX#tx.id)) ++ "/data",
			limit => Limit
		}),
	?assertEqual({error, too_much_data}, Resp).

send_block2_test_() ->
	{timeout, 20000, fun test_send_block2/0}.

test_send_block2() ->
	{_, Pub} = Wallet = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(100), <<>>}]),
	start(B0),
	slave_start(B0),
	disconnect_from_slave(),
	TXs = [sign_tx(Wallet, #{ last_tx => get_tx_anchor() }) || _ <- lists:seq(1, 10)],
	lists:foreach(fun(TX) -> assert_post_tx_to_master(TX) end, TXs),
	EverySecondTX = element(2, lists:foldl(fun(TX, {N, Acc}) when N rem 2 /= 0 ->
			{N + 1, [TX | Acc]}; (_TX, {N, Acc}) -> {N + 1, Acc} end, {0, []}, TXs)),
	lists:foreach(fun(TX) -> assert_post_tx_to_slave(TX) end, EverySecondTX),
	ar_node:mine(),
	[{H, _, _}, _] = wait_until_height(1),
	B = ar_storage:read_block(H),
	Announcement = #block_announcement{ indep_hash = B#block.indep_hash,
			previous_block = B0#block.indep_hash,
			tx_prefixes = [binary:part(TX#tx.id, 0, 8) || TX <- TXs] },
	{ok, {{<<"200">>, _}, _, Body, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(Announcement) }),
	Response = ar_serialize:binary_to_block_announcement_response(Body),
	?assertEqual({ok, #block_announcement_response{ missing_chunk = true,
			missing_tx_indices = [0, 2, 4, 6, 8] }}, Response),
	Announcement2 = Announcement#block_announcement{ recall_byte = 0 },
	{ok, {{<<"200">>, _}, _, Body, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(Announcement2) }),
	Announcement3 = Announcement#block_announcement{ recall_byte = 100000000000000 },
	{ok, {{<<"200">>, _}, _, Body, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(Announcement3) }),
	{ok, {{<<"418">>, _}, _, Body2, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block2",
			body => ar_serialize:block_to_binary(B) }),
	?assertEqual(iolist_to_binary(lists:foldl(fun(#tx{ id = TXID }, Acc) -> [Acc | TXID] end,
			[], TXs -- EverySecondTX)), Body2),
	B2 = B#block{ txs = [lists:nth(1, TXs) | tl(B#block.txs)] },
	{ok, {{<<"418">>, _}, _, Body3, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block2",
			body => ar_serialize:block_to_binary(B2) }),
	?assertEqual(iolist_to_binary(lists:foldl(fun(#tx{ id = TXID }, Acc) -> [Acc | TXID] end,
			[], TXs -- EverySecondTX -- [lists:nth(1, TXs)])), Body3),
	TXs2 = [sign_tx(Wallet, #{ last_tx => get_tx_anchor(),
			data => crypto:strong_rand_bytes(10 * 1024) }) || _ <- lists:seq(1, 10)],
	lists:foreach(fun(TX) -> assert_post_tx_to_master(TX) end, TXs2),
	ar_node:mine(),
	[{H2, _, _}, _, _] = wait_until_height(2),
	{ok, {{<<"412">>, _}, _, <<>>, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(#block_announcement{
					indep_hash = H2, previous_block = B#block.indep_hash }) }),
	BTXs = ar_storage:read_tx(B#block.txs),
	B3 = B#block{ txs = BTXs },
	{ok, {{<<"200">>, _}, _, <<"OK">>, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block2",
			body => ar_serialize:block_to_binary(B3) }),
	{ok, {{<<"200">>, _}, _, SerializedB, _, _}} = ar_http:req(#{ method => get,
			peer => master_peer(), path => "/block2/height/1" }),
	?assertEqual({ok, B}, ar_serialize:binary_to_block(SerializedB)),
	SortedTXs = lists:sort(TXs),
	Map = element(2, lists:foldl(fun(TX, {N, M}) -> {N + 1, maps:put(TX#tx.id, N, M)} end,
			{0, #{}}, SortedTXs)),
	{ok, {{<<"200">>, _}, _, Serialized2B, _, _}} = ar_http:req(#{ method => get,
			peer => master_peer(), path => "/block2/height/1",
			body => << 1:1, 0:(8 * 125 - 1) >> }),
	?assertEqual({ok, B#block{ txs = [case maps:get(TX#tx.id, Map) == 0 of true -> TX;
			_ -> TX#tx.id end || TX <- BTXs] }}, ar_serialize:binary_to_block(Serialized2B)),
	{ok, {{<<"200">>, _}, _, Serialized2B, _, _}} = ar_http:req(#{ method => get,
			peer => master_peer(), path => "/block2/height/1",
			body => << 1:1, 0:7 >> }),
	{ok, {{<<"200">>, _}, _, Serialized3B, _, _}} = ar_http:req(#{ method => get,
			peer => master_peer(), path => "/block2/height/1",
			body => << 0:1, 1:1, 0:1, 1:1, 0:4 >> }),
	?assertEqual({ok, B#block{ txs = [case lists:member(maps:get(TX#tx.id, Map), [1, 3]) of
			true -> TX; _ -> TX#tx.id end || TX <- BTXs] }},
					ar_serialize:binary_to_block(Serialized3B)),
	B4 = read_block_when_stored(H2, true),
	timer:sleep(500),
	{ok, {{<<"200">>, _}, _, <<"OK">>, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block2",
			body => ar_serialize:block_to_binary(B4) }),
	connect_to_slave(),
	lists:foreach(
		fun(Height) ->
			ar_node:mine(),
			assert_slave_wait_until_height(Height)
		end,
		lists:seq(3, 3 + ?SEARCH_SPACE_UPPER_BOUND_DEPTH)
	),
	B5 = ar_storage:read_block(ar_node:get_current_block_hash()),
	{ok, {{<<"208">>, _}, _, _, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(#block_announcement{
					indep_hash = B5#block.indep_hash,
					previous_block = B5#block.previous_block }) }),
	lists:foreach(
		fun(#tx{ id = TXID }) ->
			true = ar_util:do_until(
				fun() ->
					{ok, {End, _}} = slave_call(ar_data_sync, get_tx_offset, [TXID]),
					slave_call(ar_sync_record, is_recorded, [End, ar_data_sync])
							== {true, spora_2_5}
				end,
				100,
				5000
			)
		end,
		TXs2
	),
	disconnect_from_slave(),
	ar_node:mine(),
	[_ | _] = wait_until_height(3 + ?SEARCH_SPACE_UPPER_BOUND_DEPTH + 1),
	B6 = ar_storage:read_block(ar_node:get_current_block_hash()),
	{ok, {{<<"200">>, _}, _, Body4, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(#block_announcement{
					indep_hash = B6#block.indep_hash,
					previous_block = B6#block.previous_block,
					recall_byte = 0 }) }),
	?assertEqual({ok, #block_announcement_response{ missing_chunk = false,
			missing_tx_indices = [] }},
			ar_serialize:binary_to_block_announcement_response(Body4)),
	{ok, {{<<"200">>, _}, _, Body5, _, _}} = ar_http:req(#{ method => post,
			peer => slave_peer(), path => "/block_announcement",
			body => ar_serialize:block_announcement_to_binary(#block_announcement{
					indep_hash = B6#block.indep_hash,
					previous_block = B6#block.previous_block,
					recall_byte = 1024 }) }),
	?assertEqual({ok, #block_announcement_response{ missing_chunk = false,
			missing_tx_indices = [] }},
			ar_serialize:binary_to_block_announcement_response(Body5)),
	{H0, _Entropy} = ar_mine:spora_h0_with_entropy(ar_block:generate_block_data_segment(B6),
			B6#block.nonce, B6#block.height),
	SearchSpaceUpperBound = ar_node:get_recent_search_space_upper_bound_by_prev_h(
			B6#block.previous_block),
	{ok, RecallByte} = ar_mine:pick_recall_byte(H0, B6#block.previous_block,
			SearchSpaceUpperBound),
	{ok, {{<<"419">>, _}, _, _, _, _}} = ar_http:req(#{ method => post,
		peer => slave_peer(), path => "/block2",
		headers => [{<<"arweave-recall-byte">>, integer_to_binary(1000000000000)}],
		body => ar_serialize:block_to_binary(B6#block{ poa = #poa{} }) }),
	{ok, {{<<"200">>, _}, _, <<"OK">>, _, _}} = ar_http:req(#{ method => post,
		peer => slave_peer(), path => "/block2",
		headers => [{<<"arweave-recall-byte">>, integer_to_binary(RecallByte)}],
		body => ar_serialize:block_to_binary(B6#block{ poa = #poa{} }) }),
	assert_slave_wait_until_height(3 + ?SEARCH_SPACE_UPPER_BOUND_DEPTH + 1).

send_missing_transactions_along_with_the_block_test_() ->
	{timeout, 20000, fun test_send_missing_transactions_along_with_the_block/0}.

test_send_missing_transactions_along_with_the_block() ->
	{_, Pub} = Wallet = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(100), <<>>}]),
	start(B0),
	slave_start(B0),
	disconnect_from_slave(),
	TXs = [sign_tx(Wallet, #{ last_tx => get_tx_anchor() }) || _ <- lists:seq(1, 10)],
	lists:foreach(fun(TX) -> assert_post_tx_to_master(TX) end, TXs),
	EverySecondTX = element(2, lists:foldl(fun(TX, {N, Acc}) when N rem 2 /= 0 ->
			{N + 1, [TX | Acc]}; (_TX, {N, Acc}) -> {N + 1, Acc} end, {0, []}, TXs)),
	lists:foreach(fun(TX) -> assert_post_tx_to_slave(TX) end, EverySecondTX),
	ar_node:mine(),
	[{H, _, _}, _] = wait_until_height(1),
	B = ar_storage:read_block(H),
	B2 = B#block{ txs = ar_storage:read_tx(B#block.txs) },
	connect_to_slave(),
	ar_bridge ! {event, block, {new, B2, #{ recall_byte => undefined }}},
	assert_slave_wait_until_height(1).

falls_back_to_block_endpoint_when_cannot_send_transactions_test_() ->
	{timeout, 20000, fun test_falls_back_to_block_endpoint_when_cannot_send_transactions/0}.

test_falls_back_to_block_endpoint_when_cannot_send_transactions() ->
	{_, Pub} = Wallet = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(100), <<>>}]),
	start(B0),
	slave_start(B0),
	disconnect_from_slave(),
	TXs = [sign_tx(Wallet, #{ last_tx => get_tx_anchor() }) || _ <- lists:seq(1, 10)],
	lists:foreach(fun(TX) -> assert_post_tx_to_master(TX) end, TXs),
	EverySecondTX = element(2, lists:foldl(fun(TX, {N, Acc}) when N rem 2 /= 0 ->
			{N + 1, [TX | Acc]}; (_TX, {N, Acc}) -> {N + 1, Acc} end, {0, []}, TXs)),
	lists:foreach(fun(TX) -> assert_post_tx_to_slave(TX) end, EverySecondTX),
	ar_node:mine(),
	[{H, _, _}, _] = wait_until_height(1),
	B = ar_storage:read_block(H),
	connect_to_slave(),
	ar_bridge ! {event, block, {new, B, #{ recall_byte => undefined }}},
	assert_slave_wait_until_height(1).

get_recent_hash_list_diff_test_() ->
	{timeout, 20, fun test_get_recent_hash_list_diff/0}.

test_get_recent_hash_list_diff() ->
	{_, Pub} = Wallet = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(100), <<>>}]),
	start(B0),
	slave_start(B0),
	{ok, {{<<"404">>, _}, _, <<>>, _, _}} = ar_http:req(#{ method => get,
		peer => master_peer(), path => "/recent_hash_list_diff",
		headers => [], body => <<>> }),
	{ok, {{<<"400">>, _}, _, <<>>, _, _}} = ar_http:req(#{ method => get,
		peer => master_peer(), path => "/recent_hash_list_diff",
		headers => [], body => crypto:strong_rand_bytes(47) }),
	{ok, {{<<"404">>, _}, _, <<>>, _, _}} = ar_http:req(#{ method => get,
		peer => master_peer(), path => "/recent_hash_list_diff",
		headers => [], body => crypto:strong_rand_bytes(48) }),
	B0H = B0#block.indep_hash,
	{ok, {{<<"200">>, _}, _, B0H, _, _}} = ar_http:req(#{ method => get,
		peer => master_peer(), path => "/recent_hash_list_diff",
		headers => [], body => B0H }),
	ar_node:mine(),
	[{B1H, _, _}, _] = wait_until_height(1),
	{ok, {{<<"200">>, _}, _, << B0H:48/binary, B1H:48/binary, 0:16 >> , _, _}}
			= ar_http:req(#{ method => get, peer => master_peer(),
			path => "/recent_hash_list_diff", headers => [], body => B0H }),
	TXs = [sign_tx(Wallet, #{ last_tx => get_tx_anchor() }) || _ <- lists:seq(1, 3)],
	lists:foreach(fun(TX) -> assert_post_tx_to_master(TX) end, TXs),
	ar_node:mine(),
	[{B2H, _, _} | _] = wait_until_height(2),
	[TXID1, TXID2, TXID3] = [TX#tx.id || TX <- lists:sort(TXs)],
	{ok, {{<<"200">>, _}, _, << B0H:48/binary, B1H:48/binary, 0:16, B2H:48/binary,
			3:16, TXID1:32/binary, TXID2:32/binary, TXID3/binary >> , _, _}}
			= ar_http:req(#{ method => get, peer => master_peer(),
			path => "/recent_hash_list_diff", headers => [], body => B0H }),
	{ok, {{<<"200">>, _}, _, << B0H:48/binary, B1H:48/binary, 0:16, B2H:48/binary,
			3:16, TXID1:32/binary, TXID2:32/binary, TXID3/binary >> , _, _}}
			= ar_http:req(#{ method => get, peer => master_peer(),
			path => "/recent_hash_list_diff", headers => [],
			body => << B0H/binary, (crypto:strong_rand_bytes(48))/binary >>}),
	{ok, {{<<"200">>, _}, _, << B1H:48/binary, B2H:48/binary,
			3:16, TXID1:32/binary, TXID2:32/binary, TXID3/binary >> , _, _}}
			= ar_http:req(#{ method => get, peer => master_peer(),
			path => "/recent_hash_list_diff", headers => [],
			body => << B0H/binary, B1H/binary, (crypto:strong_rand_bytes(48))/binary >>}).

send_new_block(Peer, B) ->
	ar_http_iface_client:send_block_binary(Peer, B#block.indep_hash,
			ar_serialize:block_to_binary(B)).

wait_until_syncs_tx_data(TXID) ->
	ar_util:do_until(
		fun() ->
			case ar_http:req(#{
				method => get,
				peer => {127, 0, 0, 1, 1984},
				path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/data"
			}) of
				{ok, {{<<"404">>, _}, _, _, _, _}} ->
					false;
				{ok, {{<<"200">>, _}, _, <<>>, _, _}} ->
					false;
				{ok, {{<<"200">>, _}, _, Payload, _, _}} ->
					{ok, Payload}
			end
		end,
		100,
		2000
	).
