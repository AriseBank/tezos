(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Tezos protocol 1234abc1212 - untyped script representation *)

type location =
  int

type expr =
  | Int of location * string
  | String of location * string
  | Prim of location * string * expr list
  | Seq of location * expr list

type code =
  { code : expr ;
    arg_type : expr ;
    ret_type : expr ;
    storage_type : expr }

type storage =
  { storage : expr ;
    storage_type : expr }

type t =
  | No_script
  | Script of {
      code: code ;
      storage: storage ;
    }

val location_encoding : location Data_encoding.t
val expr_encoding : expr Data_encoding.t
val storage_encoding : storage Data_encoding.t
val code_encoding : code Data_encoding.t
val encoding : t Data_encoding.t

val storage_cost : storage -> Tez_repr.tez
val code_cost : code -> Tez_repr.tez

val hash_expr : expr -> string
