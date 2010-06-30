%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2010 Marc Worrell
%% @date 2010-05-11
%% @doc Handle the OAuth redirect of the Google logon handshake.
%% @see http://developers.google.com/docs/authentication/
%% @todo Update a user record when we receive a new e-mail address.

%% Copyright 2010 Marc Worrell
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

-module(resource_google_redirect).
-author("Marc Worrell <marc@worrell.nl>").

-export([init/1, service_available/2, charsets_provided/2, content_types_provided/2]).
-export([resource_exists/2, previously_existed/2, moved_temporarily/2]).

-include_lib("webmachine_resource.hrl").
-include_lib("include/zotonic.hrl").

init(DispatchArgs) -> {ok, DispatchArgs}.

service_available(ReqData, DispatchArgs) when is_list(DispatchArgs) ->
    Context  = z_context:new(ReqData, ?MODULE),
    Context1 = z_context:set(DispatchArgs, Context),
    Context2 = z_context:ensure_all(Context1),
    ?WM_REPLY(true, Context2).

charsets_provided(ReqData, Context) ->
    {[{"utf-8", fun(X) -> X end}], ReqData, Context}.

content_types_provided(ReqData, Context) ->
    {[{"text/html", provide_content}], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {false, ReqData, Context}.

previously_existed(ReqData, Context) ->
    {true, ReqData, Context}.

moved_temporarily(ReqData, Context) ->
    Context1 = ?WM_REQ(ReqData, Context),
    Code = z_context:get_q("code", Context1),
    case fetch_access_token(Code, Context1) of
        {ok, AccessToken, Expires} ->
            z_context:set_session(google_logon, true, Context1),
            z_context:set_session(google_access_token, AccessToken, Context1),
            z_context:set_session(google_access_token_expires, Expires, Context1),

            case fetch_user_data(AccessToken) of
                {ok, UserProps} ->
                    logon_google_user(UserProps, z_context:get_q("page", Context1), Context1);
                {error, Reason} ->
                    redirect_error(Reason, Context1)
            end;
        {error, Reason} ->
            redirect_error(Reason, Context1)
    end.


redirect_error(Reason, Context) ->
    ?DEBUG({?MODULE, Reason}),
    z_context:set_session(google_logon, false, Context),
    z_context:set_session(google_access_token, undefined, Context),
    z_context:set_session(google_access_token_expires, undefined, Context),
    Location = z_context:abs_url(z_dispatcher:url_for(logon, Context), Context),
    ?WM_REPLY({true, Location}, Context).


                                                % Exchange the code for an access token
fetch_access_token(Code, Context) ->
    {AppId, AppSecret} = mod_google:get_appid_secret(Context),
    Page = z_context:get_q("p", Context, "/"),
    RedirectUrl = lists:flatten(
                    z_context:abs_url(
                      lists:flatten(z_dispatcher:url_for(google_redirect, [{p,Page}], Context)),
                      Context)),

    GoogleUrl = "https://graph.google.com/oauth/access_token?client_id="
        ++ z_utils:url_encode(AppId)
        ++ "&redirect_uri=" ++ z_utils:url_encode(RedirectUrl)
        ++ "&client_secret=" ++ z_utils:url_encode(AppSecret)
        ++ "&code=" ++ z_utils:url_encode(Code),
    case http:request(GoogleUrl) of
        {ok, {{_, 200, _}, _Headers, Payload}} ->
            Qs = mochiweb_util:parse_qs(Payload),
            {ok, proplists:get_value("access_token", Qs), z_convert:to_integer(proplists:get_value("expires", Qs))};
        Other ->
            {error, {http_error, GoogleUrl, Other}}
    end.

                                                % Given the access token, fetch data about the user
fetch_user_data(AccessToken) ->
    GoogleUrl = "https://graph.google.com/me?access_token=" ++ z_utils:url_encode(AccessToken),
    case http:request(GoogleUrl) of
        {ok, {{_, 200, _}, _Headers, Payload}} ->
            {struct, Props} = mochijson:decode(Payload),
            {ok, [ {list_to_atom(K), V} || {K,V} <- Props ]};
        Other ->
            {error, {http_error, GoogleUrl, Other}}
    end.


%% @doc Check if the user exists, if not then hand over control to the auth_signup resource.
logon_google_user(GoogleProps, LocationAfterSignup, Context) ->
    Props = [
             {title, unicode:characters_to_binary(proplists:get_value(name, GoogleProps))},
             {name_first, unicode:characters_to_binary(proplists:get_value(first_name, GoogleProps))},
             {name_surname, unicode:characters_to_binary(proplists:get_value(last_name, GoogleProps))},
             {website, unicode:characters_to_binary(proplists:get_value(link, GoogleProps))},
             {email, unicode:characters_to_binary(proplists:get_value(email, GoogleProps))}
            ],
    UID = unicode:characters_to_binary(proplists:get_value(id, GoogleProps)),
    case m_identity:lookup_by_type_and_key("google", UID, Context) of
        undefined ->
                                                % Register the Google identities as verified
            SignupProps =
                [{identity, {username_pw, {generate_username(Props, Context), z_ids:id(6)}, true, true}},
                 {identity, {google, UID, true, true}},
                 {identity, {email, proplists:get_value(email, GoogleProps), true, true}},
                 {ready_page, LocationAfterSignup}
                ],
            case z_notifier:first({signup_url, Props, SignupProps}, Context) of
                {ok, Location} ->
                    use_see_other(Location, Context);
                                                %?WM_REPLY({true, Location}, Context);
                undefined ->
                    throw({error, {?MODULE, "No result from signup_url notification handler"}})
            end;
        Row ->
            UserId = proplists:get_value(rsc_id, Row),
			{Location,Context1} = case z_auth:logon(UserId, Context) of
                                      {ok, ContextUser} ->
                                          update_user(UserId, Props, ContextUser),
                                          case has_location(LocationAfterSignup) of
                                              false -> {m_rsc:p(UserId, page_url, ContextUser), ContextUser};
                                              true -> {LocationAfterSignup, ContextUser}
                                          end;
                                      {error, _Reason} ->
                                          {z_dispatcher:url_for(logon, [{error_uid,UserId}], Context), Context}
                                  end,
            LocationAbs = lists:flatten(z_context:abs_url(Location, Context1)),
            use_see_other(LocationAbs, Context1)
                                                %?WM_REPLY({true, LocationAbs}, Context1)
    end.

has_location(undefined) -> false;
has_location([]) -> false;
has_location(<<>>) -> false;
has_location("/") -> false;
has_location(_) -> true.

%% HACK ALERT!
%% We use a 303 See Other here as there is a serious bug in Safari 4.0.5
%% When we use a 307 then the orginal login post at Google will be posted
%% to our redirect location. Including the Google username and password....
use_see_other(Location, Context) ->
    ContextLoc = z_context:set_resp_header("Location", Location, Context),
    ?WM_REPLY({halt, 303}, ContextLoc).


generate_username(Props, Context) ->
    case proplists:get_value(title, Props) of
        [] ->
            First = proplists:get_value(name_first, Props),
            Last = proplists:get_value(name_surname, Props),
            generate_username1(z_string:nospaces(z_string:to_lower(First) ++ "." ++ z_string:to_lower(Last)), Context);
        Title ->
            generate_username1(z_string:nospaces(z_string:to_lower(Title)), Context)
    end.

generate_username1(Name, Context) ->
    case m_identity:lookup_by_username(Name, Context) of
        undefined -> Name;
        _ -> generate_username2(Name, Context)
    end.

generate_username2(Name, Context) ->
    N = integer_to_list(z_ids:number() rem 1000),
    case m_identity:lookup_by_username(Name++N, Context) of
        undefined -> Name;
        _ -> generate_username2(Name, Context)
    end.


update_user(_UserId, _Props, _Context) ->
    ok.

