(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

type t
type cycle = t
include Compare.S with type t := t
val encoding: cycle Data_encoding.t
val arg: cycle RPC.Arg.arg
val pp: Format.formatter -> cycle -> unit

val root: cycle
val pred: cycle -> cycle option
val succ: cycle -> cycle

val to_int32: cycle -> int32
val of_int32_exn: int32 -> cycle
