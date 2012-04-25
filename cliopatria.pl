/*  $Id$

    Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2004-2010, University of Amsterdam
			      VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(cp_server,
	  [ cp_server/0,
	    cp_server/1,		% +Options
	    cp_welcome/0,
	    cp_after_load/1		% :Goal
	  ]).

/** <module> ClioPatria main module

This module loads the ClioPatria  server   as  a  library, providing the
public predicates defined in the header.   Before loading this file, the
user should set up a the search path =cliopatria=. For example:

==
:- dynamic
	user:file_search_path/2.
:- multifile
	user:file_search_path/2.

user:file_search_path(cliopatria, '/usr/local/cliopatria').

:- use_module(cliopatria(load)).
==

*/

:- dynamic
	user:file_search_path/2.
:- multifile
	user:file_search_path/2.

:- (   user:file_search_path(cliopatria, _)
   ->  true
   ;   prolog_load_context(directory, Dir),
       assert(user:file_search_path(cliopatria, Dir))
   ).

user:file_search_path(library, cliopatria(lib)).

:- load_files(library(version), [silent(true), if(not_loaded)]).
:- check_prolog_version(or(51004,51109)). % Demand >= 5.11.9
:- register_git_module('ClioPatria',
		       [ home_url('http://cliopatria.swi-prolog.org/')
		       ]).

:- load_files([ parms,
		skin(cliopatria),			% HTML Page layout
		library(option),
		library(bundle),
		library(debug),
		library(lists),
		library(settings),
		library(error),
		library(broadcast),
		library(thread_pool),

		library(semweb/rdf_db),
		library(semweb/rdf_persistency),
		library(semweb/rdf_litindex),

		library(http/http_session),
		library(http/http_dispatch),
		library(http/thread_httpd),

		user(user_db),
		user(openid),
		user(preferences),

		api(sesame),
		api(journal),			% export journal information
		api(sparql),
		api(export),

		applications(admin),
		applications(user),
		applications(browse)
	      ],
	      [ silent(true),
		if(not_loaded)
	      ]).

:- dynamic
	after_load_goal/1.

%%	cp_server is det.
%%	cp_server(:Options) is det.
%
%	Start the HTTP server.  This predicate preforms the following
%	steps:
%
%	    1. Load application settings from =|settings.db|=
%	    2. Load user-data from =|users.db|=
%	    3. Start the HTTP server
%	    4. Load the RDF persistent database from =|RDF-store|=
%	    5. Execute `after load' options registered using
%	       cp_after_load/1.
%
%	Defined options are:
%
%	    * port(Port)
%	    Attach to Port instead of the port specified in the
%	    configuration file settings.db.

:- meta_predicate
	cp_server(:).

cp_server :-
	process_argv(Options),
	catch(cp_server(Options), E, true),
	(   var(E)
	->  true
	;   print_message(error, E),
	    (	E = error(socket_error('Address already in use'), _)
	    ->	print_message(error, cliopatria(use_port_option))
	    ;	true
	    )
	).

cp_server(_Options) :-
	setting(http:port, DefPort),
	http_server_property(DefPort, goal(cp_server:http_dispatch)), !,
	print_message(informational,
		      cliopatria(server_already_running(DefPort))).
cp_server(Options) :-
	meta_options(is_meta, Options, QOptions),
	load_settings('settings.db'),
	attach_account_info,
	set_session_options,
	setting(http:port, DefPort),
	setting(http:workers, DefWorkers),
	setting(http:worker_options, Settings),
	merge_options(QOptions, Settings, HTTPOptions),
	option(port(Port), QOptions, DefPort),
	update_public_port(Port, DefPort),
	option(workers(Workers), QOptions, DefWorkers),
	http_server(http_dispatch,
		    [ port(Port),
		      workers(Workers)
		    | HTTPOptions
		    ]),
	option(after_load(AfterLoad), QOptions, true),
	print_message(informational, cliopatria(server_started(Port))),
	setup_call_cleanup(http_handler(root(.), busy_loading,
					[ priority(1000),
					  hide_children(true),
					  id(busy_loading),
					  prefix
					]),
			   rdf_attach_store(QOptions, AfterLoad),
			   http_delete_handler(id(busy_loading))).

is_meta(after_load).

%%	update_public_port(+Port, +DefPort)
%
%	Update http:public_port if port is   changed  using --port=Port.
%	Without this hack it is no longer  to login after using the port
%	option.

update_public_port(Port, Port) :- !.
update_public_port(Port, DefPort) :-
	setting(http:public_port, DefPort), !,
	set_setting_default(http:public_port, Port),
	assertion(setting(http:public_port, Port)).
update_public_port(_, _).


%%	rdf_attach_store(+Options, :AfterLoad) is det.
%
%	Attach     the     RDF     store       using     the     setting
%	cliopatria:persistent_store and call the `after-load' goals.
%
%	@see cp_after_load/1 for registering after-load goals.

