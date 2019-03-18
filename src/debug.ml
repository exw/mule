open Base

type edge_type =
  [ `Structural
  | `Unify
  | `Instance
  | `Binding of [ `Flex | `Rigid ]
  ]
type node_type =
  [ `TyVar
  | `TyFn
  | `TyRecord
  | `TyUnion
  | `RowVar
  | `RowEmpty
  | `RowExtend of Ast.Label.t
  | `G
  ]


let report enabled =
  if enabled then
    fun f -> Stdio.print_endline (f ())
  else
    fun _ -> ()

let frame_no: int ref = ref 0

let edges: (edge_type * int * int) list ref = ref []
let nodes: (node_type * int) list ref = ref []

let start_graph () =
  edges := [];
  nodes := []

let show_edge ty from to_ =
  edges := (ty, from, to_) :: !edges

let show_node ty n =
  nodes := (ty, n) :: !nodes

let fmt_node: node_type -> int -> string =
  fun ty n ->
    String.concat
    [ "  n"
    ; Int.to_string n
    ; " [label=\""
    ; begin match ty with
      | `TyVar -> "T"
      | `TyFn -> "->"
      | `TyRecord -> "{}"
      | `TyUnion -> "|"
      | `RowVar -> "R"
      | `RowEmpty -> "Nil"
      | `RowExtend lbl -> Ast.Label.to_string lbl ^ " ::"
      | `G -> "G"
      end
    ; "\"];\n"
    ]

let fmt_edge_ty = function
  | `Structural -> ""
  | `Unify -> "[color=green, dir=none]"
  | `Instance -> "[color=red]"
  | `Binding `Flex -> "[style=dotted, dir=back]"
  | `Binding `Rigid -> "[style=dashed, dir=back]"

module Out = Stdio.Out_channel

let end_graph () =
  let path = Printf.sprintf "/tmp/graph-%03d.dot" !frame_no in
  frame_no := !frame_no + 1;
  let dest = Out.create path in
  Out.fprintf dest "digraph g {\n";
  List.iter !nodes ~f:(fun (ty, id) ->
    Out.fprintf dest "%s" (fmt_node ty id)
  );
  List.iter !edges ~f:(fun (ty, from, to_) ->
    Out.fprintf dest "  n%d -> n%d %s;\n" from to_ (fmt_edge_ty ty)
  );
  Out.fprintf dest "}\n";
  Out.close dest;
  let _ = Caml.Sys.command ("xdot " ^ path) in
  ()
