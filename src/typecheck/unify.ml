open Typecheck_types
open Gensym

type unify_ctx = {
  c_already_merged: IntPairSet.t;
  c_rsn: Types.reason;
  c_root_l: u_var;
  c_root_r: u_var;
}

(* Helpers for signaling type errors *)
let typeErr e = MuleErr.throw (`TypeError e)
let permErr rsn op = typeErr (rsn, `PermissionErr op)
let ctorErr rsn l r = typeErr (rsn, `MismatchedCtors (l, r))

(* Get the "permission" of a node, based on the node's binding path
 * (starting from the node and working up the tree). See section 3.1
 * in {MLF-Graph-Unify}. *)
let get_permission: (unit, bound_ty) Sequence.Generator.t -> permission =
  fun p ->
  let rec go p = match Sequence.next p with
    | None -> F
    | Some (`Explicit, _) -> E
    | Some (`Rigid, _) -> R
    | Some (`Flex, bs) ->
        begin match go bs with
          | F -> F
          | R | L -> L
          | E -> E
        end
  in go (Sequence.Generator.run p)

let rec gnode_bound_list: g_node -> (unit, bound_ty) Sequence.Generator.t =
  fun {g_bound; _} -> Sequence.Generator.(
      match g_bound with
      | None -> return ()
      | Some {b_ty; b_at} ->
          yield b_ty >>= fun () -> gnode_bound_list b_at
    )
let rec tyvar_bound_list: tyvar -> (unit, bound_ty) Sequence.Generator.t =
  fun {ty_bound; _} -> bound_list !ty_bound
and tgt_bound_list = function
  | `G g -> gnode_bound_list g
  | `Ty t -> ty_bound_list (UnionFind.get (Lazy.force t))
and bound_list {b_ty; b_at} =
  Sequence.Generator.(
    yield b_ty >>= fun () -> tgt_bound_list b_at
  )
and ty_bound_list ty =
  tyvar_bound_list (get_tyvar ty)

let tyvar_permission: tyvar -> permission =
  fun tv ->
  get_permission (tyvar_bound_list tv)

let bound_permission: bound_target bound -> permission =
  fun b -> get_permission (bound_list b)

let b_at_id = function
  | `G {g_id; _} -> g_id
  | `Ty u -> (get_tyvar (UnionFind.get (Lazy.force u))).ty_id

let bound_id {b_at; _} = b_at_id b_at

let bound_next {b_at; _} = match b_at with
  | `G {g_bound; _} ->
      begin match g_bound with
        | None -> None
        | Some {b_ty; b_at = g} -> Some
              { b_ty
              ; b_at = `G g
              }
      end
  | `Ty u ->
      Some !((get_tyvar (UnionFind.get (Lazy.force u))).ty_bound)

(* Raise b one step, if it is legal to do so, otherwise throw an error. *)
let raised_bound rsn b =
  match bound_permission b with
  | L -> permErr rsn `Raise
  | _ -> bound_next b

(* Compute the least common ancestor of two bounds.
 * If that ancestor is not reachable without performing
 * illegal raisings, fail. *)
