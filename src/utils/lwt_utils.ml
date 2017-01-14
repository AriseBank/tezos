(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

module LC = Lwt_condition

open Lwt.Infix
open Logging.Core

let may ~f = function
  | None -> Lwt.return_unit
  | Some x -> f x

let never_ending = fst (Lwt.wait ())

(* A non exception-based cancelation mechanism. Builds a [cancelation]
   thread to bind / pick on, awoken when a cancelation is requested by
   [cancel ()]. [on_cancel cb] registers a callback to be called at
   cancelation. [cancel ()] finishes when all calbacks have completed
   (sequentially), instantly when called more than once. *)
let canceler ()
  : (unit -> unit Lwt.t) *
    (unit -> unit Lwt.t) *
    ((unit -> unit Lwt.t) -> unit) =
  let cancelation = LC.create () in
  let cancelation_complete = LC.create () in
  let cancel_hook = ref (fun () -> Lwt.return ()) in
  let canceling = ref false and canceled = ref false  in
  let cancel () =
    if !canceled then
      Lwt.return ()
    else if !canceling then
      LC.wait cancelation_complete
    else begin
      canceling := true ;
      LC.broadcast cancelation () ;
      Lwt.finalize
        !cancel_hook
        (fun () ->
           canceled := true ;
           LC.broadcast cancelation_complete () ;
           Lwt.return ()) >>= fun () ->
      Lwt.return_unit
    end
  in
  let on_cancel cb =
    let hook = !cancel_hook in
    cancel_hook := (fun () -> hook () >>= cb) ;
  in
  let cancelation () =
    if !canceling then Lwt.return ()
    else LC.wait cancelation
  in
  cancelation, cancel, on_cancel

module Canceler = struct

  type t = {
    cancelation: unit Lwt_condition.t ;
    cancelation_complete: unit Lwt_condition.t ;
    mutable cancel_hook: unit -> unit Lwt.t ;
    mutable canceling: bool ;
    mutable canceled: bool ;
  }

  let create () =
    let cancelation = LC.create () in
    let cancelation_complete = LC.create () in
    { cancelation ; cancelation_complete ;
      cancel_hook = (fun () -> Lwt.return ()) ;
      canceling = false ;
      canceled = false ;
    }

  let cancel st =
    if st.canceled then
      Lwt.return ()
    else if st.canceling then
      LC.wait st.cancelation_complete
    else begin
      st.canceling <- true ;
      LC.broadcast st.cancelation () ;
      Lwt.finalize
        st.cancel_hook
        (fun () ->
           st.canceled <- true ;
           LC.broadcast st.cancelation_complete () ;
           Lwt.return ())
    end

  let on_cancel st cb =
    let hook = st.cancel_hook in
    st.cancel_hook <- (fun () -> hook () >>= cb)

  let cancelation st =
    if st.canceling then Lwt.return ()
    else LC.wait st.cancelation

  let canceled st = st.canceling

end

type trigger =
  | Absent
  | Present
  | Waiting of unit Lwt.u

let trigger () : (unit -> unit) * (unit -> unit Lwt.t) =
  let state = ref Absent in
  let trigger () =
    match !state with
    | Absent -> state := Present
    | Present -> ()
    | Waiting u ->
        state := Absent;
        Lwt.wakeup u ()
  in
  let wait () =
    match !state with
    | Absent ->
        let waiter, u = Lwt.wait () in
        state := Waiting u;
        waiter
    | Present ->
        state := Absent;
        Lwt.return_unit
    | Waiting u ->
        Lwt.waiter_of_wakener u
  in
  trigger, wait

type 'a queue =
  | Absent
  | Present of 'a list ref
  | Waiting of 'a list Lwt.u

let queue () : ('a -> unit) * (unit -> 'a list Lwt.t) =
  let state = ref Absent in
  let queue v =
    match !state with
    | Absent -> state := Present (ref [v])
    | Present r -> r := v :: !r
    | Waiting u ->
        state := Absent;
        Lwt.wakeup u [v]
  in
  let wait () =
    match !state with
    | Absent ->
        let waiter, u = Lwt.wait () in
        state := Waiting u;
        waiter
    | Present r ->
        state := Absent;
        Lwt.return (List.rev !r)
    | Waiting u ->
        Lwt.waiter_of_wakener u
  in
  queue, wait

(* A worker launcher, takes a cancel callback to call upon *)
let worker name ~run ~cancel =
  let stop = LC.create () in
  let fail e =
    log_error "%s worker failed with %s" name (Printexc.to_string e) ;
    cancel ()
  in
  let waiter = LC.wait stop in
  log_info "%s worker started" name ;
  Lwt.async
    (fun () ->
       Lwt.catch run fail >>= fun () ->
       LC.signal stop ();
       Lwt.return ()) ;
  waiter >>= fun () ->
  log_info "%s worker ended" name ;
  Lwt.return ()


let rec chop k l =
  if k = 0 then l else begin
    match l with
    | _::t -> chop (k-1) t
    | _ -> assert false
  end
let stable_sort cmp l =
  let rec rev_merge l1 l2 accu =
    match l1, l2 with
    | [], l2 -> Lwt.return (List.rev_append l2 accu)
    | l1, [] -> Lwt.return (List.rev_append l1 accu)
    | h1::t1, h2::t2 ->
        cmp h1 h2 >>= function
        | x when x <= 0 -> rev_merge t1 l2 (h1::accu)
        | _             -> rev_merge l1 t2 (h2::accu)
  in
  let rec rev_merge_rev l1 l2 accu =
    match l1, l2 with
    | [], l2 -> Lwt.return (List.rev_append l2 accu)
    | l1, [] -> Lwt.return (List.rev_append l1 accu)
    | h1::t1, h2::t2 ->
        cmp h1 h2 >>= function
        | x when x > 0 -> rev_merge_rev t1 l2 (h1::accu)
        | _            -> rev_merge_rev l1 t2 (h2::accu)
  in
  let rec sort n l =
    match n, l with
    | 2, x1 :: x2 :: _ -> begin
        cmp x1 x2 >|= function
        | x when x <= 0 -> [x1; x2]
        | _             -> [x2; x1]
      end
    | 3, x1 :: x2 :: x3 :: _ -> begin
        cmp x1 x2 >>= function
        | x when x <= 0 -> begin
            cmp x2 x3 >>= function
            | x when x <= 0 -> Lwt.return [x1; x2; x3]
            | _ -> cmp x1 x3 >|= function
              | x when x <= 0 -> [x1; x3; x2]
              | _ -> [x3; x1; x2]
          end
        | _ -> begin
            cmp x1 x3 >>= function
            | x when x <= 0 -> Lwt.return [x2; x1; x3]
            | _ -> cmp x2 x3 >|= function
              | x when x <= 0 -> [x2; x3; x1]
              | _ -> [x3; x2; x1]
          end
      end
    | n, l ->
       let n1 = n asr 1 in
       let n2 = n - n1 in
       let l2 = chop n1 l in
       rev_sort n1 l >>= fun s1 ->
       rev_sort n2 l2 >>= fun s2 ->
       rev_merge_rev s1 s2 []
  and rev_sort n l =
    match n, l with
    | 2, x1 :: x2 :: _ -> begin
        cmp x1 x2 >|= function
        | x when x > 0 -> [x1; x2]
        | _ -> [x2; x1]
      end
    | 3, x1 :: x2 :: x3 :: _ -> begin
        cmp x1 x2 >>= function
        | x when x > 0 -> begin
            cmp x2 x3 >>= function
            | x when x > 0 -> Lwt.return [x1; x2; x3]
            | _ ->
                cmp x1 x3 >|= function
                | x when x > 0 -> [x1; x3; x2]
                | _ -> [x3; x1; x2]
          end
        | _ -> begin
            cmp x1 x3 >>= function
            | x when x > 0 -> Lwt.return [x2; x1; x3]
            | _ ->
                cmp x2 x3 >|= function
                | x when x > 0 -> [x2; x3; x1]
                | _ -> [x3; x2; x1]
          end
      end
    | n, l ->
        let n1 = n asr 1 in
        let n2 = n - n1 in
        let l2 = chop n1 l in
        sort n1 l >>= fun s1 ->
        sort n2 l2 >>= fun s2 ->
        rev_merge s1 s2 []
  in
  let len = List.length l in
  if len < 2 then Lwt.return l else sort len l

let sort = stable_sort

let rec read_bytes ?(pos = 0) ?len fd buf =
  let len = match len with None -> Bytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_unix.read fd buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_read -> inner (pos + nb_read) (len - nb_read)
  in
  inner pos len

let read_mbytes ?(pos=0) ?len fd buf =
  let len = match len with None -> MBytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_bytes.read fd buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_read -> inner (pos + nb_read) (len - nb_read)
  in
  inner pos len

let write_mbytes ?(pos=0) ?len descr buf =
  let len = match len with None -> MBytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_bytes.write descr buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_written -> inner (pos + nb_written) (len - nb_written) in
  inner pos len

let write_bytes ?(pos=0) ?len descr buf =
  let len = match len with None -> Bytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_unix.write descr buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_written -> inner (pos + nb_written) (len - nb_written) in
  inner pos len

let (>>=) = Lwt.bind

let remove_dir dir =
  let rec remove dir =
    let files = Lwt_unix.files_of_directory dir in
    Lwt_stream.iter_s
      (fun file ->
         if file = "." || file = ".." then
           Lwt.return ()
         else begin
           let file = Filename.concat dir file in
           if Sys.is_directory file
           then remove file
           else Lwt_unix.unlink file
         end)
      files >>= fun () ->
    Lwt_unix.rmdir dir in
  if Sys.file_exists dir && Sys.is_directory dir then
    remove dir
  else
    Lwt.return ()

let rec create_dir ?(perm = 0o755) dir =
  if Sys.file_exists dir then
    Lwt.return ()
  else begin
    create_dir (Filename.dirname dir) >>= fun () ->
    Lwt_unix.mkdir dir perm
  end

let create_file ?(perm = 0o644) name content =
  Lwt_unix.openfile name Unix.([O_TRUNC; O_CREAT; O_WRONLY]) perm >>= fun fd ->
  Lwt_unix.write_string fd content 0 (String.length content) >>= fun _ ->
  Lwt_unix.close fd

let safe_close fd =
  Lwt.catch
    (fun () -> Lwt_unix.close fd)
    (fun _ -> Lwt.return_unit)

open Error_monad

type error += Canceled

let protect ?on_error ?canceler t =
  let cancelation =
    match canceler with
    | None -> never_ending
    | Some canceler ->
        ( Canceler.cancelation canceler >>= fun () ->
          fail Canceled ) in
  let res =
    Lwt.pick [ cancelation ;
               Lwt.catch t (fun exn -> fail (Exn exn)) ] in
  res >>= function
  | Ok _ -> res
  | Error err ->
      let canceled =
        Utils.unopt_map canceler ~default:false ~f:Canceler.canceled in
      let err = if canceled then [Canceled] else err in
      match on_error with
      | None -> Lwt.return (Error err)
      | Some on_error -> on_error err

type error += Timeout

let with_timeout ?(canceler = Canceler.create ()) timeout f =
  let t = Lwt_unix.sleep timeout in
  Lwt.choose [
    (t >|= fun () -> None) ;
    (f canceler >|= fun x -> Some x)
  ] >>= function
  | Some x when Lwt.state t = Lwt.Sleep ->
      Lwt.cancel t ;
      Lwt.return x
  | _ ->
      Canceler.cancel canceler >>= fun () ->
      fail Timeout


