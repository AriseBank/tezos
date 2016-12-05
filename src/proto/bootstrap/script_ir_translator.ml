(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Tezos_context
open Script_int
open Script
open Script_typed_ir

(* ---- Error reporting -----------------------------------------------------*)

(* Boxed existentials types to put in exception constructors *)
type stack_ty_val = Stack_ty : _ stack_ty -> stack_ty_val
type ty_val =
  | Ty : _ ty -> ty_val
  | Comparable_ty : _ comparable_ty -> ty_val
type int_kind_val = Int_kind : (_, _) int_kind -> int_kind_val

type kind = Type | Constant | Instr

(* Structure errors *)
type error += Invalid_arity of Script.location * kind * string * int * int
type error += Invalid_constant of Script.location * string
type error += Invalid_primitive of Script.location * kind * string
type error += Invalid_expression_kind of Script.location (* TODO: expected *)
type error += Sequence_parameter_expected of Script.location * kind * string * int
type error += Fail_not_in_tail_position of Script.location

(* Instruction errors *)
type error += Comparable_type_expected of Script.location
type error += Undefined_cast of Script.location * ty_val * ty_val
type error += Undefined_binop of Script.location * string * ty_val * ty_val
type error += Undefined_unop of Script.location * string * ty_val
type error += Bad_return of Script.location * stack_ty_val * ty_val
type error += Bad_stack of Script.location * int * stack_ty_val
type error += Unmatched_branches of Script.location * stack_ty_val * stack_ty_val
type error += Bad_stack_item of Script.location * int
type error += Transfer_in_lambda of Script.location

(* Value typing errors *)
type error += Inconsistent_ints of int_kind_val * int_kind_val
type error += Inconsistent_types of ty_val * ty_val
type error += Inconsistent_stack_lengths
type error += Inconsistent_stack_items of int
type error += Incomparable_type of ty_val
type error += Bad_sign of int_kind_val
type error += Invalid_contract of Script.location * Contract.t

let () =
  let open Data_encoding in
  register_error_kind
    `Permanent
    ~id:"InvalidContractError"
    ~title: "Invalid contract"
    ~description:
      "A script or RPC tried to reference a contract that does not \
       exists or assumed a wrong type for an existing contract"
    (obj2
       (req "location" Script.location_encoding)
       (req "contract" Contract.encoding))
    (function Invalid_contract (loc, c) -> Some (loc, c) | _ -> None)
    (fun (loc, c) -> Invalid_contract (loc, c))

let location = function
  | Prim (loc, _, _)
  | Int (loc, _)
  | String (loc, _)
  | Seq (loc, _) -> loc

let expect_sequence_parameter loc kind prim pos = function
  | Script.Seq _ -> return ()
  | _ -> fail (Sequence_parameter_expected (loc, kind, prim, pos))

(* ---- Equality witnesses --------------------------------------------------*)

type ('ta, 'tb) eq =
  | Eq : 'same * 'same -> ('same, 'same) eq

let eq
  : type t. t -> t -> (t, t) eq tzresult
  = fun ta tb -> Ok (Eq (ta, tb))

let int_kind_eq
  : type sa la sb lb. (sa, la) int_kind -> (sb, lb) int_kind ->
    ((sa, la) int_kind, (sb, lb) int_kind) eq tzresult
  = fun ka kb -> match ka, kb with
    | Int8, Int8 -> eq ka kb
    | Uint8, Uint8 -> eq ka kb
    | Int16, Int16 -> eq ka kb
    | Uint16, Uint16 -> eq ka kb
    | Int32, Int32 -> eq ka kb
    | Uint32, Uint32 -> eq ka kb
    | Int64, Int64 -> eq ka kb
    | Uint64, Uint64 -> eq ka kb
    | _ -> error @@ Inconsistent_ints (Int_kind ka, Int_kind kb)

let unsigned_int_kind
  : type sa la. (sa, la) int_kind -> (sa, unsigned) eq tzresult
  = fun kind -> match kind with
    | Uint8 -> eq Unsigned Unsigned
    | Uint16 -> eq Unsigned Unsigned
    | Uint32 -> eq Unsigned Unsigned
    | Uint64 -> eq Unsigned Unsigned
    | _ -> error @@ Bad_sign (Int_kind kind)

let signed_int_kind
  : type sa la. (sa, la) int_kind -> (sa, signed) eq tzresult
  = fun kind -> match kind with
    | Int8 -> eq Signed Signed
    | Int16 -> eq Signed Signed
    | Int32 -> eq Signed Signed
    | Int64 -> eq Signed Signed
    | _ -> error @@ Bad_sign (Int_kind kind)

let comparable_ty_eq
  : type ta tb.
    ta comparable_ty -> tb comparable_ty ->
    (ta comparable_ty, tb comparable_ty) eq tzresult
  = fun ta tb -> match ta, tb with
    | Int_key ka, Int_key kb ->
        record_trace (Inconsistent_types (Comparable_ty ta, Comparable_ty tb)) @@
        int_kind_eq ka kb >>? fun (Eq _) ->
        (eq ta tb : (ta comparable_ty, tb comparable_ty) eq tzresult)
    | String_key, String_key -> eq ta tb
    | Tez_key, Tez_key -> eq ta tb
    | Bool_key, Bool_key -> eq ta tb
    | Key_key, Key_key -> eq ta tb
    | Timestamp_key, Timestamp_key -> eq ta tb
    | _, _ -> error (Inconsistent_types (Comparable_ty ta, Comparable_ty tb))

let rec ty_eq
  : type ta tb. ta ty -> tb ty -> (ta ty, tb ty) eq tzresult
  = fun ta tb ->
    match ta, tb with
    | Void_t, Void_t -> eq ta tb
    | Int_t ka, Int_t kb ->
        (int_kind_eq ka kb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Key_t, Key_t -> eq ta tb
    | String_t, String_t -> eq ta tb
    | Signature_t, Signature_t -> eq ta tb
    | Tez_t, Tez_t -> eq ta tb
    | Timestamp_t, Timestamp_t -> eq ta tb
    | Bool_t, Bool_t -> eq ta tb
    | Map_t (tal, tar), Map_t (tbl, tbr) ->
        (comparable_ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Set_t ea, Set_t eb ->
        (comparable_ty_eq ea eb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Pair_t (tal, tar), Pair_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Union_t (tal, tar), Union_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Lambda_t (tal, tar), Lambda_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Contract_t (tal, tar), Contract_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | Option_t tva, Option_t tvb ->
        (ty_eq tva tvb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | List_t tva, List_t tvb ->
        (ty_eq tva tvb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (Ty ta, Ty tb))
    | _, _ -> error (Inconsistent_types (Ty ta, Ty tb))

let rec stack_ty_eq
  : type ta tb. int -> ta stack_ty -> tb stack_ty ->
    (ta stack_ty, tb stack_ty) eq tzresult = fun lvl ta tb ->
  match ta, tb with
  | Item_t (tva, ra), Item_t (tvb, rb) ->
      ty_eq tva tvb |>
      record_trace (Inconsistent_stack_items lvl) >>? fun  (Eq _) ->
      stack_ty_eq (lvl + 1) ra rb >>? fun (Eq _) ->
      (eq ta tb : (ta stack_ty, tb stack_ty) eq tzresult)
  | Empty_t, Empty_t -> eq ta tb
  | _, _ -> error Inconsistent_stack_lengths

(* ---- Sets and Maps -------------------------------------------------------*)

let compare_comparable
  : type a. a comparable_ty -> a -> a -> int
  = fun kind x y -> match kind with
    | String_key -> Compare.String.compare x y
    | Bool_key -> Compare.Bool.compare x y
    | Tez_key -> Tez.compare x y
    | Key_key -> Ed25519.Public_key_hash.compare x y
    | Int_key kind ->
        let res =
          Script_int.to_int64 Script_int.Int64
            (Script_int.compare kind x y) in
        if Compare.Int64.(res = 0L) then 0
        else if Compare.Int64.(res > 0L) then 1
        else -1
    | Timestamp_key -> Timestamp.compare x y

let empty_set
  : type a. a comparable_ty -> a set
  = fun ty ->
    let module OPS = Set.Make (struct
        type t = a
        let compare = compare_comparable ty
      end) in
    (module struct
      type elt = a
      module OPS = OPS
      let boxed = OPS.empty
    end)

let set_update
  : type a. a -> bool -> a set -> a set
  = fun v b (module Box) ->
    (module struct
      type elt = a
      module OPS = Box.OPS
      let boxed =
        if b then
          Box.OPS.add v Box.boxed
        else
          Box.OPS.remove v Box.boxed
    end)

let set_mem
  : type elt. elt -> elt set -> bool
  = fun v (module Box) ->
    Box.OPS.mem v Box.boxed

let set_fold
  : type elt acc. (elt -> acc -> acc) -> elt set -> acc -> acc
  = fun f (module Box) ->
    Box.OPS.fold f Box.boxed

let map_key_ty
  : type a b. (a, b) map -> a comparable_ty
  = fun (module Box) -> Box.key_ty

let empty_map
  : type a b. a comparable_ty -> (a, b) map
  = fun ty ->
    let module OPS = Map.Make (struct
        type t = a
        let compare = compare_comparable ty
      end) in
    (module struct
      type key = a
      type value = b
      let key_ty = ty
      module OPS = OPS
      let boxed = OPS.empty
    end)

let map_get
  : type key value. key -> (key, value) map -> value option
  = fun k (module Box) ->
    try Some (Box.OPS.find k Box.boxed) with Not_found -> None

let map_update
  : type a b. a -> b option -> (a, b) map -> (a, b) map
  = fun k v (module Box) ->
    (module struct
      type key = a
      type value = b
      let key_ty = Box.key_ty
      module OPS = Box.OPS
      let boxed =
        match v with
        | Some v -> Box.OPS.add k v Box.boxed
        | None -> Box.OPS.remove k Box.boxed
    end)

let map_mem
  : type key value. key -> (key, value) map -> bool
  = fun k (module Box) ->
    Box.OPS.mem k Box.boxed

let map_fold
  : type key value acc. (key -> value -> acc -> acc) -> (key, value) map -> acc -> acc
  = fun f (module Box) ->
    Box.OPS.fold f Box.boxed

(* ---- Type checker resuls -------------------------------------------------*)

type 'bef judgement =
  | Typed : ('bef, 'aft) descr -> 'bef judgement
  | Failed : { descr : 'aft. 'aft stack_ty -> ('bef, 'aft) descr } -> 'bef judgement

(* ---- type checker --------------------------------------------------------*)

type ('t, 'f, 'b) branch =
  { branch : 'r. ('t, 'r) descr -> ('f, 'r) descr -> ('b, 'r) descr } [@@unboxed]

let merge_branches
  : type bef a b. int -> a judgement -> b judgement ->
    (a, b, bef) branch ->
    bef judgement tzresult Lwt.t
  = fun loc btr bfr { branch } ->
    match btr, bfr with
    | Typed ({ aft = aftbt } as dbt), Typed ({ aft = aftbf } as dbf) ->
        trace
          (Unmatched_branches (loc, Stack_ty aftbt, Stack_ty aftbf))
          (Lwt.return (stack_ty_eq 0 aftbt aftbf)) >>=? fun (Eq _) ->
        return (Typed (branch dbt dbf))
    | Failed { descr = descrt }, Failed { descr = descrf } ->
        let descr ret =
          branch (descrt ret) (descrf ret) in
        return (Failed { descr })
    | Typed dbt, Failed { descr = descrf } ->
        return (Typed (branch dbt (descrf dbt.aft)))
    | Failed { descr = descrt }, Typed dbf ->
        return (Typed (branch (descrt dbf.aft) dbf))

type ex_comparable_ty = Ex : 'a comparable_ty -> ex_comparable_ty

let parse_comparable_ty : Script.expr -> ex_comparable_ty tzresult Lwt.t = function
  | Prim (_, "int8", []) -> return @@ Ex (Int_key Int8)
  | Prim (_, "int16", []) -> return @@ Ex (Int_key Int16)
  | Prim (_, "int32", []) -> return @@ Ex (Int_key Int32)
  | Prim (_, "int64", []) -> return @@ Ex (Int_key Int64)
  | Prim (_, "uint8", []) -> return @@ Ex (Int_key Uint8)
  | Prim (_, "uint16", []) -> return @@ Ex (Int_key Uint16)
  | Prim (_, "uint32", []) -> return @@ Ex (Int_key Uint32)
  | Prim (_, "uint64", []) -> return @@ Ex (Int_key Uint64)
  | Prim (_, "string", []) -> return @@ Ex String_key
  | Prim (_, "tez", []) -> return @@ Ex Tez_key
  | Prim (_, "bool", []) -> return @@ Ex Bool_key
  | Prim (_, "key", []) -> return @@ Ex Key_key
  | Prim (_, "timestamp", []) -> return @@ Ex Timestamp_key
  | Prim (loc, ("int8" | "int16" | "int32" | "int64"
               | "uint8" | "uint16" | "uint32" | "uint64"
               | "string" | "tez" | "bool"
               | "key" | "timestamp" as prim), l) ->
      fail @@ Invalid_arity (loc, Type, prim, 0, List.length l)
  | Prim (loc, ("pair" | "union" | "set" | "map"
               | "list" | "ref"  | "option"  | "lambda"
               | "void" | "signature"  | "contract"), _) ->
      fail @@ Comparable_type_expected loc
  | Prim (loc, prim, _) ->
      fail @@ Invalid_primitive (loc, Type, prim)
  | Int (loc, _) | String (loc, _) | Seq (loc, _)  ->
      fail @@ Invalid_expression_kind loc

type ex_ty = Ex : 'a ty -> ex_ty

let rec parse_ty : Script.expr -> ex_ty tzresult Lwt.t = function
  | Prim (_, "void", []) -> return @@ Ex Void_t
  | Prim (_, "int8", []) -> return @@ Ex (Int_t Int8)
  | Prim (_, "int16", []) -> return @@ Ex (Int_t Int16)
  | Prim (_, "int32", []) -> return @@ Ex (Int_t Int32)
  | Prim (_, "int64", []) -> return @@ Ex (Int_t Int64)
  | Prim (_, "uint8", []) -> return @@ Ex (Int_t Uint8)
  | Prim (_, "uint16", []) -> return @@ Ex (Int_t Uint16)
  | Prim (_, "uint32", []) -> return @@ Ex (Int_t Uint32)
  | Prim (_, "uint64", []) -> return @@ Ex (Int_t Uint64)
  | Prim (_, "string", []) -> return @@ Ex String_t
  | Prim (_, "tez", []) -> return @@ Ex Tez_t
  | Prim (_, "bool", []) -> return @@ Ex Bool_t
  | Prim (_, "key", []) -> return @@ Ex Key_t
  | Prim (_, "timestamp", []) -> return @@ Ex Timestamp_t
  | Prim (_, "signature", []) -> return @@ Ex Signature_t
  | Prim (_, "contract", [ utl; utr ]) ->
      parse_ty utl >>=? fun (Ex tl) ->
      parse_ty utr >>=? fun (Ex tr) ->
      return @@ Ex (Contract_t (tl, tr))
  | Prim (_, "pair", [ utl; utr ]) ->
      parse_ty utl >>=? fun (Ex tl) ->
      parse_ty utr >>=? fun (Ex tr) ->
      return @@ Ex (Pair_t (tl, tr))
  | Prim (_, "union", [ utl; utr ]) ->
      parse_ty utl >>=? fun (Ex tl) ->
      parse_ty utr >>=? fun (Ex tr) ->
      return @@ Ex (Union_t (tl, tr))
  | Prim (_, "lambda", [ uta; utr ]) ->
      parse_ty uta >>=? fun (Ex ta) ->
      parse_ty utr >>=? fun (Ex tr) ->
      return @@ Ex (Lambda_t (ta, tr))
  | Prim (_, "option", [ ut ]) ->
      parse_ty ut >>=? fun (Ex t) ->
      return @@ Ex (Option_t t)
  | Prim (_, "list", [ ut ]) ->
      parse_ty ut >>=? fun (Ex t) ->
      return @@ Ex (List_t t)
  | Prim (_, "set", [ ut ]) ->
      parse_comparable_ty ut >>=? fun (Ex t) ->
      return @@ Ex (Set_t t)
  | Prim (_, "map", [ uta; utr ]) ->
      parse_comparable_ty uta >>=? fun (Ex ta) ->
      parse_ty utr >>=? fun (Ex tr) ->
      return @@ Ex (Map_t (ta, tr))
  | Prim (loc, ("pair" | "union" | "set" | "map"
               | "list" | "ref"  | "option"  | "lambda"
               | "void" | "signature"  | "contract"
               | "int8" | "int16" | "int32" | "int64"
               | "uint8" | "uint16" | "uint32" | "uint64"
               | "string" | "tez" | "bool"
               | "key" | "timestamp" as prim), l) ->
      fail @@ Invalid_arity (loc, Type, prim, 0, List.length l)
  | Prim (loc, prim, _) ->
      fail @@ Invalid_primitive (loc, Type, prim)
  | Int (loc, _) | String (loc, _) | Seq (loc, _)  ->
      fail @@ Invalid_expression_kind loc

let ty_of_comparable_ty
  : type a. a comparable_ty -> a ty = function
  | Int_key k -> Int_t k
  | String_key -> String_t
  | Tez_key -> Tez_t
  | Bool_key -> Bool_t
  | Key_key -> Key_t
  | Timestamp_key -> Timestamp_t

let comparable_ty_of_ty
  : type a. a ty -> a comparable_ty tzresult = function
  | Int_t k -> ok (Int_key k)
  | String_t -> ok String_key
  | Tez_t -> ok Tez_key
  | Bool_t -> ok Bool_key
  | Key_t -> ok Key_key
  | Timestamp_t -> ok Timestamp_key
  | ty -> error (Incomparable_type (Ty ty))

type ex_tagged_data = Ex : 'a ty * 'a -> ex_tagged_data

let rec parse_tagged_data
  : context -> Script.expr -> ex_tagged_data tzresult Lwt.t
  = fun ctxt script_data ->
    match script_data with
    | Prim (_, "void", []) ->
        return @@ Ex (Void_t, ())
    | Prim (loc, "void", l) ->
        fail @@ Invalid_arity (loc, Constant, "void", 0, List.length l)
    | String (_, v) ->
        return @@ Ex (String_t, v)
    | Prim (_, "string", [ arg ]) ->
        parse_untagged_data ctxt String_t arg >>=? fun v ->
        return @@ Ex (String_t, v)
    | Prim (loc, "string", l) ->
        fail @@ Invalid_arity (loc, Constant, "string", 1, List.length l)
    | Prim (_, "true", []) ->
        return @@ Ex (Bool_t, true)
    | Prim (loc, "true", l) ->
        fail @@ Invalid_arity (loc, Constant, "true", 0, List.length l)
    | Prim (_, "false", []) ->
        return @@ Ex (Bool_t, false)
    | Prim (loc, "false", l) ->
        fail @@ Invalid_arity (loc, Constant, "false", 0, List.length l)
    | Prim (_, "bool", [ arg ]) ->
        parse_untagged_data ctxt Bool_t arg >>=? fun v ->
        return @@ Ex (Bool_t, v)
    | Prim (loc, "bool", l) ->
        fail @@ Invalid_arity (loc, Constant, "bool", 1, List.length l)
    | Prim (_, "timestamp", [ arg ]) ->
        parse_untagged_data ctxt Timestamp_t arg >>=? fun v ->
        return @@ Ex (Timestamp_t, v)
    | Prim (loc, "timestamp", l) ->
        fail @@ Invalid_arity (loc, Constant, "timestamp", 1, List.length l)
    | Prim (_, "signature", [ arg ]) ->
        parse_untagged_data ctxt Signature_t arg >>=? fun v ->
        return @@ Ex (Signature_t, v)
    | Prim (loc, "signature", l) ->
        fail @@ Invalid_arity (loc, Constant, "signature", 1, List.length l)
    | Prim (_, "tez", [ arg ]) ->
        parse_untagged_data ctxt Tez_t arg >>=? fun v ->
        return @@ Ex (Tez_t, v)
    | Prim (loc, "tez", l) ->
        fail @@ Invalid_arity (loc, Constant, "tez", 1, List.length l)
    | Prim (_, "key", [ arg ]) ->
        parse_untagged_data ctxt Key_t arg >>=? fun v ->
        return @@ Ex (Key_t, v)
    | Prim (loc, "key", l) ->
        fail @@ Invalid_arity (loc, Constant, "key", 1, List.length l)
    | Prim (_, "int8", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Int8) arg >>=? fun v ->
        return @@ Ex (Int_t Int8, v)
    | Prim (loc, "int8", l) ->
        fail @@ Invalid_arity (loc, Constant, "int8", 1, List.length l)
    | Prim (_, "int16", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Int16) arg >>=? fun v ->
        return @@ Ex (Int_t Int16, v)
    | Prim (loc, "int16", l) ->
        fail @@ Invalid_arity (loc, Constant, "int16", 1, List.length l)
    | Prim (_, "int32", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Int32) arg >>=? fun v ->
        return @@ Ex (Int_t Int32, v)
    | Prim (loc, "int32", l) ->
        fail @@ Invalid_arity (loc, Constant, "int32", 1, List.length l)
    | Prim (_, "int64", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Int64) arg >>=? fun v ->
        return @@ Ex (Int_t Int64, v)
    | Prim (loc, "int64", l) ->
        fail @@ Invalid_arity (loc, Constant, "int64", 1, List.length l)
    | Prim (_, "uint8", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Uint8) arg >>=? fun v ->
        return @@ Ex (Int_t Uint8, v)
    | Prim (loc, "uint8", l) ->
        fail @@ Invalid_arity (loc, Constant, "uint8", 1, List.length l)
    | Prim (_, "uint16", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Uint16) arg >>=? fun v ->
        return @@ Ex (Int_t Uint16, v)
    | Prim (loc, "uint16", l) ->
        fail @@ Invalid_arity (loc, Constant, "uint16", 1, List.length l)
    | Prim (_, "uint32", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Uint32) arg >>=? fun v ->
        return @@ Ex (Int_t Uint32, v)
    | Prim (loc, "uint32", l) ->
        fail @@ Invalid_arity (loc, Constant, "uint32", 1, List.length l)
    | Prim (_, "uint64", [ arg ]) ->
        parse_untagged_data ctxt (Int_t Uint64) arg >>=? fun v ->
        return @@ Ex (Int_t Uint64, v)
    | Prim (loc, "uint64", l) ->
        fail @@ Invalid_arity (loc, Constant, "uint64", 1, List.length l)
    | Prim (_, "left", [ l; tr ]) ->
        parse_ty tr >>=? fun (Ex tr) ->
        parse_tagged_data ctxt l >>=? fun (Ex (tl, l)) ->
        return @@ Ex (Union_t (tl, tr), L l)
    | Prim (loc, "left", l) ->
        fail @@ Invalid_arity (loc, Constant, "left", 2, List.length l)
    | Prim (_, "right", [ tl; r ]) ->
        parse_ty tl >>=? fun (Ex tl) ->
        parse_tagged_data ctxt r >>=? fun (Ex (tr, r)) ->
        return @@ Ex (Union_t (tl, tr), R r)
    | Prim (loc, "right", l) ->
        fail @@ Invalid_arity (loc, Constant, "right", 2, List.length l)
    | Prim (_, "or", [ tl; tr; arg ]) ->
        parse_ty tl >>=? fun (Ex tl) ->
        parse_ty tr >>=? fun (Ex tr) ->
        parse_untagged_data ctxt (Union_t (tl, tr)) arg >>=? fun v ->
        return @@ Ex (Union_t (tl, tr), v)
    | Prim (loc, "or", l) ->
        fail @@ Invalid_arity (loc, Constant, "or", 3, List.length l)
    | Prim (_, "some", [ r ]) ->
        parse_tagged_data ctxt r >>=? fun (Ex (tr, r)) ->
        return @@ Ex (Option_t tr, Some r)
    | Prim (_, "some", [ tr; r ]) ->
        parse_ty tr >>=? fun (Ex tr) ->
        parse_untagged_data ctxt tr r >>=? fun r ->
        return @@ Ex (Option_t tr, Some r)
    | Prim (loc, "some", l) ->
        fail @@ Invalid_arity (loc, Constant, "some", 1, List.length l)
    | Prim (_, "none", [ tr ]) ->
        parse_ty tr >>=? fun (Ex tr) ->
        return @@ Ex (Option_t tr, None)
    | Prim (loc, "none", l) ->
        fail @@ Invalid_arity (loc, Constant, "none", 1, List.length l)
    | Prim (_, "option", [ tr; r ]) ->
        parse_ty tr >>=? fun (Ex tr) ->
        parse_untagged_data ctxt (Option_t tr) r >>=? fun r ->
        return @@ Ex (Option_t tr, r)
    | Prim (loc, "option", l) ->
        fail @@ Invalid_arity (loc, Constant, "option", 2, List.length l)
    | Prim (_, "pair", [ tl; tr; l; r ]) ->
        parse_ty tl >>=? fun (Ex tl) ->
        parse_ty tr >>=? fun (Ex tr) ->
        parse_untagged_data ctxt tl l >>=? fun l ->
        parse_untagged_data ctxt tr r >>=? fun r ->
        return @@ Ex (Pair_t (tl, tr), (l, r))
    | Prim (_, "pair", [ l; r ]) ->
        parse_tagged_data ctxt l >>=? fun (Ex (tl, l)) ->
        parse_tagged_data ctxt r >>=? fun (Ex (tr, r)) ->
        return @@ Ex (Pair_t (tl, tr), (l, r))
    | Prim (loc, "pair", l) ->
        fail @@ Invalid_arity (loc, Constant, "pair", 4, List.length l)
    | Prim (loc, "list", t :: items) ->
        parse_ty t >>=? fun (Ex t) ->
        parse_untagged_data ctxt
          (List_t t) (Prim (loc, "list", items)) >>=? fun l ->
        return @@ Ex (List_t t, l)
    | Prim (loc, "list", l) ->
        fail @@ Invalid_arity (loc, Constant, "list", 1, List.length l)
    | Prim (loc, "set", t :: items) ->
        parse_comparable_ty t >>=? fun (Ex t) ->
        parse_untagged_data ctxt
          (Set_t t) (Prim (loc, "set", items)) >>=? fun l ->
        return @@ Ex (Set_t t, l)
    | Prim (loc, "set", l) ->
        fail @@ Invalid_arity (loc, Constant, "set", 1, List.length l)
    | Prim (loc, "map", kt :: vt :: items) ->
        parse_comparable_ty kt >>=? fun (Ex kt) ->
        parse_ty vt >>=? fun (Ex vt) ->
        parse_untagged_data ctxt
          (Map_t (kt, vt)) (Prim (loc, "map", items)) >>=? fun l ->
        return @@ Ex (Map_t (kt, vt), l)
    | Prim (loc, "map", l) ->
        fail @@ Invalid_arity (loc, Constant, "map", 2, List.length l)
    | Prim (_, "contract", [ at; rt; c ]) ->
        parse_ty at >>=? fun (Ex at) ->
        parse_ty rt >>=? fun (Ex rt) ->
        parse_untagged_data ctxt (Contract_t (at, rt)) c >>=? fun l ->
        return @@ Ex (Contract_t (at, rt), l)
    | Prim (loc, "contract", l) ->
        fail @@ Invalid_arity (loc, Constant, "contract", 3, List.length l)
    | Prim (loc, "lambda", [ at ; rt ; code ]) ->
        expect_sequence_parameter loc Constant "lambda" 2 code >>=? fun () ->
        parse_ty at >>=? fun (Ex at) ->
        parse_ty rt >>=? fun (Ex rt) ->
        parse_untagged_data ctxt (Lambda_t (at, rt)) code >>=? fun l ->
        return @@ Ex (Lambda_t (at, rt), l)
    | Prim (loc, "lambda", l) ->
        fail @@ Invalid_arity (loc, Constant, "lambda", 3, List.length l)
    | Prim (loc, name, _) ->
        fail @@ Invalid_primitive (loc, Constant, name)
    | Seq (loc, _) | Int (loc, _) ->
        fail @@ Invalid_expression_kind loc

and parse_untagged_data
  : type a. context -> a ty -> Script.expr -> a tzresult Lwt.t
  = fun ctxt ty script_data ->
    match ty, script_data with
    (* Void *)
    | Void_t, Prim (_, "void", []) -> return ()
    | Void_t, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "void")
    (* Strings *)
    | String_t, String (_, v) -> return v
    | String_t, (Prim (loc, _, _) | Int (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "string")
    (* Booleans *)
    | Bool_t, Prim (_, "true", []) -> return true
    | Bool_t, Prim (_, "false", []) -> return false
    | Bool_t, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "bool")
    (* Integers *)
    | Int_t k, Int (loc, v) -> begin try
          match checked_of_int64 k (Int64.of_string v) with
          | None -> raise Exit
          | Some i -> return i
        with _ -> fail @@ Invalid_constant (loc, string_of_int_kind k)
      end
    | Int_t k, (Prim (loc, _, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, string_of_int_kind k)
    (* Tez amounts *)
    | Tez_t, String (loc, v) -> begin try
          match Tez.of_string v with
          | None -> raise Exit
          | Some tez -> return tez
        with _ ->
          fail @@ Invalid_constant (loc, "tez")
      end
    | Tez_t, (Int (loc, _) | Prim (loc, _, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "tez")
    (* Timestamps *)
    | Timestamp_t, (Int (loc, v)) -> begin
        match (Timestamp.of_seconds v) with
        | Some v -> return v
        | None -> fail @@ Invalid_constant (loc, "timestamp")
      end
    | Timestamp_t, String (loc, s) -> begin try
          match Timestamp.of_notation s with
          | Some v -> return v
          | None-> fail @@ Invalid_constant (loc, "timestamp")
        with _ -> fail @@ Invalid_constant (loc, "timestamp")
      end
    | Timestamp_t, (Prim (loc, _, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "timestamp")
    (* IDs *)
    | Key_t, String (loc, s) -> begin try
          return (Ed25519.Public_key_hash.of_b48check s)
        with _ -> fail @@ Invalid_constant (loc, "key")
      end
    | Key_t, (Prim (loc, _, _) | Seq (loc, _) | Int (loc, _)) ->
        fail @@ Invalid_constant (loc, "key")
    (* Signatures *)
    | Signature_t, String (loc, s) -> begin try
          match Data_encoding.Binary.of_bytes
                  Ed25519.signature_encoding
                  (MBytes.of_string (Hex_encode.hex_decode s)) with
          | Some s -> return s
          | None -> raise Not_found
        with _ ->
          fail @@ Invalid_constant (loc, "signature")
      end
    | Signature_t, (Prim (loc, _, _) | Int (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "signature")
    (* Contracts *)
    | Contract_t (ty1, ty2), String (loc, s) ->
        trace
          (Invalid_constant (loc, "contract"))
          (Lwt.return (Contract.of_b48check s)) >>=? fun c ->
        parse_contract ctxt ty1 ty2 loc c >>=? fun _ ->
        return (ty1, ty2, c)
    | Contract_t _, (Prim (loc, _, _) | Int (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "contract")
    (* Pairs *)
    | Pair_t (ta, tb), Prim (_, "pair", [ va; vb ]) ->
        parse_untagged_data ctxt ta va >>=? fun va ->
        parse_untagged_data ctxt tb vb >>=? fun vb ->
        return (va, vb)
    | Pair_t _, Prim (loc, "pair", l) ->
        fail @@ Invalid_arity (loc, Constant, "pair", 2, List.length l)
    | Pair_t _, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "pair")
    (* Unions *)
    | Union_t (tl, _), Prim (_, "left", [ v ]) ->
        parse_untagged_data ctxt tl v >>=? fun v ->
        return (L v)
    | Union_t _, Prim (loc, "left", l) ->
        fail @@ Invalid_arity (loc, Constant, "left", 1, List.length l)
    | Union_t (_, tr), Prim (_, "right", [ v ]) ->
        parse_untagged_data ctxt tr v >>=? fun v ->
        return (R v)
    | Union_t _, Prim (loc, "right", l) ->
        fail @@ Invalid_arity (loc, Constant, "right", 1, List.length l)
    | Union_t _, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "union")
    (* Lambdas *)
    | Lambda_t (ta, tr), (Seq _ as script_instr) ->
        parse_lambda ctxt ta tr script_instr
    | Lambda_t (_, _), (Prim (loc, _, _) | Int (loc, _) | String (loc, _)) ->
        fail @@ Invalid_constant (loc, "lambda")
    (* Options *)
    | Option_t t, Prim (_, "some", [ v ]) ->
        parse_untagged_data ctxt t v >>=? fun v ->
        return (Some v)
    | Option_t _, Prim (loc, "some", l) ->
        fail @@ Invalid_arity (loc, Constant, "some", 1, List.length l)
    | Option_t _, Prim (_, "none", []) ->
        return None
    | Option_t _, Prim (loc, "none", l) ->
        fail @@ Invalid_arity (loc, Constant, "none", 0, List.length l)
    | Option_t _, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "option")
    (* Lists *)
    | List_t t, Prim (_, "list", vs) ->
        fold_left_s
          (fun rest v ->
             parse_untagged_data ctxt t v >>=? fun v ->
             return (v :: rest))
          [] vs
    | List_t _, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "list")
    (* Sets *)
    | Set_t t, Prim (_, "set", vs) ->
        fold_left_s
          (fun acc v ->
             parse_untagged_comparable_data ctxt t v >>=? fun v ->
             return (set_update v true acc))
          (empty_set t) vs
    | Set_t _, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "set")
    (* Maps *)
    | Map_t (tk, tv), Prim (_, "map", vs) ->
        fold_left_s
          (fun acc -> function
             | Prim (_, "item", [ k; v ]) ->
                 parse_untagged_comparable_data ctxt tk k >>=? fun k ->
                 parse_untagged_data ctxt tv v >>=? fun v ->
                 return (map_update k (Some v) acc)
             | Prim (loc, "item", l) ->
                 fail @@ Invalid_arity (loc, Constant, "item", 2, List.length l)
             | Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _) ->
                 fail @@ Invalid_constant (loc, "item"))
          (empty_map tk) vs
    | Map_t _, (Prim (loc, _, _) | Int (loc, _) | String (loc, _) | Seq (loc, _)) ->
        fail @@ Invalid_constant (loc, "map")

and parse_untagged_comparable_data
  : type a. context -> a comparable_ty -> Script.expr -> a tzresult Lwt.t
  = fun ctxt ty script_data ->
    parse_untagged_data ctxt (ty_of_comparable_ty ty) script_data

and parse_lambda
  : type arg ret storage. context ->
    ?storage_type: storage ty ->
    arg ty -> ret ty -> Script.expr -> (arg, ret) lambda tzresult Lwt.t =
  fun ctxt ?storage_type arg ret script_instr ->
    parse_instr ctxt ?storage_type script_instr (Item_t (arg, Empty_t)) >>=? function
    | Typed ({ loc ; aft = (Item_t (ty, Empty_t) as stack_ty) } as descr) ->
        trace
          (Bad_return (loc, Stack_ty stack_ty, Ty ret))
          (Lwt.return (ty_eq ty ret)) >>=? fun (Eq _) ->
        return (Lam (descr, script_instr) : (arg, ret) lambda)
    | Typed { loc ; aft = stack_ty } ->
        fail (Bad_return (loc, Stack_ty stack_ty, Ty ret))
    | Failed { descr } ->
        return (Lam (descr (Item_t (ret, Empty_t)), script_instr) : (arg, ret) lambda)

and parse_instr
  : type bef storage. context ->
    ?storage_type: storage ty ->
    Script.expr -> bef stack_ty -> bef judgement tzresult Lwt.t =
  fun ctxt ?storage_type script_instr stack_ty ->
    let return : bef judgement -> bef judgement tzresult Lwt.t = return in
    let check_item_ty got exp pos n =
      ty_eq got exp |> record_trace (Bad_stack_item (pos, n)) |> Lwt.return in
    let typed loc (instr, aft) =
      Typed { loc ; instr ; bef = stack_ty ; aft } in
    match script_instr, stack_ty with
    (* stack ops *)
    | Prim (loc, "drop", []),
      Item_t (_, rest) ->
        return (typed loc (Drop, rest))
    | Prim (loc, "dup", []),
      Item_t (v, rest) ->
        return (typed loc (Dup, Item_t (v, Item_t (v, rest))))
    | Prim (loc, "swap", []),
      Item_t (v,  Item_t (w, rest)) ->
        return (typed loc (Swap, Item_t (w, Item_t (v, rest))))
    | Prim (loc, "push", [ td ]),
      stack ->
        parse_tagged_data ctxt td >>=? fun (Ex (t, v)) ->
        return (typed loc (Const v, Item_t (t, stack)))
    (* options *)
    | Prim (loc, "some", []),
      Item_t (t, rest) ->
        return (typed loc (Cons_some, Item_t (Option_t t, rest)))
    | Prim (loc, "none", [ t ]),
      stack ->
        parse_ty t >>=? fun (Ex t) ->
        return (typed loc (Cons_none t, Item_t (Option_t t, stack)))
    | Prim (loc, "if_none", [ bt ; bf ]),
      (Item_t (Option_t t, rest) as bef) ->
        expect_sequence_parameter loc Instr "if_none" 0 bt >>=? fun () ->
        expect_sequence_parameter loc Instr "if_none" 1 bf >>=? fun () ->
        parse_instr ?storage_type ctxt bt rest >>=? fun btr ->
        parse_instr ?storage_type ctxt bf (Item_t (t, rest)) >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If_none (ibt, ibf) ; bef ; aft = ibt.aft } in
        merge_branches loc btr bfr { branch }
    (* pairs *)
    | Prim (loc, "pair", []),
      Item_t (a, Item_t (b, rest)) ->
        return (typed loc (Cons_pair, Item_t (Pair_t(a, b), rest)))
    | Prim (loc, "car", []),
      Item_t (Pair_t (a, _), rest) ->
        return (typed loc (Car, Item_t (a, rest)))
    | Prim (loc, "cdr", []),
      Item_t (Pair_t (_, b), rest) ->
        return (typed loc (Cdr, Item_t (b, rest)))
    (* unions *)
    | Prim (loc, "left", [ tr ]),
      Item_t (tl, rest) ->
        parse_ty tr >>=? fun (Ex tr) ->
        return (typed loc (Left, Item_t (Union_t (tl, tr), rest)))
    | Prim (loc, "right", [ tl ]),
      Item_t (tr, rest) ->
        parse_ty tl >>=? fun (Ex tl) ->
        return (typed loc (Right, Item_t (Union_t (tl, tr), rest)))
    | Prim (loc, "if_left", [ bt ; bf ]),
      (Item_t (Union_t (tl, tr), rest) as bef) ->
        expect_sequence_parameter loc Instr "if_left" 0 bt >>=? fun () ->
        expect_sequence_parameter loc Instr "if_left" 1 bf >>=? fun () ->
        parse_instr ?storage_type ctxt bt (Item_t (tl, rest)) >>=? fun btr ->
        parse_instr ?storage_type ctxt bf (Item_t (tr, rest)) >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If_left (ibt, ibf) ; bef ; aft = ibt.aft } in
        merge_branches loc btr bfr { branch }
    (* lists *)
    | Prim (loc, "nil", [ t ]),
      stack ->
        parse_ty t >>=? fun (Ex t) ->
        return (typed loc (Nil, Item_t (List_t t, stack)))
    | Prim (loc, "cons", []),
      Item_t (tv, Item_t (List_t t, rest)) ->
        trace
          (Bad_stack_item (loc, 2))
          (Lwt.return (ty_eq t tv)) >>=? fun (Eq _) ->
        return (typed loc (Cons_list, Item_t (List_t t, rest)))
    | Prim (loc, "if_cons", [ bt ; bf ]),
      (Item_t (List_t t, rest) as bef) ->
        expect_sequence_parameter loc Instr "if_cons" 0 bt >>=? fun () ->
        expect_sequence_parameter loc Instr "if_cons" 1 bf >>=? fun () ->
        parse_instr ?storage_type ctxt bt (Item_t (t, Item_t (List_t t, rest))) >>=? fun btr ->
        parse_instr ?storage_type ctxt bf rest >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If_cons (ibt, ibf) ; bef ; aft = ibt.aft } in
        merge_branches loc btr bfr { branch }
    | Prim (loc, "map", []),
      Item_t (Lambda_t (param, ret), Item_t (List_t elt, rest)) ->
        check_item_ty elt param loc 2 >>=? fun (Eq _) ->
        return (typed loc (List_map, Item_t (List_t ret, rest)))
    | Prim (loc, "reduce", []),
      Item_t (Lambda_t (Pair_t (pelt, pr), r),
              Item_t (List_t elt, Item_t (init, rest))) ->
        check_item_ty r pr loc 1 >>=? fun (Eq _) ->
        check_item_ty elt pelt loc 2 >>=? fun (Eq _) ->
        check_item_ty init r loc 3 >>=? fun (Eq _) ->
        return (typed loc (List_reduce, Item_t (r, rest)))
    (* sets *)
    | Prim (loc, "empty_set", [ t ]),
      rest ->
        parse_comparable_ty t >>=? fun (Ex t) ->
        return (typed loc (Empty_set t, Item_t (Set_t t, rest)))
    | Prim (loc, "map", []),
      Item_t (Lambda_t (param, ret), Item_t (Set_t elt, rest)) ->
        let elt = ty_of_comparable_ty elt in
        trace (Bad_stack_item (loc, 1)) (Lwt.return (comparable_ty_of_ty ret)) >>=? fun ret ->
        check_item_ty elt param loc 2 >>=? fun (Eq _) ->
        return (typed loc (Set_map ret, Item_t (Set_t ret, rest)))
    | Prim (loc, "reduce", []),
      Item_t (Lambda_t (Pair_t (pelt, pr), r),
              Item_t (Set_t elt, Item_t (init, rest))) ->
        let elt = ty_of_comparable_ty elt in
        check_item_ty r pr loc 1 >>=? fun (Eq _) ->
        check_item_ty elt pelt loc 2 >>=? fun (Eq _) ->
        check_item_ty init r loc 3 >>=? fun (Eq _) ->
        return (typed loc (Set_reduce, Item_t (r, rest)))
    | Prim (loc, "mem", []),
      Item_t (v, Item_t (Set_t elt, rest)) ->
        let elt = ty_of_comparable_ty elt in
        check_item_ty elt v loc 2 >>=? fun (Eq _) ->
        return (typed loc (Set_mem, Item_t (Bool_t, rest)))
    | Prim (loc, "update", []),
      Item_t (v, Item_t (Bool_t, Item_t (Set_t elt, rest))) ->
        let ty = ty_of_comparable_ty elt in
        check_item_ty ty v loc 3 >>=? fun (Eq _) ->
        return (typed loc (Set_update, Item_t (Set_t elt, rest)))
    (* maps *)
    | Prim (loc, "empty_map", [ tk ; tv ]),
      stack ->
        parse_comparable_ty tk >>=? fun (Ex tk) ->
        parse_ty tv >>=? fun (Ex tv) ->
        return (typed loc (Empty_map (tk, tv), Item_t (Map_t (tk, tv), stack)))
    | Prim (loc, "map", []),
      Item_t (Lambda_t (Pair_t (pk, pv), ret), Item_t (Map_t (ck, v), rest)) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty pk k loc 2 >>=? fun (Eq _) ->
        check_item_ty pv v loc 2 >>=? fun (Eq _) ->
        return (typed loc (Map_map, Item_t (Map_t (ck, ret), rest)))
    | Prim (loc, "reduce", []),
      Item_t (Lambda_t (Pair_t (Pair_t (pk, pv), pr), r),
              Item_t (Map_t (ck, v), Item_t (init, rest))) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty pk k loc 2 >>=? fun (Eq _) ->
        check_item_ty pv v loc 2 >>=? fun (Eq _) ->
        check_item_ty r pr loc 1 >>=? fun (Eq _) ->
        check_item_ty init r loc 3 >>=? fun (Eq _) ->
        return (typed loc (Map_reduce, Item_t (r, rest)))
    | Prim (loc, "mem", []),
      Item_t (vk, Item_t (Map_t (ck, _), rest)) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty vk k loc 1 >>=? fun (Eq _) ->
        return (typed loc (Map_mem, Item_t (Bool_t, rest)))
    | Prim (loc, "get", []),
      Item_t (vk, Item_t (Map_t (ck, elt), rest)) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty vk k loc 1 >>=? fun (Eq _) ->
        return (typed loc (Map_get, Item_t (Option_t elt, rest)))
    | Prim (loc, "update", []),
      Item_t (vk, Item_t (Option_t vv, Item_t (Map_t (ck, v), rest))) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty vk k loc 1 >>=? fun (Eq _) ->
        check_item_ty vv v loc 2 >>=? fun (Eq _) ->
        return (typed loc (Map_update, Item_t (Map_t (ck, v), rest)))
    (* control *)
    | Seq (loc, []),
      stack ->
        return (typed loc (Nop, stack))
    | Seq (_, [ single ]),
      stack ->
        parse_instr ?storage_type ctxt single stack
    | Seq (loc, hd :: tl),
      stack ->
        parse_instr ?storage_type ctxt hd stack >>=? begin function
          | Failed _ ->
              fail (Fail_not_in_tail_position loc)
          | Typed ({ aft = middle } as ihd) ->
              parse_instr ?storage_type ctxt (Seq (loc, tl)) middle >>=? function
              | Failed { descr } ->
                  let descr ret =
                    { loc ; instr = Seq (ihd, descr ret) ;
                      bef = stack ; aft = ret } in
                  return (Failed { descr })
              | Typed itl ->
                  return (typed loc (Seq (ihd, itl), itl.aft))
        end
    | Prim (loc, "if", [ bt ; bf ]),
      (Item_t (Bool_t, rest) as bef) ->
        expect_sequence_parameter loc Instr "if" 0 bt >>=? fun () ->
        expect_sequence_parameter loc Instr "if" 1 bf >>=? fun () ->
        parse_instr ?storage_type ctxt bt rest >>=? fun btr ->
        parse_instr ?storage_type ctxt bf rest >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If (ibt, ibf) ; bef ; aft = ibt.aft } in
        merge_branches loc btr bfr { branch }
    | Prim (loc, "loop", [ body ]),
      (Item_t (Bool_t, rest) as stack) ->
        expect_sequence_parameter loc Instr "loop" 0 body >>=? fun () ->
        parse_instr ?storage_type ctxt body rest >>=? begin function
          | Typed ibody ->
              trace
                (Unmatched_branches (loc, Stack_ty ibody.aft, Stack_ty stack))
                (Lwt.return (stack_ty_eq 0 ibody.aft stack)) >>=? fun (Eq _) ->
              return (typed loc (Loop ibody, rest))
          | Failed { descr } ->
              let ibody = descr (Item_t (Bool_t, rest)) in
              return (typed loc (Loop ibody, rest))
        end
    | Prim (loc, "lambda", [ arg ; ret ; code ]),
      stack ->
        parse_ty arg >>=? fun (Ex arg) ->
        parse_ty ret >>=? fun (Ex ret) ->
        expect_sequence_parameter loc Instr "lambda" 2 code >>=? fun () ->
        parse_lambda ctxt arg ret code >>=? fun lambda ->
        return (typed loc (Lambda lambda, Item_t (Lambda_t (arg, ret), stack)))
    | Prim (loc, "exec", []),
      Item_t (arg, Item_t (Lambda_t (param, ret), rest)) ->
        check_item_ty arg param loc 1 >>=? fun (Eq _) ->
        return (typed loc (Exec, Item_t (ret, rest)))
    | Prim (loc, "dip", [ code ]),
      Item_t (v, rest) ->
        expect_sequence_parameter loc Instr "dip" 0 code >>=? fun () ->
        parse_instr ctxt code rest >>=? begin function
          | Typed descr ->
              return (typed loc (Dip descr, Item_t (v, descr.aft)))
          | Failed _ ->
              fail (Fail_not_in_tail_position loc)
        end
    | Prim (loc, "fail", []),
      bef ->
        let descr aft = { loc ; instr = Fail ; bef ; aft } in
        return (Failed { descr })
    | Prim (loc, "nop", []),
      stack ->
        return (typed loc (Nop, stack))
    (* timestamp operations *)
    | Prim (loc, "add", []),
      Item_t (Timestamp_t, Item_t (Int_t kind, rest)) ->
        trace
          (Bad_stack_item (loc, 2))
          (Lwt.return (unsigned_int_kind kind)) >>=? fun (Eq _) ->
        return (typed loc (Add_timestamp_to_seconds kind, Item_t (Timestamp_t, rest)))
    | Prim (loc, "add", []),
      Item_t (Int_t kind, Item_t (Timestamp_t, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind kind)) >>=? fun (Eq _) ->
        return (typed loc (Add_seconds_to_timestamp kind, Item_t (Timestamp_t, rest)))
    (* string operations *)
    | Prim (loc, "concat", []),
      Item_t (String_t, Item_t (String_t, rest)) ->
        return (typed loc (Concat, Item_t (String_t, rest)))
    (* currency operations *)
    | Prim (loc, "add", []),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc (Add_tez, Item_t (Tez_t, rest)))
    | Prim (loc, "sub", []),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc (Sub_tez, Item_t (Tez_t, rest)))
    | Prim (loc, "mul", []),
      Item_t (Tez_t, Item_t (Int_t kind, rest)) ->
        trace
          (Bad_stack_item (loc, 2))
          (Lwt.return (unsigned_int_kind kind)) >>=? fun (Eq _) ->
        return (typed loc (Mul_tez kind, Item_t (Tez_t, rest)))
    | Prim (loc, "mul", []),
      Item_t (Int_t kind, Item_t (Tez_t, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind kind)) >>=? fun (Eq _) ->
        return (typed loc (Mul_tez' kind, Item_t (Tez_t, rest)))
    (* boolean operations *)
    | Prim (loc, "or", []),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc (Or, Item_t (Bool_t, rest)))
    | Prim (loc, "and", []),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc (And, Item_t (Bool_t, rest)))
    | Prim (loc, "xor", []),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc (Xor, Item_t (Bool_t, rest)))
    | Prim (loc, "not", []),
      Item_t (Bool_t, rest) ->
        return (typed loc (Not, Item_t (Bool_t, rest)))
    (* integer operations *)
    | Prim (loc, "checked_abs", []),
      Item_t (Int_t k, rest) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (signed_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Checked_abs_int k, Item_t (Int_t k, rest)))
    | Prim (loc, "checked_neg", []),
      Item_t (Int_t k, rest) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (signed_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Checked_neg_int k, Item_t (Int_t k, rest)))
    | Prim (loc, "checked_add", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Checked_add_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "checked_sub", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Checked_sub_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "checked_mul", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Checked_mul_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "abs", []),
      Item_t (Int_t k, rest) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (signed_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Abs_int k, Item_t (Int_t k, rest)))
    | Prim (loc, "neg", []),
      Item_t (Int_t k, rest) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (signed_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Neg_int k, Item_t (Int_t k, rest)))
    | Prim (loc, "add", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Add_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "sub", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Sub_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "mul", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Mul_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "div", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Div_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "mod", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Mod_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "lsl", []),
      Item_t (Int_t k, Item_t (Int_t Uint8, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Lsl_int k, Item_t (Int_t k, rest)))
    | Prim (loc, "lsr", []),
      Item_t (Int_t k, Item_t (Int_t Uint8, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Lsr_int k, Item_t (Int_t k, rest)))
    | Prim (loc, "or", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind kl)) >>=? fun (Eq _) ->
        trace
          (Bad_stack_item (loc, 2))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Or_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "and", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind kl)) >>=? fun (Eq _) ->
        trace
          (Bad_stack_item (loc, 2))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (And_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "xor", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind kl)) >>=? fun (Eq _) ->
        trace
          (Bad_stack_item (loc, 2))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Xor_int kl, Item_t (Int_t kl, rest)))
    | Prim (loc, "not", []),
      Item_t (Int_t k, rest) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (unsigned_int_kind k)) >>=? fun (Eq _) ->
        return (typed loc (Not_int k, Item_t (Int_t k, rest)))
    (* comparison *)
    | Prim (loc, "compare", []),
      Item_t (Int_t kl, Item_t (Int_t kr, rest)) ->
        trace
          (Bad_stack_item (loc, 1))
          (Lwt.return (int_kind_eq kl kr)) >>=? fun (Eq _) ->
        return (typed loc (Compare (Int_key kl), Item_t (Int_t Int64, rest)))
    | Prim (loc, "compare", []),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc (Compare Bool_key, Item_t (Int_t Int64, rest)))
    | Prim (loc, "compare", []),
      Item_t (String_t, Item_t (String_t, rest)) ->
        return (typed loc (Compare String_key, Item_t (Int_t Int64, rest)))
    | Prim (loc, "compare", []),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc (Compare Tez_key, Item_t (Int_t Int64, rest)))
    | Prim (loc, "compare", []),
      Item_t (Key_t, Item_t (Key_t, rest)) ->
        return (typed loc (Compare Key_key, Item_t (Int_t Int64, rest)))
    | Prim (loc, "compare", []),
      Item_t (Timestamp_t, Item_t (Timestamp_t, rest)) ->
        return (typed loc (Compare Timestamp_key, Item_t (Int_t Int64, rest)))
    (* comparators *)
    | Prim (loc, "eq", []),
      Item_t (Int_t Int64, rest) ->
        return (typed loc (Eq, Item_t (Bool_t, rest)))
    | Prim (loc, "neq", []),
      Item_t (Int_t Int64, rest) ->
        return (typed loc (Neq, Item_t (Bool_t, rest)))
    | Prim (loc, "lt", []),
      Item_t (Int_t Int64, rest) ->
        return (typed loc (Lt, Item_t (Bool_t, rest)))
    | Prim (loc, "gt", []),
      Item_t (Int_t Int64, rest) ->
        return (typed loc (Gt, Item_t (Bool_t, rest)))
    | Prim (loc, "le", []),
      Item_t (Int_t Int64, rest) ->
        return (typed loc (Le, Item_t (Bool_t, rest)))
    | Prim (loc, "ge", []),
      Item_t (Int_t Int64, rest) ->
        return (typed loc (Ge, Item_t (Bool_t, rest)))
    (* casts *)
    | Prim (loc, "checked_cast", [ t ]),
      stack ->
        parse_ty t >>=? fun (Ex ty) -> begin match ty, stack with
          | Int_t kt,
            Item_t (Int_t kf, rest) ->
              return (typed loc (Checked_int_of_int (kf, kt),
                                 Item_t (Int_t kt, rest)))
          | ty, Item_t (ty', _) ->
              fail (Undefined_cast (loc, Ty ty', Ty ty))
          | _, Empty_t ->
              fail (Bad_stack (loc, 1, Stack_ty stack))
        end
    | Prim (loc, "cast", [ t ]),
      stack ->
        parse_ty t >>=? fun (Ex ty) -> begin match ty, stack with
          | Int_t kt, Item_t (Int_t kf, rest)  ->
              return (typed loc (Int_of_int (kf, kt),
                                 Item_t (Int_t kt, rest)))
          | ty, Item_t (ty', _) ->
              fail (Undefined_cast (loc, Ty ty', Ty ty))
          | _, Empty_t ->
              fail (Bad_stack (loc, 1, Stack_ty stack))
        end
    (* protocol *)
    | Prim (loc, "manager", []),
      Item_t (Contract_t _, rest) ->
        return (typed loc (Manager, Item_t (Key_t, rest)))
    | Prim (loc, "transfer_tokens", []),
      Item_t (p, Item_t
                (Tez_t, Item_t
                   (Contract_t (cp, cr), Item_t
                      (storage, Empty_t)))) ->
        check_item_ty p cp loc 1 >>=? fun (Eq _) ->
        begin match storage_type with
          | Some storage_type ->
              check_item_ty storage storage_type loc 3 >>=? fun (Eq _) ->
              return (typed loc (Transfer_tokens storage,
                                 Item_t (cr, Item_t (storage, Empty_t))))
          | None ->
              fail (Transfer_in_lambda loc)
        end
    | Prim (loc, "create_account", []),
      Item_t
        (Key_t, Item_t
           (Option_t Key_t, Item_t
              (Bool_t, Item_t
                 (Tez_t, rest)))) ->
        return (typed loc (Create_account,
                           Item_t (Contract_t (Void_t, Void_t), rest)))
    | Prim (loc, "create_contract", []),
      Item_t
        (Key_t, Item_t
           (Option_t Key_t, Item_t
              (Bool_t, Item_t
                 (Tez_t, Item_t
                    (Lambda_t (Pair_t (Pair_t (Tez_t, p), gp),
                               Pair_t (r, gr)), Item_t
                       (ginit, rest)))))) ->
        check_item_ty gp gr loc 5 >>=? fun (Eq _) ->
        check_item_ty ginit gp loc 6 >>=? fun (Eq _) ->
        return (typed loc (Create_contract (gp, p, r),
                           Item_t (Contract_t (p, r), rest)))
    | Prim (loc, "now", []),
      stack ->
        return (typed loc (Now, Item_t (Timestamp_t, stack)))
    | Prim (loc, "amount", []),
      stack ->
        return (typed loc (Amount, Item_t (Tez_t, stack)))
    | Prim (loc, "balance", []),
      stack ->
        return (typed loc (Balance, Item_t (Tez_t, stack)))
    | Prim (loc, "check_signature", []),
      Item_t (Key_t, Item_t (Pair_t (Signature_t, String_t), rest)) ->
        return (typed loc (Check_signature, Item_t (Bool_t, rest)))
    | Prim (loc, "h", []),
      Item_t (t, rest) ->
        return (typed loc (H t, Item_t (String_t, rest)))
    | Prim (loc, "steps_to_quota", []),
      stack ->
        return (typed loc (Steps_to_quota, Item_t (Int_t Uint32, stack)))
    | Prim (loc, "source", [ ta; tb ]),
      stack ->
        parse_ty ta >>=? fun (Ex ta) ->
        parse_ty tb >>=? fun (Ex tb) ->
        return (typed loc (Source (ta, tb), Item_t (Contract_t (ta, tb), stack)))
    (* Primitive parsing errors *)
    | Prim (loc, ("drop" | "dup" | "swap" | "some"
                 | "pair" | "car" | "cdr" | "cons"
                 | "mem" | "update" | "map" | "reduce"
                 | "get" | "ref" | "deref"
                 | "set" | "exec" | "fail" | "nop"
                 | "concat" | "add" | "sub"
                 | "mul" | "floor" | "ceil" | "inf"
                 | "nan" | "isnan" | "nanan"
                 | "div" | "mod" | "or" | "and" | "xor"
                 | "not" | "checked_abs" | "checked_neg"
                 | "checked_add" | "checked_sub" | "checked_mul"
                 | "abs" | "neg" | "lsl" | "lsr"
                 | "compare" | "eq" | "neq"
                 | "lt" | "gt" | "le" | "ge"
                 | "manager" | "transfer_tokens" | "create_account"
                 | "create_contract" | "now" | "amount" | "balance"
                 | "check_signature" | "h" | "steps_to_quota"
                 as name), (_ :: _ as l)), _ ->
        fail (Invalid_arity (loc, Instr, name, 0, List.length l))
    | Prim (loc, ( "push" | "none" | "left" | "right" | "nil"
                 | "empty_set" | "dip" | "checked_cast" | "cast" | "loop"
                 as name), ([] | _ :: _ :: _ as l)), _ ->
        fail (Invalid_arity (loc, Instr, name, 1, List.length l))
    | Prim (loc, ("if_none" | "if_left" | "if_cons"
                 | "empty_map" | "if" | "source"
                 as name), ([] | [ _ ] | _ :: _ :: _ :: _ as l)), _ ->
        fail (Invalid_arity (loc, Instr, name, 2, List.length l))
    | Prim (loc, "lambda", ([] | [ _ ] | [ _; _ ]
                           | _ :: _ :: _ :: _ :: _ as l)), _ ->
        fail (Invalid_arity (loc, Instr, "lambda", 3, List.length l))
    (* Stack errors *)
    | Prim (loc, ("add" | "sub" | "mul" | "div" | "mod"
                 | "and" | "or" | "xor" | "lsl" | "lsr"
                 | "concat" | "compare"
                 | "checked_abs" | "checked_neg"
                 | "checked_add" | "checked_sub" | "checked_mul" as name), []),
      Item_t (ta, Item_t (tb, _)) ->
        fail (Undefined_binop (loc, name, Ty ta, Ty tb))
    | Prim (loc, ("neg" | "abs" | "not" | "floor" | "ceil"
                 | "isnan" | "nanan" | "eq"
                 | "neq" | "lt" | "gt" | "le" | "ge" as name), []),
      Item_t (t, _) ->
        fail (Undefined_unop (loc, name, Ty t))
    | Prim (loc, ("reduce" | "update"), []),
      stack ->
        fail (Bad_stack (loc, 3, Stack_ty stack))
    | Prim (loc, "create_contract", []),
      stack ->
        fail (Bad_stack (loc, 6, Stack_ty stack))
    | Prim (loc, "create_account", []),
      stack ->
        fail (Bad_stack (loc, 4, Stack_ty stack))
    | Prim (loc, "transfer_tokens", []),
      stack ->
        fail (Bad_stack (loc, 3, Stack_ty stack))
    | Prim (loc, ("drop" | "dup" | "car" | "cdr" | "some" | "h" | "dip"
                 | "if_none" | "left" | "right" | "if_left" | "if"
                 | "loop" | "if_cons" | "ref" | "deref" | "manager"
                 | "neg" | "abs" | "not" | "floor" | "ceil" | "isnan" | "nanan"
                 | "eq" | "neq" | "lt" | "gt" | "le" | "ge"), _),
      stack ->
        fail (Bad_stack (loc, 1, Stack_ty stack))
    | Prim (loc, ("swap" | "pair" | "cons" | "set" | "incr" | "decr"
                 | "map" | "get" | "mem" | "exec"
                 | "check_signature" | "add" | "sub" | "mul"
                 | "div" | "mod" | "and" | "or" | "xor"
                 | "lsl" | "lsr" | "concat"
                 | "checked_abs" | "checked_neg" | "checked_add"
                 | "checked_sub" | "checked_mul" | "compare"), _),
      stack ->
        fail (Bad_stack (loc, 2, Stack_ty stack))
    (* Generic parsing errors *)
    | Prim (loc, prim, _), _ ->
        fail @@ Invalid_primitive (loc, Instr, prim)
    | (Int (loc, _) | String (loc, _)), _ ->
        fail @@ Invalid_expression_kind loc

and parse_contract
  : type arg ret. context -> arg ty -> ret ty -> Script.location -> Contract.t ->
    (arg, ret) typed_contract tzresult Lwt.t
  = fun ctxt arg ret loc contract ->
    Contract.exists ctxt contract >>=? function
    | false -> fail (Invalid_contract (loc, contract))
    | true ->
        trace
          (Invalid_contract (loc, contract)) @@
        Contract.get_script ctxt contract >>=? function
        | No_script ->
            (Lwt.return
               (ty_eq arg Void_t >>? fun (Eq _) ->
                ty_eq ret Void_t >>? fun (Eq _) ->
                let contract : (arg, ret) typed_contract =
                  (arg, ret, contract) in
                ok contract))
        | Script { code = { arg_type; ret_type} } ->
            parse_ty arg_type >>=? fun (Ex targ) ->
            parse_ty ret_type >>=? fun (Ex tret) ->
            trace
              (Invalid_contract (loc, contract))
              (Lwt.return
                 (ty_eq targ arg >>? fun (Eq _) ->
                  ty_eq tret ret >>? fun (Eq _) ->
                  let contract : (arg, ret) typed_contract =
                    (arg, ret, contract) in
                  ok contract))

let unparse_comparable_ty
  : type a. a comparable_ty -> Script.expr = function
  | Int_key Int8 -> Prim (-1, "int8", [])
  | Int_key Int16 -> Prim (-1, "int16", [])
  | Int_key Int32 -> Prim (-1, "int32", [])
  | Int_key Int64 -> Prim (-1, "int64", [])
  | Int_key Uint8 -> Prim (-1, "uint8", [])
  | Int_key Uint16 -> Prim (-1, "uint16", [])
  | Int_key Uint32 -> Prim (-1, "uint32", [])
  | Int_key Uint64 -> Prim (-1, "uint64", [])
  | String_key -> Prim (-1, "string", [])
  | Tez_key -> Prim (-1, "tez", [])
  | Bool_key -> Prim (-1, "bool", [])
  | Key_key -> Prim (-1, "key", [])
  | Timestamp_key -> Prim (-1, "timestamp", [])

let rec unparse_ty
  : type a. a ty -> Script.expr = function
  | Void_t -> Prim (-1, "void", [])
  | Int_t Int8 -> Prim (-1, "int8", [])
  | Int_t Int16 -> Prim (-1, "int16", [])
  | Int_t Int32 -> Prim (-1, "int32", [])
  | Int_t Int64 -> Prim (-1, "int64", [])
  | Int_t Uint8 -> Prim (-1, "uint8", [])
  | Int_t Uint16 -> Prim (-1, "uint16", [])
  | Int_t Uint32 -> Prim (-1, "uint32", [])
  | Int_t Uint64 -> Prim (-1, "uint64", [])
  | String_t -> Prim (-1, "string", [])
  | Tez_t -> Prim (-1, "tez", [])
  | Bool_t -> Prim (-1, "bool", [])
  | Key_t -> Prim (-1, "key", [])
  | Timestamp_t -> Prim (-1, "timestamp", [])
  | Signature_t -> Prim (-1, "signature", [])
  | Contract_t (utl, utr) ->
      let tl = unparse_ty utl in
      let tr = unparse_ty utr in
      Prim (-1, "contract", [ tl; tr ])
  | Pair_t (utl, utr) ->
      let tl = unparse_ty utl in
      let tr = unparse_ty utr in
      Prim (-1, "pair", [ tl; tr ])
  | Union_t (utl, utr) ->
      let tl = unparse_ty utl in
      let tr = unparse_ty utr in
      Prim (-1, "union", [ tl; tr ])
  | Lambda_t (uta, utr) ->
      let ta = unparse_ty uta in
      let tr = unparse_ty utr in
      Prim (-1, "lambda", [ ta; tr ])
  | Option_t ut ->
      let t = unparse_ty ut in
      Prim (-1, "option", [ t ])
  | List_t ut ->
      let t = unparse_ty ut in
      Prim (-1, "list", [ t ])
  | Set_t ut ->
      let t = unparse_comparable_ty ut in
      Prim (-1, "set", [ t ])
  | Map_t (uta, utr) ->
      let ta = unparse_comparable_ty uta in
      let tr = unparse_ty utr in
      Prim (-1, "map", [ ta; tr ])

let rec unparse_untagged_data
  : type a. a ty -> a -> Script.expr
  = fun ty a -> match ty, a with
    | Void_t, () ->
        Prim (-1, "void", [])
    | Int_t k, v ->
        Int (-1, Int64.to_string (to_int64 k v))
    | String_t, s ->
        String (-1, s)
    | Bool_t, true ->
        Prim (-1, "true", [])
    | Bool_t, false ->
        Prim (-1, "false", [])
    | Timestamp_t, t ->
        String (-1, Timestamp.to_notation t)
    | Contract_t _, (_, _, c)  ->
        String (-1, Contract.to_b48check c)
    | Signature_t, s ->
        let text =
          Hex_encode.hex_encode
            (MBytes.to_string (Data_encoding.Binary.to_bytes Ed25519.signature_encoding s)) in
        String (-1, text)
    | Tez_t, v ->
        String (-1, Tez.to_string v)
    | Key_t, k ->
        String (-1, Ed25519.Public_key_hash.to_b48check k)
    | Pair_t (tl, tr), (l, r) ->
        let l = unparse_untagged_data tl l in
        let r = unparse_untagged_data tr r in
        Prim (-1, "pair", [ l; r ])
    | Union_t (tl, _), L l ->
        let l = unparse_untagged_data tl l in
        Prim (-1, "left", [ l ])
    | Union_t (_, tr), R r ->
        let r = unparse_untagged_data tr r in
        Prim (-1, "right", [ r ])
    | Option_t t, Some v ->
        let v = unparse_untagged_data t v in
        Prim (-1, "some", [ v ])
    | Option_t _, None ->
        Prim (-1, "none", [])
    | List_t t, items ->
        let items = List.map (unparse_untagged_data t) items in
        Prim (-1, "list", items)
    | Set_t t, set ->
        let t = ty_of_comparable_ty t in
        let items =
          set_fold
            (fun item acc ->
               unparse_untagged_data t item :: acc )
            set [] in
        Prim (-1, "set", items)
    | Map_t (kt, vt), map ->
        let kt = ty_of_comparable_ty kt in
        let items =
          map_fold (fun k v acc ->
              Prim (-1, "item",
                    [ unparse_untagged_data kt k;
                      unparse_untagged_data vt v ])
              :: acc)
            map [] in
        Prim (-1, "map", items)
    | Lambda_t _, Lam (_, original_code) ->
        original_code

let rec unparse_tagged_data
  : type a. a ty -> a -> Script.expr
  = fun ty a -> match ty, a with
    | Void_t, () ->
        Prim (-1, "void", [])
    | Int_t k, v ->
        Prim (-1, string_of_int_kind k, [ String (-1, Int64.to_string (to_int64 k v))])
    | String_t, s ->
        Prim (-1, "string", [ String (-1, s) ])
    | Bool_t, true ->
        Prim (-1, "bool", [ Prim (-1, "true", []) ])
    | Bool_t, false ->
        Prim (-1, "bool", [ Prim (-1, "false", []) ])
    | Timestamp_t, t ->
        Prim (-1, "timestamp", [ String (-1, Timestamp.to_notation t) ])
    | Contract_t (ta, tr), (_, _, c)  ->
        let ta = unparse_ty ta in
        let tr = unparse_ty tr in
        Prim (-1, "contract", [ ta; tr; String (-1, Contract.to_b48check c) ])
    | Signature_t, s ->
        let text =
          Hex_encode.hex_encode
            (MBytes.to_string (Data_encoding.Binary.to_bytes Ed25519.signature_encoding s)) in
        Prim (-1, "signature", [ String (-1, text) ])
    | Tez_t, v ->
        Prim (-1, "tez", [ String (-1, Tez.to_string v) ])
    | Key_t, k ->
        Prim (-1, "key", [ String (-1, Ed25519.Public_key_hash.to_b48check k)])
    | Pair_t (tl, tr), (l, r) ->
        let l = unparse_untagged_data tl l in
        let r = unparse_untagged_data tr r in
        let tl = unparse_ty tl in
        let tr = unparse_ty tr in
        Prim (-1, "pair", [ tl; tr; l; r ])
    | Union_t (tl, tr), L l ->
        let l = unparse_tagged_data tl l in
        let tr = unparse_ty tr in
        Prim (-1, "left", [ l; tr ])
    | Union_t (tl, tr), R r ->
        let r = unparse_tagged_data tr r in
        let tl = unparse_ty tl in
        Prim (-1, "right", [ tl; r ])
    | Option_t t, Some v ->
        let v = unparse_tagged_data t v in
        Prim (-1, "some", [ v ])
    | Option_t t, None ->
        let t = unparse_ty t in
        Prim (-1, "none", [ t ])
    | List_t t, items ->
        let items = List.map (unparse_untagged_data t) items in
        let t = unparse_ty t in
        Prim (-1, "list", t :: items)
    | Set_t t, set ->
        let t = ty_of_comparable_ty t in
        let items =
          set_fold
            (fun item acc ->
               unparse_untagged_data t item :: acc )
            set [] in
        let t = unparse_ty t in
        Prim (-1, "set", t :: items)
    | Map_t (kt, vt), map ->
        let kt = ty_of_comparable_ty kt in
        let items =
          map_fold (fun k v acc ->
              Prim (-1, "item",
                    [ unparse_untagged_data kt k;
                      unparse_untagged_data vt v ])
              :: acc)
            map [] in
        let kt = unparse_ty kt in
        let vt = unparse_ty vt in
        Prim (-1, "map", kt :: vt :: items)
    | Lambda_t (ta, tr), Lam (_, original_code) ->
        let ta = unparse_ty ta in
        let tr = unparse_ty tr in
        Prim (-1, "lambda", [ ta; tr; original_code ])

type ex_script = Ex : ('a, 'b, 'c) script -> ex_script

let parse_script
  : context -> Script.storage -> Script.code -> ex_script tzresult Lwt.t
  = fun ctxt { storage; storage_type } { code; arg_type; ret_type } ->
    parse_ty arg_type >>=? fun (Ex arg_type) ->
    parse_ty ret_type >>=? fun (Ex ret_type) ->
    parse_ty storage_type >>=? fun (Ex storage_type) ->
    let arg_type_full = Pair_t (Pair_t (Tez_t, arg_type), storage_type) in
    let ret_type_full = Pair_t (ret_type, storage_type) in
    parse_untagged_data ctxt storage_type storage >>=? fun storage ->
    parse_lambda ctxt ~storage_type arg_type_full ret_type_full code >>=? fun code ->
    return (Ex { code; arg_type; ret_type; storage; storage_type })

type type_map =
  (int * (Script.expr list * Script.expr list)) list

let type_map_enc =
  let open Data_encoding in
  list
    (tup2
       int31
       (tup2
          (list Script.expr_encoding)
          (list Script.expr_encoding)))

let type_map descr =
  let rec unparse_stack
    : type a. a stack_ty -> Script.expr list
    = function
      | Empty_t -> []
      | Item_t (ty, rest) -> unparse_ty ty :: unparse_stack rest in
  let rec type_map
    : type bef aft. type_map -> (bef, aft) descr -> type_map
    = fun acc { loc ; instr ; bef ; aft } ->
      let self acc =
        (loc, (unparse_stack bef, unparse_stack aft)) :: acc in
      match instr with
      | If_none (dbt, dbf) ->
          let acc = type_map acc dbt in
          let acc = type_map acc dbf in
          self acc
      | If_left (dbt, dbf) ->
          let acc = type_map acc dbt in
          let acc = type_map acc dbf in
          self acc
      | If_cons (dbt, dbf) ->
          let acc = type_map acc dbt in
          let acc = type_map acc dbf in
          self acc
      | Seq (dl, dr) ->
          let acc = type_map acc dl in
          let acc = type_map acc dr in
          acc
      | If (dbt, dbf) ->
          let acc = type_map acc dbt in
          let acc = type_map acc dbf in
          self acc
      | Loop body ->
          let acc = type_map acc body in
          self acc
      | Dip body ->
          let acc = type_map acc body in
          self acc
      | _ ->
          self acc in
  type_map [] descr

let typecheck_code
  : context -> Script.code -> type_map tzresult Lwt.t
  = fun ctxt { code; arg_type; ret_type; storage_type } ->
    parse_ty arg_type >>=? fun (Ex arg_type) ->
    parse_ty ret_type >>=? fun (Ex ret_type) ->
    parse_ty storage_type >>=? fun (Ex storage_type) ->
    let arg_type_full = Pair_t (Pair_t (Tez_t, arg_type), storage_type) in
    let ret_type_full = Pair_t (ret_type, storage_type) in
    parse_lambda ctxt ~storage_type arg_type_full ret_type_full code
    >>=? fun (Lam (descr,_)) ->
    return (type_map descr)

let typecheck_tagged_data
  : context -> Script.expr -> unit tzresult Lwt.t
  = fun ctxt data ->
    parse_tagged_data ctxt data >>=? fun (Ex _) ->
    return ()

let typecheck_untagged_data
  : context -> Script.expr * Script.expr -> unit tzresult Lwt.t
  = fun ctxt (data, exp_ty) ->
    parse_ty exp_ty >>=? fun (Ex exp_ty) ->
    parse_untagged_data ctxt exp_ty data >>=? fun _ ->
    return ()
