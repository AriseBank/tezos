(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

let (>>=) = Lwt.bind

let remove_dir dir =
  let rec remove dir =
    let files = Lwt_unix.files_of_directory dir in
    Lwt_stream.iter_s
      (fun file ->
         if file = "." || file = ".." then
           Lwt.return ()
         else begin
           let file = Filename.concat dir file in
           if Sys.is_directory file
           then remove file
           else Lwt_unix.unlink file
         end)
      files >>= fun () ->
    Lwt_unix.rmdir dir in
  if Sys.file_exists dir && Sys.is_directory dir then
    remove dir
  else
    Lwt.return ()

let rec create_dir ?(perm = 0o755) dir =
  if Sys.file_exists dir then
    Lwt.return ()
  else begin
    create_dir (Filename.dirname dir) >>= fun () ->
    Lwt_unix.mkdir dir perm
  end

let create_file ?(perm = 0o644) name content =
  Lwt_unix.openfile name Unix.([O_TRUNC; O_CREAT; O_WRONLY]) perm >>= fun fd ->
  Lwt_unix.write_string fd content 0 (String.length content) >>= fun _ ->
  Lwt_unix.close fd


exception Exit
let termination_thread, exit_wakener = Lwt.wait ()
let exit x = Lwt.wakeup exit_wakener x; raise Exit

let () =
  Lwt.async_exception_hook :=
    (function
      | Exit -> ()
      | exn ->
          Printf.eprintf "Uncaught (asynchronous) exception: %S\n%s\n%!"
            (Printexc.to_string exn) (Printexc.get_backtrace ());
          exit 1)

module StringMap = Map.Make (String)

let split delim ?(limit = max_int) path =
  let l = String.length path in
  let rec do_slashes acc limit i =
    if i >= l then
      List.rev acc
    else if String.get path i = delim then
      do_slashes acc limit (i + 1)
    else
      do_split acc limit i
  and do_split acc limit i =
    if limit <= 0 then
      if i = l then
        List.rev acc
      else
        List.rev (String.sub path i (l - i) :: acc)
    else
      do_component acc (pred limit) i i
  and do_component acc limit i j =
    if j >= l then
      if i = j then
        List.rev acc
      else
        List.rev (String.sub path i (j - i) :: acc)
    else if String.get path j = delim then
      do_slashes (String.sub path i (j - i) :: acc) limit j
    else
      do_component acc limit i (j + 1) in
  if limit > 0 then
    do_slashes [] limit 0
  else
    [ path ]

let split_path path = split '/' path

let map_option ~f = function
  | None -> None
  | Some x -> Some (f x)

let iter_option ~f = function
  | None -> ()
  | Some x -> f x

let unopt x = function
  | None -> x
  | Some x -> x

let unopt_list l =
  let may_cons xs x = match x with None -> xs | Some x -> x :: xs in
  List.rev @@ List.fold_left may_cons [] l

let filter_map f l =
  let may_cons xs x = match f x with None -> xs | Some x -> x :: xs in
  List.rev @@ List.fold_left may_cons [] l

let display_paragraph ppf description =
  Format.fprintf ppf "@[%a@]"
    (fun ppf words -> List.iter (Format.fprintf ppf "%s@ ") words)
    (split ' ' description)

let rec remove_elem_from_list nb = function
  | [] -> []
  | l when nb <= 0 -> l
  | _ :: tl -> remove_elem_from_list (nb - 1) tl
