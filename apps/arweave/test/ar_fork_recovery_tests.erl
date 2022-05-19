-module(ar_fork_recovery_tests).

-include_lib("arweave/include/ar.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(ar_test_node, [
		start/1, slave_start/1, start/2, slave_start/2, connect_to_slave/0,
		disconnect_from_slave/0, assert_post_tx_to_slave/1,
		slave_mine/0, assert_slave_wait_until_height/1, wait_until_height/1,
		slave_wait_until_height/1, sign_tx/2, read_block_when_stored/1, slave_call/3]).

height_plus_one_fork_recovery_test_() ->
	{timeout, 20, fun test_height_plus_one_fork_recovery/0}.

test_height_plus_one_fork_recovery() ->
	%% Mine on two nodes until they fork. Mine an extra block on one of them.
	%% Expect the other one to recover.
	{_SlaveNode, B0} = slave_start(no_block),
	{_MasterNode, B0} = start(B0),
	disconnect_from_slave(),
	slave_mine(),
	assert_slave_wait_until_height(1),
	ar_node:mine(),
	wait_until_height(1),
	ar_node:mine(),
	MasterBI = wait_until_height(2),
	connect_to_slave(),
	?assertEqual(MasterBI, slave_wait_until_height(2)),
	disconnect_from_slave(),
	ar_node:mine(),
	wait_until_height(3),
	slave_mine(),
	assert_slave_wait_until_height(3),
	connect_to_slave(),
	slave_mine(),
	SlaveBI = slave_wait_until_height(4),
	?assertEqual(SlaveBI, wait_until_height(4)).

height_plus_three_fork_recovery_test_() ->
	{timeout, 20, fun test_height_plus_three_fork_recovery/0}.

test_height_plus_three_fork_recovery() ->
	%% Mine on two nodes until they fork. Mine three extra blocks on one of them.
	%% Expect the other one to recover.
	{_SlaveNode, B0} = slave_start(no_block),
	{_MasterNode, B0} = start(B0),
	disconnect_from_slave(),
	slave_mine(),
	assert_slave_wait_until_height(1),
	ar_node:mine(),
	wait_until_height(1),
	ar_node:mine(),
	wait_until_height(2),
	slave_mine(),
	assert_slave_wait_until_height(2),
	ar_node:mine(),
	wait_until_height(3),
	slave_mine(),
	assert_slave_wait_until_height(3),
	connect_to_slave(),
	ar_node:mine(),
	MasterBI = wait_until_height(4),
	?assertEqual(MasterBI, slave_wait_until_height(4)).

missing_txs_fork_recovery_test_() ->
	{timeout, 120, fun test_missing_txs_fork_recovery/0}.

test_missing_txs_fork_recovery() ->
	%% Mine a block with a transaction on the slave node
	%% but do not gossip the transaction. The master node
	%% is expected fetch the missing transaction and apply the block.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(20), <<>>}]),
	{_SlaveNode, _} = slave_start(B0),
	{_MasterNode, _} = start(B0),
	disconnect_from_slave(),
	TX1 = sign_tx(Key, #{}),
	assert_post_tx_to_slave(TX1),
	%% Wait to make sure the tx will not be gossiped upon reconnect.
	timer:sleep(2000), % == 2 * ?CHECK_MEMPOOL_FREQUENCY
	connect_to_slave(),
	?assertEqual([], ar_node:get_pending_txs()),
	slave_mine(),
	[{H1, _, _} | _] = wait_until_height(1),
	?assertEqual(1, length((read_block_when_stored(H1))#block.txs)).

orphaned_txs_are_remined_after_fork_recovery_test_() ->
	{timeout, 120, fun test_orphaned_txs_are_remined_after_fork_recovery/0}.

test_orphaned_txs_are_remined_after_fork_recovery() ->
	%% Mine a transaction on slave, mine two blocks on master to
	%% make the transaction orphaned. Mine a block on slave and
	%% assert the transaction is re-mined.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(20), <<>>}]),
	{_SlaveNode, _} = slave_start(B0),
	{_MasterNode, _} = start(B0),
	disconnect_from_slave(),
	TX = #tx{ id = TXID } = sign_tx(Key, #{}),
	assert_post_tx_to_slave(TX),
	slave_mine(),
	[{H1, _, _} | _] = slave_wait_until_height(1),
	H1TXIDs = (slave_call(ar_test_node, read_block_when_stored, [H1]))#block.txs,
	?assertEqual([TXID], H1TXIDs),
	ar_node:mine(),
	[{H2, _, _} | _] = wait_until_height(1),
	ar_node:mine(),
	[{H3, _, _}, {H2, _, _}, {_, _, _}] = wait_until_height(2),
	connect_to_slave(),
	?assertMatch([{H3, _, _}, {H2, _, _}, {_, _, _}], slave_wait_until_height(2)),
	slave_mine(),
	[{H4, _, _} | _] = slave_wait_until_height(3),
	H4TXIDs = (slave_call(ar_test_node, read_block_when_stored, [H4]))#block.txs,
	?assertEqual([TXID], H4TXIDs).

