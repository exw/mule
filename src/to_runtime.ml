open Ast

module D = Desugared.Expr
module R = Runtime.Expr

type binding = [ `Index of int | `Term of R.t ]

let rec translate: int -> binding VarMap.t -> 'i D.t -> (int * R.t) =
  fun depth env -> function
    | D.Const c -> (0, R.Const c)
    | D.Var v ->
        begin match Map.find_exn env v with
          | `Index m ->
              let n = depth - m in
              (n, R.Var n)
          | `Term t -> (0, t)
        end
    | D.Fix flag ->
        (0, R.Fix flag)
    | D.Lam (param, body) ->
        let (ncap, body') =
          translate (depth + 1) (Map.set env ~key:param ~data:(`Index (depth + 1))) body
        in
        (ncap, R.Lam(ncap, [], body'))
    | D.App{ app_fn = D.Fix `Record; app_arg = f } ->
        translate_fix_rec depth env f
    | D.App { app_fn = D.WithType _; app_arg = e } ->
        translate depth env e
    | D.App {app_fn = f; app_arg = x} ->
        let (fcap, f') = translate depth env f in
        let (xcap, x') = translate depth env x in
        (max fcap xcap, R.App(f', x'))
    | D.WithType _ ->
        (0, R.Lam(0, [], R.Var 0))
    | D.Witness _ ->
        (0, R.Record LabelMap.empty)
    | D.EmptyRecord -> (0, R.Record LabelMap.empty)
    | D.GetField (mode, lbl) -> (0, R.GetField (mode, lbl))
    | D.Update (`Value, label) ->
        ( 0
        , R.Lam(0, [], R.Lam(1, [], R.Update { old = R.Var 1; label; field = R.Var 0 }))
        )
    | D.Update(`Type, _) ->
        ( 0
        , R.Lam(0, [], R.Lam(1, [], R.Var 1))
        )
    | D.Ctor (label, e) ->
        let (ncap, e') = translate depth env e in
        (ncap, R.Ctor(label, e'))
    | D.ConstMatch{cm_cases; cm_default} ->
        let cases = Map.map cm_cases ~f:(translate depth env) in
        let (n, def) = translate depth env cm_default in
        let ncaps = Map.fold
            cases
            ~init:n
            ~f:(fun ~key:_ ~data:(next, _) prev -> max next prev)
        in
        ( ncaps
        , R.ConstMatch
            { cm_cases = Map.map cases ~f:snd
            ; cm_default = def
            }
        )
    | D.Match{cases; default} ->
        let cases' = Map.map
            cases
            ~f:(fun (param, body) -> translate depth env (D.Lam(param, body)))
        in
        let (defcaps, default') = match default with
          | None -> (0, None)
          | Some (None, body) ->
              let (ncaps, body') = translate depth env (D.Lam(Gensym.anon_var(), body)) in
              (ncaps, Some body')
          | Some(Some param, body) ->
              let (ncaps, body') = translate depth env (D.Lam(param, body)) in
              (ncaps, Some body')
        in
        let ncaps = Map.fold
            ~init:defcaps
            ~f:(fun ~key:_ ~data -> max data)
            (Map.map cases' ~f:fst)
        in
        ( ncaps
        , R.Match
            { cases = Map.map ~f:snd cases'
            ; default = default'
            }
        )
    | D.Let (v, e, body) ->
        translate depth env (D.App {
            app_fn = D.Lam (v, body);
            app_arg = e;
          })
    | D.LetType(_, body) ->
        translate depth env body
and translate_fix_rec depth env = function
  | D.Lam(v, body) ->
      let (n, lblmap) =
        translate_record_body
          (depth + 1)
          (Map.set env ~key:v ~data:(`Index (depth + 1)))
          body
      in
      ( n - 1
      , R.App
          ( R.Fix `Record
          , R.Lam(n, [], R.Record lblmap)
          )
      )
  | _ ->
      failwith "BUG"
and translate_record_body depth env = function
  | D.EmptyRecord ->
      (0, LabelMap.empty)
  | D.App{ app_fn = D.App{ app_fn = D.Update(`Value, lbl); app_arg = old}; app_arg = field } ->
      let (n, head) = translate depth env field in
      let (m, tail) = translate_record_body depth env old in
      (max n m, Map.set tail ~key:lbl ~data:head)
  | D.App{ app_fn = D.App { app_fn = D.Update(`Type, _lbl); app_arg = old}; app_arg = _type } ->
      translate_record_body depth env old
  | D.LetType(_, body) ->
      translate_record_body depth env body
  | _ ->
      failwith "BUG"

let translate: 'i D.t -> R.t =
  fun exp ->
  let env = Map.map Intrinsics.values ~f:(fun x -> `Term (snd x)) in
  snd (translate 0 env exp)
