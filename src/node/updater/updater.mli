(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

type shell_operation = Store.Operation.shell_header = {
  net_id: Net_id.t ;
}
val shell_operation_encoding: shell_operation Data_encoding.t

type raw_operation = Store.Operation.t = {
  shell: shell_operation ;
  proto: MBytes.t ;
}
val raw_operation_encoding: raw_operation Data_encoding.t

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
val shell_block_encoding: shell_block Data_encoding.t

type raw_block = Store.Block_header.t = {
  shell: shell_block ;
  proto: MBytes.t ;
}
val raw_block_encoding: raw_block Data_encoding.t

module type PROTOCOL = Protocol.PROTOCOL
module type REGISTRED_PROTOCOL = sig
  val hash: Protocol_hash.t
  (* exception Ecoproto_error of error list *)
  include Protocol.PROTOCOL with type error := error
                             and type 'a tzresult := 'a tzresult
  val complete_b58prefix : Context.t -> string -> string list Lwt.t
end

type component = Tezos_compiler.Protocol.component = {
  name : string ;
  interface : string option ;
  implementation : string ;
}

val extract: Lwt_io.file_name -> Protocol_hash.t -> component list -> unit Lwt.t
val compile: Protocol_hash.t -> component list -> bool Lwt.t

val activate: Context.t -> Protocol_hash.t -> Context.t Lwt.t
val set_test_protocol: Context.t -> Protocol_hash.t -> Context.t Lwt.t
val fork_test_network: Context.t -> Context.t Lwt.t

val register: Protocol_hash.t -> (module REGISTRED_PROTOCOL) -> unit

val get: Protocol_hash.t -> (module REGISTRED_PROTOCOL) option
val get_exn: Protocol_hash.t -> (module REGISTRED_PROTOCOL)

val init: string -> unit
