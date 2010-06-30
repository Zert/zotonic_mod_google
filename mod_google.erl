%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2010 Marc Worrell
%% @date 2010-05-09
%% @doc Google integration. Adds Google login.

%% Copyright 2010 Maxim Treskin
%%
%% Based on Facebook login by Marc Worrell.
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

-module(mod_google).
-author("Maxim Treskin <zerthurd@gmail.com>").
-behaviour(gen_server).

-mod_title("Google").
-mod_description("Adds Google login.").
-mod_prio(400).

%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/1]).
-export([observe/3]).
-export([get_appid_secret/1]).

-include("zotonic.hrl").

-record(state, {context}).

-define(GOOGLE_OAUTH_KEY, "www.example.com").
-define(GOOGLE_OAUTH_SECRET, "invalid-secret").

%% @doc Reset the received google access token (as set in the session)
observe(auth_logoff, AccContext, _Context) ->
    z_context:set_session(google_logon, false, AccContext),
    z_context:set_session(google_access_token, undefined, AccContext).


%% @doc Return the google appid and secret
get_appid_secret(Context) ->
    { z_convert:to_list(m_config:get_value(mod_google, oauth_key, ?GOOGLE_OAUTH_KEY, Context)),
      z_convert:to_list(m_config:get_value(mod_google, oauth_secret, ?GOOGLE_OAUTH_SECRET, Context)) }.


start_link(Args) when is_list(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init(Args) ->
    process_flag(trap_exit, true),
    {context, Context} = proplists:lookup(context, Args),
    ContextSudo = z_acl:sudo(Context),
    z_notifier:observe(auth_logoff, {?MODULE, observe}, Context),
    {ok, #state{context=ContextSudo}}.

handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.

handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    z_notifier:detach(auth_logoff, {?MODULE, observe}, State#state.context),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
