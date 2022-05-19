-define(THROTTLE_PERIOD, 30000).

-define(BAN_CLEANUP_INTERVAL, 60000).

-define(RPM_BY_PATH(Path), fun() ->
	{ok, Config} = application:get_env(arweave, config),
	?RPM_BY_PATH(Path, Config#config.requests_per_minute_limit)()
end).

-ifdef(DEBUG).
-define(RPM_BY_PATH(Path, DefaultPathLimit), fun() ->
	case Path of
		[<<"chunk">> | _]					-> {chunk,					12000}; % ~50 MB/s.
		[<<"chunk2">> | _]					-> {chunk,					12000}; % ~50 MB/s.
		[<<"data_sync_record">> | _]		-> {data_sync_record,		400};
		[<<"recent_hash_list_diff">> | _]	-> {recent_hash_list_diff,	120};
		_									-> {default,				DefaultPathLimit}
	end
end).
-else.
-define(RPM_BY_PATH(Path, DefaultPathLimit), fun() ->
	case Path of
		[<<"chunk">> | _]					-> {chunk,					12000}; % ~50 MB/s.
		[<<"chunk2">> | _]					-> {chunk,					12000}; % ~50 MB/s.
		[<<"data_sync_record">> | _]		-> {data_sync_record,		40};
		[<<"recent_hash_list_diff">> | _]	-> {recent_hash_list_diff,	60};
		_									-> {default,				DefaultPathLimit}
	end
end).
-endif.