invalid_block_with_high_cumulative_difficulty_test_() ->
	{timeout, 30, fun test_invalid_block_with_high_cumulative_difficulty/0}.

test_invalid_block_with_high_cumulative_difficulty() ->
	%% Submit an alternative fork with valid blocks weaker than the tip and
	%% an invalid block on top, much stronger than the tip. Make sure the node
	%% ignores the invalid block and continues to build on top of the valid fork.
	RewardKey = ar_wallet:new_ecdsa(),
	RewardAddr = ar_wallet:to_address(RewardKey),
	WalletName = ar_util:encode(RewardAddr),
	Path = ar_wallet:wallet_filepath(WalletName),
	SlavePath = slave_call(ar_wallet, wallet_filepath, [WalletName]),
	%% Copy the key because we mine blocks on both nodes using the same key in this test.
	{ok, _} = file:copy(Path, SlavePath),
	[B0] = ar_weave:init([]),
	{_SlaveNode, B0} = slave_start(B0, RewardAddr),
	{_MasterNode, B0} = start(B0, RewardAddr),
	disconnect_from_slave(),
	slave_mine(),
	[{H1, _, _} | _] = slave_wait_until_height(1),
	ar_node:mine(),
	[{H2, _, _} | _] = wait_until_height(1),
	connect_to_slave(),
	?assertNotEqual(H2, H1),
	B1 = read_block_when_stored(H2),
	B2 = fake_block_with_strong_cumulative_difficulty(B1, 10000000000000000),
	?assertMatch(
	    {ok, {{<<"200">>, _}, _, _, _, _}},
	    ar_http_iface_client:send_block_json({127, 0, 0, 1, 1984}, B2#block.indep_hash,
				block_to_json(B2))
	),
	timer:sleep(500),
	[{H1, _, _} | _] = slave_wait_until_height(1),
	ar_node:mine(),
	%% Assert the nodes have continued building on the original fork.
	[{H3, _, _} | _] = slave_wait_until_height(2),
	?assertNotEqual(B2#block.indep_hash, H3),
	{_Peer, B3, _Time, _Size} = ar_http_iface_client:get_block_shadow(
			[{127, 0, 0, 1, 1983}], 1),
	?assertEqual(H2, B3#block.indep_hash).

block_to_json(B) ->
	{BlockProps} = ar_serialize:block_to_json_struct(B),
	PostProps = [{<<"new_block">>, {BlockProps}}],
	ar_serialize:jsonify({PostProps}).

fake_block_with_strong_cumulative_difficulty(B, CDiff) ->
	#block{
	    previous_block = H,
	    height = Height,
	    timestamp = Timestamp,
	    nonce = Nonce,
	    poa = #poa{ chunk = Chunk }
	} = B,
	B2 = B#block{ cumulative_diff = CDiff },
	BDS = ar_block:generate_block_data_segment(B2),
	{H0, _Entropy} = ar_mine:spora_h0_with_entropy(BDS, Nonce, Height + 1),
	B3 = B2#block{ hash = element(1, ar_mine:spora_solution_hash(H, Timestamp, H0, Chunk,
			Height + 1)) },
	B3#block{ indep_hash = ar_block:indep_hash(B3) }.
