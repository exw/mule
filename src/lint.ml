open Ast.Surface
open Ast.Surface.Expr

let rec collect_pat_vars = function
  | Pattern.Integer _ -> VarSet.empty
  | Pattern.Wild -> VarSet.empty
  | Pattern.Var (v, _) -> VarSet.singleton v
  | Pattern.Ctor(_, p) -> collect_pat_vars p

let err e =
  raise (MuleErr.MuleExn e)
let unboundVar v =
  err (MuleErr.UnboundVar v)
let duplicate_fields dups =
  err (MuleErr.DuplicateFields dups)

(* Check for unbound variables. *)
let check_unbound_vars expr =
  let rec go_expr typ term = function
    | Integer _ | Text _ -> ()
    | Var v when Set.mem term v -> ()
    | Var v -> unboundVar v
    | Lam([], body) ->
        go_expr typ term body
    | Lam(pat :: pats, body) ->
        go_pat typ pat;
        let term_new = collect_pat_vars pat in
        go_expr typ (Set.union term term_new) (Lam(pats, body))
    | App(f, x) -> go_expr typ term f; go_expr typ term x
    | Record fields ->
        let (new_types, new_terms) =
          List.partition_map fields ~f:(function
              | `Type(l, _, _)  -> `Fst (Ast.var_of_label l)
              | `Value(l, _, _) -> `Snd (Ast.var_of_label l)
            )
        in
        let typ = List.fold new_types ~init:typ ~f:Set.add in
        let term = List.fold new_terms ~init:term ~f:Set.add in
        List.iter fields ~f:(go_field typ term)
    | GetField (e, _) -> go_expr typ term e
    | Ctor _ -> ()
    | Update (e, fields) ->
        go_expr typ term e;
        List.iter fields ~f:(go_field typ term)
    | Match (e, cases) ->
        go_expr typ term e;
        List.iter cases ~f:(go_case typ term)
    | Let(binds, body) ->
        go_let typ term binds body
    | WithType (e, ty) ->
        go_expr typ term e;
        go_type typ ty
  and go_let typ term binds body =
    let (typ, term) = List.fold binds ~init:(typ, term) ~f:(fun (typ, term) -> function
        | `BindVal(pat, _) -> (typ, Set.union (collect_pat_vars pat) term)
        | `BindType(v, _, _) -> (Set.add typ v, term)
      )
    in
    List.iter binds ~f:(go_binding typ term);
    go_expr typ term body
  and go_binding typ term = function
    | `BindVal(pat, body) ->
        go_pat typ pat;
        go_expr typ term body
    | `BindType(_, params, body) ->
        let typ = List.fold params ~init:typ ~f:Set.add in
        go_type typ body
  and go_field typ term = function
    | `Value (_, ty, e) ->
        go_expr typ term e;
        Option.iter ty ~f:(go_type typ)
    | `Type (_, params, ty) ->
        let typ = List.fold params ~init:typ ~f:Set.add in
        go_type typ ty
  and go_case typ term (pat, e) =
    go_pat typ pat;
    let pat_new = collect_pat_vars pat in
    go_expr typ (Set.union term pat_new) e
  and go_pat typ = function
    | Pattern.Integer _ -> ()
    | Pattern.Wild -> ()
    | Pattern.Var (_, None) -> ()
    | Pattern.Var (_, Some ty ) -> go_type typ ty
    | Pattern.Ctor(_, p) -> go_pat typ p
  and go_type typ = function
    | Type.Var v | Type.Path(v, _) when Set.mem typ v -> ()
    | Type.Var v | Type.Path(v, _) -> unboundVar v
    | Type.Quant(_, vars, ty) ->
        go_type (List.fold ~init:typ ~f:Set.add vars) ty
    | Type.Recur(var, ty) ->
        go_type (Set.add typ var) ty
    | Type.Fn(Type.Annotated(v, param), ret) ->
        go_type typ param;
        go_type (Set.add typ v) ret
    | Type.Fn(param, ret) ->
        go_type typ param;
        go_type typ ret
    | Type.Record record ->
        go_record typ record
    | Type.Ctor _ -> ()
    | Type.App (f, x) ->
        go_type typ f;
        go_type typ x
    | Type.Union(x, y) ->
        go_type typ x;
        go_type typ y
    | Type.RowRest v ->
        go_type typ (Type.Var v)
    | Type.Annotated(_, ty) ->
        go_type typ ty
  and go_record typ items =
    let (types, values) =
      List.partition_map items ~f:(function
          | Type.Type(lbl, _, _) ->
              `Fst (Ast.var_of_label lbl)
          | x ->
              `Snd x
        )
    in
    let typ' = List.fold types ~init:typ ~f:Set.add in
    List.iter values ~f:(go_record_item typ')
  and go_record_item typ = function
    | Type.Type(_, vars, Some ty) ->
        let typ = List.fold vars ~init:typ ~f:Set.add in
        go_type typ ty
    | Type.Type(_, _, None) -> ()
    | Type.Field(_, ty) -> go_type typ ty
    | Type.Rest var -> go_type typ (Type.Var var)
  in
  let keyset m =
    m
    |> Map.keys
    |> Set.of_list (module Ast.Var)
  in
  let term = keyset Intrinsics.values in
  let typ = keyset Intrinsics.types in
  go_expr typ term expr

(* Check for duplicate record fields (in both expressions and types) *)
let check_duplicate_record_fields =
  let rec go_expr = function
    | Integer _ | Text _ -> ()
    | Record fields ->
        go_fields fields
    | Update(e, fields) ->
        go_expr e; go_fields fields

    | Lam (pats, body) ->
        List.iter pats ~f:go_pat;
        go_expr body
    | Match(e, cases) ->
        go_expr e;
        List.iter cases ~f:go_case
    | App (f, x) -> go_expr f; go_expr x
    | GetField(e, _) -> go_expr e
    | Let(bindings, body) ->
        go_let bindings;
        go_expr body
    | Var _ -> ()
    | Ctor _ -> ()
    | WithType(e, ty) ->
        go_expr e;
        go_type ty
  and go_let =
    List.iter ~f:(function
        | `BindVal(pat, e) ->
            go_pat pat;
            go_expr e
        | `BindType(_, _, ty) -> go_type ty
      )
  and go_fields fields =
    List.iter fields ~f:(function
        | `Value (_, ty, e) ->
            Option.iter ty ~f:go_type;
            go_expr e
        | `Type (_, _, ty) ->
            go_type ty
      );
    let labels = List.map fields ~f:(function
        | `Value (lbl, _, _) -> lbl
        | `Type (lbl, _, _) -> lbl
      ) in
    go_labels labels
  and go_pat = function
    | Pattern.Integer _ -> ()
    | Pattern.Ctor(_, pat) -> go_pat pat
    | Pattern.Var (_, None) | Pattern.Wild -> ()
    | Pattern.Var (_, Some ty) -> go_type ty
  and go_type = function
    | Type.Var _
    | Type.Path _
    | Type.Ctor _
    | Type.RowRest _ -> ()
    | Type.Quant(_, _, ty) -> go_type ty
    | Type.Recur(_, ty) -> go_type ty
    | Type.Fn(param, ret) -> go_type param; go_type ret
    | Type.Record fields ->
        List.map fields ~f:(function
            | Type.Rest _ -> []
            | Type.Field(lbl, ty)
            | Type.Type(lbl, _, Some ty) ->
                go_type ty;
                [lbl]
            | Type.Type (lbl, _, None) ->
                [lbl]
          )
        |> List.concat
        |> go_labels
    | Type.Union(l, r) -> go_type l; go_type r
    | Type.App(f, x) -> go_type f; go_type x
    | Type.Annotated(_, ty) -> go_type ty
  and go_labels =
    let rec go all dups = function
      | (l :: ls) when Set.mem all l ->
          go all (Set.add dups l) ls
      | (l :: ls) ->
          go (Set.add all l) dups ls
      | [] when Set.is_empty dups -> ()
      | [] -> duplicate_fields (Set.to_list dups)
    in go LabelSet.empty LabelSet.empty
  and go_case (pat, body) =
    go_pat pat;
    go_expr body
  in
  go_expr

let check expr =
  try
    begin
      check_unbound_vars expr;
      check_duplicate_record_fields expr;
      (* TODO: check for duplicate bound variables (in recursive lets). *)
      Ok ()
    end
  with
    MuleErr.MuleExn e -> Error e
