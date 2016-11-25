(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Utils

(** Tezos - X25519/XSalsa20-Poly1305 cryptography *)

type secret_key = Sodium.Box.secret_key
type public_key = Sodium.Box.public_key
type channel_key = Sodium.Box.channel_key
type nonce = Sodium.Box.nonce
type target = int64 list (* used as unsigned intergers... *)
exception TargetNot256Bit

let random_keypair = Sodium.Box.random_keypair
let random_nonce = Sodium.Box.random_nonce
let increment_nonce = Sodium.Box.increment_nonce
let box = Sodium.Box.Bigbytes.box
let box_open sk pk msg nonce =
  try Some (Sodium.Box.Bigbytes.box_open sk pk msg nonce) with
    | Sodium.Verification_failure -> None

let make_target target =
  if List.length target > 8 then raise TargetNot256Bit ;
  target

(* Compare a SHA256 hash to a 256bits-target prefix.
   The prefix is a list of "unsigned" int64. *)
let compare_target hash target =
  let rec check offset = function
    | [] -> true
    | x :: xs ->
        Compare.Uint64.(EndianString.BigEndian.get_int64 hash offset < x)
        && check (offset + 8) xs in
  check 0 target

let default_target =
  (* FIXME we use an easy target until we allow custom configuration. *)
  [ Int64.shift_left 1L 48 ]

let check_proof_of_work pk nonce target =
  let hash =
    let hash = Cryptokit.Hash.sha256 () in
    hash#add_string (Bytes.to_string @@ Sodium.Box.Bytes.of_public_key pk) ;
    hash#add_string (Bytes.to_string @@ Sodium.Box.Bytes.of_nonce nonce) ;
    let r = hash#result in hash#wipe ; r in
  compare_target hash target

let generate_proof_of_work pk target =
  let rec loop nonce =
    if check_proof_of_work pk nonce target then nonce
    else loop (increment_nonce nonce) in
  loop (random_nonce ())

let public_key_encoding =
  let open Data_encoding in
    conv
      Sodium.Box.Bigbytes.of_public_key
      Sodium.Box.Bigbytes.to_public_key
      (Fixed.bytes Sodium.Box.public_key_size)

let secret_key_encoding =
  let open Data_encoding in
    conv
      Sodium.Box.Bigbytes.of_secret_key
      Sodium.Box.Bigbytes.to_secret_key
      (Fixed.bytes Sodium.Box.secret_key_size)

let nonce_encoding =
  let open Data_encoding in
    conv
      Sodium.Box.Bigbytes.of_nonce
      Sodium.Box.Bigbytes.to_nonce
      (Fixed.bytes Sodium.Box.nonce_size)
