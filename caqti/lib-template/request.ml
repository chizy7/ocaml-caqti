(* Copyright (C) 2017--2024  Petter A. Urkedal <paurkedal@gmail.com>
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

module Log = (val Logs.src_log (Logs.Src.create "caqti"))

type ('a, 'b, +'m) t = {
  id: int option;
  query: Driver_info.t -> Query.t;
  param_type: 'a Row_type.t;
  row_type: 'b Row_type.t;
  row_mult: 'm Row_mult.t;
} constraint 'm = [< `Zero | `One | `Many]

let last_id = ref (-1)

let create ?(oneshot = false) param_type row_type row_mult query =
  let id = if oneshot then None else (incr last_id; Some !last_id) in
  {id; query; param_type; row_type; row_mult}

let param_type request = request.param_type
let row_type request = request.row_type
let row_mult request = request.row_mult

let query_id request = request.id
let query request = request.query

let no_env _ _ = raise Not_found

let make_pp ?(env = no_env) ?(driver_info = Driver_info.dummy) ()
            ppf req =
  let query = Query.expand (env driver_info) (req.query driver_info) in
  Format.fprintf ppf "(%a -->%s %a) {|%a|}"
    Row_type.pp req.param_type
    (match Row_mult.expose req.row_mult with
     | `Zero -> "."
     | `One -> ""
     | `Zero_or_one -> "?"
     | `Zero_or_more -> "*")
    Row_type.pp req.row_type
    Query.pp query

let pp ppf = make_pp () ppf

let pp_with_param_enabled =
  (match Sys.getenv "CAQTI_DEBUG_PARAM" with
   | "true" -> true
   | "false" -> false
   | s ->
      Log.err (fun f ->
        f "Invalid value %s for CAQTI_DEBUG_PARAM, assuming false." s);
      false
   | exception Not_found -> false)

let make_pp_with_param ?env ?driver_info () ppf (req, param) =
  let pp = make_pp ?env ?driver_info () in
  pp ppf req;
  if pp_with_param_enabled then
    Format.fprintf ppf " %a" Row_type.pp_value (req.param_type, param)
