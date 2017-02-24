(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Pool of connections. This module manages the connection pool that
    the shell needs to maintain in order to function correctly.

    A pool and its connections are parametrized by the type of
    messages exchanged over the connection and the type of
    meta-information associated with a peer. The type [('msg, 'meta)
    connection] is a wrapper on top of [P2p_connection.t] that adds
    meta-information, a data-structure describing a fine-grained state
    of the connection, as well as a new message queue (referred to
    "app message queue") that will only contain the messages from the
    internal [P2p_connection.t] that needs to be examined by the
    higher layers. Some messages are directly processed by an internal
    worker and thus never propagated above.
*)

open P2p_types
open P2p_connection_pool_types

type 'msg encoding = Encoding : {
    tag: int ;
    encoding: 'a Data_encoding.t ;
    wrap: 'a -> 'msg ;
    unwrap: 'msg -> 'a option ;
    max_length: int option ;
  } -> 'msg encoding

(** {1 Pool management} *)

type ('msg, 'meta) t

type ('msg, 'meta) pool = ('msg, 'meta) t
(** The type of a pool of connections, parametrized by resp. the type
    of messages and the meta-information associated to an identity. *)

type config = {

  identity : Identity.t ;
  (** Our identity. *)

  proof_of_work_target : Crypto_box.target ;
  (** The proof of work target we require from peers. *)

  trusted_points : Point.t list ;
  (** List of hard-coded known peers to bootstrap the network from. *)

  peers_file : string ;
  (** The path to the JSON file where the metadata associated to
      peer_ids are loaded / stored. *)

  closed_network : bool ;
  (** If [true], the only accepted connections are from peers whose
      addresses are in [trusted_peers]. *)

  listening_port : port option ;
  (** If provided, it will be passed to [P2p_connection.authenticate]
      when we authenticate against a new peer. *)

  min_connections : int ;
  (** Strict minimum number of connections
      (triggers [LogEvent.too_few_connections]). *)

  max_connections : int ;
  (** Max number of connections. If it's reached, [connect] and
      [accept] will fail, i.e. not add more connections
      (also triggers [LogEvent.too_many_connections]). *)

  max_incoming_connections : int ;
  (** Max not-yet-authentified incoming connections.
      Above this number, [accept] will start dropping incoming
      connections. *)

  authentification_timeout : float ;
  (** Delay granted to a peer to perform authentication, in seconds. *)

  incoming_app_message_queue_size : int option ;
  (** Size of the message queue for user messages (messages returned
      by this module's [read] function. *)

  incoming_message_queue_size : int option ;
  (** Size of the incoming message queue internal of a peer's Reader
      (See [P2p_connection.accept]). *)

  outgoing_message_queue_size : int option ;
  (** Size of the outgoing message queue internal to a peer's Writer
      (See [P2p_connection.accept]). *)

  known_peer_ids_history_size : int ;
  (** Size of the known peer_ids log buffer (default: 50) *)
  known_points_history_size : int ;
  (** Size of the known points log buffer (default: 50) *)

  max_known_points : (int * int) option ;
  (** Parameters for the the garbage collection of known points. If
      None, no garbage collection is performed. Otherwise, the first
      integer of the couple limits the size of the "known points"
      table. When this number is reached, the table is expurged from
      disconnected points, older first, to try to reach the amount of
      connections indicated by the second integer. *)

  max_known_peer_ids : (int * int) option ;
  (** Like [max_known_points], but for known peer_ids. *)
}

type 'meta meta_config = {
  encoding : 'meta Data_encoding.t;
  initial : 'meta;
  score : 'meta -> float;
}

type 'msg message_config = {
  encoding : 'msg encoding list ;
  versions : P2p_types.Version.t list;
}

val create:
  config ->
  'meta meta_config ->
  'msg message_config ->
  P2p_io_scheduler.t ->
  ('msg, 'meta) pool Lwt.t
(** [create config meta_cfg msg_cfg io_sched] is a freshly minted
    pool. *)

val destroy: ('msg, 'meta) pool -> unit Lwt.t
(** [destroy pool] returns when member connections are either
    disconnected or canceled. *)

val active_connections: ('msg, 'meta) pool -> int
(** [active_connections pool] is the number of connections inside
    [pool]. *)

