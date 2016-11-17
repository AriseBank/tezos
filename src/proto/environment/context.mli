(** View over the context store, restricted to types, access and
    functional manipulation of an existing context. *)

open Hash

include Persist.STORE

val get_genesis_time: t -> Time.t Lwt.t
val get_genesis_block: t -> Block_hash.t Lwt.t

val register_resolver:
  'a Base48.encoding -> (t -> string -> 'a list Lwt.t) -> unit

val complete:
  ?alphabet:string -> t -> string -> string list Lwt.t