rdf_attach_store(Options, AfterLoad) :-
	setting(cliopatria:persistent_store, Directory),
	Directory \== '', !,
	setup_indices,
        rdf_attach_db(Directory, Options),
	forall(after_load_goal(Goal),
	       call_warn(Goal)),
	call_warn(AfterLoad).

call_warn(Goal) :-
	(   catch(Goal, E, true)
	->  (   var(E)
	    ->	true
	    ;	print_message(warning, E)
	    )
	;   print_message(warning, goal_failed(Goal))
	).


%%	setup_indices is det.
%
%	Initialize maintenance of the full-text   indices. These indices
%	are created on first call and  maintained dynamically as the RDF
%	store changes. By initializing them  before   there  is  any RDF
%	loaded, they will be built while  the data is (re-)loaded, which
%	avoids long delays on the first  query.   Note  that most of the
%	work is done in a separate thread.

setup_indices :-
	setting(cliopatria:pre_index_tokens, true),
	rdf_find_literals(not_a_token, _),
	fail.
setup_indices :-
	setting(cliopatria:pre_index_stems, true),
	rdf_find_literals(stem(not_a_stem), _),
	fail.
setup_indices.


%%	cp_after_load(:Goal) is det.
%
%	Register Goal to be executed after  reloading the RDF persistent
%	DB. Note that  already  registered   goals  are  not duplicated.
%	Running a goal after loading the   database  is commonly used to
%	ensure presence of relevant schemas or build additional indices.
%	Note that it is possible to   start  a thread for time-consuming
%	tasks (see thread_create/3).

:- meta_predicate
	cp_after_load(0).

cp_after_load(Goal) :-
	(   after_load_goal(Goal)
	->  true
	;   assert(after_load_goal(Goal))
	).


%%	busy_loading(+Request)
%
%	This HTTP handler is  pushed  to   overrule  all  actions of the
%	server while the server is restoring   its  persistent state. It
%	replies with the 503  (unavailable)   response,  indicating  the
%	progress of restoring the repository.

:- dynamic
	loading_done/2.

busy_loading(_Request) :-
	rdf_statistics(triples(Triples)),
	(   loading_done(Nth, Total)
	->  Extra = [ '; ~D of ~D graphs.'-[Nth, Total] ]
	;   Extra = [ '.' ]
	),
	HTML = p([ 'This service is currently restoring its ',
		   'persistent database.', br([]),
		   'Loaded ~D triples'-[Triples]
		 | Extra
		 ]),
	throw(http_reply(unavailable(HTML))).

%%	attach_account_info
%
%	Set   the   registered   user-database     from    the   setting
%	cliopatria:user_data.

attach_account_info :-
	setting(cliopatria:user_data, File),
	set_user_database(File).

%%	set_session_options
%
%	Initialise session timeout from =|http:max_idle_time|=.

set_session_options :-
	setting(http:max_idle_time, Idle),
	http_set_session_options([timeout(Idle)]).


		 /*******************************
		 *	 UPDATE SETTINGS	*
		 *******************************/

update_workers(New) :-
	setting(http:port, Port),
	http_current_worker(Port, _),
	http_workers(Port, New).

:- listen(settings(changed(http:max_idle_time, _, New)),
	  http_set_session_options([timeout(New)])).
:- listen(settings(changed(http:workers, _, New)),
	  update_workers(New)).


		 /*******************************
		 *	       ARGV		*
		 *******************************/

