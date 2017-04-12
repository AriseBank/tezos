(** View over the context store, restricted to types, access and
    functional manipulation of an existing context. *)

open Hash

include Persist.STORE

val register_resolver:
  'a Base58.encoding -> (t -> string -> 'a list Lwt.t) -> unit

val complete: t -> string -> string list Lwt.t
