(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Store_sigs

type t
type global_store = t

(** Open or initialize a store at a given path. *)
val init: string -> t tzresult Lwt.t


(** {2 Net store} ************************************************************)

module Net_id : sig

  type t = Id of Block_hash.t
  type net_id = t
  val encoding: net_id Data_encoding.t
  val pp: Format.formatter -> net_id -> unit
  val compare: net_id -> net_id -> int
  val equal: net_id -> net_id -> bool

  val of_bytes_exn: MBytes.t -> net_id
  val to_bytes: net_id -> MBytes.t

  module Set : Set.S with type elt = t
  module Map : Map.S with type key = t
  module Table : Hashtbl.S with type key = t

end

module Net : sig

  val list: global_store -> Net_id.t list Lwt.t
  val destroy: global_store -> Net_id.t -> unit Lwt.t

  type store
  val get: global_store -> Net_id.t -> store

  module Genesis_time : SINGLE_STORE
    with type t := store
     and type value := Time.t

  module Genesis_protocol : SINGLE_STORE
    with type t := store
     and type value := Protocol_hash.t

  module Genesis_test_protocol : SINGLE_STORE
    with type t := store
     and type value := Protocol_hash.t

  module Expiration : SINGLE_STORE
    with type t := store
     and type value := Time.t

  module Forked_network_ttl : SINGLE_STORE
    with type t := store
     and type value := Int64.t

end


(** {2 Chain data} ***********************************************************)

module Chain : sig

  type store
  val get: Net.store -> store

  module Current_head : SINGLE_STORE
    with type t := store
     and type value := Block_hash.t

  module Known_heads : BUFFERED_SET_STORE
    with type t := store
     and type elt := Block_hash.t
     and module Set := Block_hash.Set

  module Valid_successors : BUFFERED_SET_STORE
    with type t = store * Block_hash.t
     and type elt := Block_hash.t
     and module Set := Block_hash.Set

  module Invalid_successors : BUFFERED_SET_STORE
    with type t = store * Block_hash.t
     and type elt := Block_hash.t
     and module Set := Block_hash.Set

  module Successor_in_chain : SINGLE_STORE
    with type t = store * Block_hash.t
     and type value := Block_hash.t

  module In_chain_insertion_time : SINGLE_STORE
    with type t = store * Block_hash.t
     and type value := Time.t

end


(** {2 Generic signature} *****************************************************)

(** Generic signature for Operations, Block_header, and Protocol "tracked"
    contents (i.e. with 'discovery_time', 'validtity', ...) *)
module type DATA_STORE = sig

  type store
  type key
  type key_set
  type value

  val encoding: value Data_encoding.t

  val compare: value -> value -> int
  val equal: value -> value -> bool

  val hash: value -> key
  val hash_raw: MBytes.t -> key

  module Discovery_time : MAP_STORE
    with type t := store
     and type key := key
     and type value := Time.t

  module Contents : SINGLE_STORE
    with type t = store * key
     and type value := value

  module RawContents : SINGLE_STORE
    with type t = store * key
     and type value := MBytes.t

  module Validation_time : SINGLE_STORE
    with type t = store * key
     and type value := Time.t

  module Errors : MAP_STORE
    with type t := store
     and type key := key
     and type value = error list

  module Pending : BUFFERED_SET_STORE
    with type t = store
     and type elt := key
     and type Set.t = key_set

end


(** {2 Operation store} *****************************************************)

module Operation : sig

  type shell_header = {
    net_id: Net_id.t ;
  }
  val shell_header_encoding: shell_header Data_encoding.t

  type t = {
    shell: shell_header ;
    proto: MBytes.t ;
  }

  type store
  val get: Net.store -> store

  include DATA_STORE
    with type store := store
     and type key = Operation_hash.t
     and type value = t
     and type key_set = Operation_hash.Set.t

end


(** {2 Block header store} **************************************************)

module Block_header : sig

  type shell_header = {
    net_id: Net_id.t ;
    predecessor: Block_hash.t ;
    timestamp: Time.t ;
    fitness: MBytes.t list ;
    operations: Operation_hash.t list ;
  }
  val shell_header_encoding: shell_header Data_encoding.t

  type t = {
    shell: shell_header ;
    proto: MBytes.t ;
  }

  type store
  val get: Net.store -> store

  include DATA_STORE
    with type store := store
     and type key = Block_hash.t
     and type value = t
     and type key_set = Block_hash.Set.t

end


(** {2 Protocol store} ******************************************************)

module Protocol : sig

  type t = Tezos_compiler.Protocol.t

  type store
  val get: global_store -> store

  include DATA_STORE
    with type store := store
     and type key = Protocol_hash.t
     and type value = t
     and type key_set = Protocol_hash.Set.t

end
