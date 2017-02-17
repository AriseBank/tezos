(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

type t

type config = {
  genesis: Store.genesis ;
  store_root: string ;
  context_root: string ;
  test_protocol: Protocol_hash.t option ;
  patch_context: (Context.t -> Context.t Lwt.t) option ;
  p2p: (P2p.config * P2p.limits) option ;
}

val create: config -> t tzresult Lwt.t

module RPC : sig

  type block = Node_rpc_services.Blocks.block
  type block_info = Node_rpc_services.Blocks.block_info

  val inject_block:
    t -> ?force:bool -> MBytes.t -> (Block_hash.t * unit tzresult Lwt.t) Lwt.t
  val inject_operation:
    t -> ?force:bool -> MBytes.t -> (Operation_hash.t * unit tzresult Lwt.t) Lwt.t
  val inject_protocol:
    t -> ?force:bool -> Store.protocol -> (Protocol_hash.t * unit tzresult Lwt.t) Lwt.t

  val raw_block_info:
    t -> Block_hash.t -> block_info Lwt.t
  val block_watcher:
    t -> block_info Lwt_stream.t * Watcher.stopper
  val valid_block_watcher:
    t -> (block_info Lwt_stream.t * Watcher.stopper) Lwt.t
  val heads: t -> block_info Block_hash_map.t Lwt.t

  val list:
    t -> int -> Block_hash.t list -> block_info list list Lwt.t

  val block_info:
    t -> block -> block_info Lwt.t

  val operations:
    t -> block -> Operation_hash.t list Lwt.t
  val operation_content:
    t -> Operation_hash.t -> Store.operation tzresult Time.timed_data option Lwt.t
  val operation_watcher:
    t -> (Operation_hash.t * Store.operation) Lwt_stream.t * Watcher.stopper

  val pending_operations:
    t -> block -> (error Updater.preapply_result * Operation_hash_set.t) Lwt.t

  val protocols:
    t -> Protocol_hash.t list Lwt.t
  val protocol_content:
    t -> Protocol_hash.t -> Store.protocol tzresult Time.timed_data option Lwt.t
  val protocol_watcher:
    t -> (Protocol_hash.t * Store.protocol) Lwt_stream.t * Watcher.stopper

  val context_dir:
    t -> block -> 'a RPC.directory option Lwt.t

  val preapply:
    t -> block ->
    timestamp:Time.t -> sort:bool ->
    Operation_hash.t list ->
    (Protocol.fitness * error Updater.preapply_result) tzresult Lwt.t

  val validate: t -> State.net_id -> Block_hash.t -> unit tzresult Lwt.t

  val context_dir:
    t -> block -> 'a RPC.directory option Lwt.t

  val complete:
    t -> ?block:block -> string -> string list Lwt.t

  module Network : sig
    val stat : t -> P2p.Stat.t
    val watch : t -> P2p.RPC.Event.t Lwt_stream.t * Watcher.stopper
    val connect : t -> P2p.Point.t -> float -> unit tzresult Lwt.t

    module Connection : sig
      val info : t -> P2p.Gid.t -> P2p.Connection_info.t option
      val kick : t -> P2p.Gid.t -> bool -> unit Lwt.t
      val list : t -> P2p.Connection_info.t list
      val count : t -> int
    end

    module Gid : sig
      val infos : t ->
        P2p.RPC.Gid.state list -> (P2p.Gid.t * P2p.RPC.Gid.info) list
      val info : t -> P2p.Gid.t -> P2p.RPC.Gid.info option
      val events : t -> P2p.Gid.t -> P2p.RPC.Gid.Event.t list
      val watch : t -> P2p.Gid.t ->
        P2p.RPC.Gid.Event.t Lwt_stream.t * Watcher.stopper
    end

    module Point : sig
      val infos : t ->
        P2p.RPC.Point.state list -> (P2p.Point.t * P2p.RPC.Point.info) list
      val info : t -> P2p.Point.t -> P2p.RPC.Point.info option
      val events : t -> P2p.Point.t -> P2p.RPC.Point.Event.t list
      val watch : t -> P2p.Point.t ->
        P2p.RPC.Point.Event.t Lwt_stream.t * Watcher.stopper
    end
  end
end

val shutdown: t -> unit Lwt.t