let rec bound_lca: Types.reason -> bound_target bound -> bound_target bound -> bound_target bound =
  fun rsn l r ->
  let lid, rid = bound_id l, bound_id r in
  if lid = rid then
    l
  else
    begin match bound_permission l, bound_permission r with
      | E, _ | _, E | L, _ | _, L -> permErr rsn `Raise
      | _ when lid < rid ->
          begin match raised_bound rsn r with
            | Some b -> bound_lca rsn l b
            | None -> MuleErr.bug "No LCA!"
          end
      | _ ->
          begin match raised_bound rsn l with
            | Some b -> bound_lca rsn b r
            | None -> MuleErr.bug "No LCA!"
          end
    end

(* "Unify" two binding edges. This does a combination of raising and
 * weakening as needed to make them the same. It does not modify anything,
 * but rather returns the new common bound.*)
let unify_bound rsn l r =
  let {b_at; _} = bound_lca rsn l r in
  match l.b_ty, r.b_ty with
  | `Flex, `Flex -> {b_at; b_ty = `Flex}
  | `Flex, `Rigid | `Rigid, `Flex | `Rigid, `Rigid ->
      {b_at; b_ty = `Rigid}
  | `Flex, `Explicit | `Explicit, `Flex | `Explicit, `Explicit ->
      {b_at; b_ty = `Explicit}
  | `Rigid, `Explicit | `Explicit, `Rigid ->
      permErr rsn `Raise

(* Thin wrapper around [unify_bound], which updates the [tyvar]s' bounds
 * in-place. It does *not* permanantly link them, in the way that
 * UnionFind.merge does.
*)
let unify_tyvar: Types.reason -> tyvar -> tyvar -> tyvar =
  fun rsn l r ->
  let new_bound = unify_bound rsn !(l.ty_bound) !(r.ty_bound) in
  l.ty_bound := new_bound;
  r.ty_bound := new_bound;
  l


type graft_args = {
  ga_bottom_node: u_var;
  ga_other_node: u_var;
  ga_bottom_root: u_var;
}

(* Make a copy of a sub graph, with all nodes bound somewhere under a given
 * root. For nodes in the subgraph that point above it, the copies will point
 * to the root directly.
 *
 * This is meant as a helper for grafting.
 *)
let copy_under: u_var -> u_type -> u_var = fun root ty ->
  (* TODO: make sure the root stays inert if it's not a q node. *)
  let seen = ref IntMap.empty in
  let get_b_at tv =
    match (!(tv.ty_bound)).b_at with
    | `G _ -> `Ty (lazy root);
    | `Ty luv ->
        let bound_tv =
          Lazy.force luv
          |> UnionFind.get
          |> get_tyvar
        in
        begin match Map.find !seen bound_tv.ty_id with
          | Some _ -> `Ty luv
          | None -> `Ty (lazy root)
        end
  in
  let get_bound tv = {
      b_at = get_b_at tv;
      b_ty = (!(tv.ty_bound)).b_ty;
    }
  in
  let copy_tv tv = {
    ty_id = gensym ();
    ty_bound = ref (get_bound tv);
  }
  in
  let rec go ty =
    let tv = get_tyvar ty in
    begin match Map.find !seen tv.ty_id with
      | Some uv -> uv
      | None ->
          let new_tv = copy_tv tv in

          (* XXX: this is super gross; get_kind really should just take a
           * u_type, but it takes a u_var so we wrap the type momentarily in order
           * to use it. TODO: clean this up. *)
          let k = get_kind (UnionFind.make ty) in

          let ret = UnionFind.make (`Free (new_tv, k)) in
          seen := Map.set ~key:tv.ty_id ~data:ret !seen;
          begin match ty with
          | `Free _ ->
              (* Already done; the free node we just made is actually the same here. *)
              ()
          | `Quant(_, arg) ->
              let new_arg = go (UnionFind.get arg) in
              UnionFind.set (`Quant(new_tv, new_arg)) ret
          | `Const(_, c, args, k) ->
              let new_args =
                List.map args ~f:(fun (t, k) -> (go (UnionFind.get t), k))
              in
              UnionFind.set (`Const(new_tv, c, new_args, k)) ret
          end;
          ret
    end
  in
  go ty

(* Check if two subgraphs are safe to merge. If not, raise the given error.
 *
 * TODO: it would be better to wrap the error in something that explained the
 * problem. The error should explain why a bottom-up merge attempt didn't work,
 * but we should add extra info for why top-down wasn't good enough either.
 *)
