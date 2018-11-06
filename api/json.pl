/*  Part of ClioPatria SeRQL and SPARQL server

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2010-2018, University of Amsterdam,
                              VU University Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(api_json,
          [
          ]).
:- use_module(library(semweb/rdf_db)).
:- use_module(library(semweb/rdf_json)).
:- use_module(library(semweb/rdf_describe)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_json)).

:- http_handler(json(describe), json_describe, []).
:- http_handler(json(prefixes), json_prefixes, []).
:- http_handler(json(resource_representation), json_resource_representation, []).

/* <module> Describe resources in JSON

This module produces a JSON description for a resource.

@see    sparql.pl implements a SPARQL frontend.  The SPARQL DESCRIBE
        keyword provides similar functionality, but it has no arguments
        to specify how to describe a resource and it cannot return JSON.
@see    lod.pl implements Linked Open Data (LOD) descriptions.
*/

%!  json_describe(+Request)
%
%   HTTP  handler  that  describes   a    resource   using   a  JSON
%   serialization.
%
%   @see    http://n2.talis.com/wiki/RDF_JSON_Specification describes
%           the used graph-serialization.
%   @see    http://n2.talis.com/wiki/Bounded_Descriptions_in_RDF for
%           a description of the various descriptions
%   @bug    Currently only supports =cbd=.

json_describe(Request) :-
    http_parameters(Request,
                    [ r(URI,
                        [ description('The resource to describe')
                        ]),
                      how(_How,
                          [ %oneof([cbd, scdb, ifcbd, lcbd, hcbd]),
                            oneof([cbd]),
                            default(cbd),
                            description('Algorithm that determines \c
                                             the description')
                          ])
                    ]),
    resource_CBD(rdf, URI, Graph),
    graph_json(Graph, JSON),
    reply_json(JSON).

%!  json_prefixes(+Request)
%
%   Return a JSON object mapping prefixes to URIs.

json_prefixes(_Request) :-
    findall(Prefix-URI,
            rdf_current_ns(Prefix, URI),
            Pairs),
    dict_pairs(Dict, prefixes, Pairs),
    reply_json(Dict).

%!  json_resource_representation(+Request)
%
%   HTTP Handler to represent a resource in a given language

json_resource_representation(Request) :-
    http_parameters(Request,
                    [ r(URI,
                        [ description('The resource to format')
                        ]),
                      language(Lang,
                          [ oneof([sparql,turtle,prolog,xml]),
                            default(turtle),
                            description('Target language')
                          ])
                    ]),
    format_resource(Lang, URI, String),
    reply_json_dict(String).

format_resource(sparql, URI, String) :-
    !,
    format_resource(turtle, URI, String).
format_resource(turtle, URI, String) :-
    (   rdf_global_id(Prefix:Local, URI)
    ->  format(string(String), '~w:~w', [Prefix, Local])
    ;   format(string(String), '<~w>', [URI])
    ).
format_resource(xml, URI, String) :-
    (   rdf_global_id(Prefix:Local, URI),
        xml_name(URI, utf8)
    ->  format(string(String), '~w:~w', [Prefix, Local])
    ;   format(string(String), '"~w"', [URI])
    ).
format_resource(prolog, URI, String) :-
    (   rdf_global_id(Prefix:Local, URI)
    ->  format(string(String), '~q', [Prefix:Local])
    ;   format(string(String), '~q', [URI])
    ).
