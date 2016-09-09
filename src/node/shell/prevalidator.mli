(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** The prevalidation worker is in charge of the "mempool" (a.k.a. the
    set of known not-invalid-for-sure operations that are not yet
    included in the blockchain).

    The worker also maintains a sorted subset of the mempool that
    might correspond to a valid block on top of the current head. The
    "in-progress" context produced by the application of those
    operations is called the (pre)validation context.

    Before to include an operation into the mempool, the prevalidation
    worker tries to append the operation the prevalidation context. If
    the operation is (strongly) refused, it will not be added into the
    mempool and then it will be ignored by the node and never
    broadcasted. If the operation is only "branch_refused" or
    "branch_delayed", the operation won't be appended in the
    prevalidation context, but still broadcasted.

*)

type t

(** Creation and destruction of a "prevalidation" worker. *)
val create: P2p.net -> State.Net.t -> t Lwt.t
val shutdown: t -> unit Lwt.t

(** Notify the prevalidator of a new operation. This is the
    entry-point used by the P2P layer. The operation content has been
    previously stored on disk. *)
val register_operation: t -> Operation_hash.t -> unit

(** Conditionnaly inject a new operation in the node: the operation will
    be ignored when it is (strongly) refused This is the
    entry-point used by the P2P layer. The operation content has been
    previously stored on disk. *)
val inject_operation:
  t -> ?force:bool -> Store.operation -> unit tzresult Lwt.t

val flush: t -> unit
val timestamp: t -> Time.t
val operations: t -> error Updater.preapply_result * Operation_hash_set.t
val context: t -> Context.t
val protocol: t -> (module Updater.REGISTRED_PROTOCOL)

val preapply:
  State.state -> Context.t -> (module Updater.REGISTRED_PROTOCOL) ->
  Block_hash.t -> Time.t -> bool -> Operation_hash.t list ->
  (Context.t * error Updater.preapply_result) tzresult Lwt.t
