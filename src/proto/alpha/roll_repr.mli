(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

type t
type roll = t

val encoding: roll Data_encoding.t

val random:
  Seed_repr.sequence -> bound:roll -> roll * Seed_repr.sequence

val first: roll
val succ: roll -> roll

val to_int32: roll -> Int32.t

val (=): roll -> roll -> bool
