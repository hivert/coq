(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i camlp4deps: "grammar/grammar.cma" i*)

open Util
open Names
open Locus
open Misctypes
open Genredexpr
open Stdarg
open Constrarg
open Extraargs
open Pcoq.Constr
open Pcoq.Prim
open Pcoq.Tactic

open Proofview.Notations
open Sigma.Notations

DECLARE PLUGIN "coretactics"

(** Basic tactics *)

TACTIC EXTEND reflexivity
  [ "reflexivity" ] -> [ Tactics.intros_reflexivity ]
END

TACTIC EXTEND assumption
  [ "assumption" ] -> [ Tactics.assumption ]
END

TACTIC EXTEND etransitivity
  [ "etransitivity" ] -> [ Tactics.intros_transitivity None ]
END

TACTIC EXTEND cut
  [ "cut" constr(c) ] -> [ Tactics.cut c ]
END

TACTIC EXTEND exact_no_check
  [ "exact_no_check" constr(c) ] -> [ Proofview.V82.tactic (Tactics.exact_no_check c) ]
END

TACTIC EXTEND vm_cast_no_check
  [ "vm_cast_no_check" constr(c) ] -> [ Proofview.V82.tactic (Tactics.vm_cast_no_check c) ]
END

TACTIC EXTEND native_cast_no_check
  [ "native_cast_no_check" constr(c) ] -> [ Proofview.V82.tactic (Tactics.native_cast_no_check c) ]
END

TACTIC EXTEND casetype
  [ "casetype" constr(c) ] -> [ Tactics.case_type c ]
END

TACTIC EXTEND elimtype
  [ "elimtype" constr(c) ] -> [ Tactics.elim_type c ]
END

TACTIC EXTEND lapply
  [ "lapply" constr(c) ] -> [ Tactics.cut_and_apply c ]
END

TACTIC EXTEND transitivity
  [ "transitivity" constr(c) ] -> [ Tactics.intros_transitivity (Some c) ]
END

(** Left *)

TACTIC EXTEND left
  [ "left" ] -> [ Tactics.left_with_bindings false NoBindings ]
END

TACTIC EXTEND eleft
  [ "eleft" ] -> [ Tactics.left_with_bindings true NoBindings ]
END

TACTIC EXTEND left_with
  [ "left" "with" bindings(bl) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES false bl (fun bl -> Tactics.left_with_bindings false bl)
  ]
END

TACTIC EXTEND eleft_with
  [ "eleft" "with" bindings(bl) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES true bl (fun bl -> Tactics.left_with_bindings true bl)
  ]
END

(** Right *)

TACTIC EXTEND right
  [ "right" ] -> [ Tactics.right_with_bindings false NoBindings ]
END

TACTIC EXTEND eright
  [ "eright" ] -> [ Tactics.right_with_bindings true NoBindings ]
END

TACTIC EXTEND right_with
  [ "right" "with" bindings(bl) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES false bl (fun bl -> Tactics.right_with_bindings false bl)
  ]
END

TACTIC EXTEND eright_with
  [ "eright" "with" bindings(bl) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES true bl (fun bl -> Tactics.right_with_bindings true bl)
  ]
END

(** Constructor *)

TACTIC EXTEND constructor
  [ "constructor" ] -> [ Tactics.any_constructor false None ]
| [ "constructor" int_or_var(i) ] -> [
    Tactics.constructor_tac false None i NoBindings
  ]
| [ "constructor" int_or_var(i) "with" bindings(bl) ] -> [
    let tac bl = Tactics.constructor_tac false None i bl in
    Tacticals.New.tclDELAYEDWITHHOLES false bl tac
  ]
END

TACTIC EXTEND econstructor
  [ "econstructor" ] -> [ Tactics.any_constructor true None ]
| [ "econstructor" int_or_var(i) ] -> [
    Tactics.constructor_tac true None i NoBindings
  ]
| [ "econstructor" int_or_var(i) "with" bindings(bl) ] -> [
    let tac bl = Tactics.constructor_tac true None i bl in
    Tacticals.New.tclDELAYEDWITHHOLES true bl tac
  ]
END

(** Specialize *)

TACTIC EXTEND specialize
  [ "specialize" constr_with_bindings(c) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES false c Tactics.specialize
  ]
END

TACTIC EXTEND symmetry
  [ "symmetry" ] -> [ Tactics.intros_symmetry {onhyps=Some[];concl_occs=AllOccurrences} ]
| [ "symmetry" clause_dft_concl(cl) ] -> [ Tactics.intros_symmetry cl ]
END

(** Split *)

let rec delayed_list = function
| [] -> { Tacexpr.delayed = fun _ sigma -> Sigma.here [] sigma }
| x :: l ->
  { Tacexpr.delayed = fun env sigma ->
    let Sigma (x, sigma, p) = x.Tacexpr.delayed env sigma in
    let Sigma (l, sigma, q) = (delayed_list l).Tacexpr.delayed env sigma in
    Sigma (x :: l, sigma, p +> q) }

TACTIC EXTEND split
  [ "split" ] -> [ Tactics.split_with_bindings false [NoBindings] ]
