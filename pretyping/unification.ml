(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Errors
open Pp
open Util
open Names
open Term
open Vars
open Termops
open Namegen
open Environ
open Evd
open Reduction
open Reductionops
open Evarutil
open Evarsolve
open Pretype_errors
open Retyping
open Coercion
open Recordops
open Locus
open Locusops
open Find_subterm

let occur_meta_or_undefined_evar evd c =
  let rec occrec c = match kind_of_term c with
    | Meta _ -> raise Occur
    | Evar (ev,args) ->
        (match evar_body (Evd.find evd ev) with
        | Evar_defined c ->
            occrec c; Array.iter occrec args
        | Evar_empty -> raise Occur)
    | _ -> iter_constr occrec c
  in try occrec c; false with Occur | Not_found -> true

let occur_meta_evd sigma mv c =
  let rec occrec c =
    (* Note: evars are not instantiated by terms with metas *)
    let c = whd_evar sigma (whd_meta sigma c) in
    match kind_of_term c with
    | Meta mv' when Int.equal mv mv' -> raise Occur
    | _ -> iter_constr occrec c
  in try occrec c; false with Occur -> true

(* if lname_typ is [xn,An;..;x1,A1] and l is a list of terms,
   gives [x1:A1]..[xn:An]c' such that c converts to ([x1:A1]..[xn:An]c' l) *)

