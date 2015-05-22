%%
%% Copyright (C) 2014, Jaguar Land Rover
%%
%% This program is licensed under the terms and conditions of the
%% Mozilla Public License, version 2.0.  The full text of the 
%% Mozilla Public License is at https://www.mozilla.org/MPL/2.0/
%%


-module(dlink_bt_rpc).
-behavior(gen_server).

-export([handle_rpc/2]).
-export([handle_notification/2]).
-export([handle_socket/6]).
-export([handle_socket/5]).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([start_json_server/0]).
-export([start_connection_manager/0]).

%% Invoked by service discovery
%% FIXME: Should be rvi_service_discovery behavior
-export([service_available/3,
	 service_unavailable/3]).

-export([setup_data_link/3,
	 disconnect_data_link/2,
	 send_data/5]).


-include_lib("lager/include/log.hrl").
-include_lib("rvi_common/include/rvi_common.hrl").

-define(DEFAULT_BT_CHANNEL, 1).
-define(DEFAULT_RECONNECT_INTERVAL, 1000).
-define(DEFAULT_PING_INTERVAL, 300000).  %% Five minutes
-define(SERVER, ?MODULE). 

-define(CONNECTION_TABLE, rvi_dlink_bt_connections).
-define(SERVICE_TABLE, rvi_dlink_bt_services).

%% Multiple registrations of the same service, each with a different connection,
%% is possible.
-record(service_entry, {
	  service = [],           %% Name of service
	  connections = undefined  %% PID of connection that can reach this service
	 }).

-record(connection_entry, {
	  connection = undefined, %% PID of connection that has a set of services.
	  services = []     %% List of service names available through this connection
	 }).

-record(st, { 
	  cs = #component_spec{}
	 }).


