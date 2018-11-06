/*  Part of ClioPatria SeRQL and SPARQL server

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2017, University of Amsterdam,
                   VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(cp_setup,
          [ setup/0
          ]).
:- prolog_load_context(directory, Dir),
   directory_file_path(Dir, lib, LibDir),
   asserta(user:file_search_path(library, LibDir)).

user:message_hook(git(update_versions), informational, _).

:- use_module(library(setup)).
:- use_module(library(option)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(filesex)).

:- multifile
    user:file_search_path/2.
:- dynamic
    user:file_search_path/2.

:- prolog_load_context(directory, Dir),
   asserta(user:file_search_path(cliopatria, Dir)).

:- initialization(setup, main).

%!  setup
%
%   Setup ClioPatria. This installs files   *.in from the ClioPatria
%   after localization and creates config-enabled.

setup :-
    options(Options),
    setup(Options).

setup(Options) :-
    cliopatria_dir(ClioDir),
    install_dir(Dir),
    (   option(help(true), Options)
    ->  true
    ;   setup_scripts(ClioDir, Dir)
    ),
    directory_file_path(ClioDir, 'lib/APPCONF.txt.in', ReadmeIn),
    directory_file_path(ClioDir, 'config-available', ConfigAvail),
    directory_file_path(Dir,     'config-enabled', ConfigEnabled),
    setup_default_config(ConfigEnabled, ConfigAvail,
                         [ readme(ReadmeIn)
                         | Options
                         ]),
    setup_goodbye.

cliopatria_dir(Dir) :-
    absolute_file_name(cliopatria(.),
                       Dir,
                       [ file_type(directory),
                         access(read)
                       ]).

install_dir(Dir) :-
    current_prolog_flag(windows, true),
    !,
    working_directory(CWD, CWD),
    (   get(@(display), win_directory,
            'Create ClioPatria project in', CWD, Dir)
    ->  true
    ;   halt(1)
    ).
install_dir(DIR) :-
    working_directory(DIR, DIR).


setup:substitutions([ 'SWIPL'=PL,               % Prolog executable (for #!...)
                      'CLIOPATRIA'=ClioDir,     % ClioPatria directory
                      'CWD'=CWD,                % This directory
                      'PARENTDIR'=Parent,       % Parent of CWD
                      'HASHBANG'=HashBang,      % #! (or not)
                      'LOADOPTIONS'=LoadOptions % -s (or not)
                    ]) :-
    cliopatria_dir(ClioDir),
    working_directory(CWD, CWD),
    file_directory_name(CWD, Parent),
    setup_prolog_executable(PL),
    hashbang(HashBang),
    load_options(LoadOptions).

hashbang('%!') :- current_prolog_flag(windows, true), !.
hashbang('#!').

load_options('').


%!  options(-Options) is det.
%
%   Options is a list of  (long)   commandline  options. This uses a
%   simple generic conversion  between   command-line  argument  and
%   option value, defined as follows:
%
%     | --without-X  | without(X)  |
%     | --with-X     | with(X)     |
%     | --Name=Value | Name(Value) |
%     | --Name       | Name(true)  |

options(Options) :-
    current_prolog_flag(argv, Argv),
    (   append(_, [--|AV], Argv)
    ->  true
    ;   AV = Argv
    ),
    maplist(cmd_option, AV, Options).

cmd_option(Text, Option) :-
    atom_concat('--without-', Module, Text),
    !,
    Option = without(Module).
cmd_option(Text, Option) :-
    atom_concat('--with-', Module, Text),
    !,
    Option = with(Module).
cmd_option(Text, Option) :-
    atom_concat(--, Rest, Text),
    !,
    (   sub_atom(Rest, B, _, A, =)
    ->  sub_atom(Rest, 0, B, _, Name),
        sub_atom(Rest, _, A, 0, OptVal),
        canonical_value(OptVal, Value),
        Option =.. [Name,Value]
    ;   Option =.. [Rest,true]
    ).
cmd_option(Text, Text).

canonical_value(Text, Number) :-
    catch(atom_number(Text, Number), _, true),
    !.
canonical_value(Text, Text).

