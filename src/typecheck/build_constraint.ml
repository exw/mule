open Ast.Desugared
open Typecheck_types
open Gensym
open Gen_t
module Const = Ast.Const

include Build_constraint_t

let child_g parent child =
  { g_id = gensym ()
  ; g_bound = parent
  ; g_child = child
  }

let with_g: g_node -> (g_node Lazy.t -> u_type UnionFind.var) -> g_node =
  fun parent f -> fst
      ( Util.fix
          (child_g (Some{b_ty = `Flex; b_at = parent}))
          (fun g ->
             let root = f g in
             UnionFind.make (`Quant(gen_ty_var (Lazy.force g), root))
          )
      )

let walk_const g c =
  let ty = match c with
    | Const.Integer _ -> int
    | Const.Text _ -> text
    | Const.Char _ -> char
  in
  UnionFind.make (ty (gen_ty_var g))

let rec walk: context -> k_var Expr.t -> u_var =
  fun ({cops; env_types; env_terms; g} as ctx) -> function
    | Expr.Const {const_val = c} -> walk_const g c
    | Expr.Var {v_var = v} ->
        let tv = gen_u kvar_type (`G g) in
        begin match Option.map ~f:Lazy.force (Map.find env_terms v) with
          | None ->
              MuleErr.throw (`UnboundVar v)
          | Some (`Ty tv') ->
              cops.constrain_unify
                (`VarUse
                   (object
                     method bind_type = `Lambda
                     method var = v
                   end)
                )
                tv' tv
          | Some (`G g') ->
              cops.constrain_inst g' tv
        end;
        tv
    | Expr.Fix _ ->
        (* all a. (a -> a) -> a *)
        let rec ret = lazy (
          let b_at = `Ty ret in
          let a = gen_u kvar_type b_at in
          UnionFind.make
            ( fn
                (gen_ty_var g)
                (UnionFind.make (fn (ty_var_at b_at) a a))
                a
            )
        ) in
        Lazy.force ret
    | Expr.Lam {l_param = param; l_body = body} ->
        let param_var = gen_u kvar_type (`G g) in
        let ret_var = gen_u kvar_type (`G g) in
        let f_var = UnionFind.make (fn (gen_ty_var g) param_var ret_var) in
        let g_body = with_g g
            (fun g -> walk
                { ctx with
                  env_terms = Map.set env_terms ~key:param ~data:(lazy (`Ty param_var));
                  g = Lazy.force g;
                }
                body
            )
        in
        cops.constrain_inst g_body ret_var;
        f_var
    | Expr.Let{let_v = v; let_e = e; let_body = body} ->
        let g_e =
          with_g g (fun g -> walk { ctx with g = Lazy.force g } e)
        in
        walk
          { ctx with env_terms =
                       Map.set env_terms ~key:v ~data:(lazy (`G g_e))
          }
          body
    | Expr.LetType{letty_binds = binds; letty_body = body} ->
        let binds = Map.of_alist_exn (module Ast.Var) binds in
        let env_types =
          Map.merge_skewed
            env_types
            (Map.map binds ~f:(fun _ -> gen_u (gen_k ()) (`G g)))
            ~combine:(fun ~key:_ _ v -> v)
        in
        let ctx = { ctx with env_types } in
        let u_vars = Coercions.gen_types { ctx; b_at = `G g } `Pos binds in
        let env_new =
          Map.merge_skewed
            env_types
            u_vars
            ~combine:(fun ~key:var l r ->
                cops.constrain_kind
                  (`VarUse
                     (object
                       method bind_type = `LetType;
                       method var = var;
                     end))
                  (get_kind l)
                  (get_kind r);
                r
              )
        in
        walk { ctx with env_types = env_new } body
    | Expr.App {app_fn = f; app_arg = arg} ->
        let param_var = gen_u kvar_type (`G g) in
        let ret_var = gen_u kvar_type (`G g) in
        let f_var = UnionFind.make(fn (gen_ty_var g) param_var ret_var) in
        let g_f =
          with_g g (fun g -> walk { ctx with g = Lazy.force g} f)
        in
        cops.constrain_inst g_f f_var;
        let g_arg =
          with_g g (fun g -> walk { ctx with g = Lazy.force g } arg)
        in
        cops.constrain_inst g_arg param_var;
        ret_var
    | Expr.EmptyRecord ->
        UnionFind.make
          (record
             (ty_var_at (`G g))
             (gen_u kvar_row (`G g))
             (UnionFind.make (empty (ty_var_at (`G g))))
          )
    | Expr.GetField {gf_lbl; _} ->
        (* Field accesses have the type:
         *
         * all a r. {lbl: a, ...r} -> a
        *)
        let rec ret = lazy (
          let b_at = `Ty ret in
          let head_var = gen_u kvar_type b_at in
          UnionFind.make
            (fn
               (gen_ty_var g)
               (UnionFind.make
                  (record
                     (ty_var_at b_at)
                     (gen_u kvar_row b_at)
                     (UnionFind.make
                        (extend
                           (ty_var_at b_at)
                           gf_lbl
                           head_var
                           (gen_u kvar_row b_at)
                        ))))
               head_var)
        )
        in
        Lazy.force ret
    | Expr.Update { up_level = `Value; up_lbl } ->
        (* Record updates have the type:
         *
         * all a r. {...r} -> a -> {lbl: a, ...r}
        *)
        let rec ret = lazy (
          let b_at = `Ty ret in
          let head_var = gen_u kvar_type b_at in
          let tail_var = gen_u kvar_row b_at in
          let types_row_var = gen_u kvar_row b_at in
          UnionFind.make
            (fn
               (gen_ty_var g)
               (UnionFind.make
                  (record
                     (ty_var_at b_at)
                     types_row_var
                     tail_var))
               (UnionFind.make
                  (fn
                     (ty_var_at b_at)
                     head_var
                     (UnionFind.make
                        (record
                           (ty_var_at b_at)
                           types_row_var
                           (UnionFind.make
                              (extend
                                 (ty_var_at b_at)
                                 up_lbl
                                 head_var
                                 tail_var
                              )))))))
        ) in
        Lazy.force ret
    | Expr.Update {
        up_level = `Type;
        up_lbl = lbl;
      } ->
        let rec ret = lazy (
          let b_at = `Ty ret in
          let kvar = gen_k () in
          let head_var = gen_u kvar b_at in
          let tail_var = gen_u kvar_row b_at in
          let vals_row_var = gen_u kvar_row b_at in
          UnionFind.make
            (fn
               (gen_ty_var g)
               (UnionFind.make
                  (record
                     (ty_var_at b_at)
                     tail_var
                     vals_row_var))
               (UnionFind.make
                  (fn
                     (ty_var_at b_at)
                     (UnionFind.make (witness (ty_var_at b_at) kvar head_var))
                     (UnionFind.make
                        (record
                           (ty_var_at b_at)
                           (UnionFind.make
                              (extend
                                 (ty_var_at b_at)
                                 lbl
                                 head_var
                                 tail_var))
                           vals_row_var)))))
        ) in
        Lazy.force ret
    | Expr.Ctor {c_lbl = lbl; c_arg = param} ->
        let param_var = walk ctx param in
        UnionFind.make
          (union
             (ty_var_at (`G g))
             (UnionFind.make
                (extend
                   (ty_var_at (`G g))
                   lbl
                   param_var
                   (gen_u kvar_row (`G g)))
             )
          )
    | Expr.Match {cases; default} when Map.is_empty cases ->
        let term =
          match default with
          | None -> MuleErr.throw `EmptyMatch
          | Some (Some l_param, l_body) ->
              Expr.Lam{l_param; l_body}
          | Some (None, l_body) ->
              Expr.Lam {
                l_param = Ast.Var.of_string "_";
                l_body;
              }
        in
        walk ctx term
    | Expr.ConstMatch {cm_cases; cm_default} ->
        let body_ty = gen_u kvar_type (`G g) in
        let arg_ty = gen_u kvar_type (`G g) in
        Map.iteri cm_cases ~f:(fun ~key:c ~data:body ->
            let ty = walk ctx body in
            cops.constrain_unify `MatchSiblingsBody ty body_ty;
            cops.constrain_unify `MatchSiblingsPattern (walk_const g c) arg_ty
          );
        let f_ty =
          UnionFind.make (fn (gen_ty_var g) arg_ty body_ty)
        in
        let default_ty = walk ctx cm_default in
        cops.constrain_unify `MatchDefault f_ty default_ty;
        f_ty
    | Expr.Match {cases; default} ->
        let final = match default with
          | None -> UnionFind.make (empty (gen_ty_var g))
          | Some _ -> gen_u kvar_row (`G g)
        in
        let (rowVar, bodyVar) =
          walk_match ctx final (Map.to_alist cases)
        in
        let bound = (get_tyvar (UnionFind.get rowVar)).ty_bound in
        let tv = { ty_id = gensym (); ty_bound = bound } in
        UnionFind.make
          (fn
             (gen_ty_var g)
             (UnionFind.make (union tv rowVar))
             bodyVar)
    | Expr.WithType {wt_type = ty} ->
        Coercions.make_coercion_type ctx ty
    | Expr.Witness {wi_type = ty} ->
        let uty = Coercions.gen_type { ctx; b_at = `G g } `Pos ty in
        UnionFind.make (witness (ty_var_at (`G g)) (Type.get_info ty) uty)
and walk_match ({cops; env_types = _; env_terms; g} as ctx) final =
  List.fold_right
    ~init:(final, gen_u kvar_type (`G g))
    ~f:(fun (lbl, (var, body)) (row, body') ->
        let ty = gen_u kvar_type (`G g) in
        let bodyVar =
          walk
            { ctx with
              env_terms = Map.set env_terms ~key:var ~data:(lazy (`Ty ty))
            }
            body
        in
        cops.constrain_unify `MatchSiblingsBody bodyVar body';
        ( UnionFind.make (extend (gen_ty_var g) lbl ty row)
        , bodyVar
        )
      )


let make_cops: unit ->
  ( constraint_ops
    * (unify_edge list) ref
    * ((g_node * (u_type UnionFind.var) list) IntMap.t) ref
    * (Types.reason * k_var * k_var) list ref
  ) = fun () ->
  let ucs = ref [] in (* unification constraints *)
  let ics = ref IntMap.empty in (* instantiation constraints *)
  let kcs = ref [] in (* kind constraints *)
  let cops =
    { constrain_unify   =
        (fun reason l r ->
           ucs := Unify(reason, l, r) :: !ucs)
    ; constrain_inst =
        begin fun g t ->
          ics := Map.update !ics g.g_id ~f:(function
              | None -> (g, [t])
              | Some (_, ts) -> (g, (t :: ts))
            )
        end
    ; constrain_kind =
        (fun rsn l r ->
           kcs := (rsn, l, r) :: !kcs)
    }
  in (cops, ucs, ics, kcs)

let build_constraints: k_var Expr.t -> built_constraints =
  fun expr ->
  let env_terms = Map.map ~f:fst Intrinsics.values in
  let cops, ucs, ics, kcs = make_cops () in
  let (_, ty) = Util.fix
      (child_g None)
      (fun g ->
         let g = Lazy.force g in
         let b_at = `G g in
         let env_types = Map.map Intrinsics.types ~f:(fun ty ->
             let ctx = {
               cops; g; env_types = VarMap.empty; env_terms = VarMap.empty;
             }
             in
             UnionFind.make
               ( `Quant
                   ( ty_var_at b_at
                   , Coercions.gen_type { b_at; ctx } `Pos ty
                   )
               )
           )
         in
         let env_terms = Map.map env_terms ~f:(fun ty ->
             lazy (`G (with_g g (fun g ->
                 let g = Lazy.force g in
                 let b_at = `G g in
                 let ctx = { cops; g; env_types; env_terms = VarMap.empty } in
                 UnionFind.make (
                   `Quant
                     ( ty_var_at b_at
                     , Coercions.gen_type { b_at; ctx } `Pos ty
                     )
                 )))
               )
           )
         in
         let root = walk {cops; env_types; env_terms; g} expr in
         UnionFind.make(`Quant(gen_ty_var g, root))
      )
  in
  { unification = !ucs
  ; instantiation = !ics
  ; kind = !kcs
  ; ty = ty
  }