val pool_stat: ('msg, 'meta) pool -> Stat.t
(** [pool_stat pool] is a snapshot of current bandwidth usage for the
    entire [pool]. *)

val score: ('msg, 'meta) pool -> 'meta -> float
(** [score pool meta] is the floating-point score of [meta] using
    [pool]'s metrics. *)

(** {2 Pool events} *)

module PoolEvent : sig
  val wait_too_few_connections: ('msg, 'meta) pool -> unit Lwt.t
  (** [wait_too_few_connections pool] is determined when the number of
      connections drops below the desired level. *)

  val wait_too_many_connections: ('msg, 'meta) pool -> unit Lwt.t
  (** [wait_too_many_connections pool] is determined when the number of
      connections exceeds the desired level. *)

  val wait_new_peer: ('msg, 'meta) pool -> unit Lwt.t
  (** [wait_new_peer pool] is determined when a new peer
      (i.e. authentication successful) gets added to the pool. *)

  val wait_new_connection: ('msg, 'meta) pool -> unit Lwt.t
  (** [wait_new_connection pool] is determined when a new connection is
      succesfully established in the pool. *)
end

module LogEvent : sig
  type t =
    (** Pool-level events *)

    | Too_few_connections
    | Too_many_connections

    | New_point of Point.t
    | New_peer of Peer_id.t

    (** Connection-level events *)

    | Incoming_connection of Point.t
    (** We accept(2)-ed an incoming connection *)
    | Outgoing_connection of Point.t
    (** We connect(2)-ed to a remote endpoint *)
    | Authentication_failed of Point.t
    (** Remote point failed authentication *)

    | Accepting_request of Point.t * Id_point.t * Peer_id.t
    (** We accepted a connection after authentifying the remote peer. *)
    | Rejecting_request of Point.t * Id_point.t * Peer_id.t
    (** We rejected a connection after authentifying the remote peer. *)
    | Request_rejected of Point.t * (Id_point.t * Peer_id.t) option
    (** The remote peer rejected our connection. *)

    | Connection_established of Id_point.t * Peer_id.t
    (** We succesfully established a authentified connection. *)

    | Disconnection of Peer_id.t
    (** We decided to close the connection. *)
    | External_disconnection of Peer_id.t
    (** The connection was closed for external reason. *)

    | Gc_points
    (** Garbage correction of known point table has been triggered. *)
    | Gc_peer_ids
    (** Garbage correction of known peer_ids table has been triggered. *)

  val encoding : t Data_encoding.t
end

val watch: ('msg, 'meta) pool -> LogEvent.t Lwt_stream.t * Watcher.stopper
(** [watch pool] is a [stream, close] a [stream] of events and a
    [close] function for this stream. *)

(** {1 Connections management} *)

type ('msg, 'meta) connection
(** Type of a connection to a peer, parametrized by the type of
    messages exchanged as well as meta-information associated to a
    peer. It mostly wraps [P2p_connection.connection], adding
    meta-information and data-structures describing a more
    fine-grained logical state of the connection. *)

type error += Pending_connection
type error += Connected
type error += Connection_refused
type error += Rejected of Peer_id.t
type error += Too_many_connections
type error += Closed_network

val connect:
  timeout:float ->
  ('msg, 'meta) pool -> Point.t ->
  ('msg, 'meta) connection tzresult Lwt.t
(** [connect ~timeout pool point] tries to add a
    connection to [point] in [pool] in less than [timeout] seconds. *)

val accept:
  ('msg, 'meta) pool -> Lwt_unix.file_descr -> Point.t -> unit
(** [accept pool fd point] instructs [pool] to start the process of
    accepting a connection from [fd]. Used by [P2p]. *)

val disconnect:
  ?wait:bool -> ('msg, 'meta) connection -> unit Lwt.t
(** [disconnect conn] cleanly closes [conn] and returns after [conn]'s
    internal worker has returned. *)

val connection_info: ('msg, 'meta) connection -> Connection_info.t

val connection_stat:  ('msg, 'meta) connection -> Stat.t
(** [stat conn] is a snapshot of current bandwidth usage for
    [conn]. *)

val fold_connections:
  ('msg, 'meta) pool ->
  init:'a ->
  f:(Peer_id.t ->  ('msg, 'meta) connection -> 'a -> 'a) ->
  'a

(** {1 I/O on connections} *)

type error += Connection_closed

val read:  ('msg, 'meta) connection -> 'msg tzresult Lwt.t
(** [read conn] returns a message popped from [conn]'s app message
    queue, or fails with [Connection_closed]. *)

val is_readable: ('msg, 'meta) connection -> unit tzresult Lwt.t
(** [is_readable conn] returns when there is at least one message
    ready to be read. *)

val write:  ('msg, 'meta) connection -> 'msg -> unit tzresult Lwt.t
(** [write conn msg] is [P2p_connection.write conn' msg] where [conn']
    is the internal [P2p_connection.t] inside [conn]. *)

val write_sync:  ('msg, 'meta) connection -> 'msg -> unit tzresult Lwt.t
(** [write_sync conn msg] is [P2p_connection.write_sync conn' msg]
    where [conn'] is the internal [P2p_connection.t] inside [conn]. *)

val write_now:  ('msg, 'meta) connection -> 'msg -> bool tzresult
(** [write_now conn msg] is [P2p_connection.write_now conn' msg] where
    [conn'] is the internal [P2p_connection.t] inside [conn]. *)

(** {2 Broadcast functions} *)

val write_all:  ('msg, 'meta) pool -> 'msg -> unit
(** [write_all pool msg] is [write_now conn msg] for all member
    connections to [pool] in [Running] state. *)

val broadcast_bootstrap_msg:  ('msg, 'meta) pool -> unit
(** [write_all pool msg] is [P2P_connection.write_now conn Bootstrap]
    for all member connections to [pool] in [Running] state. *)

(** {1 Functions on [Peer_id]} *)

module Peer_ids : sig

  type ('msg, 'meta) info = (('msg, 'meta) connection, 'meta) Peer_info.t

  val info:
    ('msg, 'meta) pool -> Peer_id.t -> ('msg, 'meta) info option

  val get_metadata: ('msg, 'meta) pool -> Peer_id.t -> 'meta option
  val set_metadata: ('msg, 'meta) pool -> Peer_id.t -> 'meta -> unit
  val get_score: ('msg, 'meta) pool -> Peer_id.t -> float option

  val get_trusted: ('msg, 'meta) pool -> Peer_id.t -> bool
  val set_trusted: ('msg, 'meta) pool -> Peer_id.t -> unit
  val unset_trusted: ('msg, 'meta) pool -> Peer_id.t -> unit

  val find_connection:
    ('msg, 'meta) pool -> Peer_id.t ->  ('msg, 'meta) connection option

  val fold_known:
    ('msg, 'meta) pool ->
    init:'a ->
    f:(Peer_id.t ->  ('msg, 'meta) info -> 'a -> 'a) ->
    'a

  val fold_connected:
    ('msg, 'meta) pool ->
    init:'a ->
    f:(Peer_id.t ->  ('msg, 'meta) info -> 'a -> 'a) ->
    'a

end

(** {1 Functions on [Points]} *)

module Points : sig

  type ('msg, 'meta) info = ('msg, 'meta) connection Point_info.t

  val info:
    ('msg, 'meta) pool -> Point.t -> ('msg, 'meta) info option

  val get_trusted: ('msg, 'meta) pool -> Point.t -> bool
  val set_trusted: ('msg, 'meta) pool -> Point.t -> unit
  val unset_trusted: ('msg, 'meta) pool -> Point.t -> unit

  val find_connection:
    ('msg, 'meta) pool -> Point.t ->  ('msg, 'meta) connection option

  val fold_known:
    ('msg, 'meta) pool ->
    init:'a ->
    f:(Point.t -> ('msg, 'meta) info  -> 'a -> 'a) ->
    'a

  val fold_connected:
    ('msg, 'meta) pool ->
    init:'a ->
    f:(Point.t -> ('msg, 'meta) info  -> 'a -> 'a) ->
    'a

end

(**/**)

module Message : sig

  type 'msg t =
    | Bootstrap
    | Advertise of Point.t list
    | Message of 'msg
    | Disconnect

  val encoding: 'msg encoding list -> 'msg t Data_encoding.t

end
