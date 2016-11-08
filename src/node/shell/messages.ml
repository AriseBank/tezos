(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Netbits

type net_id = Store.net_id

type message =

  | Discover_blocks of net_id * Block_hash.t list (* Block locator *)
  | Block_inventory of net_id * Block_hash.t list

  | Get_blocks of Block_hash.t list
  | Block of MBytes.t

  | Current_operations of net_id
  | Operation_inventory of net_id * Operation_hash.t list

  | Get_operations of Operation_hash.t list
  | Operation of MBytes.t

  | Get_protocols of Protocol_hash.t list
  | Protocol of MBytes.t


let to_frame msg =

  let bh h = B (Block_hash.to_bytes h) in
  let oph h = B (Operation_hash.to_bytes h) in
  let ph h = B (Protocol_hash.to_bytes h) in
  match msg with

  | Discover_blocks (Net netid, blocks) ->
      [ S 2100 ; bh netid ; F (List.map bh blocks) ]
  | Block_inventory (Net netid, blocks) ->
      [ S 2101 ; bh netid ; F (List.map bh blocks) ]
  | Get_blocks blocks ->
      [ S 2102 ; F (List.map bh blocks) ]
  | Block b ->
      [ S 2103 ; B b ]

  | Current_operations (Net net_id) ->
      [ S 2700 ; bh net_id ]
  | Operation_inventory (Net net_id, ops) ->
      [ S 2701 ; bh net_id ; F (List.map oph ops) ]
  | Get_operations ops ->
      [ S 2702 ; F (List.map oph ops) ]
  | Operation b ->
      [ S 2703 ; B b ]

  | Get_protocols protos ->
      [ S 2800 ; F (List.map ph protos) ]
  | Protocol p ->
      [ S 2801 ; B p ]

let from_frame msg =

  let bh = function B s -> (Block_hash.of_bytes s) | _ -> invalid_arg "bh" in
  let oph = function B s -> (Operation_hash.of_bytes s) | _ -> invalid_arg "oph" in
  let ph = function B s -> (Protocol_hash.of_bytes s) | _ -> invalid_arg "ph" in
  let net = function netid -> Store.Net (Block_hash.of_bytes netid) in
  try match msg with

    | [ S 2100 ; B netid ; F blocks ] ->
        Some (Discover_blocks (net netid, List.map bh blocks))
    | [ S 2101 ; B netid ; F blocks ] ->
        Some (Block_inventory (net netid, List.map bh blocks))
    | [ S 2102 ; F blocks ] ->
        Some (Get_blocks (List.map bh blocks))
    | [ S 2103 ; B bh ] -> Some (Block bh)
    | [ S 2700 ; B netid ] ->
        Some (Current_operations (net netid))
    | [ S 2701 ; B netid ; F ops ] ->
        Some (Operation_inventory (net netid, List.map oph ops))
    | [ S 2702 ; F ops ] ->
        Some (Get_operations (List.map oph ops))
    | [ S 2703 ; B contents ] -> Some (Operation contents)

    | [ S 2800 ; F protos ] -> Some (Get_protocols (List.map ph protos))

    | [ S 2801 ; B contents ] -> Some (Protocol contents)

    | _ -> None

  with Invalid_argument _ -> None

