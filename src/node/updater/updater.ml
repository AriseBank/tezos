(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Logging.Updater

let (//) = Filename.concat

module type PROTOCOL = Protocol.PROTOCOL
module type REGISTRED_PROTOCOL = sig
  val hash: Protocol_hash.t
  include Protocol.PROTOCOL with type error := error
                             and type 'a tzresult := 'a tzresult
  val complete_b58prefix : Context.t -> string -> string list Lwt.t
end

type shell_operation = Store.Operation.shell_header = {
  net_id: Net_id.t ;
}
let shell_operation_encoding = Store.Operation.shell_header_encoding

type raw_operation = Store.Operation.t = {
  shell: shell_operation ;
  proto: MBytes.t ;
}
let raw_operation_encoding = Store.Operation.encoding

(** The version agnostic toplevel structure of blocks. *)
type shell_block = Store.Block_header.shell_header = {
  net_id: Net_id.t ;
  (** The genesis of the chain this block belongs to. *)
  predecessor: Block_hash.t ;
  (** The preceding block in the chain. *)
  timestamp: Time.t ;
  (** The date at which this block has been forged. *)
  operations: Operation_list_list_hash.t ;
  (** The sequence of operations. *)
  fitness: MBytes.t list ;
  (** The announced score of the block. As a sequence of sequences
      of unsigned bytes. Ordered by length and then by contents
      lexicographically. *)
}
let shell_block_encoding = Store.Block_header.shell_header_encoding

type raw_block = Store.Block_header.t = {
  shell: shell_block ;
  proto: MBytes.t ;
}
let raw_block_encoding = Store.Block_header.encoding

type 'error preapply_result = 'error Protocol.preapply_result = {
  applied: Operation_hash.t list;
  refused: 'error list Operation_hash.Map.t;
  branch_refused: 'error list Operation_hash.Map.t;
  branch_delayed: 'error list Operation_hash.Map.t;
}

let empty_result = {
  applied = [] ;
  refused = Operation_hash.Map.empty ;
  branch_refused = Operation_hash.Map.empty ;
  branch_delayed = Operation_hash.Map.empty ;
}

let map_result f r = {
  applied = r.applied;
  refused = Operation_hash.Map.map f r.refused ;
  branch_refused = Operation_hash.Map.map f r.branch_refused ;
  branch_delayed = Operation_hash.Map.map f r.branch_delayed ;
}

let preapply_result_encoding error_encoding =
  let open Data_encoding in
  let refused_encoding = tup2 Operation_hash.encoding error_encoding in
  let build_list map = Operation_hash.Map.bindings map in
  let build_map list =
    List.fold_right
      (fun (k, e) m -> Operation_hash.Map.add k e m)
      list Operation_hash.Map.empty in
  conv
    (fun { applied ; refused ; branch_refused ; branch_delayed } ->
       (applied, build_list refused,
        build_list branch_refused, build_list branch_delayed))
    (fun (applied, refused, branch_refused, branch_delayed) ->
       let refused = build_map refused in
       let branch_refused = build_map branch_refused in
       let branch_delayed = build_map branch_delayed in
       { applied ; refused ; branch_refused ; branch_delayed })
    (obj4
       (req "applied" (list Operation_hash.encoding))
       (req "refused" (list refused_encoding))
       (req "branch_refused" (list refused_encoding))
       (req "branch_delayed" (list refused_encoding)))


(** Version table *)

module VersionTable = Protocol_hash.Table

let versions : ((module REGISTRED_PROTOCOL)) VersionTable.t =
  VersionTable.create 20

let register hash proto =
  VersionTable.add versions hash proto

let activate = Context.set_protocol
let fork_test_network = Context.fork_test_network
let set_test_protocol = Context.set_test_protocol

let get_exn hash = VersionTable.find versions hash
let get hash =
  try Some (get_exn hash)
  with Not_found -> None

(** Compiler *)

let datadir = ref None
let get_datadir () =
  match !datadir with
  | None -> fatal_error "not initialized"
  | Some m -> m

let init dir =
  datadir := Some dir

type component = Tezos_compiler.Protocol.component = {
  name : string ;
  interface : string option ;
  implementation : string ;
}

let create_files dir units =
  Lwt_utils.remove_dir dir >>= fun () ->
  Lwt_utils.create_dir dir >>= fun () ->
  Lwt_list.map_s
    (fun { name; interface; implementation } ->
       let name = String.lowercase_ascii name in
       let ml = dir // (name ^ ".ml") in
       let mli = dir // (name ^ ".mli") in
       Lwt_utils.create_file ml implementation >>= fun () ->
       match interface with
       | None -> Lwt.return [ml]
       | Some content ->
           Lwt_utils.create_file mli content >>= fun () ->
           Lwt.return [mli;ml])
    units >>= fun files ->
  let files = List.concat files in
  Lwt.return files

let extract dirname hash units =
  let source_dir = dirname // Protocol_hash.to_short_b58check hash // "src" in
  create_files source_dir units >|= fun _files ->
  Tezos_compiler.Meta.to_file source_dir ~hash
    (List.map (fun {name} -> String.capitalize_ascii name) units)

let do_compile hash units =
  let datadir = get_datadir () in
  let source_dir = datadir // Protocol_hash.to_short_b58check hash // "src" in
  let log_file = datadir // Protocol_hash.to_short_b58check hash // "LOG" in
  let plugin_file = datadir // Protocol_hash.to_short_b58check hash //
                    Format.asprintf "protocol_%a.cmxs" Protocol_hash.pp hash
  in
  create_files source_dir units >>= fun _files ->
  Tezos_compiler.Meta.to_file source_dir ~hash
    (List.map (fun {name} -> String.capitalize_ascii name) units);
  let compiler_command =
    (Sys.executable_name,
     Array.of_list [Node_compiler_main.compiler_name; plugin_file; source_dir]) in
  let fd = Unix.(openfile log_file [O_WRONLY; O_CREAT; O_TRUNC] 0o644) in
  let pi =
    Lwt_process.exec
      ~stdin:`Close ~stdout:(`FD_copy fd) ~stderr:(`FD_move fd)
      compiler_command in
  pi >>= function
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      log_error "INTERRUPTED COMPILATION (%s)" log_file;
      Lwt.return false
  | Unix.WEXITED x when x <> 0 ->
      log_error "COMPILATION ERROR (%s)" log_file;
      Lwt.return false
  | Unix.WEXITED _ ->
      try Dynlink.loadfile_private plugin_file; Lwt.return true
      with Dynlink.Error err ->
        log_error "Can't load plugin: %s (%s)"
          (Dynlink.error_message err) plugin_file;
        Lwt.return false

let compile hash units =
  if VersionTable.mem versions hash then
    Lwt.return true
  else begin
    do_compile hash units >>= fun success ->
    let loaded = VersionTable.mem versions hash in
    if success && not loaded then
      log_error "Internal error while compiling %a" Protocol_hash.pp hash;
    Lwt.return loaded
  end

let operations t =
  let ops =
    List.fold_left
      (fun acc x -> Operation_hash.Set.add x acc)
      Operation_hash.Set.empty t.applied in
  let ops =
    Operation_hash.Map.fold
      (fun x _ acc -> Operation_hash.Set.add x acc)
      t.branch_delayed ops in
  let ops =
    Operation_hash.Map.fold
      (fun x _ acc -> Operation_hash.Set.add x acc)
      t.branch_refused ops in
  ops
