(* Copyright (C) 2014--2025  Petter A. Urkedal <paurkedal@gmail.com>
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

open Lwt.Infix
open Lwt.Syntax

module Pool = Caqti_lwt_unix.System.Pool

module Resource = struct
  type t = {
    id: int;
    mutable use_count: int;
  }

  let alive = Hashtbl.create 17

  let latest_id = ref 0

  let create () =
    incr latest_id;
    Hashtbl.add alive !latest_id ();
    Lwt.return_ok {id = !latest_id; use_count = 0}

  let create_or_fail () =
    if Random.int 4 = 0 then Lwt.return_error () else
    create ()

  let free resource =
    assert (Hashtbl.mem alive resource.id);
    Hashtbl.remove alive resource.id;
    Lwt.return_unit
end

let test_n n =
  Caqti_lwt.Switch.run @@ fun sw ->
  let max_idle_size = Random.int 11 in
  let max_size = max 1 (max_idle_size + Random.int 5) in
  let max_use_count =
    (match Random.bool () with
     | false -> None
     | true -> Some (1 + Random.int 8))
  in
  let pool =
    let config =
      Caqti_pool_config.create ~max_idle_size ~max_size ~max_use_count ()
    in
    Pool.create ~config ~sw ~stdenv:()
      Resource.create_or_fail Resource.free
  in
  let wakers = Array.make n None in
  let wait_count = ref 0 in
  let wait_count_cond = Lwt_condition.create () in
  let wake j u = Lwt.wakeup u (); wakers.(j) <- None in
  for _ = 0 to 3 * n - 1 do
    let j = Random.int n in
    assert (Pool.size pool = Hashtbl.length Resource.alive);
    (match wakers.(j) with
     | None ->
        let waiter, waker = Lwt.wait () in
        incr wait_count;
        let task (resource : Resource.t) =
          (match max_use_count with
           | None -> ()
           | Some n -> assert (resource.use_count < n));
          resource.use_count <- resource.use_count + 1;
          waiter >|= fun () ->
          decr wait_count;
          Lwt_condition.signal wait_count_cond ();
          Ok ()
        in
        Lwt.async begin fun () ->
          Pool.use task pool >>=
          (function
           | Ok () -> Lwt.return_unit
           | Error () ->
              waiter >|= fun () ->
              decr wait_count;
              Lwt_condition.signal wait_count_cond ())
        end;
        wakers.(j) <- Some waker
     | Some u -> wake j u)
  done;
  for j = 0 to n - 1 do
    (match wakers.(j) with
     | None -> ()
     | Some u -> wake j u)
  done;
  let rec wait_for_all () =
    if !wait_count = 0 then Lwt.return_unit else
    Lwt_condition.wait wait_count_cond >>= wait_for_all
  in
  Lwt_unix.with_timeout 2.0 wait_for_all >>= fun () ->
  assert (Pool.size pool <= max_idle_size);
  Alcotest.(check int) "still waiting" 0 !wait_count;
  Pool.drain pool >|= fun () ->
  Alcotest.(check int) "pool size after drain" 0 (Pool.size pool);
  Alcotest.(check int) "alive after drain" 0 (Hashtbl.length Resource.alive)

let test _ () =
  test_n 0 >>= fun () ->
  test_n 1 >>= fun () ->
  let rec loop n_it =
    if n_it = 0 then Lwt.return_unit else
    test_n (Random.int (1 lsl Random.int 12)) >>= fun () ->
    loop (n_it - 1)
  in
  loop 500

let create_gathering n =
  let count = ref n in
  let wait, disband = Lwt.task () in
  fun () ->
    decr count;
    if !count > 0 then wait else
    (Lwt.wakeup_later disband (); Lwt.return_unit)

let test_age _ () =
  Caqti_lwt.Switch.run @@ fun sw ->
  let max_size = 8 in
  let max_idle_size = 4 in
  let max_idle_age = Some Mtime.Span.(100 * ms) in
  let pool =
    let config =
      Caqti_pool_config.create ~max_size ~max_idle_size ~max_idle_age ()
    in
    Pool.create ~config ~sw ~stdenv:() Resource.create Resource.free
  in
  let user_count = 8 in
  let join_gathering = create_gathering user_count in
  let* () =
    let f _i _resource = join_gathering () >|= Result.ok in
    List.init user_count f
      |> List.map (fun f -> Pool.use f pool >|= Result.get_ok)
      |> Lwt.join
  in
  Alcotest.(check int) "pool size before sleep" 4 (Pool.size pool);
  let+ () =
    let rec wait_while_draining timeout =
      if Pool.size pool = 0 then Lwt.return_unit else
      Lwt_unix.sleep 0.1 >>= fun () -> wait_while_draining (timeout -. 0.1)
    in
    wait_while_draining 5.0
  in
  Alcotest.(check int) "pool size after sleep" 0 (Pool.size pool)

let test_cases = [
  Alcotest_lwt.V1.test_case "basic usage" `Quick test;
  Alcotest_lwt.V1.test_case "timed cleanup" `Quick test_age;
]
