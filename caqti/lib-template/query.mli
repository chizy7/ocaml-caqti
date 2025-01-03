(* Copyright (C) 2019--2025  Petter A. Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the LGPL-3.0 Linking Exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * and the LGPL-3.0 Linking Exception along with this library.  If not, see
 * <http://www.gnu.org/licenses/> and <https://spdx.org>, respectively.
 *)

(** This module provides templating of database query strings.  It helps
    mitigate differences between database systems, and provides additional
    functionality such as variable substitution and safe embedding of values.
    The representation is also suited for dynamic construction.

    There are three ways to construct a template:

      - Using the parser ({!of_string}, {!of_string_exn}, etc.) if the query
        template is known at compile time.

      - Using the {{!query_construction} constructors} of the current module.

      - Using the {!Query_fmt} module, which provides an alternative to the
        previous option. *)

(**/**)
module Private : sig
  type t =
    | L of string
      (** [L frag] translates to the literally inserted substring [frag].  The
          [frag] argument must be trusted or verified to be secure to avoid SQL
          injection attacks.  Use {!V}, {!Q}, or {!P} to safely insert strings or
          other values. *)
    | V : 'a Field_type.t * 'a -> t
      (** [V (t, v)] translates to a parameter of type [t] bound to the value [v].
          That is, the query string will contain a parameter reference which does
          not conflict with any {!P} nodes and bind [v] to the corresponding
          parameter each time the query is executed.  This allows taking advantage
          of driver-dependent serialization and escaping mechanisms to safely send
          values to the database server. *)
    | Q of string
      (** [Q s] corresponds to a quoted string literal.  This is passed as part of
          the query string if a suitable quoting function is available in the
          client library, otherwise it is equivalent to
          {!V}[(]{!Caqti_template.Field_type.String}[, s)]. *)
    | P of int
      (** [P i] refers to parameter number [i], counting from 0, so that e.g.
          [P 0] translates to ["$1"] for PostgreSQL and ["?1"] for SQLite3. *)
    | E of string
      (** [E name] will be replaced by the fragment returned by an environment
          lookup function, as passed directly to {!expand} or indirectly through
          the [?env] argument found in higher-level functions.  An error will be
          issued for any remaining [E]-nodes in the final translation to a query
          string. *)
    | S of t list
      (** [S frags] is the concatenation of [frags].  Apart from combining
          different kinds of nodes, this constructor can be nested according to
          the flow of the generating code. *)
end [@@alert caqti_private]
(**/**)

type t = Private.t [@@alert "-caqti_private"]
(** [t] is an intermediate representation of a query string to be send to a
    database, possibly combined with some hidden parameters used to safely embed
    values.  Apart from embedding values, this representation provides indexed
    parameter references, independent of the target database system.  For
    databases which use linear parameter references (like [?] for MariaDB), the
    driver will reshuffle, elide, and duplicate parameters as needed. *)

(** {2:query_construction Construction} *)

val empty : t
(** [empty] is the empty query fragment; i.e. it expands to nothing. *)

val lit : string -> t
(** [lit frag] expands to [frag], literally; i.e. the argument is passed
    unchanged to the database system as a substring of the query. *)

val quote : string -> t
(** [quote str] expands to the literally quoted string [str] if an reliable
    escape function is available from the driver library, otherwise [quote] is
    equivalent to {!string}. *)

val param : int -> t
(** [param i] expands to a reference to parameter number [i], counting from
    zero.  That is, [param 0] expands to ["$1"] for PostgreSQL and to ["?1"] for
    SQLite3.  For MariaDB, [param i] expands to ["?"] for any [i]; the driver
    will instead shuffle, elide, and duplicate the actual arguments to match
    their order of reference in the query string. *)

val var : string -> t
(** [var v] expands to [subst v] where [subst] is the substitution function
    passed to {!expand} or one of the connector functions. *)

val concat : ?sep: string -> t list -> t
(** [concat ?sep frags] concatenates [frags], optionally separated by [sep].
    Returns the empty fragment on the empty list of fragments. *)

val cat : t -> t -> t
(** [cat q1 q2] expands to the juxtaposition of the expansions of [q1] followed
    by [q2].  This is an associative alternative to {!concat} when no separator
    is needed. *)

module Infix : sig
  (** This module provides a terser way to compose queries.  As an example,
      consider the dynamic construction of a simple SELECT-request which
      extracts a list of named columns given a corresponding row type, and where
      conditions are given as query templates with any values embedded:
      {[
        open Caqti_template.Create

        type cond =
          | Column_eq : string * 'a Caqti_template.Field_type.t * 'a -> cond

        let query_of_cond = function
         | Column_eq (col, t, v) ->
            Q.lit col @++ " = " ^++ Q.const t v

        let make_simple_select conditions columns row_type =
          (unit -->* row_type) ~oneshot:true @@ fun _ ->
          "SELECT " ^++ Q.concat ~sep:", " (List.map Q.lit columns) @++
          " FROM $.foo" ^++
          " WHERE " ^++ Q.concat ~sep:" AND " (List.map query_of_cond conditions)
      ]}
      *)

  val (@++) : t -> t -> t
  (** An alias for {!cat}. *)

  val (^++) : string -> t -> t
  (** [pfx ^++ q] is [q] prefixed with the literal fragment [pfx], i.e.
      [cat (lit pfx) q]. *)

  val (++^) : t -> string -> t
  (** [q ++^ sfx] is [q] suffixed with the literal fragment [sfx], i.e.
      [cat q (lit sfx)]. *)
