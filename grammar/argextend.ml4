(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i camlp4deps: "tools/compat5b.cmo" i*)

open Q_util
open Compat

let loc = CompatLoc.ghost
let default_loc = <:expr< Loc.ghost >>

let mk_extraarg loc s = <:expr< $lid:"wit_"^s$ >>

let rec make_wit loc = function
  | ListArgType t -> <:expr< Genarg.wit_list $make_wit loc t$ >>
  | OptArgType t -> <:expr< Genarg.wit_opt $make_wit loc t$ >>
  | PairArgType (t1,t2) ->
      <:expr< Genarg.wit_pair $make_wit loc t1$ $make_wit loc t2$ >>
  | ExtraArgType s -> mk_extraarg loc s

let is_self s = function
| ExtraArgType s' -> s = s'
| _ -> false

let make_rawwit loc arg = <:expr< Genarg.rawwit $make_wit loc arg$ >>
let make_globwit loc arg = <:expr< Genarg.glbwit $make_wit loc arg$ >>
let make_topwit loc arg = <:expr< Genarg.topwit $make_wit loc arg$ >>

let make_act loc act pil =
  let rec make = function
    | [] -> <:expr< (fun loc -> $act$) >>
    | ExtNonTerminal (_, p) :: tl -> <:expr< (fun $lid:p$ -> $make tl$) >>
    | ExtTerminal _ :: tl ->
	<:expr< (fun _ -> $make tl$) >> in
  make (List.rev pil)

let make_prod_item = function
  | ExtTerminal s -> <:expr< Extend.Atoken (Lexer.terminal $mlexpr_of_string s$) >>
  | ExtNonTerminal (g, _) ->
    let base s = <:expr< Pcoq.name_of_entry $lid:s$ >> in
    mlexpr_of_prod_entry_key base g

let rec make_prod = function
| [] -> <:expr< Extend.Stop >>
| item :: prods -> <:expr< Extend.Next $make_prod prods$ $make_prod_item item$ >>

let make_rule loc (prods,act) =
  <:expr< Extend.Rule $make_prod (List.rev prods)$ $make_act loc act prods$ >>

let is_ident x = function
| <:expr< $lid:s$ >> -> (s : string) = x
| _ -> false

let make_extend loc s cl wit = match cl with
| [[ExtNonTerminal (Uentry e, id)], act] when is_ident id act ->
  (** Special handling of identity arguments by not redeclaring an entry *)
  <:str_item<
    value $lid:s$ =
      let () = Pcoq.register_grammar $wit$ $lid:e$ in
      $lid:e$
  >>
| _ ->
  let se = mlexpr_of_string s in
  let rules = mlexpr_of_list (make_rule loc) (List.rev cl) in
  <:str_item<
    value $lid:s$ =
      let $lid:s$ = Pcoq.create_generic_entry Pcoq.utactic $se$ (Genarg.rawwit $wit$) in
      let () = Pcoq.grammar_extend $lid:s$ None (None, [(None, None, $rules$)]) in
      $lid:s$ >>

let warning_redundant prefix s =
  Printf.eprintf "Redundant [%sTYPED AS] clause in [ARGUMENT EXTEND %s].\n%!" prefix s

let get_type prefix s = function
| None -> None
| Some typ ->
  if is_self s typ then
    let () = warning_redundant prefix s in None
  else Some typ

let check_type prefix s = function
| None -> ()
| Some _ -> warning_redundant prefix s

let declare_tactic_argument loc s (typ, f, g, h) cl =
  let rawtyp, rawpr, globtyp, globpr, typ, pr = match typ with
    | `Uniform (typ, pr) ->
      let typ = get_type "" s typ in
      typ, pr, typ, pr, typ, pr
    | `Specialized (a, rpr, c, gpr, e, tpr) ->
      (** Check that we actually need the TYPED AS arguments *)
      let rawtyp = get_type "RAW_" s a in
      let glbtyp = get_type "GLOB_" s c in
      let toptyp = get_type "" s e in
      let () = match g with None -> () | Some _ -> check_type "RAW_" s rawtyp in
      let () = match f, h with Some _, Some _ -> check_type "GLOB_" s glbtyp | _ -> () in
      rawtyp, rpr, glbtyp, gpr, toptyp, tpr
  in
  let glob = match g with
    | None ->
      begin match rawtyp with
      | None -> <:expr< fun ist v -> (ist, v) >>
      | Some rawtyp ->
        <:expr< fun ist v ->
          let ans = out_gen $make_globwit loc rawtyp$
          (Tacintern.intern_genarg ist
          (Genarg.in_gen $make_rawwit loc rawtyp$ v)) in
          (ist, ans) >>
      end
    | Some f ->
      <:expr< fun ist v -> (ist, $lid:f$ ist v) >>
  in
  let interp = match f with
    | None ->
      begin match globtyp with
      | None -> <:expr< fun ist v -> Ftactic.return v >>
      | Some globtyp ->
        <:expr< fun ist x ->
          Ftactic.bind
            (Tacinterp.interp_genarg ist (Genarg.in_gen $make_globwit loc globtyp$ x))
            (fun v -> Ftactic.return (Tacinterp.Value.cast $make_topwit loc globtyp$ v)) >>
      end
    | Some f ->
      (** Compatibility layer, TODO: remove me *)
      <:expr<
        let f = $lid:f$ in
        fun ist v -> Ftactic.nf_s_enter { Proofview.Goal.s_enter = fun gl ->
          let (sigma, v) = Tacmach.New.of_old (fun gl -> f ist gl v) gl in
          Sigma.Unsafe.of_pair (Ftactic.return v, sigma)
        }
      >> in
  let subst = match h with
    | None ->
      begin match globtyp with
      | None -> <:expr< fun s v -> v >>
      | Some globtyp ->
        <:expr< fun s x ->
          out_gen $make_globwit loc globtyp$
          (Tacsubst.subst_genarg s
            (Genarg.in_gen $make_globwit loc globtyp$ x)) >>
      end
    | Some f -> <:expr< $lid:f$>> in
  let dyn = match typ with
  | None -> <:expr< None >>
  | Some typ ->
    if is_self s typ then <:expr< None >>
    else <:expr< Some (Genarg.val_tag $make_topwit loc typ$) >>
  in
  let se = mlexpr_of_string s in
  let wit = <:expr< $lid:"wit_"^s$ >> in
  declare_str_items loc
   [ <:str_item<
      value ($lid:"wit_"^s$) =
        let dyn = $dyn$ in
        Genarg.make0 ?dyn $se$ >>;
     <:str_item< Genintern.register_intern0 $wit$ $glob$ >>;
     <:str_item< Genintern.register_subst0 $wit$ $subst$ >>;
     <:str_item< Geninterp.register_interp0 $wit$ $interp$ >>;
     make_extend loc s cl wit;
     <:str_item< do {
      Pptactic.declare_extra_genarg_pprule
        $wit$ $lid:rawpr$ $lid:globpr$ $lid:pr$;
      Tacentries.create_ltac_quotation $se$
        (fun (loc, v) -> Tacexpr.TacGeneric (Genarg.in_gen (Genarg.rawwit $wit$) v))
        ($lid:s$, None)
      } >> ]