start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ?info("dlink_bt:init(): Called"),
    %% Dig out the bert rpc server setup

    ets:new(?SERVICE_TABLE, [ set, public, named_table, 
			      { keypos, #service_entry.service }]),

    ets:new(?CONNECTION_TABLE, [ set, public, named_table, 
				 { keypos, #connection_entry.connection }]),

    CS = rvi_common:get_component_specification(),
    service_discovery_rpc:subscribe(CS, ?MODULE),

    {ok, #st { 
	    cs = CS
	   }
    }.

start_json_server() ->
    rvi_common:start_json_rpc_server(data_link, ?MODULE, dlink_bt_sup).


start_connection_manager() ->
    CompSpec = rvi_common:get_component_specification(),
    {ok, BertOpts } = rvi_common:get_module_config(data_link, 
						   ?MODULE, 
						   server_opts, 
						   [], 
						   CompSpec),
    %% Retrieve the channel we should use
    Channel = proplists:get_value(channel, BertOpts, ?DEFAULT_BT_CHANNEL),
    
    ?info("dlink_bt:init_rvi_component(~p): Starting listener.", [self()]),

    %% Fire up listener
 
    bt:start(),
    bt:debug(debug),
    bt_listener:start_link(), 
    bt_connection_manager:start_link(), 
    ?info("dlink_bt:start_connection_manager(): Adding listener on bluetooth channel ~p", [Channel ]),
    
    %% Add listener channel.
    case bt_listener:add_listener(Channel) of
	ok ->
	    ok;

	Err -> 	
	    ?error("dlink_bt:init_rvi_component(): Failed to launch listener: ~p", [ Err ]),
	    ok
    end,

    ok.

service_available(CompSpec, SvcName, DataLinkModule) ->
    rvi_common:notification(data_link, ?MODULE, 
			    service_available, 
			    [{ service, SvcName },
			     { data_link_module, DataLinkModule }],
			    CompSpec).

service_unavailable(CompSpec, SvcName, DataLinkModule) ->
    rvi_common:notification(data_link, ?MODULE, 
			    service_unavailable, 
			    [{ service, SvcName },
			     { data_link_module, DataLinkModule }],
			    CompSpec).


setup_data_link(CompSpec, Service, Opts) ->
    rvi_common:request(data_link, ?MODULE, setup_data_link,
		       [ { service, Service },
			 { opts, Opts }],
		       [status, timeout], CompSpec).

disconnect_data_link(CompSpec, NetworkAddress) ->
    rvi_common:request(data_link, ?MODULE, disconnect_data_link,
		       [ {network_address, NetworkAddress} ],
		       [status], CompSpec).


send_data(CompSpec, ProtoMod, Service, DataLinkOpts, Data) ->
    rvi_common:request(data_link, ?MODULE, send_data,
		       [ { proto_mod, ProtoMod }, 
			 { service, Service }, 
			 { data, Data },
			 { opts, DataLinkOpts }
		       ], 
		       [status], CompSpec).


%% End of behavior

%%
%% Connect to a remote RVI node.
%%
connect_remote(BTAddr, Channel, CompSpec) ->
    case bt_connection_manager:find_connection_by_address(BTAddr, Channel) of
	{ ok, _Pid } ->
	    already_connected;

	not_found ->
	    %% Setup a new outbound connection
	    ?info("dlink_bt:connect_remote(): Connecting ~p:~p",
		  [BTAddr, Channel]),

	    %%FIXME
	    case rfcomm:open(BTAddr, Channel) of
		{ ok, Ref } -> 
		    ?info("dlink_bt:connect_remote(): Connected ~p:~p", 
			   [BTAddr, Channel]),

		    %% Setup a genserver around the new connection.
		    {ok, Pid } = connection:setup(BTAddr, Channel, Ref, 
						  ?MODULE, handle_socket, CompSpec ),

		    %% Send authorize
		    { LocalBTAddr, LocalChannel} = rvi_common:node_address_tuple(),
		    connection:send(Pid, 
				    { authorize, 
				      1, LocalBTAddr, LocalChannel, rvi_binary, 
				      { certificate, {}}, { signature, {}} }),
		    ok;
		
		{error, Err } -> 
		    ?info("dlink_bt:connect_remote(): Failed ~p:~p: ~p",
			   [BTAddr, Channel, Err]),
		    not_available
	    end
    end.
		    

connect_and_retry_remote( BTAddr, Channel, CompSpec) ->
    ?info("dlink_bt:connect_and_retry_remote(): ~p:~p", 
	  [ BTAddr, Channel]),

    case connect_remote(BTAddr, list_to_integer(Channel), CompSpec) of
	ok  -> ok;

	Err -> %% Failed to connect. Sleep and try again
	    ?notice("dlink_bt:connect_and_retry_remote(~p:~p): Failed: ~p", 
			   [BTAddr, Channel, Err]),

	    ?notice("dlink_bt:connect_and_retry_remote(~p:~p): Will try again in ~p sec", 
			   [BTAddr, Channel, ?DEFAULT_RECONNECT_INTERVAL]),

	    setup_reconnect_timer(?DEFAULT_RECONNECT_INTERVAL, BTAddr, Channel, CompSpec),

	    not_available
    end.


announce_local_service_(_CompSpec, [], _Service, _Availability) ->
    ok;

announce_local_service_(CompSpec, 
			[ConnPid | T],
			Service, Availability) ->
    
    Res = connection:send(ConnPid, 
			  {service_announce, 3, Availability, 
			   [Service], { signature, {}}}),

    ?debug("dlink_bt:announce_local_service(~p: ~p) -> ~p  Res: ~p", 
	   [ Availability, Service, ConnPid, Res]),

    %% Move on to next connection.
    announce_local_service_(CompSpec, 
			    T,
			    Service, Availability).

announce_local_service_(CompSpec, Service, Availability) ->
    announce_local_service_(CompSpec, 
			    get_connections(),
			    Service, Availability).


handle_socket(_FromPid, PeerBTAddr, PeerChannel, data, ping, [_CompSpec]) ->
    ?info("dlink_bt:ping(): Pinged from: ~p:~p", [ PeerBTAddr, PeerChannel]),
    ok;

handle_socket(FromPid, PeerBTAddr, PeerChannel, data, 
	      { authorize, 
		TransactionID, 
		RemoteAddress, 
		RemoteChannel, 
		Protocol, 
		Certificate,
		Signature}, [CompSpec]) ->

    ?info("dlink_bt:authorize(): Peer Address:   ~p:~p", [PeerBTAddr, PeerChannel ]),
    ?info("dlink_bt:authorize(): Remote Address: ~p~p", [ RemoteAddress, RemoteChannel ]),
    ?info("dlink_bt:authorize(): Protocol:       ~p", [ Protocol ]),
    ?debug("dlink_bt:authorize(): TransactionID:  ~p", [ TransactionID ]),
    ?debug("dlink_bt:authorize(): Certificate:    ~p", [ Certificate ]),
    ?debug("dlink_bt:authorize(): Signature:      ~p", [ Signature ]),


    { LocalAddress, LocalChannel } = rvi_common:node_address_tuple(),

    %% If FromPid (the genserver managing the socket) is not yet registered
    %% with the conneciton manager, this is an incoming connection
    %% from the client. We should respond with our own authorize followed by
    %% a service announce
    
    %% FIXME: Validate certificate and signature before continuing.
    case connection_manager:find_connection_by_pid(FromPid) of
	not_found ->
	    ?info("dlink_bt:authorize(): New connection!"),
	    connection_manager:add_connection(RemoteAddress, RemoteChannel, FromPid),
	    ?debug("dlink_bt:authorize(): Sending authorize."),
	    Res = connection:send(FromPid, 
			    { authorize, 
			      1, LocalAddress, LocalChannel, rvi_binary, 
			      {certificate, {}}, { signature, {}}}),
	    ?debug("dlink_bt:authorize(): Sending authorize: ~p", [ Res]),
	    ok;
	_ -> ok
    end,

    %% Send our own servide announcement to the remote server
    %% that just authorized to us.
    [ ok, LocalServices ] = service_discovery_rpc:get_services_by_module(CompSpec, local),
	 

    %% Send an authorize back to the remote node
    ?info("dlink_bt:authorize(): Announcing local services: ~p to remote ~p:~p",
	  [LocalServices, RemoteAddress, RemoteChannel]),

    connection:send(FromPid, 
		    { service_announce, 2, available,
		      LocalServices, { signature, {}}}),

    %% Setup ping interval
    gen_server:call(?SERVER, { setup_initial_ping, RemoteAddress, RemoteChannel, FromPid }),
    ok;

handle_socket(FromPid, RemoteBTAddr, RemoteChannel, data, 
	      { service_announce, 
		TransactionID,
		available,
		Services,
		Signature }, [CompSpec]) ->
    ?debug("dlink_bt:service_announce(available): Address:       ~p:~p", [ RemoteBTAddr, RemoteChannel ]),
    ?debug("dlink_bt:service_announce(available): Remote Channel:   ~p", [ RemoteChannel ]),
    ?debug("dlink_bt:service_announce(available): TransactionID: ~p", [ TransactionID ]),
    ?debug("dlink_bt:service_announce(available): Signature:     ~p", [ Signature ]),
    ?debug("dlink_bt:service_announce(available): Service:       ~p", [ Services ]),

    
    add_services(Services, FromPid),
    
    service_discovery_rpc:register_services(CompSpec, Services, ?MODULE),
    ok;


handle_socket(FromPid, RemoteBTAddr, RemoteChannel, data, 
	      { service_announce, 
		TransactionID, 
		unavailable,
		Services, 
		Signature}, [CompSpec]) ->
    ?debug("dlink_bt:service_announce(unavailable): Address:       ~p:~p", [ RemoteBTAddr, RemoteChannel ]),
    ?debug("dlink_bt:service_announce(unavailable): Remote Channel:   ~p", [ RemoteChannel ]),
    ?debug("dlink_bt:service_announce(unavailable): TransactionID: ~p", [ TransactionID ]),
    ?debug("dlink_bt:service_announce(unavailable): Signature:     ~p", [ Signature ]),
    ?debug("dlink_bt:service_announce(unavailable): Service:       ~p", [ Services ]),

    %% Register the received services with all relevant components

    
    %% Delete from our own tables.
    
    delete_services(FromPid, Services),
    service_discovery_rpc:unregister_services(CompSpec, Services, ?MODULE),
    ok;


handle_socket(_FromPid, SetupBTAddr, SetupChannel, data, 
	      { receive_data, ProtocolMod, Data}, [CompSpec]) ->
%%    ?info("dlink_bt:receive_data(): ~p", [ Data ]),
    ?debug("dlink_bt:receive_data(): SetupAddress:  {~p, ~p}", [ SetupBTAddr, SetupChannel ]),
    ProtocolMod:receive_message(CompSpec, Data),
    ok;


handle_socket(_FromPid, SetupBTAddr, SetupChannel, data, Data, [_CompSpec]) ->
    ?warning("dlink_bt:unknown_data(): SetupAddress:  {~p, ~p}", [ SetupBTAddr, SetupChannel ]),
    ?warning("dlink_bt:unknown_data(): Unknown data:  ~p",  [ Data]),
    ok.


%% We lost the socket connection.
%% Unregister all services that were routed to the remote end that just died.
handle_socket(FromPid, SetupBTAddr, SetupChannel, closed, [CompSpec]) ->
    ?info("dlink_bt:closed(): SetupAddress:  {~p, ~p}", [ SetupBTAddr, SetupChannel ]),

    NetworkAddress = SetupBTAddr  ++ "-" ++ integer_to_list(SetupChannel),

    %% Get all service records associated with the given connection
    LostSvcNameList = get_services_by_connection(FromPid),

    delete_connection(FromPid),

    %% Check if this was our last connection supchanneling each given service.
    lists:map(
      fun(SvcName) ->
	      case get_connections_by_service(SvcName) of
		  [] ->
		      service_discovery_rpc:
			  unregister_services(CompSpec, 
					      [SvcName], 
					      ?MODULE);
		  _ -> ok
	      end
      end, LostSvcNameList),

    {ok, PersistentConnections } = rvi_common:get_module_config(data_link, 
								?MODULE, 
								persistent_connections, 
								[], 
								CompSpec),
    %% Check if this is a static node. If so, setup a timer for a reconnect
    case lists:member(NetworkAddress, PersistentConnections) of
	true ->
	    ?info("dlink_bt:closed(): Reconnect address:  ~p", [ NetworkAddress ]),
	    ?info("dlink_bt:closed(): Reconnect interval: ~p", [ ?DEFAULT_RECONNECT_INTERVAL ]),
	    [ BTAddr, Channel] = string:tokens(NetworkAddress, "-"),

	    setup_reconnect_timer(?DEFAULT_RECONNECT_INTERVAL, 
				  BTAddr, Channel, CompSpec);
	false -> ok
    end,
    ok;

handle_socket(_FromPid, SetupBTAddr, SetupChannel, error, _ExtraArgs) ->
    ?info("dlink_bt:socket_error(): SetupAddress:  {~p, ~p}", [ SetupBTAddr, SetupChannel ]),
    ok.


%% JSON-RPC entry point
%% CAlled by local exo http server
handle_notification("service_available", Args) ->
    {ok, SvcName} = rvi_common:get_json_element(["service"], Args),
    {ok, DataLinkModule} = rvi_common:get_json_element(["data_link_module"], Args),

    gen_server:cast(?SERVER, { rvi, service_available, 
				      [ SvcName,
					DataLinkModule ]}),

    ok;
handle_notification("service_unavailable", Args) ->
    {ok, SvcName} = rvi_common:get_json_element(["service"], Args),
    {ok, DataLinkModule} = rvi_common:get_json_element(["data_link_module"], Args),

    gen_server:cast(?SERVER, { rvi, service_unavailable, 
				      [ SvcName,
					DataLinkModule ]}),

    ok;

handle_notification(Other, _Args) ->
    ?info("dlink_bt:handle_notification(~p): unknown", [ Other ]),
    ok.

handle_rpc("setup_data_link", Args) ->
    { ok, Service } = rvi_common:get_json_element(["service"], Args),

    { ok, Opts } = rvi_common:get_json_element(["opts"], Args),

    [ Res, Timeout ] = gen_server:call(?SERVER, { rvi, setup_data_link, 
						  [ Service, Opts ] }),

    {ok, [ {status, rvi_common:json_rpc_status(Res)} , { timeout, Timeout }]};

handle_rpc("disconenct_data_link", Args) ->
    { ok, NetworkAddress} = rvi_common:get_json_element(["network_address"], Args),
    [Res] = gen_server:call(?SERVER, { rvi, disconnect_data_link, [NetworkAddress]}),
    {ok, [ {status, rvi_common:json_rpc_status(Res)} ]};

handle_rpc("send_data", Args) ->
    { ok, ProtoMod } = rvi_common:get_json_element(["proto_mod"], Args),
    { ok, Service } = rvi_common:get_json_element(["service"], Args),
    { ok,  Data } = rvi_common:get_json_element(["data"], Args),
    { ok,  DataLinkOpts } = rvi_common:get_json_element(["opts"], Args),
    [ Res ]  = gen_server:call(?SERVER, { rvi, send_data, [ProtoMod, Service, Data, DataLinkOpts]}),
    {ok, [ {status, rvi_common:json_rpc_status(Res)} ]};
    

handle_rpc(Other, _Args) ->
    ?info("dlink_bt:handle_rpc(~p): unknown", [ Other ]),
    { ok, [ { status, rvi_common:json_rpc_status(invalid_command)} ] }.


handle_cast( {rvi, service_available, [SvcName, local]}, St) ->
    ?debug("dlink_bt:service_available(): ~p (local)", [ SvcName ]),
    announce_local_service_(St#st.cs, SvcName, available),
    {noreply, St};


handle_cast( {rvi, service_available, [SvcName, Mod]}, St) ->
    ?debug("dlink_bt:service_available(): ~p (~p) ignored", [ SvcName, Mod ]),
    %% We don't care about remote services available through
    %% other data link modules
    {noreply, St};


handle_cast( {rvi, service_unavailable, [SvcName, local]}, St) ->
    announce_local_service_(St#st.cs, SvcName, unavailable),
    {noreply, St};

handle_cast( {rvi, service_unavailable, [_SvcName, _]}, St) ->
    %% We don't care about remote services available through 
    %% other data link modules
    {noreply, St};


handle_cast(Other, St) ->
    ?warning("dlink_bt:handle_cast(~p): unknown", [ Other ]),
    {noreply, St}.


handle_call({rvi, setup_data_link, [ Service, Opts ]}, _From, St) ->
    %% Do we already have a connection that supchannel service?
    case get_connections_by_service(Service) of
	[] -> %% Nope
	    case proplists:get_value(target, Opts, undefined) of
		undefined ->
		    ?info("dlink_bt:setup_data_link(~p) Failed: no target given in options.",
			  [Service]),
		    { reply, [ok, -1 ], St };

		Addr -> 
		    [ Address, Channel] =  string:tokens(Addr, "-"),

		    case connect_remote(Address, list_to_integer(Channel), St#st.cs) of
			ok  ->
			    { reply, [ok, 2000], St };  %% 2 second timeout

			already_connected ->  %% We are already connected
			    { reply, [already_connected, -1], St };  

			Err ->
			    { reply, [Err, 0], St }
		    end
	    end;

	_ ->  %% Yes - We do have a connection that knows of service
	    { reply, [already_connected, -1], St }
    end;


handle_call({rvi, disconnect_data_link, [NetworkAddress] }, _From, St) ->
    [ Address, Channel] = string:tokens(NetworkAddress, "-"),
    Res = connection:terminate_connection(Address,Channel),
    { reply, [ Res ], St };


handle_call({rvi, send_data, [ProtoMod, Service, Data, _DataLinkOpts]}, _From, St) ->

    %% Resolve connection pid from service
    case get_connections_by_service(Service) of
	[] ->
	    { reply, [ no_route ], St};

	%% FIXME: What to do if we have multiple connections to the same service?
	[ConnPid | _T] -> 
	    Res = connection:send(ConnPid, {receive_data, ProtoMod, Data}),
	    { reply, [ Res ], St}
    end;
	    



handle_call({setup_initial_ping, Address, Channel, Pid}, _From, St) ->
    %% Create a timer to handle periodic pings.
    {ok, ServerOpts } = rvi_common:get_module_config(data_link, 
						     ?MODULE,
						     server_opts, [], 
						     St#st.cs),
    Timeout = proplists:get_value(ping_interval, ServerOpts, ?DEFAULT_PING_INTERVAL),

    ?info("dlink_bt:setup_ping(): ~p:~p will be pinged every ~p msec", 
	  [ Address, Channel, Timeout] ),
										      
    erlang:send_after(Timeout, self(), { rvi_ping, Pid, Address, Channel, Timeout }),

    {reply, ok, St};

handle_call(Other, _From, St) ->
    ?warning("dlink_bt:handle_rpc(~p): unknown", [ Other ]),
    { reply, { ok, [ { status, rvi_common:json_rpc_status(invalid_command)} ]}, St}.



%% Ping time
handle_info({ rvi_ping, Pid, Address, Channel, Timeout},  St) ->

    %% Check that connection is up
    case connection:is_connection_up(Pid) of
	true ->
	    ?info("dlink_bt:ping(): Pinging: ~p:~p", [Address, Channel]),
	    connection:send(Pid, ping),
	    erlang:send_after(Timeout, self(), 
			      { rvi_ping, Pid, Address, Channel, Timeout });

	false ->
	    ok
    end,
    {noreply, St};

%% Setup static nodes
handle_info({ rvi_setup_persistent_connection, BTAddr, Channel, CompSpec }, St) ->
    connect_and_retry_remote(BTAddr, Channel, CompSpec),
    { noreply, St };

handle_info(Info, St) ->
    ?notice("dlink_bt(): Unkown message: ~p", [ Info]),
    {noreply, St}.

terminate(_Reason, _St) ->
    ok.
code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

setup_reconnect_timer(MSec, BTAddr, Channel, CompSpec) ->
    erlang:send_after(MSec, ?MODULE, 
		      { rvi_setup_persistent_connection, 
			BTAddr, Channel, CompSpec }),
    ok.


get_services_by_connection(ConnPid) ->
    case ets:lookup(?CONNECTION_TABLE, ConnPid) of
	[ #connection_entry { services = SvcNames } ] ->
	    SvcNames;
	[] -> []
    end.


get_connections_by_service(Service) ->
    case ets:lookup(?SERVICE_TABLE, Service) of
	[ #service_entry { connections = Connections } ] ->
	    Connections;
	[] -> []
    end.
		 

add_services(SvcNameList, ConnPid) ->
    %% Create or replace existing connection table entry
    %% with the sum of new and old services.
    ets:insert(?CONNECTION_TABLE, 
	       #connection_entry {
		  connection = ConnPid,
		  services = SvcNameList ++ get_services_by_connection(ConnPid)
	      }),

    %% Add the connection to the service entry for each servic.
    [ ets:insert(?SERVICE_TABLE, 
	       #service_entry {
		  service = SvcName,
		  connections = [ConnPid | get_connections_by_service(SvcName)]
		 }) || SvcName <- SvcNameList ],
    ok.


delete_services(ConnPid, SvcNameList) ->
    ets:insert(?CONNECTION_TABLE, 
	       #connection_entry {
		  connection = ConnPid,
		  services = get_services_by_connection(ConnPid) -- SvcNameList
		 }),
    
    %% Loop through all services and update the conn table
    %% Update them with a new version where ConnPid has been removed
    [ ets:insert(?SERVICE_TABLE, 
		 #service_entry {
		  service = SvcName,
		  connections = get_connections_by_service(SvcName) -- [ConnPid]
		 }) || SvcName <- SvcNameList ],
    ok.



delete_connection(Conn) ->
    %% Create or replace existing connection table entry
    %% with the sum of new and old services.
    SvcNameList = get_services_by_connection(Conn),

    %% Replace each existing connection entry that has 
    %% SvcName with a new one where the SvcName is removed.
    lists:map(fun(SvcName) ->
		      Existing = get_connections_by_service(SvcName),
		      ets:insert(?SERVICE_TABLE, #
				     service_entry {
				       service = SvcName,
				       connections = Existing -- [ Conn ]
				      })
	      end, SvcNameList),
    
    %% Delete the connection
    ets:delete(?CONNECTION_TABLE, Conn),
    ok.

		 

get_connections('$end_of_table', Acc) ->
    Acc;

get_connections(Key, Acc) ->
    get_connections(ets:next(?CONNECTION_TABLE, Key), [ Key | Acc ]).

	    
get_connections() ->
    get_connections(ets:first(?CONNECTION_TABLE), []).