%%	process_argv(-Options)
%
%	Processes the ClioPatria commandline options.
%
%	@tbd	Move most of this to the Prolog library

process_argv(Options) :-
	argv(Program, Argv),
	(   catch((   parse_options(Argv, Options, Rest),
		      maplist(process_argument, Rest)
		  ),
		  E,
		  (   print_message(error, E),
		      fail
		  ))
	->  true
	;   usage(Program)
	).

process_argument(URL) :-
	(   sub_atom('http://', 0, _, _, URL)
	;   sub_atom('https://', 0, _, _, URL)
	), !,
	rdf_load(URL).
process_argument(File) :-
	file_name_extension(_Base, Ext, File),
	process_argument(Ext, File).

process_argument(pl, File) :- !,
	ensure_loaded(user:File).
process_argument(gz, File) :-
	file_name_extension(Plain, gz, File),
	file_name_extension(_, RDF, Plain),
	rdf_extension(RDF),
	rdf_load(File).
process_argument(RDF, File) :-
	rdf_extension(RDF),
	rdf_load(File).

rdf_extension(rdf).
rdf_extension(owl).
rdf_extension(ttl).
rdf_extension(nt).

cmd_option(p, port,    positive_integer, 'Port to connect to').
cmd_option(w, workers, positive_integer, 'Number of workers to start').
cmd_option(-, prefix,  atom,	         'Rebase the server to prefix/').

usage(Program) :-
	format('Usage: ~w [options] arguments~n', [Program]),
	forall(cmd_option(Short, Long, Type, Comment),
	       describe_option(Short, Long, Type, Comment)),
	halt(1).

describe_option(-, Long, -, Comment) :- !,
	format(user_error, '    --~w~t~40|~w~n', [Long, Comment]).
describe_option(-, Long, _, Comment) :- !,
	format(user_error, '    --~w=~w~t~40|~w~n', [Long, Long, Comment]).
describe_option(Short, Long, -, Comment) :- !,
	format(user_error, '    -~w, --~w~t~40|~w~n',
	       [Short, Long, Comment]).
describe_option(Short, Long, _, Comment) :- !,
	format(user_error, '    -~w ~w, --~w=~w~t~40|~w~n',
	       [Short, Long, Long, Long, Comment]).


parse_options([], [], []).
parse_options([--|Rest], [], Rest) :- !.
parse_options([H|T], [Opt|OT], Rest) :-
	sub_atom(H, 0, _, _, --), !,
	(   sub_atom(H, B, _, A, =)
	->  B2 is B - 2,
	    sub_atom(H, 2, B2, _, Name),
	    sub_atom(H, _, A,  0, Value),
	    long_option(Name, Value, Opt)
	;   long_option(Name, Opt)
	),
	parse_options(T, OT, Rest).
parse_options([H|T], Opts, Rest) :-
	atom_chars(H, [-|Opts]), !,
	short_options(Opts, T, Opts, Rest).
parse_options(Rest, [], Rest).

short_options([], Av, Opts, Rest) :-
	parse_options(Av, Opts, Rest).
short_options([H|T], Av, Opts, Rest) :-
	cmd_option(H, Name, Type, _),
	(   Type == (-)
	->  Opt =.. [Name,true],
	    Opts = [Opt|OptT],
	    short_options(T, Av, OptT, Rest)
	;   Av = [Av0|AvT],
	    text_to_value(Type, Av0, Value),
	    Opt =.. [Name,Value],
	    short_options(T, AvT, OptT, Rest)
	).

long_option(Name, Text, Opt) :-
	cmd_option(_, Name, Type, _),
	text_to_value(Type, Text, Value),
	Opt =.. [Name,Value].
long_option(Name, Opt) :-
	cmd_option(_, Name, boolean, _),
	Opt =.. [Name,true].

text_to_value(boolean, Text, Value) :-
	downcase_atom(Text, Lwr),
	boolean(Lwr, Value).
text_to_value(atom, Text, Text).
text_to_value(oneof(L), Text, Text) :-
	memberchk(Text, L).
text_to_value(integer, Text, Int) :-
	atom_number(Text, Int), integer(Int).
text_to_value(nonneg, Text, Int) :-
	atom_number(Text, Int), integer(Int), Int >= 0.
