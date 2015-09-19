%% -*- erlang-indent-level: 4; indent-tabs-mode: nil -*-
%%
%% Copyright (C) 2014, Jaguar Land Rover
%%
%% This program is licensed under the terms and conditions of the
%% Mozilla Public License, version 2.0.  The full text of the
%% Mozilla Public License is at https://www.mozilla.org/MPL/2.0/
%%

%%%-------------------------------------------------------------------
%%% @author magnus <magnus@t520.home>
%%% @copyright (C) 2014, magnus
%%% @doc
%%%
%%% @end
%%% Created : 12 Sep 2014 by magnus <magnus@t520.home>
%%%-------------------------------------------------------------------
-module(dlink_tls_conn).

-behaviour(gen_server).
-include_lib("lager/include/log.hrl").


%% API

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([setup/6]).
-export([upgrade/2]).
-export([send/2]).
-export([send/3]).
-export([is_connection_up/1]).
-export([is_connection_up/2]).
-export([terminate_connection/1]).
-export([terminate_connection/2]).


-define(SERVER, ?MODULE).

-record(st, {
	  ip = {0,0,0,0},
	  port = 0,
	  sock = undefined,
	  mode = tcp :: tcp | tls,
	  mod = undefined,
	  func = undefined,
	  args = undefined,
	  pst = undefined %%  Payload state
	 }).

%%%===================================================================
%%% API
%%%===================================================================
%% MFA is to deliver data received on the socket.

setup(IP, Port, Sock, Mod, Fun, Arg) ->
    case gen_server:start_link(?MODULE, {IP, Port, Sock, Mod, Fun, Arg},[]) of
	{ ok, GenSrvPid } = Res ->
	    gen_tcp:controlling_process(Sock, GenSrvPid),
	    gen_server:cast(GenSrvPid, {activate_socket, Sock}),
	    Res;

	Err ->
	    Err
    end.

upgrade(Pid, Role) ->
    gen_server:call(Pid, {upgrade, Role}).

send(Pid, Data) when is_pid(Pid) ->
    gen_server:cast(Pid, {send, Data}).

send(IP, Port, Data) ->
    case dlink_tls_connmgr:find_connection_by_address(IP, Port) of
	{ok, Pid} ->
	    gen_server:cast(Pid, {send, Data});

	_Err ->
	    ?info("connection:send(): Connection ~p:~p not found for data: ~p",
		  [ IP, Port, Data]),
	    not_found

    end.

terminate_connection(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, terminate_connection).

terminate_connection(IP, Port) ->
    case dlink_tls_connmgr:find_connection_by_address(IP, Port) of
	{ok, Pid} ->
	    gen_server:call(Pid, terminate_connection);

	_Err -> not_found
    end.


is_connection_up(Pid) when is_pid(Pid) ->
    is_process_alive(Pid).

is_connection_up(IP, Port) ->
    case dlink_tls_connmgr:find_connection_by_address(IP, Port) of
	{ok, Pid} ->
	    is_connection_up(Pid);

	_Err ->
	    false
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
%% MFA used to handle socket closed, socket error and received data
%% When data is received, a separate process is spawned to handle
%% the MFA invocation.
init({IP, Port, Sock, Mod, Fun, Arg}) ->
    case IP of
	undefined -> ok;
	_ -> dlink_tls_connmgr:add_connection(IP, Port, self())
    end,
    ?debug("connection:init(): self():   ~p", [self()]),
    ?debug("connection:init(): IP:       ~p", [IP]),
    ?debug("connection:init(): Port:     ~p", [Port]),
    ?debug("connection:init(): Sock:     ~p", [Sock]),
    ?debug("connection:init(): Module:   ~p", [Mod]),
    ?debug("connection:init(): Function: ~p", [Fun]),
    ?debug("connection:init(): Arg:      ~p", [Arg]),
    %% Grab socket control
    {ok, #st{
	    ip = IP,
	    port = Port,
	    sock = Sock,
	    mod = Mod,
	    func = Fun,
	    args = Arg,
	    pst = undefined
	   }}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------


