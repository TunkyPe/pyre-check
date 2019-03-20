(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Expression
open Pyre


type mode =
  | Default
  | DefaultButDontCheck of int list
  | Declare
  | Strict
  | Infer
  | PlaceholderStub
[@@deriving compare, eq, show, sexp, hash]


module Metadata = struct
  type t = {
    autogenerated: bool;
    debug: bool;
    local_mode: mode;
    ignore_lines: Ignore.t list;
    number_of_lines: int;
    version: int;
  }
  [@@deriving compare, eq, show, hash, sexp]

  let create
      ?(autogenerated = false)
      ?(debug = true)
      ?(declare = false)
      ?(ignore_lines = [])
      ?(strict = false)
      ?(version = 3)
      ~number_of_lines
      () =
    let local_mode =
      if declare then
        Declare
      else if strict then
        Strict
      else
        Default
    in
    {
      autogenerated;
      debug;
      local_mode;
      ignore_lines;
      number_of_lines;
      version;
    }


  let signature_hash { autogenerated; debug; local_mode; version; _ }=
    [%hash: bool * bool * mode * int](autogenerated, debug, local_mode, version)


  let parse path lines =
    let is_python_2_shebang line =
      String.is_prefix ~prefix:"#!" line &&
      String.is_substring ~substring:"python2" line
    in
    let is_pyre_comment comment_substring line =
      String.is_prefix ~prefix:"#" line &&
      String.is_substring ~substring:comment_substring line
    in
    let is_debug = is_pyre_comment "pyre-debug" in
    let is_strict = is_pyre_comment "pyre-strict" in
    (* We do not fall back to declarative mode on a typo when attempting to only
       suppress certain errors. *)
    let is_declare line =
      Str.string_match (Str.regexp "^[ \t]*# *pyre-ignore-all-errors *$") line 0
    in
    let is_default_with_suppress line =
      let default_with_suppress_regex =
        Str.regexp "^[ \t]*# *pyre-ignore-all-errors\\[\\([0-9]+, *\\)*\\([0-9]+\\)\\] *$"
      in
      Str.string_match default_with_suppress_regex line 0
    in
    let is_placeholder_stub = is_pyre_comment "pyre-placeholder-stub" in
    let parse_ignore index line ignore_lines =
      let line_index = index + 1 in
      let create_ignore ~line ~kind =
        let codes =
          try
            Str.search_forward
              (Str.regexp "pyre-\\(ignore\\|fixme\\)\\[\\([0-9, ]+\\)\\]")
              line
              0
            |> ignore;
            Str.matched_group 2 line
            |> Str.split (Str.regexp "[^0-9]+")
            |> List.map ~f:Int.of_string
          with Not_found -> []
        in
        let location =
          let start_column =
            Str.search_forward (Str.regexp "\\(pyre-\\(ignore\\|fixme\\)\\|type: ignore\\)") line 0
          in
          let end_column = String.length line in
          let start = { Location.line = line_index; column = start_column } in
          let stop = { Location.line = line_index; column = end_column } in
          Location.reference { Location.path; start; stop }
        in
        Ignore.create ~ignored_line:(line_index) ~codes ~location ~kind
      in
      let contains_outside_quotes ~substring line =
        let find_substring index characters =
          String.is_substring ~substring characters && index mod 2 = 0
        in
        String.split_on_chars ~on:['\"'; '\''] line
        |> List.existsi ~f:find_substring
      in
      let ignore_lines =
        let kind =
          if (contains_outside_quotes ~substring:"pyre-ignore" line) &&
             not (contains_outside_quotes ~substring:"pyre-ignore-all-errors" line)
          then
            Some Ignore.PyreIgnore
          else if contains_outside_quotes ~substring:"pyre-fixme" line then
            Some Ignore.PyreFixme
          else if contains_outside_quotes ~substring:"type: ignore" line then
            Some Ignore.TypeIgnore
          else
            None
        in
        kind
        >>| (fun kind -> create_ignore ~line ~kind)
        >>| (fun data -> Int.Map.add_multi ~key:line_index ~data ignore_lines)
        |> Option.value ~default:ignore_lines
      in
      if String.is_prefix ~prefix:"#" (String.strip line) then
        (* Increment ignores applied to current line if it is a comment. *)
        match Int.Map.find ignore_lines line_index with
        | Some ignores ->
            let ignore_lines = Int.Map.remove ignore_lines line_index in
            begin
              match Int.Map.find ignore_lines (line_index + 1) with
              | Some existing_ignores ->
                  Int.Map.set
                    ~key:(line_index + 1)
                    ~data:((List.map ~f:Ignore.increment ignores) @ existing_ignores)
                    ignore_lines
              | None ->
                  Int.Map.set
                    ~key:(line_index + 1)
                    ~data:(List.map ~f:Ignore.increment ignores)
                    ignore_lines
            end
        | None ->
            ignore_lines
      else
        ignore_lines
    in
    let is_autogenerated line =
      String.is_substring ~substring:("@" ^ "generated") line ||
      String.is_substring ~substring:("@" ^ "auto-generated") line
    in

    let collect
        index
        (version, debug, local_mode, ignore_lines, autogenerated)
        line =
      let local_mode =
        match local_mode with
        | Some _ ->
            local_mode
        | None ->
            if is_default_with_suppress line then
              let suppressed_codes =
                Str.global_substitute (Str.regexp "[^,0-9]+") (fun _ -> "") line
                |> String.split_on_chars ~on:[',']
                |> List.map ~f:int_of_string
              in
              Some (DefaultButDontCheck suppressed_codes)
            else if is_declare line then
              Some Declare
            else if is_strict line then
              Some Strict
            else if is_placeholder_stub line then
              Some PlaceholderStub
            else
              None
      in
      let version =
        match version with
        | Some _ ->
            version
        | None ->
            if is_python_2_shebang line then Some 2 else None
      in
      version,
      debug || is_debug line,
      local_mode,
      parse_ignore index line ignore_lines,
      autogenerated || is_autogenerated line
    in
    let version, debug, local_mode, ignore_lines, autogenerated =
      List.map ~f:(fun line -> String.strip line |> String.lowercase) lines
      |> List.foldi ~init:(None, false, None, Int.Map.empty, false) ~f:collect
    in
    let local_mode = Option.value local_mode ~default:Default in
    {
      autogenerated;
      debug;
      local_mode;
      ignore_lines = ignore_lines |> Int.Map.data |> List.concat;
      number_of_lines = List.length lines;
      version = Option.value ~default:3 version;
    }
end


type t = {
  docstring: string option;
  hash: int;
  metadata: Metadata.t;
  handle: File.Handle.t;
  qualifier: Access.t;
  statements: Statement.t list;
}
[@@deriving compare, eq, hash, show, sexp]


let pp format { statements; _ } =
  let print_statement statement =
    Format.fprintf format "%a\n" Statement.pp statement
  in
  List.iter statements ~f:print_statement


let show source =
  Format.asprintf "%a" pp source


let mode ~configuration ~local_mode =
  match configuration, local_mode with
  | { Configuration.Analysis.infer = true; _ }, _ ->
      Infer

  | { Configuration.Analysis.strict = true; _ }, _
  | _, Some Strict ->
      Strict

  | { Configuration.Analysis.declare = true; _ }, _
  | _, Some Declare ->
      Declare

  | _, Some (DefaultButDontCheck suppressed_codes) ->
      DefaultButDontCheck suppressed_codes

  | _ ->
      Default


let create
    ?(docstring = None)
    ?(metadata = Metadata.create ~number_of_lines:(-1) ())
    ?(handle = File.Handle.create "")
    ?(qualifier = [])
    ?(hash = -1)
    statements =
  {
    docstring;
    hash;
    metadata;
    handle;
    qualifier;
    statements;
  }

let hash { hash; _ } =
  hash


let signature_hash { metadata; handle; qualifier; statements; _ } =
  let rec statement_hashes statements =
    let statement_hash { Node.value; _ } =
      let open Statement in
      match value with
      | Assign { Assign.target; annotation; value; parent } ->
          [%hash: Expression.t * (Expression.t option) * Expression.t * (Access.t option)]
            (target, annotation, value, parent)
      | Define { Define.name; parameters; decorators; return_annotation; async; parent; _ } ->
          [%hash:
            Reference.t *
            ((Expression.t Parameter.t) list) *
            (Expression.t list) *
            (Expression.t option) *
            bool *
            (Reference.t option)]
            (name, parameters, decorators, return_annotation, async, parent)
      | Class { Class.name; bases; body; decorators; _ } ->
          [%hash: Access.t * (Argument.t list) * (int list) * (Expression.t list)]
            (name, bases, (statement_hashes body), decorators)
      | If { If.test; body; orelse } ->
          [%hash: Expression.t * (int list) * (int list)]
            (test, statement_hashes body, statement_hashes orelse)
      | Import import ->
          [%hash: Import.t] import
      | With { With.body; _ } ->
          [%hash: (int list)] (statement_hashes body)
      | Assert _
      | Break
      | Continue
      | Delete _
      | Expression _
      | For _
      | Global _
      | Nonlocal _
      | Pass
      | Raise _
      | Return _
      | Try _
      | While _
      | Yield _
      | YieldFrom _ ->
          0
    in
    List.map statements ~f:statement_hash
  in
  [%hash: int * File.Handle.t * Access.t * (int list)]
    (Metadata.signature_hash metadata, handle, qualifier, (statement_hashes statements))


let ignore_lines { metadata = { Metadata.ignore_lines; _ }; _ } =
  ignore_lines


let statements { statements; _ } =
  statements


let qualifier ~handle =
  let qualifier =
    let reversed_elements =
      Filename.parts (File.Handle.show handle)
      |> List.tl_exn (* Strip current directory. *)
      |> List.rev in
    let last_without_suffix =
      let last = List.hd_exn reversed_elements in
      match String.rindex last '.' with
      | Some index ->
          String.slice last 0 index
      | _ ->
          last in
    let strip = function
      | "future" :: "builtins" :: tail
      | "builtins" :: tail ->
          tail
      | "__init__" :: tail ->
          tail
      | elements ->
          elements in
    (last_without_suffix :: (List.tl_exn reversed_elements))
    |> strip
    |> List.rev_map
      ~f:Access.create
    |> List.concat
  in
  if File.Handle.is_stub handle then
    (* Drop version from qualifier. *)
    let is_digit qualifier =
      try
        qualifier
        |> Int.of_string
        |> ignore;
        true
      with _ ->
        false
    in
    begin
      match qualifier with
      | minor :: major :: tail
        when is_digit (Access.show [minor]) &&
             is_digit (Access.show [major]) ->
          tail
      | major :: tail when is_digit (String.prefix (Access.show [major]) 1) ->
          tail
      | qualifier ->
          qualifier
    end
  else
    qualifier


let expand_relative_import ?handle ~qualifier ~from =
  match Access.show from with
  | "builtins" ->
      []
  | serialized ->
      (* Expand relative imports according to PEP 328 *)
      let dots = String.take_while ~f:(fun dot -> dot = '.') serialized in
      let postfix =
        match String.drop_prefix serialized (String.length dots) with
        (* Special case for single `.`, `..`, etc. in from clause. *)
        | "" -> []
        | nonempty -> Access.create nonempty
      in
      let prefix =
        if not (String.is_empty dots) then
          let initializer_module_offset =
            match handle with
            | Some handle ->
                let path = File.Handle.show handle in
                (* `.` corresponds to the directory containing the module. For non-init modules, the
                   qualifier matches the path, so we drop exactly the number of dots. However, for
                   __init__ modules, the directory containing it represented by the qualifier. *)
                if String.is_suffix path ~suffix:"/__init__.py"
                || String.is_suffix path ~suffix:"/__init__.pyi" then
                  1
                else
                  0
            | None ->
                0
          in
          List.rev qualifier
          |> (fun reversed -> List.drop reversed (String.length dots - initializer_module_offset))
          |> List.rev
        else
          []
      in
      prefix @ postfix