END

TACTIC EXTEND esplit
  [ "esplit" ] -> [ Tactics.split_with_bindings true [NoBindings] ]
END

TACTIC EXTEND split_with
  [ "split" "with" bindings(bl) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES false bl (fun bl -> Tactics.split_with_bindings false [bl])
  ]
END

TACTIC EXTEND esplit_with
  [ "esplit" "with" bindings(bl) ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES true bl (fun bl -> Tactics.split_with_bindings true [bl])
  ]
END

TACTIC EXTEND exists
  [ "exists" ] -> [ Tactics.split_with_bindings false [NoBindings] ]
| [ "exists" ne_bindings_list_sep(bll, ",") ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES false (delayed_list bll) (fun bll -> Tactics.split_with_bindings false bll)
  ]
END

TACTIC EXTEND eexists
  [ "eexists" ] -> [ Tactics.split_with_bindings true [NoBindings] ]
| [ "eexists" ne_bindings_list_sep(bll, ",") ] -> [
    Tacticals.New.tclDELAYEDWITHHOLES true (delayed_list bll) (fun bll -> Tactics.split_with_bindings true bll)
  ]
END

(** Intro *)

TACTIC EXTEND intros_until
  [ "intros" "until" quantified_hypothesis(h) ] -> [ Tactics.intros_until h ]
END

(** Move *)

TACTIC EXTEND move
  [ "move" hyp(id) "at" "top" ] -> [ Proofview.V82.tactic (Tactics.move_hyp id MoveFirst) ]
| [ "move" hyp(id) "at" "bottom" ] -> [ Proofview.V82.tactic (Tactics.move_hyp id MoveLast) ]
| [ "move" hyp(id) "after" hyp(h) ] -> [ Proofview.V82.tactic (Tactics.move_hyp id (MoveAfter h)) ]
| [ "move" hyp(id) "before" hyp(h) ] -> [ Proofview.V82.tactic (Tactics.move_hyp id (MoveBefore h)) ]
END

(** Revert *)

TACTIC EXTEND revert
  [ "revert" ne_hyp_list(hl) ] -> [ Tactics.revert hl ]
END

(** Simple induction / destruct *)

TACTIC EXTEND simple_induction
  [ "simple" "induction" quantified_hypothesis(h) ] -> [ Tactics.simple_induct h ]
END

TACTIC EXTEND simple_destruct
  [ "simple" "destruct" quantified_hypothesis(h) ] -> [ Tactics.simple_destruct h ]
END

(* Admit *)

TACTIC EXTEND admit
 [ "admit" ] -> [ Proofview.give_up ]
END

(* Fix *)

TACTIC EXTEND fix
  [ "fix" natural(n) ] -> [ Proofview.V82.tactic (Tactics.fix None n) ]
| [ "fix" ident(id) natural(n) ] -> [ Proofview.V82.tactic (Tactics.fix (Some id) n) ]
END

(* Cofix *)

TACTIC EXTEND cofix
  [ "cofix" ] -> [ Proofview.V82.tactic (Tactics.cofix None) ]
| [ "cofix" ident(id) ] -> [ Proofview.V82.tactic (Tactics.cofix (Some id)) ]
END

(* Clear *)

TACTIC EXTEND clear
  [ "clear" hyp_list(ids) ] -> [
    if List.is_empty ids then Tactics.keep []
    else Proofview.V82.tactic (Tactics.clear ids)
  ]
| [ "clear" "-" ne_hyp_list(ids) ] -> [ Tactics.keep ids ]
END

(* Clearbody *)

TACTIC EXTEND clearbody
  [ "clearbody" ne_hyp_list(ids) ] -> [ Tactics.clear_body ids ]
END

(* Generalize dependent *)

TACTIC EXTEND generalize_dependent
  [ "generalize" "dependent" constr(c) ] -> [ Proofview.V82.tactic (Tactics.generalize_dep c) ]
END

(* Table of "pervasives" macros tactics (e.g. auto, simpl, etc.) *)

open Tacexpr

let initial_atomic () =
  let dloc = Loc.ghost in
  let nocl = {onhyps=Some[];concl_occs=AllOccurrences} in
  let iter (s, t) =
    let body = TacAtom (dloc, t) in
    Tacenv.register_ltac false false (Id.of_string s) body
  in
  let () = List.iter iter
      [ "red", TacReduce(Red false,nocl);
        "hnf", TacReduce(Hnf,nocl);
        "simpl", TacReduce(Simpl (Redops.all_flags,None),nocl);
        "compute", TacReduce(Cbv Redops.all_flags,nocl);
        "intro", TacIntroMove(None,MoveLast);
        "intros", TacIntroPattern [];
      ]
  in
  let iter (s, t) = Tacenv.register_ltac false false (Id.of_string s) t in
  List.iter iter
      [ "idtac",TacId [];
        "fail", TacFail(TacLocal,ArgArg 0,[]);
        "fresh", TacArg(dloc,TacFreshId [])
      ]

let () = Mltop.declare_cache_obj initial_atomic "coretactics"