let abstract_scheme env evd c l lname_typ =
  List.fold_left2
    (fun (t,evd) (locc,a) (na,_,ta) ->
       let na = match kind_of_term a with Var id -> Name id | _ -> na in
(* [occur_meta ta] test removed for support of eelim/ecase but consequences
   are unclear...
       if occur_meta ta then error "cannot find a type for the generalisation"
       else *) 
       if occur_meta a then mkLambda_name env (na,ta,t), evd
       else
	 let t', evd' = Find_subterm.subst_closed_term_occ evd locc a t in
	   mkLambda_name env (na,ta,t'), evd')
    (c,evd)
    (List.rev l)
    lname_typ

(* Precondition: resulting abstraction is expected to be of type [typ] *)

let abstract_list_all env evd typ c l =
  let ctxt,_ = splay_prod_n env evd (List.length l) typ in
  let l_with_all_occs = List.map (function a -> (AllOccurrences,a)) l in
  let p,evd = abstract_scheme env evd c l_with_all_occs ctxt in
  let evd,typp =
    try Typing.e_type_of env evd p
    with
    | UserError _ ->
        error_cannot_find_well_typed_abstraction env evd p l None
    | Type_errors.TypeError (env',x) ->
        error_cannot_find_well_typed_abstraction env evd p l (Some (env',x)) in
  evd,(p,typp)

let set_occurrences_of_last_arg args =
  Some AllOccurrences :: List.tl (Array.map_to_list (fun _ -> None) args)

let abstract_list_all_with_dependencies env evd typ c l =
  let evd,ev = new_evar evd env typ in
  let evd,ev' = evar_absorb_arguments env evd (destEvar ev) l in
  let argoccs = set_occurrences_of_last_arg (snd ev') in
  let evd,b =
    Evarconv.second_order_matching empty_transparent_state
      env evd ev' argoccs c in
  if b then
    let p = nf_evar evd (existential_value evd (destEvar ev)) in
      evd, p
  else error_cannot_find_well_typed_abstraction env evd 
    (nf_evar evd c) l None

(**)

(* A refinement of [conv_pb]: the integers tells how many arguments
   were applied in the context of the conversion problem; if the number
   is non zero, steps of eta-expansion will be allowed
*)

let opp_status = function
  | IsSuperType -> IsSubType
  | IsSubType -> IsSuperType
  | Conv -> Conv

let add_type_status (x,y) = ((x,TypeNotProcessed),(y,TypeNotProcessed))

let extract_instance_status = function
  | CUMUL -> add_type_status (IsSubType, IsSuperType)
  | CONV -> add_type_status (Conv, Conv)

let rec subst_meta_instances bl c =
  match kind_of_term c with
    | Meta i ->
      let select (j,_,_) = Int.equal i j in
      (try pi2 (List.find select bl) with Not_found -> c)
    | _ -> map_constr (subst_meta_instances bl) c

(** [env] should be the context in which the metas live *)

let evar_source_of_meta mv evd =
  match Evd.meta_name evd mv with
  | Anonymous -> (Loc.ghost,Evar_kinds.GoalEvar)
  | Name id -> (Loc.ghost,Evar_kinds.VarInstance id)

let pose_all_metas_as_evars env evd t =
  let evdref = ref evd in
  let rec aux t = match kind_of_term t with
  | Meta mv ->
      (match Evd.meta_opt_fvalue !evdref mv with
       | Some ({rebus=c},_) -> c
       | None ->
        let {rebus=ty;freemetas=mvs} = Evd.meta_ftype evd mv in
        let ty = if Evd.Metaset.is_empty mvs then ty else aux ty in
        let src = evar_source_of_meta mv !evdref in
        let ev = Evarutil.e_new_evar evdref env ~src ty in
        evdref := meta_assign mv (ev,(Conv,TypeNotProcessed)) !evdref;
        ev)
  | _ ->
      map_constr aux t in
  let c = aux t in
  (* side-effect *)
  (!evdref, c)

let solve_pattern_eqn_array (env,nb) f l c (sigma,metasubst,evarsubst) =
  match kind_of_term f with
    | Meta k ->
	(* We enforce that the Meta does not depend on the [nb]
	   extra assumptions added by unification to the context *)
        let env' = pop_rel_context nb env in
	let sigma,c = pose_all_metas_as_evars env' sigma c in
	let c = solve_pattern_eqn env l c in
	let pb = (Conv,TypeNotProcessed) in
	  if noccur_between 1 nb c then
            sigma,(k,lift (-nb) c,pb)::metasubst,evarsubst
	  else error_cannot_unify_local env sigma (applist (f, l),c,c)
    | Evar ev ->
        let env' = pop_rel_context nb env in
	let sigma,c = pose_all_metas_as_evars env' sigma c in
	sigma,metasubst,(env,ev,solve_pattern_eqn env l c)::evarsubst
    | _ -> assert false

let push d (env,n) = (push_rel_assum d env,n+1)

(*******************************)

(* Unification à l'ordre 0 de m et n: [unify_0 env sigma cv_pb m n]
   renvoie deux listes:

   metasubst:(int*constr)list    récolte les instances des (Meta k)
   evarsubst:(constr*constr)list récolte les instances des (Const "?k")

   Attention : pas d'unification entre les différences instances d'une
   même meta ou evar, il peut rester des doublons *)

(* Unification order: *)
(* Left to right: unifies first argument and then the other arguments *)
(*let unify_l2r x = List.rev x
(* Right to left: unifies last argument and then the other arguments *)
let unify_r2l x = x

let sort_eqns = unify_r2l
*)

(* Option introduced and activated in Coq 8.3 *)
let global_evars_pattern_unification_flag = ref true

open Goptions
let _ =
  declare_bool_option
    { optsync  = true;
      optdepr  = false;
      optname  = "pattern-unification for existential variables in tactics";
      optkey   = ["Tactic";"Evars";"Pattern";"Unification"];
      optread  = (fun () -> !global_evars_pattern_unification_flag);
      optwrite = (:=) global_evars_pattern_unification_flag }

let _ =
  declare_bool_option
    { optsync  = true;
      optdepr  = false;
      optname  = "pattern-unification for existential variables in tactics";
      optkey   = ["Tactic";"Pattern";"Unification"];
      optread  = (fun () -> !global_evars_pattern_unification_flag);
      optwrite = (:=) global_evars_pattern_unification_flag }

type unify_flags = {
  modulo_conv_on_closed_terms : Names.transparent_state option;
    (* What this flag controls was activated with all constants transparent, *)
    (* even for auto, since Coq V5.10 *)

  use_metas_eagerly_in_conv_on_closed_terms : bool;
    (* This refinement of the conversion on closed terms is activable *)
    (* (and activated for apply, rewrite but not auto since Feb 2008 for 8.2) *)

  modulo_delta : Names.transparent_state;
    (* This controls which constants are unfoldable; this is on for apply *)
    (* (but not simple apply) since Feb 2008 for 8.2 *)

  modulo_delta_types : Names.transparent_state;

  modulo_delta_in_merge : Names.transparent_state option;
    (* This controls whether unfoldability is different when trying to unify *)
    (* several instances of the same metavariable *)
    (* Typical situation is when we give a pattern to be matched *)
    (* syntactically against a subterm but we want the metas of the *)
    (* pattern to be modulo convertibility *)

  check_applied_meta_types : bool;
    (* This controls whether meta's applied to arguments have their *)
    (* type unified with the type of their instance *)

  resolve_evars : bool;
    (* This says if type classes instances resolution must be used to infer *)
    (* the remaining evars *)

  use_pattern_unification : bool;
    (* This says if type classes instances resolution must be used to infer *)
    (* the remaining evars *)

  use_meta_bound_pattern_unification : bool;
    (* This solves pattern "?n x1 ... xn = t" when the xi are distinct rels *)
    (* This allows for instance to unify "forall x:A, B(x)" with "A' -> B'" *)
    (* This was on for all tactics, including auto, since Sep 2006 for 8.1 *)

  frozen_evars : Evar.Set.t;
    (* Evars of this set are considered axioms and never instantiated *)
    (* Useful e.g. for autorewrite *)

  restrict_conv_on_strict_subterms : bool;
    (* No conversion at the root of the term; potentially useful for rewrite *)

  modulo_betaiota : bool;
    (* Support betaiota in the reduction *)
    (* Note that zeta is always used *)

  modulo_eta : bool;
    (* Support eta in the reduction *)

  allow_K_in_toplevel_higher_order_unification : bool
    (* This is used only in second/higher order unification when looking for *)
    (* subterms (rewrite and elim) *)
}

(* Default flag for unifying a type against a type (e.g. apply) *)
(* We set all conversion flags (no flag should be modified anymore) *)
let default_unify_flags () = 
  let ts = Names.full_transparent_state in
  { modulo_conv_on_closed_terms = Some ts;
  use_metas_eagerly_in_conv_on_closed_terms = true;
  modulo_delta = ts;
  modulo_delta_types = ts;
  modulo_delta_in_merge = None;
  check_applied_meta_types = true;
  resolve_evars = false;
  use_pattern_unification = true;
  use_meta_bound_pattern_unification = true;
  frozen_evars = Evar.Set.empty;
  restrict_conv_on_strict_subterms = false;
  modulo_betaiota = true;
  modulo_eta = true;
  allow_K_in_toplevel_higher_order_unification = false
      (* in fact useless when not used in w_unify_to_subterm_list *)
}

let set_merge_flags flags =
  match flags.modulo_delta_in_merge with
  | None -> flags
  | Some ts ->
    { flags with modulo_delta = ts; modulo_conv_on_closed_terms = Some ts }

(* Default flag for the "simple apply" version of unification of a *)
(* type against a type (e.g. apply) *)
(* We set only the flags available at the time the new "apply" extends *)
(* out of "simple apply" *)
let default_no_delta_unify_flags () = { (default_unify_flags ()) with
  modulo_delta = empty_transparent_state;
  check_applied_meta_types = false;
  use_pattern_unification = false;
  use_meta_bound_pattern_unification = true;
  modulo_betaiota = false;
}

(* Default flags for looking for subterms in elimination tactics *)
(* Not used in practice at the current date, to the exception of *)
(* allow_K) because only closed terms are involved in *)
(* induction/destruct/case/elim and w_unify_to_subterm_list does not *)
(* call w_unify for induction/destruct/case/elim  (13/6/2011) *)
let elim_flags () = { (default_unify_flags ()) with
  restrict_conv_on_strict_subterms = false; (* ? *)
  modulo_betaiota = false;
  allow_K_in_toplevel_higher_order_unification = true
}

let elim_no_delta_flags () = { (elim_flags ()) with
  modulo_delta = empty_transparent_state;
  check_applied_meta_types = false;
  use_pattern_unification = false;
}

let use_evars_pattern_unification flags =
  !global_evars_pattern_unification_flag && flags.use_pattern_unification
  && Flags.version_strictly_greater Flags.V8_2

let use_metas_pattern_unification flags nb l =
  !global_evars_pattern_unification_flag && flags.use_pattern_unification
  || (Flags.version_less_or_equal Flags.V8_3 || 
      flags.use_meta_bound_pattern_unification) &&
     Array.for_all (fun c -> isRel c && destRel c <= nb) l

type key = 
  | IsKey of Closure.table_key
  | IsProj of constant * constr

let expand_table_key env = function
  | ConstKey cst -> constant_opt_value_in env cst
  | VarKey id -> (try named_body id env with Not_found -> None)
  | RelKey _ -> None

let unfold_projection env p stk =
  (match try Some (lookup_projection p env) with Not_found -> None with
  | Some pb -> 
    let s = Stack.Proj (pb.Declarations.proj_npars, pb.Declarations.proj_arg, p) in
      s :: stk
  | None -> assert false)

let expand_key ts env sigma = function
  | Some (IsKey k) -> expand_table_key env k
  | Some (IsProj (p, c)) -> 
    let red = Stack.zip (fst (whd_betaiota_deltazeta_for_iota_state ts env sigma 
			  Cst_stack.empty (c, unfold_projection env p [])))
    in if eq_constr (mkProj (p, c)) red then None else Some red
  | None -> None

let subterm_restriction is_subterm flags =
  not is_subterm && flags.restrict_conv_on_strict_subterms

let key_of env b flags f =
  if subterm_restriction b flags then None else
  match kind_of_term f with
  | Const (cst, u) when is_transparent env (ConstKey cst) &&
      Cpred.mem cst (snd flags.modulo_delta) ->
      Some (IsKey (ConstKey (cst, u)))
  | Var id when is_transparent env (VarKey id) && 
      Id.Pred.mem id (fst flags.modulo_delta) ->
    Some (IsKey (VarKey id))
  | Proj (p, c) when Cpred.mem p (snd flags.modulo_delta) ->
    Some (IsProj (p, c))
  | _ -> None
  

let translate_key = function
  | ConstKey (cst,u) -> ConstKey cst
  | VarKey id -> VarKey id
  | RelKey n -> RelKey n

let translate_key = function
  | IsKey k -> translate_key k    
  | IsProj (c, _) -> ConstKey c
  
let oracle_order env cf1 cf2 =
  match cf1 with
  | None ->
      (match cf2 with
      | None -> None
      | Some k2 -> Some false)
  | Some k1 ->
      match cf2 with
      | None -> Some true
      | Some k2 ->
	match k1, k2 with
	| IsProj (p, _), IsKey (ConstKey (p',_)) when eq_constant p p' -> Some false
	| IsKey (ConstKey (p,_)), IsProj (p', _) when eq_constant p p' -> Some true
	| _ ->
          Some (Conv_oracle.oracle_order (Environ.oracle env) false
		  (translate_key k1) (translate_key k2))

let is_rigid_head flags t =
  match kind_of_term t with
  | Const (cst,u) -> not (Cpred.mem cst (snd flags.modulo_delta))
  | Ind (i,u) -> true
  | Construct _ -> true
  | Fix _ | CoFix _ -> true
  | _ -> false

let force_eqs c = 
  Universes.Constraints.fold
    (fun ((l,d,r) as c) acc -> 
      let c' = if d == Universes.ULub then (l,Universes.UEq,r) else c in
	Universes.Constraints.add c' acc) 
    c Universes.Constraints.empty

let constr_cmp pb sigma flags t u =
  let b, cstrs = 
    if pb == Reduction.CONV then Universes.eq_constr_universes t u
    else Universes.leq_constr_universes t u
  in 
    if b then 
      try Evd.add_universe_constraints sigma cstrs, b
      with Univ.UniverseInconsistency _ -> sigma, false
      | Evd.UniversesDiffer -> 
	if is_rigid_head flags t then 
	  try Evd.add_universe_constraints sigma (force_eqs cstrs), b
	  with Univ.UniverseInconsistency _ -> sigma, false
	else sigma, false
    else sigma, b
    
let do_reduce ts (env, nb) sigma c =
  Stack.zip (fst (whd_betaiota_deltazeta_for_iota_state ts env sigma Cst_stack.empty (c, Stack.empty)))

let use_full_betaiota flags =
  flags.modulo_betaiota && Flags.version_strictly_greater Flags.V8_3

let isAllowedEvar flags c = match kind_of_term c with
  | Evar (evk,_) -> not (Evar.Set.mem evk flags.frozen_evars)
  | _ -> false

let check_compatibility env pbty flags (sigma,metasubst,evarsubst) tyM tyN =
  match subst_defined_metas metasubst tyM with
  | None -> sigma
  | Some m ->
  match subst_defined_metas metasubst tyN with
  | None -> sigma
  | Some n ->
    if is_ground_term sigma m && is_ground_term sigma n then
      let sigma, b = infer_conv ~pb:pbty ~ts:flags.modulo_delta_types env sigma m n in
	if b then sigma
	else error_cannot_unify env sigma (m,n)
    else sigma

let is_eta_constructor_app env f l1 =
  match kind_of_term f with
  | Construct (((_, i as ind), j), u) when i == 0 && j == 1 ->
    let mib = lookup_mind (fst ind) env in
      (match mib.Declarations.mind_record with
      | Some (exp,projs) when Array.length projs > 0
        && mib.Declarations.mind_finite -> 
        Array.length projs == Array.length l1 - mib.Declarations.mind_nparams
      | _ -> false)
  | _ -> false

let eta_constructor_app env f l1 term =
  match kind_of_term f with
  | Construct (((_, i as ind), j), u) ->
    let mib = lookup_mind (fst ind) env in
      (match mib.Declarations.mind_record with
      | Some (projs, _) ->
        let pars = mib.Declarations.mind_nparams in
	let l1' = Array.sub l1 pars (Array.length l1 - pars) in
	let l2 = Array.map (fun p -> mkProj (p, term)) projs in
	  l1', l2
      | _ -> assert false)
  | _ -> assert false

let unify_0_with_initial_metas (sigma,ms,es as subst) conv_at_top env cv_pb flags m n =
  let rec unirec_rec (curenv,nb as curenvnb) pb b wt ((sigma,metasubst,evarsubst) as substn) curm curn =
    let cM = Evarutil.whd_head_evar sigma curm
    and cN = Evarutil.whd_head_evar sigma curn in
      match (kind_of_term cM,kind_of_term cN) with
	| Meta k1, Meta k2 ->
            if Int.equal k1 k2 then substn else
	    let stM,stN = extract_instance_status pb in
            let sigma = 
	      if wt && flags.check_applied_meta_types then
		let tyM = Typing.meta_type sigma k1 in
		let tyN = Typing.meta_type sigma k2 in
		let l, r = if k2 < k1 then tyN, tyM else tyM, tyN in
		  check_compatibility curenv CUMUL flags substn l r
	      else sigma
	    in
	    if k2 < k1 then sigma,(k1,cN,stN)::metasubst,evarsubst
	    else sigma,(k2,cM,stM)::metasubst,evarsubst
	| Meta k, _
            when not (dependent cM cN) (* helps early trying alternatives *) ->
            let sigma = 
	      if wt && flags.check_applied_meta_types then
		(try
                   let tyM = Typing.meta_type sigma k in
                   let tyN = get_type_of curenv ~lax:true sigma cN in
                     check_compatibility curenv CUMUL flags substn tyN tyM
		 with RetypeError _ ->
                   (* Renounce, maybe metas/evars prevents typing *) sigma)
	      else sigma
	    in
	    (* Here we check that [cN] does not contain any local variables *)
	    if Int.equal nb 0 then
              sigma,(k,cN,snd (extract_instance_status pb))::metasubst,evarsubst
            else if noccur_between 1 nb cN then
              (sigma,
	      (k,lift (-nb) cN,snd (extract_instance_status pb))::metasubst,
              evarsubst)
	    else error_cannot_unify_local curenv sigma (m,n,cN)
	| _, Meta k
            when not (dependent cN cM) (* helps early trying alternatives *) ->
          let sigma = 
	    if wt && flags.check_applied_meta_types then
              (try
                 let tyM = get_type_of curenv ~lax:true sigma cM in
                 let tyN = Typing.meta_type sigma k in
                   check_compatibility curenv CUMUL flags substn tyM tyN
               with RetypeError _ ->
                 (* Renounce, maybe metas/evars prevents typing *) sigma)
	    else sigma
	  in
	    (* Here we check that [cM] does not contain any local variables *)
	    if Int.equal nb 0 then
              (sigma,(k,cM,fst (extract_instance_status pb))::metasubst,evarsubst)
	    else if noccur_between 1 nb cM
	    then
              (sigma,(k,lift (-nb) cM,fst (extract_instance_status pb))::metasubst,
              evarsubst)
	    else error_cannot_unify_local curenv sigma (m,n,cM)
	| Evar (evk,_ as ev), _
            when not (Evar.Set.mem evk flags.frozen_evars) 
	      && not (occur_evar evk cN) ->
	    let cmvars = free_rels cM and cnvars = free_rels cN in
	      if Int.Set.subset cnvars cmvars then
		sigma,metasubst,((curenv,ev,cN)::evarsubst)
	      else error_cannot_unify_local curenv sigma (m,n,cN)
	| _, Evar (evk,_ as ev)
            when not (Evar.Set.mem evk flags.frozen_evars)
	      && not (occur_evar evk cM) ->
	    let cmvars = free_rels cM and cnvars = free_rels cN in
	      if Int.Set.subset cmvars cnvars then
		sigma,metasubst,((curenv,ev,cM)::evarsubst)
	      else error_cannot_unify_local curenv sigma (m,n,cN)
	| Sort s1, Sort s2 ->
	    (try 
	       let sigma' = 
		 if pb == CUMUL
		 then Evd.set_leq_sort sigma s1 s2 
		 else Evd.set_eq_sort sigma s1 s2 
	       in (sigma', metasubst, evarsubst)
	     with e when Errors.noncritical e ->
               error_cannot_unify curenv sigma (m,n))

	| Lambda (na,t1,c1), Lambda (_,t2,c2) ->
	    unirec_rec (push (na,t1) curenvnb) CONV true wt
	      (unirec_rec curenvnb CONV true false substn t1 t2) c1 c2
	| Prod (na,t1,c1), Prod (_,t2,c2) ->
	    unirec_rec (push (na,t1) curenvnb) pb true false
	      (unirec_rec curenvnb CONV true false substn t1 t2) c1 c2
	| LetIn (_,a,_,c), _ -> unirec_rec curenvnb pb b wt substn (subst1 a c) cN
	| _, LetIn (_,a,_,c) -> unirec_rec curenvnb pb b wt substn cM (subst1 a c)

        (* eta-expansion *)
	| Lambda (na,t1,c1), _ when flags.modulo_eta ->
	    unirec_rec (push (na,t1) curenvnb) CONV true wt substn
	      c1 (mkApp (lift 1 cN,[|mkRel 1|]))
	| _, Lambda (na,t2,c2) when flags.modulo_eta ->
	    unirec_rec (push (na,t2) curenvnb) CONV true wt substn
	      (mkApp (lift 1 cM,[|mkRel 1|])) c2

	(* For records *)
	| App (f1, l1), _ when flags.modulo_eta && is_eta_constructor_app env f1 l1 ->
	  (try let l1', l2' = eta_constructor_app env f1 l1 cN in
		 Array.fold_left2 
		   (unirec_rec curenvnb CONV true wt) substn l1' l2'
	   with ex when precatchable_exception ex -> 
	     (match kind_of_term cN with
             | App (f2,l2) -> unify_app curenvnb pb b substn cM f1 l1 cN f2 l2
             | _ -> unify_not_same_head curenvnb pb b wt substn cM cN))

	| _, App (f2, l2) when flags.modulo_eta && is_eta_constructor_app env f2 l2 ->
	  (try let l2', l1' = eta_constructor_app env f2 l2 cM in
		 Array.fold_left2 
		   (unirec_rec curenvnb CONV true wt) substn l1' l2'
	   with ex when precatchable_exception ex -> 
	     (match kind_of_term cM with
             | App (f1,l1) -> unify_app curenvnb pb b substn cM f1 l1 cN f2 l2
             | _ -> unify_not_same_head curenvnb pb b wt substn cM cN))
	   
	| Case (_,p1,c1,cl1), Case (_,p2,c2,cl2) ->
            (try 
	       Array.fold_left2 (unirec_rec curenvnb CONV true wt)
		 (unirec_rec curenvnb CONV true false
		    (unirec_rec curenvnb CONV true false substn p1 p2) c1 c2)
                 cl1 cl2
	     with ex when precatchable_exception ex ->
	       reduce curenvnb pb b wt substn cM cN)

	| App (f1,l1), _ when 
	    (isMeta f1 && use_metas_pattern_unification flags nb l1
            || use_evars_pattern_unification flags && isAllowedEvar flags f1) ->
            (match
                is_unification_pattern curenvnb sigma f1 (Array.to_list l1) cN
             with
             | None ->
                 (match kind_of_term cN with
                 | App (f2,l2) -> unify_app curenvnb pb b substn cM f1 l1 cN f2 l2
                 | _ -> unify_not_same_head curenvnb pb b wt substn cM cN)
             | Some l ->
                 solve_pattern_eqn_array curenvnb f1 l cN substn)

	| _, App (f2,l2) when
	    (isMeta f2 && use_metas_pattern_unification flags nb l2
            || use_evars_pattern_unification flags && isAllowedEvar flags f2) ->
            (match
                is_unification_pattern curenvnb sigma f2 (Array.to_list l2) cM
             with
             | None ->
                 (match kind_of_term cM with
                 | App (f1,l1) -> unify_app curenvnb pb b substn cM f1 l1 cN f2 l2
                 | _ -> unify_not_same_head curenvnb pb b wt substn cM cN)
             | Some l ->
	         solve_pattern_eqn_array curenvnb f2 l cM substn)

	| App (f1,l1), App (f2,l2) ->
            unify_app curenvnb pb b substn cM f1 l1 cN f2 l2

	| Proj (p1,c1), Proj (p2,c2) ->
	    if eq_constant p1 p2 then
	      try 
	        let c1, c2, substn = 
		   if isCast c1 && isCast c2 then
		     let (c1,_,tc1) = destCast c1 in
		     let (c2,_,tc2) = destCast c2 in
		       c1, c2, unirec_rec curenvnb CONV true false substn tc1 tc2
		   else c1, c2, substn
		in
		  unirec_rec curenvnb CONV true wt substn c1 c2
	      with ex when precatchable_exception ex ->
	        unify_not_same_head curenvnb pb b wt substn cM cN
	    else
	      unify_not_same_head curenvnb pb b wt substn cM cN

	| _ ->
            unify_not_same_head curenvnb pb b wt substn cM cN

  and unify_app curenvnb pb b substn cM f1 l1 cN f2 l2 =
    try
      let (f1,l1,f2,l2) = adjust_app_array_size f1 l1 f2 l2 in
      Array.fold_left2 (unirec_rec curenvnb CONV true false)
	(unirec_rec curenvnb CONV true true substn f1 f2) l1 l2
    with ex when precatchable_exception ex ->
    try reduce curenvnb pb b false substn cM cN
    with ex when precatchable_exception ex ->
    try canonical_projections curenvnb pb b cM cN substn
    with ex when precatchable_exception ex ->
    expand curenvnb pb b false substn cM f1 l1 cN f2 l2

  and unify_not_same_head curenvnb pb b wt (sigma, metas, evars as substn) cM cN =
    try canonical_projections curenvnb pb b cM cN substn
    with ex when precatchable_exception ex ->
    let sigma', b = constr_cmp cv_pb sigma flags cM cN in
      if b then (sigma', metas, evars)
      else
	try reduce curenvnb pb b wt substn cM cN
	with ex when precatchable_exception ex ->
	let (f1,l1) =
	  match kind_of_term cM with App (f,l) -> (f,l) | _ -> (cM,[||]) in
	let (f2,l2) =
	  match kind_of_term cN with App (f,l) -> (f,l) | _ -> (cN,[||]) in
	  expand curenvnb pb b wt substn cM f1 l1 cN f2 l2

  and reduce curenvnb pb b wt (sigma, metas, evars as substn) cM cN =
    if use_full_betaiota flags && not (subterm_restriction b flags) then
      let cM' = do_reduce flags.modulo_delta curenvnb sigma cM in
	if not (eq_constr cM cM') then
	  unirec_rec curenvnb pb b wt substn cM' cN
	else
	  let cN' = do_reduce flags.modulo_delta curenvnb sigma cN in
	    if not (eq_constr cN cN') then
	      unirec_rec curenvnb pb b wt substn cM cN'
	    else error_cannot_unify (fst curenvnb) sigma (cM,cN)
    else error_cannot_unify (fst curenvnb) sigma (cM,cN)
	    
  and expand (curenv,_ as curenvnb) pb b wt (sigma,metasubst,evarsubst as substn) cM f1 l1 cN f2 l2 =
    let res =
      (* Try full conversion on meta-free terms. *)
      (* Back to 1995 (later on called trivial_unify in 2002), the
	 heuristic was to apply conversion on meta-free (but not
	 evar-free!) terms in all cases (i.e. for apply but also for
	 auto and rewrite, even though auto and rewrite did not use
	 modulo conversion in the rest of the unification
	 algorithm). By compatibility we need to support this
	 separately from the main unification algorithm *)
      (* The exploitation of known metas has been added in May 2007
	 (it is used by apply and rewrite); it might now be redundant
	 with the support for delta-expansion (which is used
	 essentially for apply)... *)
      if subterm_restriction b flags then None else 
      match flags.modulo_conv_on_closed_terms with
      | None -> None
      | Some convflags ->
      let subst = if flags.use_metas_eagerly_in_conv_on_closed_terms then metasubst else ms in
      match subst_defined_metas subst cM with
      | None -> (* some undefined Metas in cM *) None
      | Some m1 ->
      match subst_defined_metas subst cN with
      | None -> (* some undefined Metas in cN *) None
      | Some n1 ->
          (* No subterm restriction there, too much incompatibilities *)
	  let sigma, b = infer_conv ~pb ~ts:convflags env sigma m1 n1 in
	    if b then Some (sigma, metasubst, evarsubst)
	    else 
	      if is_ground_term sigma m1 && is_ground_term sigma n1 then
		error_cannot_unify curenv sigma (cM,cN)
	      else None
    in
      match res with
      | Some substn -> substn
      | None ->
      let cf1 = key_of env b flags f1 and cf2 = key_of env b flags f2 in
	match oracle_order curenv cf1 cf2 with
	| None -> error_cannot_unify curenv sigma (cM,cN)
	| Some true ->
	    (match expand_key flags.modulo_delta curenv sigma cf1 with
	    | Some c ->
		unirec_rec curenvnb pb b wt substn
                  (whd_betaiotazeta sigma (mkApp(c,l1))) cN
	    | None ->
		(match expand_key flags.modulo_delta curenv sigma cf2 with
		| Some c ->
		    unirec_rec curenvnb pb b wt substn cM
                      (whd_betaiotazeta sigma (mkApp(c,l2)))
		| None ->
		    error_cannot_unify curenv sigma (cM,cN)))
	| Some false ->
	    (match expand_key flags.modulo_delta curenv sigma cf2 with
	    | Some c ->
		unirec_rec curenvnb pb b wt substn cM
                  (whd_betaiotazeta sigma (mkApp(c,l2)))
	    | None ->
		(match expand_key flags.modulo_delta curenv sigma cf1 with
		| Some c ->
		    unirec_rec curenvnb pb b wt substn
                      (whd_betaiotazeta sigma (mkApp(c,l1))) cN
		| None ->
		    error_cannot_unify curenv sigma (cM,cN)))

  and canonical_projections curenvnb pb b cM cN (sigma,_,_ as substn) =
    let f1 () =
      if isApp cM then
	let f1l1 = whd_nored_state sigma (cM,Stack.empty) in
	  if is_open_canonical_projection env sigma f1l1 then
	    let f2l2 = whd_nored_state sigma (cN,Stack.empty) in
	      solve_canonical_projection curenvnb pb b cM f1l1 cN f2l2 substn
	  else error_cannot_unify (fst curenvnb) sigma (cM,cN)
      else error_cannot_unify (fst curenvnb) sigma (cM,cN)
    in
      if
        begin match flags.modulo_conv_on_closed_terms with
        | None -> true
        | Some _ -> subterm_restriction b flags
        end then
	error_cannot_unify (fst curenvnb) sigma (cM,cN)
      else
	try f1 () with e when precatchable_exception e ->
	  if isApp cN then
	    let f2l2 = whd_nored_state sigma (cN, Stack.empty) in
	      if is_open_canonical_projection env sigma f2l2 then
		let f1l1 = whd_nored_state sigma (cM, Stack.empty) in
		  solve_canonical_projection curenvnb pb b cN f2l2 cM f1l1 substn
	      else error_cannot_unify (fst curenvnb) sigma (cM,cN)
	  else error_cannot_unify (fst curenvnb) sigma (cM,cN)

  and solve_canonical_projection curenvnb pb b cM f1l1 cN f2l2 (sigma,ms,es) =
    let (ctx,t,c,bs,(params,params1),(us,us2),(ts,ts1),c1,(n,t2)) =
      try Evarconv.check_conv_record f1l1 f2l2
      with Not_found -> error_cannot_unify (fst curenvnb) sigma (cM,cN)
    in
    if Reductionops.Stack.compare_shape ts ts1 then
      let sigma = Evd.merge_context_set Evd.univ_flexible sigma ctx in
      let (evd,ks,_) =
	List.fold_left
	  (fun (evd,ks,m) b ->
	    if Int.equal m n then (evd,t2::ks, m-1) else
              let mv = new_meta () in
	      let evd' = meta_declare mv (substl ks b) evd in
	      (evd', mkMeta mv :: ks, m - 1))
	  (sigma,[],List.length bs - 1) bs
      in
      try
      let (substn,_,_) = Reductionops.Stack.fold2
			   (fun s u1 u -> unirec_rec curenvnb pb b false s u1 (substl ks u))
			   (evd,ms,es) us2 us in
      let (substn,_,_) = Reductionops.Stack.fold2
			   (fun s u1 u -> unirec_rec curenvnb pb b false s u1 (substl ks u))
			   substn params1 params in
      let (substn,_,_) = Reductionops.Stack.fold2 (unirec_rec curenvnb pb b false) substn ts ts1 in
      let app = mkApp (c, Array.rev_of_list ks) in
      (* let substn = unirec_rec curenvnb pb b false substn t cN in *)
	unirec_rec curenvnb pb b false substn c1 app
      with Invalid_argument "Reductionops.Stack.fold2" ->
	error_cannot_unify (fst curenvnb) sigma (cM,cN)
    else error_cannot_unify (fst curenvnb) sigma (cM,cN)
  in
    
  let res = 
    if occur_meta_or_undefined_evar sigma m || occur_meta_or_undefined_evar sigma n
      || subterm_restriction conv_at_top flags then None
    else 
      let sigma, b = match flags.modulo_conv_on_closed_terms with
	| Some convflags -> infer_conv ~pb:cv_pb ~ts:convflags env sigma m n
	| _ -> constr_cmp cv_pb sigma flags m n in
	if b then Some sigma
	else if (match flags.modulo_conv_on_closed_terms, flags.modulo_delta with
        | Some (cv_id, cv_k), (dl_id, dl_k) ->
          Id.Pred.subset dl_id cv_id && Cpred.subset dl_k cv_k
        | None,(dl_id, dl_k) ->
          Id.Pred.is_empty dl_id && Cpred.is_empty dl_k)
	then error_cannot_unify env sigma (m, n) else None
  in 
    match res with 
    | Some sigma -> sigma, ms, es
    | None -> unirec_rec (env,0) cv_pb conv_at_top false subst m n

let unify_0 env sigma = unify_0_with_initial_metas (sigma,[],[]) true env

let left = true
let right = false

let rec unify_with_eta keptside flags env sigma c1 c2 =
(* Question: try whd_betadeltaiota on ci if not two lambdas? *)
  match kind_of_term c1, kind_of_term c2 with
  | (Lambda (na,t1,c1'), Lambda (_,t2,c2')) ->
    let env' = push_rel_assum (na,t1) env in
    let sigma,metas,evars = unify_0 env sigma CONV flags t1 t2 in
    let side,(sigma,metas',evars') =
      unify_with_eta keptside flags env' sigma c1' c2'
    in (side,(sigma,metas@metas',evars@evars'))
  | (Lambda (na,t,c1'),_)->
    let env' = push_rel_assum (na,t) env in
    let side = left in (* expansion on the right: we keep the left side *)
      unify_with_eta side flags env' sigma
      c1' (mkApp (lift 1 c2,[|mkRel 1|]))
  | (_,Lambda (na,t,c2')) ->
    let env' = push_rel_assum (na,t) env in
    let side = right in (* expansion on the left: we keep the right side *)
      unify_with_eta side flags env' sigma
      (mkApp (lift 1 c1,[|mkRel 1|])) c2'
  | _ ->
    (keptside,unify_0 env sigma CONV flags c1 c2)
    
(* We solved problems [?n =_pb u] (i.e. [u =_(opp pb) ?n]) and [?n =_pb' u'],
   we now compute the problem on [u =? u'] and decide which of u or u' is kept

   Rem: the upper constraint is lost in case u <= ?n <= u' (and symmetrically
   in the case u' <= ?n <= u)
 *)
    
let merge_instances env sigma flags st1 st2 c1 c2 =
  match (opp_status st1, st2) with
  | (Conv, Conv) ->
      let side = left (* arbitrary choice, but agrees with compatibility *) in
      let (side,res) = unify_with_eta side flags env sigma c1 c2 in
      (side,Conv,res)
  | ((IsSubType | Conv as oppst1),
     (IsSubType | Conv)) ->
    let res = unify_0 env sigma CUMUL flags c2 c1 in
      if eq_instance_constraint oppst1 st2 then (* arbitrary choice *) (left, st1, res)
      else if eq_instance_constraint st2 IsSubType then (left, st1, res)
      else (right, st2, res)
  | ((IsSuperType | Conv as oppst1),
     (IsSuperType | Conv)) ->
    let res = unify_0 env sigma CUMUL flags c1 c2 in
      if eq_instance_constraint oppst1 st2 then (* arbitrary choice *) (left, st1, res)
      else if eq_instance_constraint st2 IsSuperType then (left, st1, res)
      else (right, st2, res)
  | (IsSuperType,IsSubType) ->
    (try (left, IsSubType, unify_0 env sigma CUMUL flags c2 c1)
     with e when Errors.noncritical e ->
       (right, IsSubType, unify_0 env sigma CUMUL flags c1 c2))
  | (IsSubType,IsSuperType) ->
    (try (left, IsSuperType, unify_0 env sigma CUMUL flags c1 c2)
     with e when Errors.noncritical e ->
       (right, IsSuperType, unify_0 env sigma CUMUL flags c2 c1))
    
(* Unification
 *
 * Procedure:
 * (1) The function [unify mc wc M N] produces two lists:
 *     (a) a list of bindings Meta->RHS
 *     (b) a list of bindings EVAR->RHS
 *
 * The Meta->RHS bindings cannot themselves contain
 * meta-vars, so they get applied eagerly to the other
 * bindings.  This may or may not close off all RHSs of
 * the EVARs.  For each EVAR whose RHS is closed off,
 * we can just apply it, and go on.  For each which
 * is not closed off, we need to do a mimick step -
 * in general, we have something like:
 *
 *      ?X == (c e1 e2 ... ei[Meta(k)] ... en)
 *
 * so we need to do a mimick step, converting ?X
 * into
 *
 *      ?X -> (c ?z1 ... ?zn)
 *
 * of the proper types.  Then, we can decompose the
 * equation into
 *
 *      ?z1 --> e1
 *          ...
 *      ?zi --> ei[Meta(k)]
 *          ...
 *      ?zn --> en
 *
 * and keep on going.  Whenever we find that a R.H.S.
 * is closed, we can, as before, apply the constraint
 * directly.  Whenever we find an equation of the form:
 *
 *      ?z -> Meta(n)
 *
 * we can reverse the equation, put it into our metavar
 * substitution, and keep going.
 *
 * The most efficient mimick possible is, for each
 * Meta-var remaining in the term, to declare a
 * new EVAR of the same type.  This is supposedly
 * determinable from the clausale form context -
 * we look up the metavar, take its type there,
 * and apply the metavar substitution to it, to
 * close it off.  But this might not always work,
 * since other metavars might also need to be resolved. *)

let applyHead env evd n c  =
  let rec apprec n c cty evd =
    if Int.equal n 0 then
      (evd, c)
    else
      match kind_of_term (whd_betadeltaiota env evd cty) with
      | Prod (_,c1,c2) ->
        let (evd',evar) =
	  Evarutil.new_evar evd env ~src:(Loc.ghost,Evar_kinds.GoalEvar) c1 in
	  apprec (n-1) (mkApp(c,[|evar|])) (subst1 evar c2) evd'
      | _ -> error "Apply_Head_Then"
  in
    apprec n c (Typing.type_of env evd c) evd
    
let is_mimick_head ts f =
  match kind_of_term f with
  | Const (c,u) -> not (Closure.is_transparent_constant ts c)
  | Var id -> not (Closure.is_transparent_variable ts id)
  | (Rel _|Construct _|Ind _) -> true
  | _ -> false

let try_to_coerce env evd c cty tycon =
  let j = make_judge c cty in
  let (evd',j') = inh_conv_coerce_rigid_to true Loc.ghost env evd j tycon in
  let evd' = Evarconv.consider_remaining_unif_problems env evd' in
  let evd' = Evd.map_metas_fvalue (nf_evar evd') evd' in
    (evd',j'.uj_val)

let w_coerce_to_type env evd c cty mvty =
  let evd,tycon = pose_all_metas_as_evars env evd mvty in
    try try_to_coerce env evd c cty tycon
    with e when precatchable_exception e ->
    (* inh_conv_coerce_rigid_to should have reasoned modulo reduction
       but there are cases where it though it was not rigid (like in
       fst (nat,nat)) and stops while it could have seen that it is rigid *)
    let cty = Tacred.hnf_constr env evd cty in
      try_to_coerce env evd c cty tycon
	  
let w_coerce env evd mv c =
  let cty = get_type_of env evd c in
  let mvty = Typing.meta_type evd mv in
  w_coerce_to_type env evd c cty mvty

let unify_to_type env sigma flags c status u =
  let sigma, c = refresh_universes (Some false) env sigma c in
  let t = get_type_of env sigma (nf_meta sigma c) in
  let t = nf_betaiota sigma (nf_meta sigma t) in
    unify_0 env sigma CUMUL flags t u

let unify_type env sigma flags mv status c =
  let mvty = Typing.meta_type sigma mv in
  let mvty = nf_meta sigma mvty in
    unify_to_type env sigma 
      {flags with modulo_delta = flags.modulo_delta_types;
	 modulo_conv_on_closed_terms = Some flags.modulo_delta_types;
	 modulo_betaiota = true}
      c status mvty

(* Move metas that may need coercion at the end of the list of instances *)

let order_metas metas =
  let rec order latemetas = function
  | [] -> List.rev latemetas
  | (_,_,(_,CoerceToType) as meta)::metas ->
    order (meta::latemetas) metas
  | (_,_,(_,_) as meta)::metas ->
    meta :: order latemetas metas
  in order [] metas

(* Solve an equation ?n[x1=u1..xn=un] = t where ?n is an evar *)

let solve_simple_evar_eqn ts env evd ev rhs =
  match solve_simple_eqn (Evarconv.evar_conv_x ts) env evd (None,ev,rhs) with
  | UnifFailure (evd,reason) ->
      error_cannot_unify env evd ~reason (mkEvar ev,rhs);
  | Success evd ->
      Evarconv.consider_remaining_unif_problems env evd

(* [w_merge env sigma b metas evars] merges common instances in metas
   or in evars, possibly generating new unification problems; if [b]
   is true, unification of types of metas is required *)

let w_merge env with_types flags (evd,metas,evars) =
  let rec w_merge_rec evd metas evars eqns =

    (* Process evars *)
    match evars with
    | (curenv,(evk,_ as ev),rhs)::evars' ->
	if Evd.is_defined evd evk then
	  let v = Evd.existential_value evd ev in
	  let (evd,metas',evars'') =
	    unify_0 curenv evd CONV (set_merge_flags flags) rhs v in
	  w_merge_rec evd (metas'@metas) (evars''@evars') eqns
    	else begin
	  (* This can make rhs' ill-typed if metas are *)
          let rhs' = subst_meta_instances metas rhs in
          match kind_of_term rhs with
	  | App (f,cl) when occur_meta rhs' ->
	      if occur_evar evk rhs' then
                error_occur_check curenv evd evk rhs';
	      if is_mimick_head flags.modulo_delta f then
		let evd' =
		  mimick_undefined_evar evd flags f (Array.length cl) evk in
		w_merge_rec evd' metas evars eqns
	      else
		let evd', rhs'' = pose_all_metas_as_evars curenv evd rhs' in
		w_merge_rec (solve_simple_evar_eqn flags.modulo_delta_types curenv evd' ev rhs'')
		  metas evars' eqns

          | _ ->
	      let evd', rhs'' = pose_all_metas_as_evars curenv evd rhs' in
		w_merge_rec (solve_simple_evar_eqn flags.modulo_delta_types curenv evd' ev rhs'')
		  metas evars' eqns
	end
    | [] ->

    (* Process metas *)
    match metas with
    | (mv,c,(status,to_type))::metas ->
        let ((evd,c),(metas'',evars'')),eqns =
	  if with_types && to_type != TypeProcessed then
	    begin match to_type with
	    | CoerceToType ->
              (* Some coercion may have to be inserted *)
	      (w_coerce env evd mv c,([],[])),eqns
	    | _ ->
              (* No coercion needed: delay the unification of types *)
	      ((evd,c),([],[])),(mv,status,c)::eqns
	    end
	  else
	    ((evd,c),([],[])),eqns 
	in
	  if meta_defined evd mv then
	    let {rebus=c'},(status',_) = meta_fvalue evd mv in
            let (take_left,st,(evd,metas',evars')) =
	      merge_instances env evd flags status' status c' c
	    in
	    let evd' =
              if take_left then evd
              else meta_reassign mv (c,(st,TypeProcessed)) evd
	    in
              w_merge_rec evd' (metas'@metas@metas'') (evars'@evars'') eqns
    	  else
            let evd' =
              if occur_meta_evd evd mv c then
                if isMetaOf mv (whd_betadeltaiota env evd c) then evd
                else error_cannot_unify env evd (mkMeta mv,c)
              else
	        meta_assign mv (c,(status,TypeProcessed)) evd in
	    w_merge_rec evd' (metas''@metas) evars'' eqns
    | [] ->
	(* Process type eqns *)
	let rec process_eqns failures = function
	  | (mv,status,c)::eqns ->
              (match (try Inl (unify_type env evd flags mv status c)
		      with e when Errors.noncritical e -> Inr e)
	       with 
	       | Inr e -> process_eqns (((mv,status,c),e)::failures) eqns
	       | Inl (evd,metas,evars) ->
		   w_merge_rec evd metas evars (List.map fst failures @ eqns))
	  | [] -> 
	      (match failures with
	       | [] -> evd
	       | ((mv,status,c),e)::_ -> raise e)
	in process_eqns [] eqns
	      
  and mimick_undefined_evar evd flags hdc nargs sp =
    let ev = Evd.find_undefined evd sp in
    let sp_env = Global.env_of_context ev.evar_hyps in
    let (evd', c) = applyHead sp_env evd nargs hdc in
    let (evd'',mc,ec) =
      unify_0 sp_env evd' CUMUL (set_merge_flags flags)
        (get_type_of sp_env evd' c) ev.evar_concl in
    let evd''' = w_merge_rec evd'' mc ec [] in
    if evd' == evd'''
    then Evd.define sp c evd'''
    else Evd.define sp (Evarutil.nf_evar evd''' c) evd''' in

  let check_types evd = 
    let metas = Evd.meta_list evd in
    let eqns = List.fold_left (fun acc (mv, b) ->
      match b with
      | Clval (n, (t, (c, TypeNotProcessed)), v) -> (mv, c, t.rebus) :: acc
      | _ -> acc) [] metas
    in w_merge_rec evd [] [] eqns
  in
  let res =  (* merge constraints *)
    w_merge_rec evd (order_metas metas) (List.rev evars) []
  in
    if with_types then check_types res
    else res

let w_unify_meta_types env ?(flags=default_unify_flags ()) evd =
  let metas,evd = retract_coercible_metas evd in
  w_merge env true flags (evd,metas,[])

(* [w_unify env evd M N]
   performs a unification of M and N, generating a bunch of
   unification constraints in the process.  These constraints
   are processed, one-by-one - they may either generate new
   bindings, or, if there is already a binding, new unifications,
   which themselves generate new constraints.  This continues
   until we get failure, or we run out of constraints.
   [clenv_typed_unify M N clenv] expects in addition that expected
   types of metavars are unifiable with the types of their instances    *)

let head_app sigma m =
  fst (whd_nored_state sigma (m, Stack.empty))

let check_types env flags (sigma,_,_ as subst) m n =
  if isEvar_or_Meta (head_app sigma m) then
    unify_0_with_initial_metas subst true env CUMUL
      flags
      (get_type_of env sigma n)
      (get_type_of env sigma m)
  else if isEvar_or_Meta (head_app sigma n) then
    unify_0_with_initial_metas subst true env CUMUL
      flags
      (get_type_of env sigma m)
      (get_type_of env sigma n)
  else subst

let try_resolve_typeclasses env evd flags m n =
  if flags.resolve_evars then
    Typeclasses.resolve_typeclasses ~filter:Typeclasses.no_goals ~split:false
      ~fail:true env evd
  else evd

let w_unify_core_0 env evd with_types cv_pb flags m n =
  let (mc1,evd') = retract_coercible_metas evd in
  let (sigma,ms,es) = check_types env flags (evd,mc1,[]) m n in
  let subst2 =
     unify_0_with_initial_metas (evd',ms,es) false env cv_pb flags m n
  in
  let evd = w_merge env with_types flags subst2 in
  try_resolve_typeclasses env evd flags m n

let w_typed_unify env evd = w_unify_core_0 env evd true

let w_typed_unify_array env evd flags f1 l1 f2 l2 =
  let flags' = { flags with resolve_evars = false } in
  let f1,l1,f2,l2 = adjust_app_array_size f1 l1 f2 l2 in
  let (mc1,evd') = retract_coercible_metas evd in
  let fold_subst subst m n = unify_0_with_initial_metas subst true env CONV flags' m n in
  let subst = fold_subst (evd', [], []) f1 f2 in
  let subst = Array.fold_left2 fold_subst subst l1 l2 in
  let evd = w_merge env true flags subst in
  try_resolve_typeclasses env evd flags (mkApp(f1,l1)) (mkApp(f2,l2))

(* takes a substitution s, an open term op and a closed term cl
   try to find a subterm of cl which matches op, if op is just a Meta
   FAIL because we cannot find a binding *)

let iter_fail f a =
  let n = Array.length a in
  let rec ffail i =
    if Int.equal i n then error "iter_fail"
    else
      try f a.(i)
      with ex when precatchable_exception ex -> ffail (i+1)
  in ffail 0

(* make_abstraction: a variant of w_unify_to_subterm which works on
   contexts, with evars, and possibly with occurrences *)

let out_arg = function
  | Misctypes.ArgVar _ -> anomaly (Pp.str "Unevaluated or_var variable")
  | Misctypes.ArgArg x -> x

let occurrences_of_hyp id cls =
  let rec hyp_occ = function
      [] -> None
    | ((occs,id'),hl)::_ when Id.equal id id' ->
        Some (occurrences_map (List.map out_arg) occs, hl)
    | _::l -> hyp_occ l in
  match cls.onhyps with
      None -> Some (AllOccurrences,InHyp)
    | Some l -> hyp_occ l

let occurrences_of_goal cls =
  if cls.concl_occs == NoOccurrences then None
  else Some (occurrences_map (List.map out_arg) cls.concl_occs)

let in_every_hyp cls = Option.is_empty cls.onhyps

let indirectly_dependent c d decls =
  not (isVar c) &&
    (* This test is not needed if the original term is a variable, but
       it is needed otherwise, as e.g. when abstracting over "2" in
       "forall H:0=2, H=H:>(0=1+1) -> 0=2." where there is now obvious
       way to see that the second hypothesis depends indirectly over 2 *)
    List.exists (fun (id,_,_) -> dependent_in_decl (mkVar id) d) decls

let indirect_dependency d decls =
  pi1 (List.hd (List.filter (fun (id,_,_) -> dependent_in_decl (mkVar id) d) decls))

let finish_evar_resolution ?(flags=Pretyping.all_and_fail_flags) env initial_sigma (sigma,c) =
  let sigma = Pretyping.solve_remaining_evars flags env initial_sigma sigma
  in Evd.evar_universe_context sigma, nf_evar sigma c

let default_matching_flags sigma = {
  modulo_conv_on_closed_terms = Some empty_transparent_state;
  use_metas_eagerly_in_conv_on_closed_terms = false;
  modulo_delta = empty_transparent_state;
  modulo_delta_types = full_transparent_state;
  modulo_delta_in_merge = Some full_transparent_state;
  check_applied_meta_types = true;
  resolve_evars = false;
  use_pattern_unification = false;
  use_meta_bound_pattern_unification = false;
  frozen_evars =
    fold_undefined (fun evk _ evars -> Evar.Set.add evk evars)
      sigma Evar.Set.empty;
  restrict_conv_on_strict_subterms = false;
  modulo_betaiota = false;
  modulo_eta = false;
  allow_K_in_toplevel_higher_order_unification = false
}

(* This supports search of occurrences of term from a pattern *)

let make_pattern_test inf_flags env sigma0 (sigma,c) =
  let flags = default_matching_flags sigma0 in
  let matching_fun _ t =
    try let sigma = w_typed_unify env sigma Reduction.CONV flags c t in
	  Some(sigma, t)
    with
    | PretypeError (_,_,CannotUnify (c1,c2,Some e)) ->
        raise (NotUnifiable (Some (c1,c2,e)))
    | e when Errors.noncritical e -> raise (NotUnifiable None) in
  let merge_fun c1 c2 =
    match c1, c2 with
    | Some (evd,c1) as x, Some (_,c2) ->
      if is_conv env sigma c1 c2 then x else raise (NotUnifiable None)
    | Some _, None -> c1
    | None, Some _ -> c2
    | None, None -> None in
  { match_fun = matching_fun; merge_fun = merge_fun;
    testing_state = None; last_found = None },
  (fun test -> match test.testing_state with
  | None ->
      finish_evar_resolution ~flags:inf_flags env sigma0 (sigma,c)
  | Some (sigma,_) ->
     let univs, subst = nf_univ_variables sigma in
     Evd.evar_universe_context univs,
     subst_univs_constr subst (nf_evar sigma c))

let make_eq_test evd c =
  let out cstr =
    Evd.evar_universe_context cstr.testing_state, c
  in
    (make_eq_univs_test evd c, out)

let make_abstraction_core name (test,out) (sigmac,c) ty occs check_occs env concl =
  let id =
    let t = match ty with Some t -> t | None -> get_type_of env sigmac c in
    let x = id_of_name_using_hdchar (Global.env()) t name in
    let ids = ids_of_named_context (named_context env) in
    if name == Anonymous then next_ident_away_in_goal x ids else
    if mem_named_context x (named_context env) then
      error ("The variable "^(Id.to_string x)^" is already declared.")
    else
      x
  in
  let mkvarid () = mkVar id in
  let compute_dependency _ (hyp,_,_ as d) depdecls =
    match occurrences_of_hyp hyp occs with
    | None ->
        if indirectly_dependent c d depdecls then
          (* Told explicitly not to abstract over [d], but it is dependent *)
          let id' = indirect_dependency d depdecls in
          errorlabstrm "" (str "Cannot abstract over " ++ Nameops.pr_id id'
            ++ str " without also abstracting or erasing " ++ Nameops.pr_id hyp
            ++ str ".")
        else
          depdecls
    | Some ((AllOccurrences, InHyp) as occ) ->
        let newdecl = replace_term_occ_decl_modulo occ test mkvarid d in
        if Context.eq_named_declaration d newdecl
           && not (indirectly_dependent c d depdecls)
        then
          if check_occs && not (in_every_hyp occs)
          then raise (PretypeError (env,sigmac,NoOccurrenceFound (c,Some hyp)))
          else depdecls
        else
          newdecl :: depdecls
    | Some occ ->
        replace_term_occ_decl_modulo occ test mkvarid d :: depdecls in
  try
    let depdecls = fold_named_context compute_dependency env ~init:[] in
    let ccl = match occurrences_of_goal occs with
      | None -> concl
      | Some occ ->
          replace_term_occ_modulo occ test mkvarid concl
    in
    let lastlhyp =
      if List.is_empty depdecls then None else Some (pi1(List.last depdecls)) in
    (id,depdecls,lastlhyp,ccl,out test)
  with
    SubtermUnificationError e ->
      raise (PretypeError (env,sigmac,CannotUnifyOccurrences e))

(** [make_abstraction] is the main entry point to abstract over a term
    or pattern at some occurrences; it returns:
    - the id used for the abstraction
    - the type of the abstraction
    - the declarations from the context which depend on the term or pattern
    - the most recent hyp before which there is no dependency in the term of pattern
    - the abstracted conclusion
    - an evar universe context effect to apply on the goal
    - the term or pattern to abstract fully instantiated
*)

type abstraction_request =
| AbstractPattern of Name.t * (evar_map * constr) * clause * bool * Pretyping.inference_flags
| AbstractExact of Name.t * constr * types option * clause * bool

type abstraction_result =
  Names.Id.t * Context.named_declaration list * Names.Id.t option *
    constr * (Evd.evar_universe_context * constr)

let make_abstraction env evd ccl abs =
  match abs with
  | AbstractPattern (name,c,occs,check_occs,flags) ->
      make_abstraction_core name
        (make_pattern_test flags env evd c) c None occs check_occs env ccl
  | AbstractExact (name,c,ty,occs,check_occs) ->
      make_abstraction_core name
        (make_eq_test evd c) (evd,c) ty occs check_occs env ccl

(* Tries to find an instance of term [cl] in term [op].
   Unifies [cl] to every subterm of [op] until it finds a match.
   Fails if no match is found *)
let w_unify_to_subterm env evd ?(flags=default_unify_flags ()) (op,cl) =
  let bestexn = ref None in
  let rec matchrec cl =
    let cl = strip_outer_cast cl in
    (try
       if closed0 cl && not (isEvar cl)
       then
	 (try w_typed_unify env evd CONV flags op cl,cl
	  with ex when Pretype_errors.unsatisfiable_exception ex ->
	    bestexn := Some ex; error "Unsat")
       else error "Bound 1"
     with ex when precatchable_exception ex ->
       (match kind_of_term cl with
	  | App (f,args) ->
	      let n = Array.length args in
	      assert (n>0);
	      let c1 = mkApp (f,Array.sub args 0 (n-1)) in
	      let c2 = args.(n-1) in
	      (try
		 matchrec c1
	       with ex when precatchable_exception ex ->
		 matchrec c2)
          | Case(_,_,c,lf) -> (* does not search in the predicate *)
	       (try
		 matchrec c
	       with ex when precatchable_exception ex ->
		 iter_fail matchrec lf)
	  | LetIn(_,c1,_,c2) ->
	       (try
		 matchrec c1
	       with ex when precatchable_exception ex ->
		 matchrec c2)

	  | Proj (p,c) -> matchrec c

	  | Fix(_,(_,types,terms)) ->
	       (try
		 iter_fail matchrec types
	       with ex when precatchable_exception ex ->
		 iter_fail matchrec terms)

	  | CoFix(_,(_,types,terms)) ->
	       (try
		 iter_fail matchrec types
	       with ex when precatchable_exception ex ->
		 iter_fail matchrec terms)

          | Prod (_,t,c) ->
	      (try
		 matchrec t
	       with ex when precatchable_exception ex ->
		 matchrec c)
          | Lambda (_,t,c) ->
	      (try
		 matchrec t
	       with ex when precatchable_exception ex ->
		 matchrec c)
          | _ -> error "Match_subterm"))
  in
  try matchrec cl
  with ex when precatchable_exception ex ->
    match !bestexn with
    | None -> raise (PretypeError (env,evd,NoOccurrenceFound (op, None)))
    | Some e -> raise e

(* Tries to find all instances of term [cl] in term [op].
   Unifies [cl] to every subterm of [op] and return all the matches.
   Fails if no match is found *)
let w_unify_to_subterm_all env evd ?(flags=default_unify_flags ()) (op,cl) =
  let return a b =
    let (evd,c as a) = a () in
      if List.exists (fun (evd',c') -> eq_constr c c') b then b else a :: b
  in
  let fail str _ = error str in
  let bind f g a =
    let a1 = try f a
             with ex
             when precatchable_exception ex -> a
    in try g a1
       with ex
       when precatchable_exception ex -> a1
  in
  let bind_iter f a =
    let n = Array.length a in
    let rec ffail i =
      if Int.equal i n then fun a -> a
      else bind (f a.(i)) (ffail (i+1))
    in ffail 0
  in
  let rec matchrec cl =
    let cl = strip_outer_cast cl in
      (bind
	  (if closed0 cl
	  then return (fun () -> w_typed_unify env evd CONV flags op cl,cl)
            else fail "Bound 1")
          (match kind_of_term cl with
	    | App (f,args) ->
		let n = Array.length args in
		assert (n>0);
		let c1 = mkApp (f,Array.sub args 0 (n-1)) in
		let c2 = args.(n-1) in
		bind (matchrec c1) (matchrec c2)

            | Case(_,_,c,lf) -> (* does not search in the predicate *)
		bind (matchrec c) (bind_iter matchrec lf)

	    | Proj (p,c) -> matchrec c

	    | LetIn(_,c1,_,c2) ->
		bind (matchrec c1) (matchrec c2)

	    | Fix(_,(_,types,terms)) ->
		bind (bind_iter matchrec types) (bind_iter matchrec terms)

	    | CoFix(_,(_,types,terms)) ->
		bind (bind_iter matchrec types) (bind_iter matchrec terms)

            | Prod (_,t,c) ->
		bind (matchrec t) (matchrec c)

            | Lambda (_,t,c) ->
		bind (matchrec t) (matchrec c)

            | _ -> fail "Match_subterm"))
  in
  let res = matchrec cl [] in
  match res with
  | [] ->
    raise (PretypeError (env,evd,NoOccurrenceFound (op, None)))
  | _ -> res

let w_unify_to_subterm_list env evd flags hdmeta oplist t =
  List.fold_right
    (fun op (evd,l) ->
      let op = whd_meta evd op in
      if isMeta op then
	if flags.allow_K_in_toplevel_higher_order_unification then (evd,op::l)
	else error_abstraction_over_meta env evd hdmeta (destMeta op)
      else if occur_meta_or_existential op then
        let (evd',cl) =
          try
	    (* This is up to delta for subterms w/o metas ... *)
	    w_unify_to_subterm env evd ~flags (strip_outer_cast op,t)
	  with PretypeError (env,_,NoOccurrenceFound _) when
              flags.allow_K_in_toplevel_higher_order_unification -> (evd,op)
        in
	  if not flags.allow_K_in_toplevel_higher_order_unification &&
            (* ensure we found a different instance *)
	    List.exists (fun op -> eq_constr op cl) l
	  then error_non_linear_unification env evd hdmeta cl
	  else (evd',cl::l)
      else if flags.allow_K_in_toplevel_higher_order_unification 
	  || dependent_univs op t
      then
	(evd,op::l)
      else
	(* This is not up to delta ... *)
	raise (PretypeError (env,evd,NoOccurrenceFound (op, None))))
    oplist
    (evd,[])

let secondOrderAbstraction env evd flags typ (p, oplist) =
  (* Remove delta when looking for a subterm *)
  let flags = { flags with modulo_delta = empty_transparent_state } in
  let (evd',cllist) = w_unify_to_subterm_list env evd flags p oplist typ in
  let typp = Typing.meta_type evd' p in
  let evd',(pred,predtyp) = abstract_list_all env evd' typp typ cllist in
  let evd', b = infer_conv ~pb:CUMUL env evd' predtyp typp in
    if not b then
      error_wrong_abstraction_type env evd'
  	(Evd.meta_name evd p) pred typp predtyp;
    w_merge env false flags (evd',[p,pred,(Conv,TypeProcessed)],[])

  (* let evd',metas,evars =  *)
  (*   try unify_0 env evd' CUMUL flags predtyp typp  *)
  (*   with NotConvertible -> *)
  (*     error_wrong_abstraction_type env evd *)
  (*       (Evd.meta_name evd p) pred typp predtyp *)
  (* in *)
  (*   w_merge env false flags (evd',(p,pred,(Conv,TypeProcessed))::metas,evars) *)

let secondOrderDependentAbstraction env evd flags typ (p, oplist) =
  let typp = Typing.meta_type evd p in
  let evd, pred = abstract_list_all_with_dependencies env evd typp typ oplist in
  w_merge env false flags (evd,[p,pred,(Conv,TypeProcessed)],[])

let secondOrderAbstractionAlgo dep =
  if dep then secondOrderDependentAbstraction else secondOrderAbstraction

let w_unify2 env evd flags dep cv_pb ty1 ty2 =
  let c1, oplist1 = whd_nored_stack evd ty1 in
  let c2, oplist2 = whd_nored_stack evd ty2 in
  match kind_of_term c1, kind_of_term c2 with
    | Meta p1, _ ->
        (* Find the predicate *)
        secondOrderAbstractionAlgo dep env evd flags ty2 (p1,oplist1)
    | _, Meta p2 ->
        (* Find the predicate *)
        secondOrderAbstractionAlgo dep env evd flags ty1 (p2, oplist2)
    | _ -> error "w_unify2"

(* The unique unification algorithm works like this: If the pattern is
   flexible, and the goal has a lambda-abstraction at the head, then
   we do a first-order unification.

   If the pattern is not flexible, then we do a first-order
   unification, too.

   If the pattern is flexible, and the goal doesn't have a
   lambda-abstraction head, then we second-order unification. *)

(* We decide here if first-order or second-order unif is used for Apply *)
(* We apply a term of type (ai:Ai)C and try to solve a goal C'          *)
(* The type C is in clenv.templtyp.rebus with a lot of Meta to solve    *)

(* 3-4-99 [HH] New fo/so choice heuristic :
   In case we have to unify (Meta(1) args) with ([x:A]t args')
   we first try second-order unification and if it fails first-order.
   Before, second-order was used if the type of Meta(1) and [x:A]t was
   convertible and first-order otherwise. But if failed if e.g. the type of
   Meta(1) had meta-variables in it. *)
let w_unify env evd cv_pb ?(flags=default_unify_flags ()) ty1 ty2 =
  let hd1,l1 = decompose_appvect (whd_nored evd ty1) in
  let hd2,l2 = decompose_appvect (whd_nored evd ty2) in
  let is_empty1 = Array.is_empty l1 in
  let is_empty2 = Array.is_empty l2 in
    match kind_of_term hd1, not is_empty1, kind_of_term hd2, not is_empty2 with
      (* Pattern case *)
      | (Meta _, true, Lambda _, _ | Lambda _, _, Meta _, true)
	  when Int.equal (Array.length l1) (Array.length l2) ->
	  (try
	      w_typed_unify_array env evd flags hd1 l1 hd2 l2
	    with ex when precatchable_exception ex ->
	      try
		w_unify2 env evd flags false cv_pb ty1 ty2
	      with PretypeError (env,_,NoOccurrenceFound _) as e -> raise e)

      (* Second order case *)
      | (Meta _, true, _, _ | _, _, Meta _, true) ->
	  (try
	      w_unify2 env evd flags false cv_pb ty1 ty2
	    with PretypeError (env,_,NoOccurrenceFound _) as e -> raise e
	      | ex when precatchable_exception ex ->
		  try
		    w_typed_unify_array env evd flags hd1 l1 hd2 l2
		  with ex' when precatchable_exception ex' ->
                    (* Last chance, use pattern-matching with typed
                       dependencies (done late for compatibility) *)
	            try
	              w_unify2 env evd flags true cv_pb ty1 ty2
		    with ex' when precatchable_exception ex' ->
		      raise ex)

      (* General case: try first order *)
      | _ -> w_typed_unify env evd cv_pb flags ty1 ty2

(* Profiling *)

let w_unify env evd cv_pb flags ty1 ty2 =
  w_unify env evd cv_pb ~flags:flags ty1 ty2

let w_unify = 
  if Flags.profile then
    let wunifkey = Profile.declare_profile "w_unify" in
      Profile.profile6 wunifkey w_unify
  else w_unify

let w_unify env evd cv_pb ?(flags=default_unify_flags ()) ty1 ty2 =
  w_unify env evd cv_pb flags ty1 ty2