let check_merge_graphs: MuleErr.t -> u_type -> u_type -> unit =
  fun e l r ->
    (* Two maps for keeping track of which nodes from the sub
     * graphs correspond to one another: *)
    let l2r = ref IntMap.empty in
    let r2l = ref IntMap.empty in

    let rec go l r =
      let tvl = get_tyvar l in
      let tvr = get_tyvar r in
      let check_bounds () =
        (* If these are empty it's because we're the root; nothing
         * to do: *)
        if not (Map.is_empty !l2r) then
          begin
            let get_tgt_id tv =
              let {b_at; _} = !(tv.ty_bound) in
              match b_at with
              | `G _ ->
                  (* Condition 4: bound on g-node, which is therefore above
                   * our root. *)
                  raise (MuleErr.MuleExn e)
              | `Ty t -> (get_tyvar (UnionFind.get (Lazy.force t))).ty_id
            in
            (* make sure these are bound somewhere higher up in the tree. *)
            let lparent = get_tgt_id tvl in
            let rparent = get_tgt_id tvr in
            if not (Map.mem !l2r lparent && Map.mem !r2l rparent) then
              (* Condition 4 failed; one of the nodes is bound above our
               * root. *)
              raise (MuleErr.MuleExn e)
          end
      in
      if tvl.ty_id = tvr.ty_id then
        (* Same node, we're good. *)
        ()
      else
        begin match l, r with
        | `Const(_, cl, argsl, _), `Const(_, cr, argsr, _) ->
            if not (typeconst_eq cl cr) then
              (* The graphs are not isomorphic; if this didn't get fixed during
               * the bottom up attempt then we're out of luck. *)
              raise (MuleErr.MuleExn e);
            let arg_pairs = List.zip_exn argsl argsr in
            List.iter arg_pairs
              ~f:(fun ((l, _), (r, _)) ->
                  go (UnionFind.get l) (UnionFind.get r)
                )
        | `Quant(_, argl), `Quant(_, argr) ->
            check_bounds ();
            go (UnionFind.get argl) (UnionFind.get argr)
        | `Free _, `Free _ ->
            check_bounds ()
        | _ ->
          (* Graphs are not isomorphic. *)
          raise (MuleErr.MuleExn e)
        end
    in
    go l r

let rec unify: unify_ctx -> u_var -> u_var -> unit = fun ctx l' r' ->
  let finish v = UnionFind.merge (fun _ _ -> v) l' r' in
  let l, r = UnionFind.get l', UnionFind.get r' in
  !Debug.render_hook ();
  let lid, rid = (get_tyvar l).ty_id, (get_tyvar r).ty_id in
  if lid = rid || Set.mem ctx.c_already_merged (lid, rid) then
    finish l
  else begin
    let ctx =
      { ctx with c_already_merged = Set.add ctx.c_already_merged (lid, rid) }
    in
    let merge_tv () =
      let tv = unify_tyvar ctx.c_rsn (get_tyvar l) (get_tyvar r) in
      if perm_eq (tyvar_permission tv) L then
        permErr ctx.c_rsn `Merge
      else
        tv
    in
    match l, r with
    (* If they're both free we should see if we can do a
     * merge: *)
    | `Free (_, kl), `Free _ -> finish (`Free (merge_tv (), kl))

    (* Otherwise, try grafting first. It is important that we do the graft
     * permission checks *before* any raisings/weakenings to get the bounds to
     * match -- otherwise we could get spurrious permission errors. *)
    | (`Free (v, _)), _ when perm_eq (tyvar_permission v) F -> graft_and_unify ctx {
        ga_bottom_node = l';
        ga_bottom_root = ctx.c_root_l;
        ga_other_node = r';
      }
    | _, (`Free (v, _)) when perm_eq (tyvar_permission v) F -> graft_and_unify ctx {
        ga_bottom_node = r';
        ga_bottom_root = ctx.c_root_r;
        ga_other_node = l';
      }
    | (`Free _), _ | _, (`Free _) -> permErr ctx.c_rsn `Graft

    (* Neither side of these is a type variable, so we need to do a merge.
     * See the definition in section 3.2.2 of {MLF-Graph-Unify}. *)
    | `Quant(_, argl), `Quant(_, argr) ->
        begin
          try
            normalize_unify
              { ctx with c_rsn = `Cascade(ctx.c_rsn, 1) }
              argl
              argr;
            finish (`Quant(merge_tv (), argl))
          with MuleErr.MuleExn e ->
            begin
              (* We couldn't do the merge in a bottom-up fashion, as described
               * in the comments for the Const,Const case below. Instead, we
               * check the remaining invariants and do the merge directly.
               * In particular:
               *
               * - check_merge_graphs verfies 1 & 4.
               * - 2 is satisified by definition.
               * - 3 is checked by merge_tv, as in the bottom up case.
               *
               * It doesn't make sense to do this on `Const nodes; being
               * inert means that any failure in the bottom up strategy
               * would also affect the top-down strategy.
               *
               * On `Free nodes there is no subgraph to check; we handle
               * the `Free, `Free case above.
               *)
              check_merge_graphs e l r;
              finish (`Quant(merge_tv (), argl))
            end
        end

    | `Quant _, `Const _ | `Const _, `Quant _ ->
        MuleErr.bug "normalization left quant & const paired."
    | `Const(_, cl, argsl, k), `Const(_, cr, argsr, _) ->
        if typeconst_eq cl cr then
          (* Top level type constructors that match. We recursively
           * merge the types in a bottom-up fashion. Doing this makes it
           * easy to see that the conditions for being a valid merge
           * are satisfied:
           *
           * - 1 & 2 are trivial, since the subgraphs are always identical.
           * - 3 is enforced/checked by merge_tv ().
           * - 4 follows vaccuously from the fact that merging the roots
           *   will not cause any other nodes to be merged (since they already
           *   have been).
           *
           * For this argument to work it is important that we can consider
           * the merge of the roots not to have "started" until the subgraphs
           * are fully merged -- so we must be careful not to violate this
           * invariant.
           *
           * The above by itself is *sound*, but not *complete* -- there are
           * cases that it will reject that should be accepted. Instead of
           * just doing the above, if we hit an error in one branch we try
           * to keep going in the others, and then re-raise the error at the
           * end. Then, the Quant,Quant case handles the remaining cases.
          *)
          begin
            let args_i_l = List.mapi argsl ~f:(fun i v -> (i, v)) in
            let subgraph_error = ref None in
            List.iter2_exn args_i_l argsr
              ~f:(fun (i, (l, _)) (r, _) ->
                  try
                    normalize_unify
                      { ctx with c_rsn = `Cascade(ctx.c_rsn, i+1) }
                      l
                      r
                  with MuleErr.MuleExn e ->
                    (* Save the error and keep trying to unify the other branches. *)
                    begin match !subgraph_error with
                      | Some _ -> () (* don't overwrite the first error. *)
                      | None -> subgraph_error := Some e
                    end
                );
            begin match !subgraph_error with
              | Some e -> raise (MuleErr.MuleExn e)
              | None -> ()
            end;
            finish (`Const(merge_tv (), cl, argsl, k))
          end
        else
          begin match cl, argsl, cr, argsr with
            (* Mismatched extend constructors get treated specially, because of the
             * equivalence relation on rows. *)
            | `Extend l_lbl, [l_ty, _; l_rest, _], `Extend r_lbl, [r_ty, _; r_rest, _] ->
                begin
                  (* Extend nodes are always inert, so the exact bounds we choose
                   * for the new nodes don't really matter, as long as the resulting
                   * graph is well-formed. *)
                  let new_with_bound v =
                    UnionFind.make
                      (`Free
                         ( { ty_id = gensym ()
                           ; ty_bound = ref (get_u_bound (UnionFind.get v))
                           }
                         , kvar_row
                         )
                      )
                  in
                  let new_rest_r = new_with_bound r_rest in
                  let new_rest_l = new_with_bound l_rest in
                  let new_tv () =
                    { ty_id = gensym ()
                    ; ty_bound = (get_tyvar l).ty_bound
                    }
                  in
                  normalize_unify
                    { ctx with c_rsn = `ExtendTail (ctx.c_rsn, `L) }
                    r_rest
                    (UnionFind.make (extend (new_tv ()) l_lbl l_ty new_rest_r));
                  normalize_unify
                    { ctx with c_rsn = `ExtendTail (ctx.c_rsn, `R) }
                    l_rest
                    (UnionFind.make (extend (new_tv ()) r_lbl r_ty new_rest_l));
                end;
                finish (extend (merge_tv ()) l_lbl l_ty l_rest)
            | _ ->
                (* Top level type constructors that _do not_ match. In this case
                 * unfication fails. *)
                ctorErr ctx.c_rsn cl cr
          end
  end
(* Wrapper around UnionFind.merge/unify that first normalizes the arguments. *)
and normalize_unify ctx l r =
  let l, r = Normalize.pair l r in
  unify ctx l r
and graft_and_unify: unify_ctx -> graft_args -> unit = fun ctx ga ->
  (* {MLF-Graph} describes grafting as the process of replacing a
   * flexible bottom node with another type. However, we only graft
   * in places where we're actually looking to merge the two graphs, so
   * we combine the two into one function. First, we make a copy of the
   * subgraph rooted at the non-bottom node. If the subgraph includes nodes
   * bound above it, the copies are bound on the root of the merge on the
   * bottom node's side (handled by copy_under)
   *
   * Then, after doing the graft, we try merging. If this fails then we'll
   * end up raising an exception, and when a top-down merge is attempted,
   * we'll have at least gotten the sub-graph into the shape it needs to be
   * in.
  *)
  let copy = copy_under ga.ga_bottom_root (UnionFind.get ga.ga_other_node) in
  UnionFind.merge (fun l _ -> l) copy ga.ga_bottom_node;
  normalize_unify ctx copy ga.ga_other_node

let normalize_unify rsn l r =
  normalize_unify {
    c_already_merged = IntPairSet.empty;
    c_rsn = rsn;
    c_root_l = l;
    c_root_r = r;
  }
  l r