let declare_vernac_argument loc s pr cl =
  let se = mlexpr_of_string s in
  let wit = <:expr< $lid:"wit_"^s$ >> in
  let pr_rules = match pr with
    | None -> <:expr< fun _ _ _ _ -> str $str:"[No printer for "^s^"]"$ >>
    | Some pr -> <:expr< fun _ _ _ -> $lid:pr$ >> in
  declare_str_items loc
   [ <:str_item<
      value ($lid:"wit_"^s$ : Genarg.genarg_type 'a unit unit) =
        Genarg.create_arg $se$ >>;
     make_extend loc s cl wit;
    <:str_item< do {
      Pptactic.declare_extra_genarg_pprule $wit$
        $pr_rules$
        (fun _ _ _ _ -> Errors.anomaly (Pp.str "vernac argument needs not globwit printer"))
        (fun _ _ _ _ -> Errors.anomaly (Pp.str "vernac argument needs not wit printer")) }
      >> ]

open Pcaml
open PcamlSig (* necessary for camlp4 *)

EXTEND
  GLOBAL: str_item;
  str_item:
    [ [ "ARGUMENT"; "EXTEND"; s = entry_name;
        header = argextend_header;
        OPT "|"; l = LIST1 argrule SEP "|";
        "END" ->
         declare_tactic_argument loc s header l
      | "VERNAC"; "ARGUMENT"; "EXTEND"; s = entry_name;
        pr = OPT ["PRINTED"; "BY"; pr = LIDENT -> pr];
        OPT "|"; l = LIST1 argrule SEP "|";
        "END" ->
         declare_vernac_argument loc s pr l ] ]
  ;
  argextend_specialized:
  [ [ rawtyp = OPT [ "RAW_TYPED"; "AS"; rawtyp = argtype -> rawtyp ];
      "RAW_PRINTED"; "BY"; rawpr = LIDENT;
      globtyp = OPT [ "GLOB_TYPED"; "AS"; globtyp = argtype -> globtyp ];
      "GLOB_PRINTED"; "BY"; globpr = LIDENT ->
      (rawtyp, rawpr, globtyp, globpr) ] ]
  ;
  argextend_header:
    [ [ typ = OPT [ "TYPED"; "AS"; typ = argtype -> typ ];
        "PRINTED"; "BY"; pr = LIDENT;
        f = OPT [ "INTERPRETED"; "BY"; f = LIDENT -> f ];
        g = OPT [ "GLOBALIZED"; "BY"; f = LIDENT -> f ];
        h = OPT [ "SUBSTITUTED"; "BY"; f = LIDENT -> f ];
        special = OPT argextend_specialized ->
        let repr = match special with
        | None -> `Uniform (typ, pr)
        | Some (rtyp, rpr, gtyp, gpr) -> `Specialized (rtyp, rpr, gtyp, gpr, typ, pr)
        in
        (repr, f, g, h) ] ]
  ;
  argtype:
    [ "2"
      [ e1 = argtype; "*"; e2 = argtype -> PairArgType (e1, e2) ]
    | "1"
      [ e = argtype; LIDENT "list" -> ListArgType e
      | e = argtype; LIDENT "option" -> OptArgType e ]
    | "0"
      [ e = LIDENT ->
        let e = parse_user_entry e "" in
        type_of_user_symbol e
      | "("; e = argtype; ")" -> e ] ]
  ;
  argrule:
    [ [ "["; l = LIST0 genarg; "]"; "->"; "["; e = Pcaml.expr; "]" -> (l,e) ] ]
  ;
  genarg:
    [ [ e = LIDENT; "("; s = LIDENT; ")" ->
        let e = parse_user_entry e "" in
        ExtNonTerminal (e, s)
      | e = LIDENT; "("; s = LIDENT; ","; sep = STRING; ")" ->
        let e = parse_user_entry e sep in
        ExtNonTerminal (e, s)
      | s = STRING -> ExtTerminal s
    ] ]
  ;
  entry_name:
    [ [ s = LIDENT -> s
      | UIDENT -> failwith "Argument entry names must be lowercase"
      ] ]
  ;
  END