handle_call(terminate_connection, _From,  St) ->
    ?debug("~p:handle_call(terminate_connection): Terminating: ~p",
	   [ ?MODULE, {St#st.ip, St#st.port}]),

    {stop, Reason, NSt} = handle_info({tcp_closed, St#st.sock}, St),
    {stop, Reason, ok, NSt};
handle_call({upgrade, Role} = Req, _From, #st{sock = S} = St) ->
    ?debug("~p:handle_call(~p)~n", [?MODULE, Req]),

    {ok, [{active, Last}]} = inet:getopts(S, [active]),
    inet:setopts(S, [{active, false}]),
    case do_upgrade(S, Role) of
	{ok, NewS} ->
	    ?debug("upgrade to TLS succcessful~n", []),
	    ssl:setopts(NewS, [{active, Last}]),
	    {reply, ok, St#st{sock = NewS, mode = tls}};
	Error ->
	    ?error("Cannot upgrade to TLS: ~p~n", [Error]),
	    {stop, Error, Error, St}
    end;
handle_call(_Request, _From, State) ->
    ?warning("~p:handle_call(): Unknown call: ~p", [ ?MODULE, _Request]),
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({send, Data},  St) ->
    ?debug("~p:handle_call(send): Sending: ~p",
	   [ ?MODULE, Data]),
    case St#st.mode of
	tcp -> gen_tcp:send(St#st.sock, Data);
	tls -> ssl:send(St#st.sock, Data)
    end,
    {noreply, St};

handle_cast({activate_socket, Sock}, State) ->
    Res = inet:setopts(Sock, [{active, once}]),
    ?debug("connection:activate_socket(): ~p", [Res]),
    {noreply, State};


handle_cast(_Msg, State) ->
    ?warning("~p:handle_cast(): Unknown call: ~p", [ ?MODULE, _Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

%% Fill in peername if empty.
handle_info({tcp, Sock, Data},
	    #st { ip = undefined } = St) ->
    {ok, {IP, Port}} = inet:peername(Sock),
    NSt = St#st { ip = inet_parse:ntoa(IP), port = Port },
    ?warning("YESSSS"),
    handle_info({tcp, Sock, Data}, NSt);

handle_info({ssl, Sock, Data},
	    #st{ip = IP, port = Port,
		mod = Mod, func = Fun, args = Arg,
		pst = PST} = State) ->
    ?debug("handle_info(data): ~p", [Data]),
    case rvi_common:extract_json(Data, PST) of
	{[], NPST} ->
	    ?debug("data incomplete", []),
	    ssl:setopts(Sock, [{active, once}]),
	    {noreply, State#st{pst = NPST}};
	{JSONElements, NPST} ->
	    ?debug("data complete; Processed: ~p", [JSONElements]),
	    FromPid = self(),
	    spawn(fun() -> [Mod:Fun(FromPid, IP, Port, data, SingleElem, Arg)
			    || SingleElem <- JSONElements]
		  end),
	    ssl:setopts(Sock, [{active, once}]),
	    {noreply, State#st{pst = NPST}}
    end;
handle_info({tcp, Sock, Data},
	    #st { ip = IP,
		  port = Port,
		  mod = Mod,
		  func = Fun,
		  args = Arg,
		  pst = PST} = State) ->
    ?debug("~p:handle_info(data): Data: ~p", [ ?MODULE, Data]),
    ?debug("~p:handle_info(data): From: ~p:~p ", [ ?MODULE, IP, Port]),

    case rvi_common:extract_json(Data, PST) of
	{ [], NPST } ->
	    ?debug("~p:handle_info(data incomplete)", [ ?MODULE]),
	    inet:setopts(Sock, [{active, once}]),
	    {noreply, State#st { pst = NPST} };

	{ JSONElements, NPST } ->
	    ?debug("~p:handle_info(data complete): Processed: ~p", [ ?MODULE, JSONElements]),
	    FromPid = self(),
	    spawn(fun() -> [ Mod:Fun(FromPid, IP, Port,
				     data, SingleElem, Arg) || SingleElem <- JSONElements ]
		  end),
	    inet:setopts(Sock, [ { active, once } ]),
	    {noreply, State#st { pst = NPST} }
    end;



handle_info({tcp_closed, Sock},
	    #st { ip = IP,
		  port = Port,
		  mod = Mod,
		  func = Fun,
		  args = Arg } = State) ->
    ?debug("~p:handle_info(tcp_closed): Address: ~p:~p ", [ ?MODULE, IP, Port]),
    Mod:Fun(self(), IP, Port,closed, Arg),
    gen_tcp:close(Sock),
    dlink_tls_connmgr:delete_connection_by_pid(self()),
    {stop, normal, State};

handle_info({tcp_error, _Sock},
	    #st { ip = IP,
		  port = Port,
		  mod = Mod,
		  func = Fun,
		  args = Arg} = State) ->

    ?debug("~p:handle_info(tcp_error): Address: ~p:~p ", [ ?MODULE, IP, Port]),
    Mod:Fun(self(), IP, Port, error, Arg),
    dlink_tls_connmgr:delete_connection_by_pid(self()),
    {stop, normal, State};


handle_info(_Info, State) ->
    ?warning("~p:handle_cast(): Unknown info: ~p", [ ?MODULE, _Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ?debug("~p:terminate(): Reason: ~p ", [ ?MODULE, _Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% FIXME: For now, use the example certs delivered with the OTP SSL appl.
tls_opts(Role) ->
    Dir = tls_dir(Role),
    [{certfile, filename:join(Dir, "cert.pem")},
     {keyfile, filename:join(Dir, "key.pem")}].

tls_dir(Role) when Role==client;
		   Role==server ->
    filename:join([code:lib_dir(ssl), "examples", "certs", "etc",
		   atom_to_list(Role)]).

do_upgrade(Sock, client) ->
    ssl:connect(Sock, tls_opts(client));
do_upgrade(Sock, server) ->
    ssl:ssl_accept(Sock, tls_opts(server)).