text_to_value(positive_integer, Text, Int) :-
	atom_number(Text, Int), integer(Int), Int > 0.
text_to_value(negative_integer, Text, Int) :-
	atom_number(Text, Int), integer(Int), Int < 0.
text_to_value(float, Text, Float) :-
	atom_number(Text, Number), Float = float(Number).

boolean(true,  true).
boolean(yes,   true).
boolean(on,    true).
boolean(false, false).
boolean(no,    false).
boolean(off,   false).

argv(Program, Av) :-
	current_prolog_flag(argv, Argv),
	Argv = [Prog|Av0],
	file_base_name(Prog, Program),
	(   append(_, [--|Av], Av0)
	->  true
	;   current_prolog_flag(windows, true)
	->  Av = Av0
	;   Av = []
	).

		 /*******************************
		 *	      BANNER		*
		 *******************************/

%%	cp_welcome
%
%	Print welcome banner.

cp_welcome :-
	setting(http:port, Port),
	print_message(informational, cliopatria(welcome(Port))).


		 /*******************************
		 *	       POOLS		*
		 *******************************/

:- multifile
	http:create_pool/1.

:- setting(cliopatria:max_clients, integer, 50,
	   'Max number of concurrent requests in ClioPatria pool').
:- setting(cliopatria:stack_size, integer, 256,
	   'Stack limit in MB for ClioPatria pool').


%%	http:create_pool(+Pool) is semidet.
%
%	Create a thread-pool on-demand.

http:create_pool(sparql_query) :-
	debug(http(pool), 'Demand-creating pool ~q', [sparql_query]),
	setting(sparql:max_clients, Count),
	setting(sparql:stack_size, MB),
	Global is MB * 1024,
	Trail is MB * 1024,
	thread_pool_create(sparql_query,
			   Count,
			   [ global(Global),
			     trail(Trail)
			   ]).
http:create_pool(cliopatria) :-
	setting(cliopatria:max_clients, Count),
	setting(cliopatria:stack_size, MB),
	Global is MB * 1024,
	Trail is MB * 1024,
	thread_pool_create(cliopatria,
			   Count,
			   [ global(Global),
			     trail(Trail)
			   ]).


		 /*******************************
		 *	     MESSAGES		*
		 *******************************/

:- multifile
	prolog:message//1.

prolog:message(cliopatria(server_started(Port))) -->
	{ cp_host(Host),
	  cp_port(Port, PublicPort),
	  http_location_by_id(root, Root)
	},
	[ 'Started ClioPatria server at port ~w'-[Port], nl,
	  'You may access the server at http://~w:~w~w'-[Host, PublicPort, Root]
	].
prolog:message(cliopatria(welcome(DefaultPort))) -->
	[ nl,
	  'Use one of the calls below to start the ClioPatria server:', nl, nl,
	  '  ?- cp_server.               % start at port ~w'-[DefaultPort], nl,
	  '  ?- cp_server([port(Port)]). % start at Port'
	].
prolog:message(cliopatria(use_port_option)) -->
	[ '   Could not start the HTTP server!', nl,
	  '   Choose a different port using ./run.pl --port=<port> or', nl,
	  '   use the network plugin to change the default port.'
	].
prolog:message(cliopatria(server_already_running(Port))) -->
	{ cp_host(Host),
	  cp_port(Port, PublicPort),
	  http_location_by_id(root, Root)
	},
	[ 'CliopPatria server is already running at http://~w:~w~w'-
	  [Host, PublicPort, Root]
	].

cp_host(Host) :-
	setting(http:public_host, Host),
	Host \== '', !.
cp_host(Host) :-
	gethostname(Host).

cp_port(_ServerPort, PublicPort) :-
	setting(http:public_host, Host),
	Host \== '', Host \== localhost,
	setting(http:public_port, PublicPort), !.
cp_port(ServerPort, ServerPort).



		 /*******************************
		 *	        HOOKS		*
		 *******************************/

:- multifile
	user:message_hook/3.

user:message_hook(rdf(restore(_, done(_DB, _T, _Count, Nth, Total))),
		  _Kind, _Lines) :-
	retractall(loading_done(_,_)),
	assert(loading_done(Nth, Total)),
	fail.
