(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

module Ed25519 = Environment.Ed25519

module RawContractAlias = Client_aliases.Alias (struct
    type t = Contract.t
    let encoding = Contract.encoding
    let of_source _ s =
      match Contract.of_b48check s with
      | Error _ -> Lwt.fail (Failure "bad contract notation")
      | Ok s -> Lwt.return s
    let to_source _ s =
      Lwt.return (Contract.to_b48check s)
    let name = "contract"
  end)

module ContractAlias = struct
  let find cctxt s =
    RawContractAlias.find_opt cctxt s >>= function
    | Some v -> Lwt.return (s, v)
    | None ->
        Client_keys.Public_key_hash.find_opt cctxt s >>= function
        | Some v ->
            Lwt.return (s, Contract.default_contract v)
        | None ->
            cctxt.error
              "no contract alias nor key alias names %s" s
  let find_key cctxt name =
    Client_keys.Public_key_hash.find cctxt name >>= fun v ->
    Lwt.return (name, Contract.default_contract v)

  let rev_find cctxt c =
    match Contract.is_default c with
    | Some hash -> begin
        Client_keys.Public_key_hash.rev_find cctxt hash >>= function
        | Some name -> Lwt.return (Some ("key:" ^ name))
        | None -> Lwt.return_none
      end
    | None -> RawContractAlias.rev_find cctxt c

  let get_contract cctxt s =
    match Utils.split ~limit:1 ':' s with
    | [ "key" ; key ]->
        find_key cctxt key
    | _ -> find cctxt s

  let alias_param ?(name = "name") ?(desc = "existing contract alias") next =
    let desc =
      desc ^ "\n"
      ^ "can be an contract alias or a key alias (autodetected in this order)\n\
         use 'key:name' to force the later" in
    Cli_entries.param ~name ~desc get_contract next

  let destination_param ?(name = "dst") ?(desc = "destination contract") next =
    let desc =
      desc ^ "\n"
      ^ "can be an alias, a key alias, or a literal (autodetected in this order)\n\
         use 'text:literal', 'alias:name', 'key:name' to force" in
    Cli_entries.param ~name ~desc
      (fun cctxt s ->
         match Utils.split ~limit:1 ':' s with
         | [ "alias" ; alias ]->
             find cctxt alias
         | [ "key" ; text ] ->
             Client_keys.Public_key_hash.find cctxt text >>= fun v ->
             Lwt.return (s, Contract.default_contract v)
         | _ ->
             Lwt.catch
               (fun () -> find cctxt s)
               (fun _ ->
                  match Contract.of_b48check s with
                  | Error _ -> Lwt.fail (Failure "bad contract notation")
                  | Ok v -> Lwt.return (s, v)))
      next

   let name cctxt contract =
     rev_find cctxt contract >|= function
     | None -> Contract.to_b48check contract
     | Some name -> name

end

let get_manager cctxt block source =
  match Contract.is_default source with
  | Some hash -> return hash
  | None -> Client_proto_rpcs.Context.Contract.manager cctxt block source

let get_delegate cctxt block source =
  let open Client_keys in
  match Contract.is_default source with
  | Some hash -> return hash
  | None ->
      Client_proto_rpcs.Context.Contract.delegate cctxt block source >>=? function
      | Some delegate -> return delegate
      | None -> Client_proto_rpcs.Context.Contract.manager cctxt block source

let may_check_key sourcePubKey sourcePubKeyHash =
  match sourcePubKey with
  | Some sourcePubKey ->
      if not (Ed25519.Public_key_hash.equal (Ed25519.hash sourcePubKey) sourcePubKeyHash)
      then
        failwith "Invalid public key in `client_proto_endorsement`"
      else
        return ()
  | None -> return ()

let check_public_key cctxt block ?src_pk src_pk_hash =
  Client_proto_rpcs.Context.Key.get cctxt block src_pk_hash >>= function
  | Error errors ->
      begin
        match src_pk with
        | None ->
            let exn = Client_proto_rpcs.string_of_errors errors in
            failwith "Unknown public key\n%s" exn
        | Some key ->
            may_check_key src_pk src_pk_hash >>=? fun () ->
            return (Some key)
      end
  | Ok _ -> return None

let group =
  { Cli_entries.name = "contracts" ;
    title = "Commands for managing the record of known contracts" }

let commands  () =
  let open Cli_entries in
  [
    command ~group ~desc: "add a contract to the wallet"
      (prefixes [ "remember" ; "contract" ]
       @@ RawContractAlias.fresh_alias_param
       @@ RawContractAlias.source_param
       @@ stop)
      (fun name hash cctxt -> RawContractAlias.add cctxt name hash) ;
    command ~group ~desc: "remove a contract from the wallet"
      (prefixes [ "forget" ; "contract" ]
       @@ RawContractAlias.alias_param
       @@ stop)
      (fun (name, _) cctxt -> RawContractAlias.del cctxt name) ;
    command ~group ~desc: "lists all known contracts"
      (fixed [ "list" ; "known" ; "contracts" ])
      (fun cctxt ->
         RawContractAlias.load cctxt >>= fun list ->
         Lwt_list.iter_s (fun (n, v) ->
             let v = Contract.to_b48check v in
             cctxt.message "%s: %s" n v)
           list >>= fun () ->
         Client_keys.Public_key_hash.load cctxt >>= fun list ->
         Lwt_list.iter_s (fun (n, v) ->
             RawContractAlias.mem cctxt n >>= fun mem ->
             let p = if mem then "key:" else "" in
             let v = Contract.to_b48check (Contract.default_contract v) in
             cctxt.message "%s%s: %s" p n v)
           list >>= fun () ->
         Lwt.return ()) ;
    command ~group ~desc: "forget all known contracts"
      (fixed [ "forget" ; "all" ; "contracts" ])
      (fun cctxt ->
         if not Client_config.force#get then
            cctxt.Client_commands.error "this can only used with option -force true"
         else
           RawContractAlias.save cctxt []) ;
    command ~group ~desc: "display a contract from the wallet"
      (prefixes [ "show" ; "known" ; "contract" ]
       @@ RawContractAlias.alias_param
       @@ stop)
      (fun (_, contract) cctxt ->
         cctxt.message "%a\n%!" Contract.pp contract) ;
  ]
