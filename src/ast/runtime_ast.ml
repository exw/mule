open Common_ast

module Expr = struct
  type 'a io = 'a Lwt.t

  let sexp_of_io _ _ = sexp_of_string "<io>"

  type t =
    | Var of int
    | Fix of [ `Let | `Record ]
    | Lam of (int * t list * t)
    | App of (t * t)
    | Record of t LabelMap.t
    | GetField of ([`Lazy|`Strict] * Label.t)
    | Update of
        { old: t
        ; label: Label.t
        ; field: t
        }
    | Ctor of (Label.t * t)
    | Match of {
        cases: t LabelMap.t;
        default: t option;
      }
    | IntMatch of
        { im_cases: t ZMap.t
        ; im_default: t
        }
    | Lazy of (t list * t ref)
    | Vec of t array
    | Integer of Bigint.t
    | Text of string
    | Prim of (t -> t)
    | PrimIO of (t io)
  [@@deriving sexp_of]
end