end

(** {3 Embedding Values}

    The following functions can be used to embed values into a query, including
    the generic {!const}, corresponding specialized variants.  Additionally
    {!const_fields} can be used to extract fragments for multiple fields given a
    row type and a value. *)

val bool : bool -> t
val int : int -> t
val int16 : int -> t
val int32 : int32 -> t
val int64 : int64 -> t
val float : float -> t
val string : string -> t
val octets : string -> t
val pdate : Ptime.t -> t
val ptime : Ptime.t -> t
val ptime_span : Ptime.span -> t

val const : 'a Field_type.t -> 'a -> t
(** [const t x] is a fragment representing the value [x] of field type [t].
    This typically expands to a parameter reference which will receive the value
    [x] when executed, though the value may also be embedded in the query if it
    is deemed safe. *)

val const_fields : 'a Row_type.t -> 'a -> t list
(** [const_fields t x] returns a list of fragments corresponding to the
    single-field projections of the value [x] as described by the type
    descriptor [t].  Each element of the returned list will be either a
    {!V}-fragment containing the projected value, or the [L["NULL"]] fragment if
    the projection is [None].

    The result can be turned into a comma-separated list with {!concat}, except
    values of unitary types, i.e. types having no fields, may require special
    care. *)


(** {2 Normalization and Equality} *)

val normal : t -> t
(** [normal q] rewrites [q] to a normal form containing at most one top-level
    {!S} constructor, containing no empty literals, and no consecutive literals.
    This function can be used to post-process queries before using {!equal} and
    {!hash}. *)

val equal : t -> t -> bool
(** Equality predicate for {!t}. *)

val hash : t -> int
(** A hash function compatible with {!equal}.  The hash function may change
    across minor versions and may depend on architecture. *)


(** {2 Parsing, Expansion, and Printing} *)

val pp : Format.formatter -> t -> unit
(** [pp ppf q] prints a {e human}-readable representation of [q] on [ppf].
    The printed string is {e not suitable for sending to an SQL database}; doing
    so may lead to an SQL injection vulnerability. *)

val show : t -> string
(** [show q] is the same {e human}-readable representation of [q] as printed by
    {!pp}.
    The returned string is {e not suitable for sending to an SQL database};
    doing so may lead to an SQL injection vulnerability. *)

type expand_error
(** A description of the error caused during {!expand} if the environment lookup
    function returns an invalid result or [None] for a variable when the
    expansion is final. *)

val pp_expand_error : Format.formatter -> expand_error -> unit
(** Prints an informative error. *)

exception Expand_error of expand_error
(** The exception raised by {!expand} when there are issues expanding an
    environment variable using the provided callback. *)

type subst = string -> t
(** A partial mapping from variable names to query fragments, which raises
    [Not_found] for undefined variables.  This is used by {!expand} to resolve
    variable references, with the special handling of a final period in the
    variable names described in {{!query_template} The Syntax of Query
    Templates}. *)

val expand : ?final: bool -> subst -> t -> t
(** [expand subst query] replaces each occurrence of [E var] with [subst var] or
    leaves it unchanged where [subst var] is [None].

    @param final
      If [true], then an error is raised instead of leaving environment
      references unexpended if [f] returns [None].  This is used by drivers
      for performing the final expansion.  Defaults to [false].

    @raise Expand_error
      if [subst var] contains an [E]-node (nested reference) or if [~final:true]
      is passed and [subst var] is [None] for some occurrence of [E var] in
      [query]. *)

val angstrom_parser : t Angstrom.t
(** Matches a single expression terminated by the end of input or a semicolon
    lookahead. The accepted languages is described in {{!query_template} The
    Syntax of Query Templates}. *)

val angstrom_parser_with_semicolon : t Angstrom.t
(** A variant of [angstrom_parser] which accepts unquoted semicolons as part of
    the single statement, as is valid in some cases like in SQLite3 trigger
    definitions.  This is the parser used by {!Caqti_template.Request}, where
    it's assumed that the input is a single SQL statement. *)

val angstrom_list_parser : t list Angstrom.t
(** Matches a sequence of statements while ignoring surrounding white space and
    end-of-line comments starting with ["--"].  This parser can be used to load
    schema files with support for environment expansions, like substituting the
    name of the database schema. *)

val of_string : string -> (t, [`Invalid of int * string]) result
(** Parses a single expression using {!angstrom_parser_with_semicolon}.  The
    error indicates the byte position of the input string where the parse
    failure occurred in addition to an error message. See {{!query_template} The
    Syntax of Query Templates} for how the input string is interpreted. *)

val of_string_exn : string -> t
(** Like {!of_string}, but raises an exception on error.

    @raise Failure if parsing failed. *)
