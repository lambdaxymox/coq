(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Pp
open CErrors
open Util
open CAst
open Names
open Nameops
open Namegen
open Constr
open Context
open Libnames
open Globnames
open Impargs
open Glob_term
open Glob_ops
open Patternops
open Pretyping
open Cases
open Constrexpr
open Constrexpr_ops
open Notation_term
open Notation_ops
open Notation
open Inductiveops
open Context.Rel.Declaration
open NumTok

(** constr_expr -> glob_constr translation:
    - it adds holes for implicit arguments
    - it replaces notations by their value (scopes stuff are here)
    - it recognizes global vars from local ones
    - it prepares pattern matching problems (a pattern becomes a tree
      where nodes are constructor/variable pairs and leafs are variables)

    All that at once, fasten your seatbelt!
*)

(* To interpret implicits and arg scopes of variables in inductive
   types and recursive definitions and of projection names in records *)

type var_internalization_type =
  | Inductive
  | Recursive
  | Method
  | Variable

type var_unique_id = string

let var_uid =
  let count = ref 0 in
  fun id -> incr count; Id.to_string id ^ ":" ^ string_of_int !count

type var_internalization_data =
    (* type of the "free" variable, for coqdoc, e.g. while typing the
       constructor of JMeq, "JMeq" behaves as a variable of type Inductive *)
    var_internalization_type *
    (* signature of impargs of the variable *)
    Impargs.implicit_status list *
    (* subscopes of the args of the variable *)
    scope_name option list *
    (* unique ID for coqdoc links *)
    var_unique_id

type internalization_env =
    (var_internalization_data) Id.Map.t

type ltac_sign = {
  ltac_vars : Id.Set.t;
  ltac_bound : Id.Set.t;
  ltac_extra : Genintern.Store.t;
}

let interning_grammar = ref false

(* Historically for parsing grammar rules, but in fact used only for
   translator, v7 parsing, and unstrict tactic internalization *)
let for_grammar f x =
  interning_grammar := true;
  let a = f x in
    interning_grammar := false;
    a

(**********************************************************************)
(* Locating reference, possibly via an abbreviation *)

let locate_reference qid =
  Smartlocate.global_of_extended_global (Nametab.locate_extended qid)

let is_global id =
  try
    let _ = locate_reference (qualid_of_ident id) in true
  with Not_found ->
    false

(**********************************************************************)
(* Internalization errors                                             *)

type internalization_error =
  | VariableCapture of Id.t * Id.t
  | IllegalMetavariable
  | NotAConstructor of qualid
  | UnboundFixName of bool * Id.t
  | NonLinearPattern of Id.t
  | BadPatternsNumber of int * int
  | NotAProjection of qualid
  | NotAProjectionOf of qualid * qualid
  | ProjectionsOfDifferentRecords of qualid * qualid

exception InternalizationError of internalization_error

let explain_variable_capture id id' =
  Id.print id ++ str " is dependent in the type of " ++ Id.print id' ++
  strbrk ": cannot interpret both of them with the same type"

let explain_illegal_metavariable =
  str "Metavariables allowed only in patterns"

let explain_not_a_constructor qid =
  str "Unknown constructor: " ++ pr_qualid qid

let explain_unbound_fix_name is_cofix id =
  str "The name" ++ spc () ++ Id.print id ++
  spc () ++ str "is not bound in the corresponding" ++ spc () ++
  str (if is_cofix then "co" else "") ++ str "fixpoint definition"

let explain_non_linear_pattern id =
  str "The variable " ++ Id.print id ++ str " is bound several times in pattern"

let explain_bad_patterns_number n1 n2 =
  str "Expecting " ++ int n1 ++ str (String.plural n1 " pattern") ++
  str " but found " ++ int n2

let explain_field_not_a_projection field_id =
  pr_qualid field_id ++ str ": Not a projection"

let explain_field_not_a_projection_of field_id inductive_id =
  pr_qualid field_id ++ str ": Not a projection of inductive " ++ pr_qualid inductive_id

let explain_projections_of_diff_records inductive1_id inductive2_id =
  str "This record contains fields of both " ++ pr_qualid inductive1_id ++
  str " and " ++ pr_qualid inductive2_id

let explain_internalization_error e =
  let pp = match e with
  | VariableCapture (id,id') -> explain_variable_capture id id'
  | IllegalMetavariable -> explain_illegal_metavariable
  | NotAConstructor ref -> explain_not_a_constructor ref
  | UnboundFixName (iscofix,id) -> explain_unbound_fix_name iscofix id
  | NonLinearPattern id -> explain_non_linear_pattern id
  | BadPatternsNumber (n1,n2) -> explain_bad_patterns_number n1 n2
  | NotAProjection field_id -> explain_field_not_a_projection field_id
  | NotAProjectionOf (field_id, inductive_id) ->
    explain_field_not_a_projection_of field_id inductive_id
  | ProjectionsOfDifferentRecords (inductive1_id, inductive2_id) ->
    explain_projections_of_diff_records inductive1_id inductive2_id
  in pp ++ str "."

let _ = CErrors.register_handler (function
    | InternalizationError e ->
      Some (explain_internalization_error e)
    | _ -> None)

let error_bad_inductive_type ?loc ?info () =
  user_err ?loc ?info (str
    "This should be an inductive type applied to patterns.")

let error_parameter_not_implicit ?loc =
  user_err ?loc  (str
   "The parameters do not bind in patterns;" ++ spc () ++ str
    "they must be replaced by '_'.")

let error_ldots_var ?loc =
  user_err ?loc  (str "Special token " ++ Id.print ldots_var ++
    str " is for use in the Notation command.")

(**********************************************************************)
(* Pre-computing the implicit arguments and arguments scopes needed   *)
(* for interpretation *)

let parsing_explicit = ref false

let empty_internalization_env = Id.Map.empty

let compute_internalization_data env sigma id ty typ impl =
  let impl = compute_implicits_with_manual env sigma typ (is_implicit_args()) impl in
  (ty, impl, compute_arguments_scope env sigma typ, var_uid id)

let compute_internalization_env env sigma ?(impls=empty_internalization_env) ty =
  List.fold_left3
    (fun map id typ impl -> Id.Map.add id (compute_internalization_data env sigma id ty typ impl) map)
    impls

let extend_internalization_data (r, impls, scopes, uid) impl scope =
  (r, impls@[impl], scopes@[scope], uid)

(**********************************************************************)
(* Contracting "{ _ }" in notations *)

let rec wildcards ntn n =
  if Int.equal n (String.length ntn) then []
  else let l = spaces ntn (n+1) in if ntn.[n] == '_' then n::l else l
and spaces ntn n =
  if Int.equal n (String.length ntn) then []
  else if ntn.[n] == ' ' then wildcards ntn (n+1) else spaces ntn (n+1)

let expand_notation_string ntn n =
  let pos = List.nth (wildcards ntn 0) n in
  let hd = if Int.equal pos 0 then "" else String.sub ntn 0 pos in
  let tl =
    if Int.equal pos (String.length ntn) then ""
    else String.sub ntn (pos+1) (String.length ntn - pos -1) in
  hd ^ "{ _ }" ^ tl

(* This contracts the special case of "{ _ }" for sumbool, sumor notations *)
(* Remark: expansion of squash at definition is done in metasyntax.ml *)
let contract_curly_brackets ntn (l,ll,bl,bll) =
  match ntn with
  | InCustomEntry _,_ -> ntn,(l,ll,bl,bll)
  | InConstrEntry, ntn ->
  let ntn' = ref ntn in
  let rec contract_squash n = function
    | [] -> []
    | { CAst.v = CNotation (None,(InConstrEntry,"{ _ }"),([a],[],[],[])) } :: l ->
        ntn' := expand_notation_string !ntn' n;
        contract_squash n (a::l)
    | a :: l ->
        a::contract_squash (n+1) l in
  let l = contract_squash 0 l in
  (* side effect; don't inline *)
  (InConstrEntry,!ntn'),(l,ll,bl,bll)

let contract_curly_brackets_pat ntn (l,ll) =
  match ntn with
  | InCustomEntry _,_ -> ntn,(l,ll)
  | InConstrEntry, ntn ->
  let ntn' = ref ntn in
  let rec contract_squash n = function
    | [] -> []
    | { CAst.v = CPatNotation (None,(InConstrEntry,"{ _ }"),([a],[]),[]) } :: l ->
        ntn' := expand_notation_string !ntn' n;
        contract_squash n (a::l)
    | a :: l ->
        a::contract_squash (n+1) l in
  let l = contract_squash 0 l in
  (* side effect; don't inline *)
  (InConstrEntry,!ntn'),(l,ll)

type intern_env = {
  ids: Names.Id.Set.t;
  unb: bool;
  tmp_scope: Notation_term.tmp_scope_name option;
  scopes: Notation_term.scope_name list;
  impls: internalization_env;
  binder_block_names: (abstraction_kind option (* None = unknown *) * Id.Set.t) option;
}

type pattern_intern_env = {
  pat_scopes: Notation_term.subscopes;
  (* ids = Some means accept local variables; this is useful for
     terms as patterns parsed as pattersn in notations *)
  pat_ids: Id.Set.t option;
}

(**********************************************************************)
(* Remembering the parsing scope of variables in notations            *)

let make_current_scope tmp scopes = match tmp, scopes with
| Some tmp_scope, (sc :: _) when String.equal sc tmp_scope -> scopes
| Some tmp_scope, scopes -> tmp_scope :: scopes
| None, scopes -> scopes

let pr_scope_stack = function
  | [] -> str "the empty scope stack"
  | [a] -> str "scope " ++ str a
  | l -> str "scope stack " ++
      str "[" ++ prlist_with_sep pr_comma str l ++ str "]"

let error_inconsistent_scope ?loc id scopes1 scopes2 =
  user_err ?loc ~hdr:"set_var_scope"
   (Id.print id ++ str " is here used in " ++
    pr_scope_stack scopes2 ++ strbrk " while it was elsewhere used in " ++
    pr_scope_stack scopes1)

let error_expect_binder_notation_type ?loc id =
  user_err ?loc
   (Id.print id ++
    str " is expected to occur in binding position in the right-hand side.")

let set_var_scope ?loc id istermvar (tmp_scope,subscopes as scopes) ntnvars =
  try
    let used_as_binder,idscopes,typ = Id.Map.find id ntnvars in
    if not istermvar then used_as_binder := true;
    let () = if istermvar then
      (* scopes have no effect on the interpretation of identifiers *)
      begin match !idscopes with
      | None -> idscopes := Some scopes
      | Some (tmp_scope', subscopes') ->
        let s' = make_current_scope tmp_scope' subscopes' in
        let s = make_current_scope tmp_scope subscopes in
        if not (List.equal String.equal s' s) then error_inconsistent_scope ?loc id s' s
      end
    in
    match typ with
    | Notation_term.NtnInternTypeOnlyBinder ->
        if istermvar then error_expect_binder_notation_type ?loc id
    | Notation_term.NtnInternTypeAny -> ()
  with Not_found ->
    (* Not in a notation *)
    ()

let set_type_scope env = {env with tmp_scope = Notation.current_type_scope_name ()}

let reset_tmp_scope env = {env with tmp_scope = None}

let set_env_scopes env (scopt,subscopes) =
  {env with tmp_scope = scopt; scopes = subscopes @ env.scopes}

let env_for_pattern env =
  {pat_scopes = (env.tmp_scope, env.scopes); pat_ids = Some env.ids}

let mkGProd ?loc (na,bk,t) body = DAst.make ?loc @@ GProd (na, bk, t, body)
let mkGLambda ?loc (na,bk,t) body = DAst.make ?loc @@ GLambda (na, bk, t, body)

(**********************************************************************)
(* Utilities for binders                                              *)

let warn_shadowed_implicit_name =
  CWarnings.create ~name:"shadowed-implicit-name" ~category:"syntax"
    Pp.(fun na -> str "Making shadowed name of implicit argument accessible by position.")

let exists_name na l =
  match na with
  | Name id -> List.exists (function Some (ExplByName id',_,_) -> Id.equal id id' | _ -> false) l
  | _ -> false

let build_impls ?loc n bk na acc =
  let impl_status max =
    let na =
      if exists_name na acc then begin warn_shadowed_implicit_name ?loc na; Anonymous end
      else na in
    let impl = match na with
      | Name id -> Some (ExplByName id,Manual,(max,true))
      | Anonymous -> Some (ExplByPos (n,None),Manual,(max,true)) in
    impl
  in
  match bk with
  | NonMaxImplicit -> impl_status false :: acc
  | MaxImplicit -> impl_status true :: acc
  | Explicit -> None :: acc

let impls_binder_list =
  let rec aux acc n = function
    | (na,bk,None,_) :: binders -> aux (build_impls n bk na acc) (n+1) binders
    | (na,bk,Some _,_) :: binders -> aux acc n binders
    | [] -> (n,acc)
  in aux []

let impls_type_list n ?(args = []) =
  let rec aux acc n c = match DAst.get c with
    | GProd (na,bk,_,c) -> aux (build_impls n bk na acc) (n+1) c
    | _ -> List.rev acc
  in aux args n

let impls_term_list n ?(args = []) =
  let rec aux acc n c = match DAst.get c with
    | GLambda (na,bk,_,c) -> aux (build_impls n bk na acc) (n+1) c
    | GRec (fix_kind, nas, args, tys, bds) ->
       let nb = match fix_kind with |GFix (_, n) -> n | GCoFix n -> n in
       let n,acc' = List.fold_left (fun (n,acc) (na, bk, _, _) -> (n+1,build_impls n bk na acc)) (n,acc) args.(nb) in
       aux acc' n bds.(nb)
    |_ -> List.rev acc
  in aux args n

(* Check if in binder "(x1 x2 .. xn : t)", none of x1 .. xn-1 occurs in t *)
let rec check_capture ty = let open CAst in function
  | { loc; v = Name id } :: { v = Name id' } :: _ when occur_glob_constr id ty ->
    Loc.raise ?loc (InternalizationError (VariableCapture (id,id')))
  | _::nal ->
      check_capture ty nal
  | [] ->
      ()

(** Status of the internalizer wrt "Arguments" of names *)

let restart_no_binders env =
  { env with binder_block_names = None}
  (* Not in relation with the "Arguments" of a name *)

let restart_prod_binders env =
  { env with binder_block_names = Some (Some AbsPi, Id.Set.empty) }
  (* In a position binding a type to a name *)

let restart_lambda_binders env =
  { env with binder_block_names = Some (Some AbsLambda, Id.Set.empty) }
  (* In a position binding a body to a name *)

let switch_prod_binders env =
  match env.binder_block_names with
  | Some (o,ids) when o <> Some AbsLambda -> restart_prod_binders env
  | _ -> restart_no_binders env
  (* In a position switching to a type *)

let switch_lambda_binders env =
  match env.binder_block_names with
  | Some (o,ids) when o <> Some AbsPi -> restart_lambda_binders env
  | _ -> restart_no_binders env
  (* In a position switching to a term *)

let slide_binders env =
  match env.binder_block_names with
  | Some (o,ids) when o <> Some AbsPi -> restart_prod_binders env
  | _ -> restart_no_binders env
  (* In a position of cast *)

let binder_status_fun = {
  no = (fun x -> x);
  restart_prod = on_snd restart_prod_binders;
  restart_lambda = on_snd restart_lambda_binders;
  switch_prod = on_snd switch_prod_binders;
  switch_lambda = on_snd switch_lambda_binders;
  slide = on_snd slide_binders;
}

(* [test_kind_strict] rules out pattern which refers to global other
   than constructors or variables; It is used in instances of notations *)

let test_kind_pattern_in_notation ?loc = function
  | GlobRef.ConstructRef _ -> ()
    (* We do not accept non constructors to be used as variables in
       patterns *)
  | GlobRef.ConstRef _ ->
    user_err ?loc (str "Found a constant while a pattern was expected.")
  | GlobRef.IndRef _ ->
    user_err ?loc (str "Found an inductive type while a pattern was expected.")
  | GlobRef.VarRef _ ->
    (* we accept a section variable name to be used as pattern variable *)
    raise Not_found

let test_kind_ident_in_notation ?loc = function
  | GlobRef.ConstructRef _ ->
    user_err ?loc (str "Found a constructor while a variable name was expected.")
  | GlobRef.ConstRef _ ->
    user_err ?loc (str "Found a constant while a variable name was expected.")
  | GlobRef.IndRef _ ->
    user_err ?loc (str "Found an inductive type while a variable name was expected.")
  | GlobRef.VarRef _ ->
    (* we accept a section variable name to be used as pattern variable *)
    raise Not_found

(* [test_kind_tolerant] allow global reference names to be used as pattern variables *)

let test_kind_tolerant ?loc = function
  | GlobRef.ConstructRef _ -> ()
  | GlobRef.ConstRef _ | GlobRef.IndRef _ | GlobRef.VarRef _ ->
    (* A non-constructor global reference in a pattern is seen as a variable *)
    raise Not_found

(**)

let locate_if_hole ?loc na c = match DAst.get c with
  | GHole (_,naming,arg) ->
      (try match na with
        | Name id -> glob_constr_of_notation_constr ?loc
                       (Reserve.find_reserved_type id)
        | Anonymous -> raise Not_found
      with Not_found -> DAst.make ?loc @@ GHole (Evar_kinds.BinderType na, naming, arg))
  | _ -> c

let pure_push_name_env (id,implargs) env =
  {env with
    ids = Id.Set.add id env.ids;
    impls = Id.Map.add id implargs env.impls;
    binder_block_names = Option.map (fun (b,ids) -> (b,Id.Set.add id ids)) env.binder_block_names;
  }

let push_name_env ntnvars implargs env =
  let open CAst in
  function
  | { loc; v = Anonymous } ->
      env
  | { loc; v = Name id } ->
      if Id.Map.is_empty ntnvars && Id.equal id ldots_var
        then error_ldots_var ?loc;
      set_var_scope ?loc id false (env.tmp_scope,env.scopes) ntnvars;
      let uid = var_uid id in
      Dumpglob.dump_binding ?loc uid;
      pure_push_name_env (id,(Variable,implargs,[],uid)) env

let remember_binders_impargs env bl =
  List.map_filter (fun (na,_,_,_) ->
      match na with
      | Anonymous -> None
      | Name id -> Some (id,Id.Map.find id env.impls)) bl

let restore_binders_impargs env l =
  List.fold_right pure_push_name_env l env

let warn_ignoring_unexpected_implicit_binder_declaration =
  CWarnings.create ~name:"unexpected-implicit-declaration" ~category:"syntax"
    Pp.(fun () -> str "Ignoring implicit binder declaration in unexpected position.")

let check_implicit_meaningful ?loc k env =
  if k <> Explicit && env.binder_block_names = None then
    (warn_ignoring_unexpected_implicit_binder_declaration ?loc (); Explicit)
  else
    k

let intern_generalized_binder intern_type ntnvars
    env {loc;v=na} b' t ty =
  let ids = (match na with Anonymous -> fun x -> x | Name na -> Id.Set.add na) env.ids in
  let ty, ids' =
    if t then ty, ids
    else Implicit_quantifiers.implicit_application ids ty
  in
  let ty' = intern_type {env with ids = ids; unb = true} ty in
  let fvs = Implicit_quantifiers.generalizable_vars_of_glob_constr ~bound:ids ~allowed:ids' ty' in
  let env' = List.fold_left
    (fun env {loc;v=x} -> push_name_env ntnvars [](*?*) env (make ?loc @@ Name x))
    env fvs in
  let b' = check_implicit_meaningful ?loc b' env in
  let bl = List.map
    CAst.(map (fun id ->
      (Name id, MaxImplicit, DAst.make ?loc @@ GHole (Evar_kinds.BinderType (Name id), IntroAnonymous, None))))
    fvs
  in
  let na = match na with
    | Anonymous ->
      let id =
        match ty with
        | { v = CApp ((_, { v = CRef (qid,_) } ), _) } when qualid_is_ident qid ->
          qualid_basename qid
        | _ -> default_non_dependent_ident
      in
      let ids' = List.fold_left (fun ids' lid -> Id.Set.add lid.CAst.v ids') ids' fvs in
      let id =
        Implicit_quantifiers.make_fresh ids' (Global.env ()) id
      in
      Name id
    | _ -> na
  in
  let impls = impls_type_list 1 ty' in
  (push_name_env ntnvars impls env' (make ?loc na),
   (make ?loc (na,b',ty')) :: List.rev bl)

let intern_assumption intern ntnvars env nal bk ty =
  let intern_type env = intern (restart_prod_binders (set_type_scope env)) in
  match bk with
  | Default k ->
      let ty = intern_type env ty in
      check_capture ty nal;
      let impls = impls_type_list 1 ty in
      List.fold_left
        (fun (env, bl) ({loc;v=na} as locna) ->
          let k = check_implicit_meaningful ?loc k env in
          (push_name_env ntnvars impls env locna,
           (make ?loc (na,k,locate_if_hole ?loc na ty))::bl))
        (env, []) nal
  | Generalized (b',t) ->
     let env, b = intern_generalized_binder intern_type ntnvars env (List.hd nal) b' t ty in
     env, b

let glob_local_binder_of_extended = DAst.with_loc_val (fun ?loc -> function
  | GLocalAssum (na,bk,t) -> (na,bk,None,t)
  | GLocalDef (na,bk,c,Some t) -> (na,bk,Some c,t)
  | GLocalDef (na,bk,c,None) ->
      let t = DAst.make ?loc @@ GHole(Evar_kinds.BinderType na,IntroAnonymous,None) in
      (na,bk,Some c,t)
  | GLocalPattern (_,_,_,_) ->
      Loc.raise ?loc (Stream.Error "pattern with quote not allowed here")
  )

let intern_cases_pattern_fwd = ref (fun _ -> failwith "intern_cases_pattern_fwd")

let intern_letin_binder intern ntnvars env (({loc;v=na} as locna),def,ty) =
  let term = intern (reset_tmp_scope (restart_lambda_binders env)) def in
  let ty = Option.map (intern (set_type_scope (restart_prod_binders env))) ty in
  let impls = impls_term_list 1 term in
  (push_name_env ntnvars impls env locna,
   (na,Explicit,term,ty))

let intern_cases_pattern_as_binder ?loc test_kind ntnvars env p =
  let il,disjpat =
    let (il, subst_disjpat) = !intern_cases_pattern_fwd test_kind ntnvars (env_for_pattern (reset_tmp_scope env)) p in
    let substl,disjpat = List.split subst_disjpat in
    if not (List.for_all (fun subst -> Id.Map.equal Id.equal subst Id.Map.empty) substl) then
      user_err ?loc (str "Unsupported nested \"as\" clause.");
    il,disjpat
  in
  let env = List.fold_right (fun {loc;v=id} env -> push_name_env ntnvars [] env (make ?loc @@ Name id)) il env in
  let na = alias_of_pat (List.hd disjpat) in
  let ienv = Name.fold_right Id.Set.remove na env.ids in
  let id = Namegen.next_name_away_with_default "pat" na ienv in
  let na = make ?loc @@ Name id in
  env,((disjpat,il),id),na

let intern_local_binder_aux intern ntnvars (env,bl) = function
  | CLocalAssum(nal,bk,ty) ->
      let env, bl' = intern_assumption intern ntnvars env nal bk ty in
      let bl' = List.map (fun {loc;v=(na,c,t)} -> DAst.make ?loc @@ GLocalAssum (na,c,t)) bl' in
      env, bl' @ bl
  | CLocalDef( {loc; v=na} as locna,def,ty) ->
     let env,(na,bk,def,ty) = intern_letin_binder intern ntnvars env (locna,def,ty) in
     env, (DAst.make ?loc @@ GLocalDef (na,bk,def,ty)) :: bl
  | CLocalPattern {loc;v=(p,ty)} ->
      let tyc =
        match ty with
        | Some ty -> ty
        | None -> CAst.make ?loc @@ CHole(None,IntroAnonymous,None)
      in
      let env, ((disjpat,il),id),na = intern_cases_pattern_as_binder ?loc test_kind_tolerant ntnvars env p in
      let bk = Default Explicit in
      let _, bl' = intern_assumption intern ntnvars env [na] bk tyc in
      let {v=(_,bk,t)} = List.hd bl' in
      (env, (DAst.make ?loc @@ GLocalPattern((disjpat,List.map (fun x -> x.v) il),id,bk,t)) :: bl)

let intern_generalization intern env ntnvars loc bk ak c =
  let c = intern {env with unb = true} c in
  let fvs = Implicit_quantifiers.generalizable_vars_of_glob_constr ~bound:env.ids c in
  let env', c' =
    let abs =
      let pi = match ak with
        | Some AbsPi -> true
        | Some _ -> false
        | None ->
          match Notation.current_type_scope_name () with
          | Some type_scope ->
              let is_type_scope = match env.tmp_scope with
              | None -> false
              | Some sc -> String.equal sc type_scope
              in
              is_type_scope ||
              String.List.mem type_scope env.scopes
          | None -> false
      in
        if pi then
          (fun {loc=loc';v=id} acc ->
            DAst.make ?loc:(Loc.merge_opt loc' loc) @@
            GProd (Name id, bk, DAst.make ?loc:loc' @@ GHole (Evar_kinds.BinderType (Name id), IntroAnonymous, None), acc))
        else
          (fun {loc=loc';v=id} acc ->
            DAst.make ?loc:(Loc.merge_opt loc' loc) @@
            GLambda (Name id, bk, DAst.make ?loc:loc' @@ GHole (Evar_kinds.BinderType (Name id), IntroAnonymous, None), acc))
    in
      List.fold_right (fun ({loc;v=id} as lid) (env, acc) ->
        let env' = push_name_env ntnvars [] env CAst.(make @@ Name id) in
          (env', abs lid acc)) fvs (env,c)
  in c'

let rec expand_binders ?loc mk bl c =
  match bl with
  | [] -> c
  | b :: bl ->
     match DAst.get b with
     | GLocalDef (n, bk, b, oty) ->
        expand_binders ?loc mk bl (DAst.make ?loc @@ GLetIn (n, b, oty, c))
     | GLocalAssum (n, bk, t) ->
        expand_binders ?loc mk bl (mk ?loc (n,bk,t) c)
     | GLocalPattern ((disjpat,ids), id, bk, ty) ->
        let tm = DAst.make ?loc (GVar id) in
        (* Distribute the disjunctive patterns over the shared right-hand side *)
        let eqnl = List.map (fun pat -> CAst.make ?loc (ids,[pat],c)) disjpat in
        let c = DAst.make ?loc @@ GCases (LetPatternStyle, None, [tm,(Anonymous,None)], eqnl) in
        expand_binders ?loc mk bl (mk ?loc (Name id,Explicit,ty) c)

(**********************************************************************)
(* Syntax extensions                                                  *)

let check_not_notation_variable f ntnvars =
  (* Check bug #4690 *)
  match DAst.get f with
  | GVar id when Id.Map.mem id ntnvars ->
    user_err (str "Prefix @ is not applicable to notation variables.")
  | _ ->
     ()

let option_mem_assoc id = function
  | Some (id',c) -> Id.equal id id'
  | None -> false

let find_fresh_name renaming (terms,termlists,binders,binderlists) avoid id =
  let fold1 _ (c, _) accu = Id.Set.union (free_vars_of_constr_expr c) accu in
  let fold2 _ (l, _) accu =
    let fold accu c = Id.Set.union (free_vars_of_constr_expr c) accu in
    List.fold_left fold accu l
  in
  let fold3 _ x accu = Id.Set.add x accu in
  let fvs1 = Id.Map.fold fold1 terms avoid in
  let fvs2 = Id.Map.fold fold2 termlists fvs1 in
  let fvs3 = Id.Map.fold fold3 renaming fvs2 in
  (* TODO binders *)
  next_ident_away_from id (fun id -> Id.Set.mem id fvs3)

let is_patvar c =
  match DAst.get c with
  | PatVar _ -> true
  | _ -> false

let is_patvar_store store pat =
  match DAst.get pat with
  | PatVar na -> ignore(store na); true
  | _ -> false

let out_patvar = CAst.map_with_loc (fun ?loc -> function
  | CPatAtom (Some qid) when qualid_is_ident qid ->
    Name (qualid_basename qid)
  | CPatAtom None -> Anonymous
  | _ -> assert false)

let traverse_binder intern_pat ntnvars (terms,_,binders,_ as subst) avoid (renaming,env) = function
 | Anonymous -> (renaming,env), None, Anonymous
 | Name id ->
  let store,get = set_temporary_memory () in
  let test_kind = test_kind_tolerant in
  try
    (* We instantiate binder name with patterns which may be parsed as terms *)
    let pat = coerce_to_cases_pattern_expr (fst (Id.Map.find id terms)) in
    let env,((disjpat,ids),id),na = intern_pat test_kind ntnvars env pat in
    let pat, na = match disjpat with
    | [pat] when is_patvar_store store pat -> let na = get () in None, na
    | _ -> Some ((List.map (fun x -> x.v) ids,disjpat),id), na.v in
    (renaming,env), pat, na
  with Not_found ->
  try
    (* Trying to associate a pattern *)
    let pat,(onlyident,scopes) = Id.Map.find id binders in
    let env = set_env_scopes env scopes in
    if onlyident then
      (* Do not try to interpret a variable as a constructor *)
      let na = out_patvar pat in
      let env = push_name_env ntnvars [] env na in
      (renaming,env), None, na.v
    else
      (* Interpret as a pattern *)
      let env,((disjpat,ids),id),na = intern_pat test_kind ntnvars env pat in
      let pat, na =
        match disjpat with
        | [pat] when is_patvar_store store pat -> let na = get () in None, na
        | _ -> Some ((List.map (fun x -> x.v) ids,disjpat),id), na.v in
      (renaming,env), pat, na
  with Not_found ->
    (* Binders not bound in the notation do not capture variables *)
    (* outside the notation (i.e. in the substitution) *)
    let id' = find_fresh_name renaming subst avoid id in
    let renaming' =
      if Id.equal id id' then renaming else Id.Map.add id id' renaming
    in
    (renaming',env), None, Name id'

type binder_action =
| AddLetIn of lname * constr_expr * constr_expr option
| AddTermIter of (constr_expr * subscopes) Names.Id.Map.t
| AddPreBinderIter of Id.t * local_binder_expr (* A binder to be internalized *)
| AddBinderIter of Id.t * extended_glob_local_binder (* A binder already internalized - used for generalized binders *)

let dmap_with_loc f n =
  CAst.map_with_loc (fun ?loc c -> f ?loc (DAst.get_thunk c)) n

let error_cannot_coerce_wildcard_term ?loc () =
  user_err ?loc Pp.(str "Cannot turn \"_\" into a term.")

let error_cannot_coerce_disjunctive_pattern_term ?loc () =
  user_err ?loc Pp.(str "Cannot turn a disjunctive pattern into a term.")

let terms_of_binders bl =
  let rec term_of_pat pt = dmap_with_loc (fun ?loc -> function
    | PatVar (Name id)   -> CRef (qualid_of_ident id, None)
    | PatVar (Anonymous) -> error_cannot_coerce_wildcard_term ?loc ()
    | PatCstr (c,l,_) ->
       let qid = qualid_of_path ?loc (Nametab.path_of_global (GlobRef.ConstructRef c)) in
       let hole = CAst.make ?loc @@ CHole (None,IntroAnonymous,None) in
       let params = List.make (Inductiveops.inductive_nparams (Global.env()) (fst c)) hole in
       CAppExpl ((None,qid,None),params @ List.map term_of_pat l)) pt in
  let rec extract_variables l = match l with
    | bnd :: l ->
      let loc = bnd.loc in
      begin match DAst.get bnd with
      | GLocalAssum (Name id,_,_) -> (CAst.make ?loc @@ CRef (qualid_of_ident ?loc id, None)) :: extract_variables l
      | GLocalDef (Name id,_,_,_) -> extract_variables l
      | GLocalDef (Anonymous,_,_,_)
      | GLocalAssum (Anonymous,_,_) -> user_err Pp.(str "Cannot turn \"_\" into a term.")
      | GLocalPattern (([u],_),_,_,_) -> term_of_pat u :: extract_variables l
      | GLocalPattern ((_,_),_,_,_) -> error_cannot_coerce_disjunctive_pattern_term ?loc ()
      end
    | [] -> [] in
  extract_variables bl

let flatten_generalized_binders_if_any y l =
  match List.rev l with
  | [] -> assert false
  | a::l -> a, List.map (fun a -> AddBinderIter (y,a)) l (* if l not empty, this means we had a generalized binder *)

let flatten_binders bl =
  let dispatch = function
    | CLocalAssum (nal,bk,t) -> List.map (fun na -> CLocalAssum ([na],bk,t)) nal
    | a -> [a] in
  List.flatten (List.map dispatch bl)

let rec adjust_env env = function
  (* We need to adjust scopes, binder blocks ... to the env expected
     at the recursive occurrence; We do an underapproximation... *)
  | NProd (_,_,c) -> adjust_env (switch_prod_binders env) c
  | NLambda (_,_,c) -> adjust_env (switch_lambda_binders env) c
  | NLetIn (_,_,_,c) -> adjust_env env c
  | NVar id when Id.equal id ldots_var -> env
  | NCast (c,_) -> adjust_env env c
  | NApp _ -> restart_no_binders env
  | NVar _ | NRef _ | NHole _ | NCases _ | NLetTuple _ | NIf _
  | NRec _ | NSort _ | NInt _ | NFloat _ | NArray _
  | NList _ | NBinderList _ -> env (* to be safe, but restart should be ok *)

let instantiate_notation_constr loc intern intern_pat ntnvars subst infos c =
  let (terms,termlists,binders,binderlists) = subst in
  (* when called while defining a notation, avoid capturing the private binders
     of the expression by variables bound by the notation (see #3892) *)
  let avoid = Id.Map.domain ntnvars in
  let rec aux (terms,binderopt,iteropt as subst') (renaming,env) c =
    let subinfos = renaming,{env with tmp_scope = None} in
    match c with
    | NVar id when Id.equal id ldots_var ->
        let rec aux_letin env = function
        | [],terminator,_ -> aux (terms,None,None) (renaming,env) terminator
        | AddPreBinderIter (y,binder)::rest,terminator,iter ->
           let env,binders = intern_local_binder_aux intern ntnvars (adjust_env env iter,[]) binder in
           let binder,extra = flatten_generalized_binders_if_any y binders in
           aux (terms,Some (y,binder),Some (extra@rest,terminator,iter)) (renaming,env) iter
        | AddBinderIter (y,binder)::rest,terminator,iter ->
           aux (terms,Some (y,binder),Some (rest,terminator,iter)) (renaming,env) iter
        | AddTermIter nterms::rest,terminator,iter ->
           aux (nterms,None,Some (rest,terminator,iter)) (renaming,env) iter
        | AddLetIn (na,c,t)::rest,terminator,iter ->
           let env,(na,_,c,t) = intern_letin_binder intern ntnvars (adjust_env env iter) (na,c,t) in
           DAst.make ?loc (GLetIn (na,c,t,aux_letin env (rest,terminator,iter))) in
        aux_letin env (Option.get iteropt)
    | NVar id -> subst_var subst' (renaming, env) id
    | NList (x,y,iter,terminator,revert) ->
      let l,(scopt,subscopes) =
        (* All elements of the list are in scopes (scopt,subscopes) *)
        try
          let l,scopes = Id.Map.find x termlists in
          (if revert then List.rev l else l),scopes
        with Not_found ->
        try
          let (bl,(scopt,subscopes)) = Id.Map.find x binderlists in
          let env,bl' = List.fold_left (intern_local_binder_aux intern ntnvars) (env,[]) bl in
          terms_of_binders (if revert then bl' else List.rev bl'),(None,[])
        with Not_found ->
          anomaly (Pp.str "Inconsistent substitution of recursive notation.") in
      let l = List.map (fun a -> AddTermIter ((Id.Map.add y (a,(scopt,subscopes)) terms))) l in
      aux (terms,None,Some (l,terminator,iter)) subinfos (NVar ldots_var)
    | NHole (knd, naming, arg) ->
      let knd = match knd with
      | Evar_kinds.BinderType (Name id as na) ->
        let na =
          try (coerce_to_name (fst (Id.Map.find id terms))).v
          with Not_found ->
          try Name (Id.Map.find id renaming)
          with Not_found -> na
        in
        Evar_kinds.BinderType na
      | _ -> knd
      in
      let arg = match arg with
      | None -> None
      | Some arg ->
        let mk_env id (c, scopes) map =
          let nenv = set_env_scopes env scopes in
          try
            let gc = intern nenv c in
            Id.Map.add id (gc, None) map
          with Nametab.GlobalizationError _ -> map
        in
        let mk_env' (c, (onlyident,scopes)) =
          let nenv = set_env_scopes env scopes in
          let test_kind =
            if onlyident then test_kind_ident_in_notation
            else test_kind_pattern_in_notation in
          let _,((disjpat,_),_),_ = intern_pat test_kind ntnvars nenv c in
          match disjpat with
          | [pat] -> (glob_constr_of_cases_pattern (Global.env()) pat, None)
          | _ -> error_cannot_coerce_disjunctive_pattern_term ?loc:c.loc ()
        in
        let terms = Id.Map.fold mk_env terms Id.Map.empty in
        let binders = Id.Map.map mk_env' binders in
        let bindings = Id.Map.fold Id.Map.add terms binders in
        Some (Genintern.generic_substitute_notation bindings arg)
      in
      DAst.make ?loc @@ GHole (knd, naming, arg)
    | NBinderList (x,y,iter,terminator,revert) ->
      (try
        (* All elements of the list are in scopes (scopt,subscopes) *)
        let (bl,(scopt,subscopes)) = Id.Map.find x binderlists in
        (* We flatten binders so that we can interpret them at substitution time *)
        let bl = flatten_binders bl in
        let bl = if revert then List.rev bl else bl in
        (* We isolate let-ins which do not contribute to the repeated pattern *)
        let l = List.map (function | CLocalDef (na,c,t) -> AddLetIn (na,c,t)
                                   | binder -> AddPreBinderIter (y,binder)) bl in
        (* We stack the binders to iterate or let-ins to insert *)
        aux (terms,None,Some (l,terminator,iter)) subinfos (NVar ldots_var)
      with Not_found ->
          anomaly (Pp.str "Inconsistent substitution of recursive notation."))
    | NProd (Name id, NHole _, c') when option_mem_assoc id binderopt ->
        let binder = snd (Option.get binderopt) in
        expand_binders ?loc mkGProd [binder] (aux subst' (renaming,env) c')
    | NLambda (Name id,NHole _,c') when option_mem_assoc id binderopt ->
        let binder = snd (Option.get binderopt) in
        expand_binders ?loc mkGLambda [binder] (aux subst' (renaming,env) c')
    (* Two special cases to keep binder name synchronous with BinderType *)
    | NProd (na,NHole(Evar_kinds.BinderType na',naming,arg),c')
        when Name.equal na na' ->
        let subinfos,disjpat,na = traverse_binder intern_pat ntnvars subst avoid subinfos na in
        let ty = DAst.make ?loc @@ GHole (Evar_kinds.BinderType na,naming,arg) in
        DAst.make ?loc @@ GProd (na,Explicit,ty,Option.fold_right apply_cases_pattern disjpat (aux subst' subinfos c'))
    | NLambda (na,NHole(Evar_kinds.BinderType na',naming,arg),c')
        when Name.equal na na' ->
        let subinfos,disjpat,na = traverse_binder intern_pat ntnvars subst  avoid subinfos na in
        let ty = DAst.make ?loc @@ GHole (Evar_kinds.BinderType na,naming,arg) in
        DAst.make ?loc @@ GLambda (na,Explicit,ty,Option.fold_right apply_cases_pattern disjpat (aux subst' subinfos c'))
    | t ->
      glob_constr_of_notation_constr_with_binders ?loc
        (traverse_binder intern_pat ntnvars subst  avoid) (aux subst') ~h:binder_status_fun subinfos t
  and subst_var (terms, binderopt, _terminopt) (renaming, env) id =
    (* subst remembers the delimiters stack in the interpretation *)
    (* of the notations *)
    try
      let (a,scopes) = Id.Map.find id terms in
      intern (set_env_scopes env scopes) a
    with Not_found ->
    try
      let pat,(onlyident,scopes) = Id.Map.find id binders in
      let nenv = set_env_scopes env scopes in
      let test_kind =
        if onlyident then test_kind_ident_in_notation
        else test_kind_pattern_in_notation in
      let env,((disjpat,ids),id),na = intern_pat test_kind ntnvars nenv pat in
      match disjpat with
      | [pat] -> glob_constr_of_cases_pattern (Global.env()) pat
      | _ -> user_err Pp.(str "Cannot turn a disjunctive pattern into a term.")
    with Not_found ->
    try
      match binderopt with
      | Some (x,binder) when Id.equal x id ->
         let terms = terms_of_binders [binder] in
         assert (List.length terms = 1);
         intern env (List.hd terms)
      | _ -> raise Not_found
    with Not_found ->
    DAst.make ?loc (
    try
      GVar (Id.Map.find id renaming)
    with Not_found ->
      (* Happens for local notation joint with inductive/fixpoint defs *)
      GVar id)
  in aux (terms,None,None) infos c

(* Turning substitution coming from parsing and based on production
   into a substitution for interpretation and based on binding/constr
   distinction *)

let cases_pattern_of_name {loc;v=na} =
  let atom = match na with Name id -> Some (qualid_of_ident ?loc id) | Anonymous -> None in
  CAst.make ?loc (CPatAtom atom)

let split_by_type ids subst =
  let bind id scl l s =
    match l with
    | [] -> assert false
    | a::l -> l, Id.Map.add id (a,scl) s in
  let (terms,termlists,binders,binderlists),subst =
    List.fold_left (fun ((terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists')) (id,((_,scl),typ)) ->
    match typ with
    | NtnTypeConstr ->
       let terms,terms' = bind id scl terms terms' in
       (terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists')
    | NtnTypeBinder NtnBinderParsedAsConstr (AsIdentOrPattern | AsStrictPattern) ->
       let a,terms = match terms with a::terms -> a,terms | _ -> assert false in
       let binders' = Id.Map.add id (coerce_to_cases_pattern_expr a,(false,scl)) binders' in
       (terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists')
    | NtnTypeBinder NtnBinderParsedAsConstr AsIdent ->
       let a,terms = match terms with a::terms -> a,terms | _ -> assert false in
       let binders' = Id.Map.add id (cases_pattern_of_name (coerce_to_name a),(true,scl)) binders' in
       (terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists')
    | NtnTypeBinder (NtnParsedAsIdent | NtnParsedAsPattern _ as x) ->
       let onlyident = (x = NtnParsedAsIdent) in
       let binders,binders' = bind id (onlyident,scl) binders binders' in
       (terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists')
    | NtnTypeConstrList ->
       let termlists,termlists' = bind id scl termlists termlists' in
       (terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists')
    | NtnTypeBinderList ->
       let binderlists,binderlists' = bind id scl binderlists binderlists' in
       (terms,termlists,binders,binderlists),(terms',termlists',binders',binderlists'))
                   (subst,(Id.Map.empty,Id.Map.empty,Id.Map.empty,Id.Map.empty)) ids in
  assert (terms = [] && termlists = [] && binders = [] && binderlists = []);
  subst

let split_by_type_pat ?loc ids subst =
  let bind id (_,scopes) l s =
    match l with
    | [] -> assert false
    | a::l -> l, Id.Map.add id (a,scopes) s in
  let (terms,termlists),subst =
    List.fold_left (fun ((terms,termlists),(terms',termlists')) (id,(scl,typ)) ->
    match typ with
    | NtnTypeConstr | NtnTypeBinder _ ->
       let terms,terms' = bind id scl terms terms' in
       (terms,termlists),(terms',termlists')
    | NtnTypeConstrList ->
       let termlists,termlists' = bind id scl termlists termlists' in
       (terms,termlists),(terms',termlists')
    | NtnTypeBinderList -> error_invalid_pattern_notation ?loc ())
                   (subst,(Id.Map.empty,Id.Map.empty)) ids in
  assert (terms = [] && termlists = []);
  subst

let intern_notation intern env ntnvars loc ntn fullargs =
  (* Adjust to parsing of { } *)
  let ntn,fullargs = contract_curly_brackets ntn fullargs in
  (* Recover interpretation { } *)
  let ((ids,c),df) = interp_notation ?loc ntn (env.tmp_scope,env.scopes) in
  Dumpglob.dump_notation_location (ntn_loc ?loc fullargs ntn) ntn df;
  (* Dispatch parsing substitution to an interpretation substitution *)
  let subst = split_by_type ids fullargs in
  (* Instantiate the notation *)
  instantiate_notation_constr loc intern intern_cases_pattern_as_binder ntnvars subst (Id.Map.empty, env) c

(**********************************************************************)
(* Discriminating between bound variables and global references       *)

let string_of_ty = function
  | Inductive -> "ind"
  | Recursive -> "def"
  | Method -> "meth"
  | Variable -> "var"

let gvar (loc, id) us = match us with
| None | Some [] -> DAst.make ?loc @@ GVar id
| Some _ ->
  user_err ?loc  (str "Variable " ++ Id.print id ++
    str " cannot have a universe instance")

let intern_var env (ltacvars,ntnvars) namedctx loc id us =
  (* Is [id] a notation variable *)
  if Id.Map.mem id ntnvars then
    begin
      if not (Id.Map.mem id env.impls) then set_var_scope ?loc id true (env.tmp_scope,env.scopes) ntnvars;
      gvar (loc,id) us, [], []
    end
  else
  (* Is [id] registered with implicit arguments *)
  try
    let ty,impls,argsc,uid = Id.Map.find id env.impls in
    let tys = string_of_ty ty in
    Dumpglob.dump_reference ?loc "<>" uid tys;
    gvar (loc,id) us, make_implicits_list impls, argsc
  with Not_found ->
  (* Is [id] bound in current term or is an ltac var bound to constr *)
  if Id.Set.mem id env.ids || Id.Set.mem id ltacvars.ltac_vars
  then
    gvar (loc,id) us, [], []
  else if Id.equal id ldots_var
  (* Is [id] the special variable for recursive notations? *)
  then if Id.Map.is_empty ntnvars
    then error_ldots_var ?loc
    else gvar (loc,id) us, [], []
  else if Id.Set.mem id ltacvars.ltac_bound then
    (* Is [id] bound to a free name in ltac (this is an ltac error message) *)
    user_err ?loc ~hdr:"intern_var"
     (str "variable " ++ Id.print id ++ str " should be bound to a term.")
  else
    (* Is [id] a goal or section variable *)
    let _ = Environ.lookup_named_ctxt id namedctx in
      try
        (* [id] a section variable *)
        (* Redundant: could be done in intern_qualid *)
        let ref = GlobRef.VarRef id in
        let impls = implicits_of_global ref in
        let scopes = find_arguments_scope ref in
        Dumpglob.dump_secvar ?loc id; (* this raises Not_found when not a section variable *)
        (* Someday we should stop relying on Dumglob raising exceptions *)
        DAst.make ?loc @@ GRef (ref, us), impls, scopes
      with e when CErrors.noncritical e ->
        (* [id] a goal variable *)
        gvar (loc,id) us, [], []

let find_appl_head_data c =
  match DAst.get c with
  | GRef (ref,_) ->
    let impls = implicits_of_global ref in
    let scopes = find_arguments_scope ref in
      c, impls, scopes
  | GApp (r, l) ->
    begin match DAst.get r with
    | GRef (ref,_) ->
      let n = List.length l in
      let impls = implicits_of_global ref in
      let scopes = find_arguments_scope ref in
        c, (if n = 0 then [] else List.map (drop_first_implicits n) impls),
        List.skipn_at_least n scopes
    | _ -> c,[],[]
    end
  | _ -> c,[],[]

let error_not_enough_arguments ?loc =
  user_err ?loc  (str "Abbreviation is not applied enough.")

let check_no_explicitation l =
  let is_unset (a, b) = match b with None -> false | Some _ -> true in
  let l = List.filter is_unset l in
  match l with
  | [] -> ()
  | (_, None) :: _ -> assert false
  | (_, Some {loc}) :: _ ->
    user_err ?loc  (str"Unexpected explicitation of the argument of an abbreviation.")

let dump_extended_global loc = function
  | TrueGlobal ref -> (*feedback_global loc ref;*) Dumpglob.add_glob ?loc ref
  | SynDef sp -> Dumpglob.add_glob_kn ?loc sp

let intern_extended_global_of_qualid qid =
  let r = Nametab.locate_extended qid in dump_extended_global qid.CAst.loc r; r

let intern_reference qid =
  let r =
    try intern_extended_global_of_qualid qid
    with Not_found as exn ->
      let _, info = Exninfo.capture exn in
      Nametab.error_global_not_found ~info qid
  in
  Smartlocate.global_of_extended_global r

let glob_sort_of_level (level: glob_level) : glob_sort =
  match level with
  | UAnonymous {rigid} -> UAnonymous {rigid}
  | UNamed id -> UNamed [id,0]

(* Is it a global reference or a syntactic definition? *)
let intern_qualid ?(no_secvar=false) qid intern env ntnvars us args =
  let loc = qid.loc in
  match intern_extended_global_of_qualid qid with
  | TrueGlobal (GlobRef.VarRef _) when no_secvar ->
      (* Rule out section vars since these should have been found by intern_var *)
      raise Not_found
  | TrueGlobal ref -> (DAst.make ?loc @@ GRef (ref, us)), Some ref, args
  | SynDef sp ->
      let (ids,c) = Syntax_def.search_syntactic_definition ?loc sp in
      let nids = List.length ids in
      if List.length args < nids then error_not_enough_arguments ?loc;
      let args1,args2 = List.chop nids args in
      check_no_explicitation args1;
      let subst = split_by_type ids (List.map fst args1,[],[],[]) in
      let infos = (Id.Map.empty, env) in
      let c = instantiate_notation_constr loc intern intern_cases_pattern_as_binder ntnvars subst infos c in
      let loc = c.loc in
      let err () =
        user_err ?loc  (str "Notation " ++ pr_qualid qid
                  ++ str " cannot have a universe instance,"
                  ++ str " its expanded head does not start with a reference")
      in
      let c = match us, DAst.get c with
      | None, _ -> c
      | Some _, GRef (ref, None) -> DAst.make ?loc @@ GRef (ref, us)
      | Some _, GApp (r, arg) ->
        let loc' = r.CAst.loc in
        begin match DAst.get r with
        | GRef (ref, None) ->
          DAst.make ?loc @@ GApp (DAst.make ?loc:loc' @@ GRef (ref, us), arg)
        | _ -> err ()
        end
      | Some [s], GSort (UAnonymous {rigid=true}) -> DAst.make ?loc @@ GSort (glob_sort_of_level s)
      | Some [_old_level], GSort _new_sort ->
        (* TODO: add old_level and new_sort to the error message *)
        user_err ?loc (str "Cannot change universe level of notation " ++ pr_qualid qid)
      | Some _, _ -> err ()
      in
      c, None, args2

let warn_nonprimitive_projection =
  CWarnings.create ~name:"nonprimitive-projection-syntax" ~category:"syntax" ~default:CWarnings.Disabled
    Pp.(fun f -> pr_qualid f ++ str " used as a primitive projection but is not one.")

let error_nonprojection_syntax ?loc qid =
  CErrors.user_err ?loc ~hdr:"nonprojection-syntax" Pp.(pr_qualid qid ++ str" is not a projection.")

let check_applied_projection isproj realref qid =
  match isproj with
  | None -> ()
  | Some projargs ->
    let open GlobRef in
    let is_prim = match realref with
      | None | Some (IndRef _ | ConstructRef _ | VarRef _) -> false
      | Some (ConstRef c) ->
        if Recordops.is_primitive_projection c then true
        else if Recordops.is_projection c then false
        else error_nonprojection_syntax ?loc:qid.loc qid
        (* TODO check projargs, note we will need implicit argument info *)
    in
    if not is_prim then warn_nonprimitive_projection ?loc:qid.loc qid

let intern_applied_reference ~isproj intern env namedctx (_, ntnvars as lvar) us args qid =
  let loc = qid.CAst.loc in
  if qualid_is_ident qid then
      try
        let res = intern_var env lvar namedctx loc (qualid_basename qid) us in
        check_applied_projection isproj None qid;
        res, args
      with Not_found ->
      try
        let r, realref, args2 = intern_qualid ~no_secvar:true qid intern env ntnvars us args in
        check_applied_projection isproj realref qid;
        find_appl_head_data r, args2
      with Not_found as exn ->
        (* Extra allowance for non globalizing functions *)
        if !interning_grammar || env.unb then
          (* check_applied_projection ?? *)
          (gvar (loc,qualid_basename qid) us, [], []), args
        else
          let _, info = Exninfo.capture exn in
          Nametab.error_global_not_found ~info qid
  else
    let r,realref,args2 =
      try intern_qualid qid intern env ntnvars us args
      with Not_found as exn ->
        let _, info = Exninfo.capture exn in
        Nametab.error_global_not_found ~info qid
    in
    check_applied_projection isproj realref qid;
    find_appl_head_data r, args2

let interp_reference vars r =
  let (r,_,_),_ =
    intern_applied_reference ~isproj:None (fun _ -> error_not_enough_arguments ?loc:None)
      {ids = Id.Set.empty; unb = false ;
       tmp_scope = None; scopes = []; impls = empty_internalization_env;
       binder_block_names = None}
      Environ.empty_named_context_val
      (vars, Id.Map.empty) None [] r
  in r

(**********************************************************************)
(** {5 Cases }                                                        *)

(** Private internalization patterns *)
type 'a raw_cases_pattern_expr_r =
  | RCPatAlias of 'a raw_cases_pattern_expr * lname
  | RCPatCstr  of GlobRef.t
    * 'a raw_cases_pattern_expr list * 'a raw_cases_pattern_expr list
  (** [RCPatCstr (loc, c, l1, l2)] represents [((@ c l1) l2)] *)
  | RCPatAtom  of (lident * (Notation_term.tmp_scope_name option * Notation_term.scope_name list)) option
  | RCPatOr    of 'a raw_cases_pattern_expr list
and 'a raw_cases_pattern_expr = ('a raw_cases_pattern_expr_r, 'a) DAst.t

(** {6 Elementary bricks } *)
let apply_scope_env env = function
  | [] -> {env with tmp_scope = None}, []
  | sc::scl -> {env with tmp_scope = sc}, scl

let rec simple_adjust_scopes n scopes =
  (* Note: they can be less scopes than arguments but also more scopes *)
  (* than arguments because extra scopes are used in the presence of *)
  (* coercions to funclass *)
  if Int.equal n 0 then [] else match scopes with
  | [] -> None :: simple_adjust_scopes (n-1) []
  | sc::scopes -> sc :: simple_adjust_scopes (n-1) scopes

let find_remaining_scopes pl1 pl2 ref =
  let impls_st = implicits_of_global ref in
  let len_pl1 = List.length pl1 in
  let len_pl2 = List.length pl2 in
  let impl_list = if Int.equal len_pl1 0
    then select_impargs_size len_pl2 impls_st
    else List.skipn_at_least len_pl1 (select_stronger_impargs impls_st) in
  let allscs = find_arguments_scope ref in
  let scope_list = List.skipn_at_least len_pl1 allscs in
  let rec aux = function
    |[],l -> l
    |_,[] -> []
    |h::t,_::tt when is_status_implicit h -> aux (t,tt)
    |_::t,h::tt -> h :: aux (t,tt)
  in ((try List.firstn len_pl1 allscs with Failure _ -> simple_adjust_scopes len_pl1 allscs),
      simple_adjust_scopes len_pl2 (aux (impl_list,scope_list)))

(* @return the first variable that occurs twice in a pattern

naive n^2 algo *)
let rec has_duplicate = function
  | [] -> None
  | x::l -> if Id.List.mem x l then (Some x) else has_duplicate l

let loc_of_multiple_pattern pl =
 Loc.merge_opt (cases_pattern_expr_loc (List.hd pl)) (cases_pattern_expr_loc (List.last pl))

let loc_of_lhs lhs =
 Loc.merge_opt (loc_of_multiple_pattern (List.hd lhs)) (loc_of_multiple_pattern (List.last lhs))

let check_linearity lhs ids =
  match has_duplicate ids with
    | Some id ->
      let loc = loc_of_lhs lhs in
      Loc.raise ?loc (InternalizationError (NonLinearPattern id))
    | None ->
        ()

(* Match the number of pattern against the number of matched args *)
let check_number_of_pattern loc n l =
  let p = List.length l in
  if not (Int.equal n p) then
    Loc.raise ?loc (InternalizationError (BadPatternsNumber (n,p)))

let check_or_pat_variables loc ids idsl =
  let eq_id {v=id} {v=id'} = Id.equal id id' in
  (* Collect remaining patterns which do not have the same variables as the first pattern *)
  let idsl = List.filter (fun ids' -> not (List.eq_set eq_id ids ids')) idsl in
  match idsl with
  | ids'::_ ->
    (* Look for an [id] which is either in [ids] and not in [ids'] or in [ids'] and not in [ids] *)
    let ids'' = List.subtract eq_id ids ids' in
    let ids'' = if ids'' = [] then List.subtract eq_id ids' ids else ids'' in
    user_err ?loc
      (strbrk "The components of this disjunctive pattern must bind the same variables (" ++
       Id.print (List.hd ids'').v ++ strbrk " is not bound in all patterns).")
  | [] -> ()

(** Use only when params were NOT asked to the user.
    @return if letin are included *)
let check_constructor_length env loc cstr len_pl pl0 =
  let n = len_pl + List.length pl0 in
  if Int.equal n (Inductiveops.constructor_nallargs env cstr) then false else
    (Int.equal n (Inductiveops.constructor_nalldecls env cstr) ||
      (error_wrong_numarg_constructor ?loc env cstr
         (Inductiveops.constructor_nrealargs env cstr)))

open Declarations

(* Similar to Cases.adjust_local_defs but on RCPat *)
let insert_local_defs_in_pattern (ind,j) l =
  let (mib,mip) = Global.lookup_inductive ind in
  if mip.mind_consnrealdecls.(j-1) = mip.mind_consnrealargs.(j-1) then
    (* Optimisation *) l
  else
    let (ctx, _) = mip.mind_nf_lc.(j-1) in
    let decls = List.skipn (Context.Rel.length mib.mind_params_ctxt) (List.rev ctx) in
    let rec aux decls args =
      match decls, args with
      | Context.Rel.Declaration.LocalDef _ :: decls, args -> (DAst.make @@ RCPatAtom None) :: aux decls args
      | _, [] -> [] (* In particular, if there were trailing local defs, they have been inserted *)
      | Context.Rel.Declaration.LocalAssum _ :: decls, a :: args -> a :: aux decls args
      | _ -> assert false in
    aux decls l

let add_local_defs_and_check_length loc env g pl args =
  let open GlobRef in
  match g with
  | ConstructRef cstr ->
     (* We consider that no variables corresponding to local binders
        have been given in the "explicit" arguments, which come from a
        "@C args" notation or from a custom user notation *)
     let pl' = insert_local_defs_in_pattern cstr pl in
     let maxargs = Inductiveops.constructor_nalldecls env cstr in
     if List.length pl' + List.length args > maxargs then
       error_wrong_numarg_constructor ?loc env cstr (Inductiveops.constructor_nrealargs env cstr);
     (* Two possibilities: either the args are given with explicit
     variables for local definitions, then we give the explicit args
     extended with local defs, so that there is nothing more to be
     added later on; or the args are not enough to have all arguments,
     which a priori means local defs to add in the [args] part, so we
     postpone the insertion of local defs in the explicit args *)
     (* Note: further checks done later by check_constructor_length *)
     if List.length pl' + List.length args = maxargs then pl' else pl
  | _ -> pl

let add_implicits_check_length fail nargs nargs_with_letin impls_st len_pl1 pl2 =
  let impl_list = if Int.equal len_pl1 0
    then select_impargs_size (List.length pl2) impls_st
    else List.skipn_at_least len_pl1 (select_stronger_impargs impls_st) in
  let remaining_args = List.fold_left (fun i x -> if is_status_implicit x then i else succ i) in
  let rec aux i = function
    |[],l -> let args_len = List.length l + List.length impl_list + len_pl1 in
             ((if Int.equal args_len nargs then false
              else Int.equal args_len nargs_with_letin || (fst (fail (nargs - List.length impl_list + i))))
               ,l)
    |imp::q as il,[] -> if is_status_implicit imp && maximal_insertion_of imp
      then let (b,out) = aux i (q,[]) in (b,(DAst.make @@ RCPatAtom None)::out)
      else fail (remaining_args (len_pl1+i) il)
    |imp::q,(hh::tt as l) -> if is_status_implicit imp
      then let (b,out) = aux i (q,l) in (b,(DAst.make @@ RCPatAtom None)::out)
      else let (b,out) = aux (succ i) (q,tt) in (b,hh::out)
  in aux 0 (impl_list,pl2)

let add_implicits_check_constructor_length env loc c len_pl1 pl2 =
  let nargs = Inductiveops.constructor_nallargs env c in
  let nargs' = Inductiveops.constructor_nalldecls env c in
  let impls_st = implicits_of_global (GlobRef.ConstructRef c) in
  add_implicits_check_length (error_wrong_numarg_constructor ?loc env c)
    nargs nargs' impls_st len_pl1 pl2

let add_implicits_check_ind_length env loc c len_pl1 pl2 =
  let nallargs = inductive_nallargs env c in
  let nalldecls = inductive_nalldecls env c in
  let impls_st = implicits_of_global (GlobRef.IndRef c) in
  add_implicits_check_length (error_wrong_numarg_inductive ?loc env c)
    nallargs nalldecls impls_st len_pl1 pl2

(** Do not raise NotEnoughArguments thanks to preconditions*)
let chop_params_pattern loc ind args with_letin =
  let nparams = if with_letin
    then Inductiveops.inductive_nparamdecls (Global.env()) ind
    else Inductiveops.inductive_nparams (Global.env()) ind in
  assert (nparams <= List.length args);
  let params,args = List.chop nparams args in
  List.iter (fun c -> match DAst.get c with
    | PatVar Anonymous -> ()
    | PatVar _ | PatCstr(_,_,_) -> error_parameter_not_implicit ?loc:c.CAst.loc) params;
  args

let find_constructor loc add_params ref =
  let open GlobRef in
  let (ind,_ as cstr) = match ref with
  | ConstructRef cstr -> cstr
  | IndRef _ ->
    let error = str "There is an inductive name deep in a \"in\" clause." in
    user_err ?loc ~hdr:"find_constructor" error
  | ConstRef _ | VarRef _ ->
    let error = str "This reference is not a constructor." in
    user_err ?loc ~hdr:"find_constructor" error
  in
  cstr, match add_params with
    | Some nb_args ->
      let env = Global.env () in
      let nb =
        if Int.equal nb_args (Inductiveops.constructor_nrealdecls env cstr)
        then Inductiveops.inductive_nparamdecls env ind
        else Inductiveops.inductive_nparams env ind
      in
      List.make nb ([], [(Id.Map.empty, DAst.make @@ PatVar Anonymous)])
    | None -> []

let find_pattern_variable qid =
  if qualid_is_ident qid then qualid_basename qid
  else Loc.raise ?loc:qid.CAst.loc (InternalizationError(NotAConstructor qid))

let check_duplicate ?loc fields =
  let eq (ref1, _) (ref2, _) = qualid_eq ref1 ref2 in
  let dups = List.duplicates eq fields in
  match dups with
  | [] -> ()
  | (r, _) :: _ ->
    user_err ?loc (str "This record defines several times the field " ++
      pr_qualid r ++ str ".")

let inductive_of_record loc record =
  let inductive = GlobRef.IndRef (inductive_of_constructor record.Recordops.s_CONST) in
  Nametab.shortest_qualid_of_global ?loc Id.Set.empty inductive

(** [sort_fields ~complete loc fields completer] expects a list
    [fields] of field assignments [f = e1; g = e2; ...], where [f, g]
    are fields of a record and [e1] are "values" (either terms, when
    interning a record construction, or patterns, when intering record
    pattern-matching). It will sort the fields according to the record
    declaration order (which is important when type-checking them in
    presence of dependencies between fields). If the parameter
    [complete] is true, we require the assignment to be complete: all
    the fields of the record must be present in the
    assignment. Otherwise the record assignment may be partial
    (in a pattern, we may match on some fields only), and we call the
    function [completer] to fill the missing fields; the returned
    field assignment list is always complete. *)
let sort_fields ~complete loc fields completer =
  match fields with
    | [] -> None
    | (first_field_ref, _):: _ ->
        let (first_field_glob_ref, record) =
          try
            let gr = locate_reference first_field_ref in
            Dumpglob.add_glob ?loc:first_field_ref.CAst.loc gr;
            (gr, Recordops.find_projection gr)
          with Not_found as exn ->
            let _, info = Exninfo.capture exn in
            let info = Option.cata (Loc.add_loc info) info loc in
            Exninfo.iraise (InternalizationError(NotAProjection first_field_ref), info)
        in
        (* the number of parameters *)
        let nparams = record.Recordops.s_EXPECTEDPARAM in
        (* the reference constructor of the record *)
        let base_constructor = GlobRef.ConstructRef record.Recordops.s_CONST in
        let () = check_duplicate ?loc fields in
        let build_proj idx proj kind =
          if proj = None && complete then
            (* we don't want anonymous fields *)
            user_err ?loc (str "This record contains anonymous fields.")
          else
            (idx, proj, kind.Recordops.pk_true_proj) in
        let proj_list =
          List.map2_i build_proj 1 record.Recordops.s_PROJ record.Recordops.s_PROJKIND in
        (* now we want to have all fields assignments indexed by their place in
           the constructor *)
        let rec index_fields fields remaining_projs acc =
          match fields with
            | (field_ref, field_value) :: fields ->
               let field_glob_ref = try locate_reference field_ref
               with Not_found ->
                 user_err ?loc:field_ref.CAst.loc ~hdr:"intern"
                               (str "The field \"" ++ pr_qualid field_ref ++ str "\" does not exist.") in
               let remaining_projs, (field_index, _, regular) =
                 let the_proj = function
                   | (idx, Some glob_id, _) -> GlobRef.equal field_glob_ref (GlobRef.ConstRef glob_id)
                   | (idx, None, _) -> false in
                 try CList.extract_first the_proj remaining_projs
                 with Not_found ->
                   let floc = field_ref.CAst.loc in
                   let this_field_record =
                     try Recordops.find_projection field_glob_ref
                     with Not_found ->
                       let inductive_ref = inductive_of_record floc record in
                       Loc.raise ?loc:floc (InternalizationError(NotAProjectionOf (field_ref, inductive_ref))) in
                   let ind1 = inductive_of_record floc record in
                   let ind2 = inductive_of_record floc this_field_record in
                   Loc.raise ?loc (InternalizationError(ProjectionsOfDifferentRecords (ind1, ind2)))
               in
               if not regular && complete then
                 (* "regular" is false when the field is defined
                    by a let-in in the record declaration
                    (its value is fixed from other fields). *)
                 user_err ?loc  (str "No local fields allowed in a record construction.");
               Dumpglob.add_glob ?loc:field_ref.CAst.loc field_glob_ref;
               index_fields fields remaining_projs ((field_index, field_value) :: acc)
            | [] ->
               let remaining_fields =
                 let complete_field (idx, field_ref, regular) =
                   if not regular && complete then
                     (* For terms, we keep only regular fields *)
                     None
                   else
                     Some (idx, completer idx field_ref record.Recordops.s_CONST) in
                 List.map_filter complete_field remaining_projs in
               List.rev_append remaining_fields acc
        in
        let unsorted_indexed_fields = index_fields fields proj_list [] in
        let sorted_indexed_fields =
          let cmp_by_index (i, _) (j, _) = Int.compare i j in
          List.sort cmp_by_index unsorted_indexed_fields in
        let sorted_fields = List.map snd sorted_indexed_fields in
        Some (nparams, base_constructor, sorted_fields)

(** {6 Manage multiple aliases} *)

type alias = {
  alias_ids : lident list;
  alias_map : Id.t Id.Map.t;
}

let empty_alias = {
  alias_ids = [];
  alias_map = Id.Map.empty;
}

  (* [merge_aliases] returns the sets of all aliases encountered at this
     point and a substitution mapping extra aliases to the first one *)
let merge_aliases aliases {loc;v=na} =
  match na with
  | Anonymous -> aliases
  | Name id ->
  let alias_ids = aliases.alias_ids @ [make ?loc id] in
  let alias_map = match aliases.alias_ids with
  | [] -> aliases.alias_map
  | {v=id'} :: _ -> Id.Map.add id id' aliases.alias_map
  in
  { alias_ids; alias_map; }

let alias_of als = match als.alias_ids with
| [] -> Anonymous
| {v=id} :: _ -> Name id

(** {6 Expanding notations }

    @returns a raw_case_pattern_expr :
    - no notations and syntactic definition
    - global reference and identifier instead of reference

*)

let merge_subst s1 s2 = Id.Map.fold Id.Map.add s1 s2

let product_of_cases_patterns aliases idspl =
  (* each [pl] is a disjunction of patterns over common identifiers [ids] *)
  (* We stepwise build a disjunction of patterns [ptaill] over common [ids'] *)
  List.fold_right (fun (ids,pl) (ids',ptaill) ->
    (ids @ ids',
     (* Cartesian prod of the or-pats for the nth arg and the tail args *)
     List.flatten (
       List.map (fun (subst,p) ->
         List.map (fun (subst',ptail) -> (merge_subst subst subst',p::ptail)) ptaill) pl)))
    idspl (aliases.alias_ids,[aliases.alias_map,[]])

let rec subst_pat_iterator y t = DAst.(map (function
  | RCPatAtom id as p ->
    begin match id with Some ({v=x},_) when Id.equal x y -> DAst.get t | _ -> p end
  | RCPatCstr (id,l1,l2) ->
    RCPatCstr (id,List.map (subst_pat_iterator y t) l1,
               List.map (subst_pat_iterator y t) l2)
  | RCPatAlias (p,a) -> RCPatAlias (subst_pat_iterator y t p,a)
  | RCPatOr pl -> RCPatOr (List.map (subst_pat_iterator y t) pl)))

let is_non_zero c = match c with
| { CAst.v = CPrim (Number p) } -> not (NumTok.Signed.is_zero p)
| _ -> false

let is_non_zero_pat c = match c with
| { CAst.v = CPatPrim (Number p) } -> not (NumTok.Signed.is_zero p)
| _ -> false

let get_asymmetric_patterns = Goptions.declare_bool_option_and_ref
    ~depr:false
    ~key:["Asymmetric";"Patterns"]
    ~value:false

let drop_notations_pattern (test_kind_top,test_kind_inner) genv env pat =
  (* At toplevel, Constructors and Inductives are accepted, in recursive calls
     only constructor are allowed *)
  let ensure_kind test_kind ?loc g =
    try test_kind ?loc g
    with Not_found ->
      error_invalid_pattern_notation ?loc ()
  in
  (* [rcp_of_glob] : from [glob_constr] to [raw_cases_pattern_expr] *)
  let rec rcp_of_glob scopes x = DAst.(map (function
    | GVar id -> RCPatAtom (Some (CAst.make ?loc:x.loc id,scopes))
    | GHole (_,_,_) -> RCPatAtom (None)
    | GRef (g,_) -> RCPatCstr (g,[],[])
    | GApp (r, l) ->
      begin match DAst.get r with
      | GRef (g,_) ->
        let allscs = find_arguments_scope g in
        let allscs = simple_adjust_scopes (List.length l) allscs in (* TO CHECK *)
        RCPatCstr (g, List.map2 (fun sc a -> rcp_of_glob (sc,snd scopes) a) allscs l,[])
      | _ ->
        CErrors.anomaly Pp.(str "Invalid return pattern from Notation.interp_prim_token_cases_pattern_expr.")
      end
    | _ -> CErrors.anomaly Pp.(str "Invalid return pattern from Notation.interp_prim_token_cases_pattern_expr."))) x
  in
  let rec drop_syndef test_kind ?loc scopes qid pats =
    try
      if qualid_is_ident qid && Option.cata (Id.Set.mem (qualid_basename qid)) false env.pat_ids then
        raise Not_found;
      match Nametab.locate_extended qid with
      | SynDef sp ->
        let filter (vars,a) =
        try match a with
        | NRef g ->
          (* Convention: do not deactivate implicit arguments and scopes for further arguments *)
          test_kind ?loc g;
          let () = assert (List.is_empty vars) in
          let (_,argscs) = find_remaining_scopes [] pats g in
          Some (g, [], List.map2 (in_pat_sc scopes) argscs pats)
        | NApp (NRef g,[]) -> (* special case: Syndef for @Cstr deactivates implicit arguments *)
              test_kind ?loc g;
              let () = assert (List.is_empty vars) in
              let (_,argscs) = find_remaining_scopes [] pats g in
              Some (g, List.map2 (in_pat_sc scopes) argscs pats, [])
        | NApp (NRef g,args) ->
              (* Convention: do not deactivate implicit arguments and scopes for further arguments *)
              test_kind ?loc g;
              let nvars = List.length vars in
              if List.length pats < nvars then error_not_enough_arguments ?loc:qid.loc;
              let pats1,pats2 = List.chop nvars pats in
              let subst = split_by_type_pat vars (pats1,[]) in
              let idspl1 = List.map (in_not test_kind_inner qid.loc scopes subst []) args in
              let (_,argscs) = find_remaining_scopes pats1 pats2 g in
              Some (g, idspl1, List.map2 (in_pat_sc scopes) argscs pats2)
        | _ -> raise Not_found
        with Not_found -> None in
        Syntax_def.search_filtered_syntactic_definition filter sp
      | TrueGlobal g ->
          test_kind ?loc g;
          Dumpglob.add_glob ?loc:qid.loc g;
          let (_,argscs) = find_remaining_scopes [] pats g in
          Some (g,[],List.map2 (in_pat_sc scopes) argscs pats)
    with Not_found -> None
  and in_pat test_kind scopes pt =
    let open CAst in
    let loc = pt.loc in
    match pt.v with
    | CPatAlias (p, id) -> DAst.make ?loc @@ RCPatAlias (in_pat test_kind scopes p, id)
    | CPatRecord l ->
      let sorted_fields =
        sort_fields ~complete:false loc l (fun _idx fieldname constructor -> CAst.make ?loc @@ CPatAtom None) in
      begin match sorted_fields with
        | None -> DAst.make ?loc @@ RCPatAtom None
        | Some (n, head, pl) ->
          let pl =
            let pars = List.make n (CAst.make ?loc @@ CPatAtom None) in
            List.rev_append pars pl
          in
          let (_,argscs) = find_remaining_scopes [] pl head in
          let pats = List.map2 (in_pat_sc scopes) argscs pl in
          DAst.make ?loc @@ RCPatCstr(head, pats, [])
      end
    | CPatCstr (head, None, pl) ->
      begin
        match drop_syndef test_kind ?loc scopes head pl with
          | Some (a,b,c) -> DAst.make ?loc @@ RCPatCstr(a, b, c)
          | None -> Loc.raise ?loc (InternalizationError (NotAConstructor head))
      end
    | CPatCstr (qid, Some expl_pl, pl) ->
      let g =
        try Nametab.locate qid
        with Not_found as exn ->
          let _, info = Exninfo.capture exn in
          let info = Option.cata (Loc.add_loc info) info loc in
          Exninfo.iraise (InternalizationError (NotAConstructor qid), info)
      in
      if expl_pl == [] then
        (* Convention: (@r) deactivates all further implicit arguments and scopes *)
        DAst.make ?loc @@ RCPatCstr (g, List.map (in_pat test_kind_inner scopes) pl, [])
      else
        (* Convention: (@r expl_pl) deactivates implicit arguments in expl_pl and in pl *)
        (* but not scopes in expl_pl *)
        let (argscs1,_) = find_remaining_scopes expl_pl pl g in
        DAst.make ?loc @@ RCPatCstr (g, List.map2 (in_pat_sc scopes) argscs1 expl_pl @ List.map (in_pat test_kind_inner scopes) pl, [])
    | CPatNotation (_,(InConstrEntry,"- _"),([a],[]),[]) when is_non_zero_pat a ->
      let p = match a.CAst.v with CPatPrim (Number (_, p)) -> p | _ -> assert false in
      let pat, _df = Notation.interp_prim_token_cases_pattern_expr ?loc (ensure_kind test_kind_inner) (Number (SMinus,p)) scopes in
      rcp_of_glob scopes pat
    | CPatNotation (_,(InConstrEntry,"( _ )"),([a],[]),[]) ->
      in_pat test_kind scopes a
    | CPatNotation (_,ntn,fullargs,extrargs) ->
      let ntn,(terms,termlists) = contract_curly_brackets_pat ntn fullargs in
      let ((ids',c),df) = Notation.interp_notation ?loc ntn scopes in
      let subst = split_by_type_pat ?loc ids' (terms,termlists) in
      Dumpglob.dump_notation_location (patntn_loc ?loc fullargs ntn) ntn df;
      in_not test_kind loc scopes subst extrargs c
    | CPatDelimiters (key, e) ->
      in_pat test_kind (None,find_delimiters_scope ?loc key::snd scopes) e
    | CPatPrim p ->
      let pat, _df = Notation.interp_prim_token_cases_pattern_expr ?loc test_kind_inner p scopes in
      rcp_of_glob scopes pat
    | CPatAtom (Some id) ->
      begin
        match drop_syndef test_kind ?loc scopes id [] with
          | Some (a,b,c) -> DAst.make ?loc @@ RCPatCstr (a, b, c)
          | None         -> DAst.make ?loc @@ RCPatAtom (Some ((make ?loc @@ find_pattern_variable id),scopes))
      end
    | CPatAtom None -> DAst.make ?loc @@ RCPatAtom None
    | CPatOr pl     -> DAst.make ?loc @@ RCPatOr (List.map (in_pat test_kind scopes) pl)
    | CPatCast (_,_) ->
      (* We raise an error if the pattern contains a cast, due to
         current restrictions on casts in patterns. Cast in patterns
         are supported only in local binders and only at top level.
         The only reason they are in the [cases_pattern_expr] type
         is that the parser needs to factor the "c : t" notation
         with user defined notations. In the long term, we will try to
         support such casts everywhere, and perhaps use them to print
         the domains of lambdas in the encoding of match in constr.
         This check is here and not in the parser because it would require
         duplicating the levels of the [pattern] rule. *)
      CErrors.user_err ?loc (Pp.strbrk "Casts are not supported in this pattern.")
  and in_pat_sc scopes x = in_pat test_kind_inner (x,snd scopes)
  and in_not (test_kind:?loc:Loc.t->'a->'b) loc scopes (subst,substlist as fullsubst) args = function
    | NVar id ->
      let () = assert (List.is_empty args) in
      begin
        (* subst remembers the delimiters stack in the interpretation *)
        (* of the notations *)
        try
          let (a,(scopt,subscopes)) = Id.Map.find id subst in
          in_pat test_kind (scopt,subscopes@snd scopes) a
        with Not_found ->
          if Id.equal id ldots_var then DAst.make ?loc @@ RCPatAtom (Some ((make ?loc id),scopes)) else
            anomaly (str "Unbound pattern notation variable: " ++ Id.print id ++ str ".")
      end
    | NRef g ->
      ensure_kind test_kind ?loc g;
      let (_,argscs) = find_remaining_scopes [] args g in
      DAst.make ?loc @@ RCPatCstr (g, [], List.map2 (in_pat_sc scopes) argscs args)
    | NApp (NRef g,pl) ->
      ensure_kind test_kind ?loc g;
      let (argscs1,argscs2) = find_remaining_scopes pl args g in
      let pl = List.map2 (fun x -> in_not test_kind_inner loc (x,snd scopes) fullsubst []) argscs1 pl in
      let pl = add_local_defs_and_check_length loc genv g pl args in
      let args = List.map2 (fun x -> in_pat test_kind_inner (x,snd scopes)) argscs2 args in
      let pat =
        if List.length pl = 0 then
          (* Convention: if notation is @f, encoded as NApp(Nref g,[]), then
             implicit arguments are not inherited *)
          RCPatCstr (g, pl @ args, [])
        else
          RCPatCstr (g, pl, args) in
      DAst.make ?loc @@ pat
    | NList (x,y,iter,terminator,revert) ->
      if not (List.is_empty args) then user_err ?loc
        (strbrk "Application of arguments to a recursive notation not supported in patterns.");
      (try
         (* All elements of the list are in scopes (scopt,subscopes) *)
         let (l,(scopt,subscopes)) = Id.Map.find x substlist in
         let termin = in_not test_kind_inner loc scopes fullsubst [] terminator in
         List.fold_right (fun a t ->
           let nsubst = Id.Map.add y (a, (scopt, subscopes)) subst in
           let u = in_not test_kind_inner loc scopes (nsubst, substlist) [] iter in
           subst_pat_iterator ldots_var t u)
           (if revert then List.rev l else l) termin
       with Not_found ->
         anomaly (Pp.str "Inconsistent substitution of recursive notation."))
    | NHole _ ->
      let () = assert (List.is_empty args) in
      DAst.make ?loc @@ RCPatAtom None
    | t -> error_invalid_pattern_notation ?loc ()
  in in_pat test_kind_top env.pat_scopes pat

let rec intern_pat genv ntnvars aliases pat =
  let intern_cstr_with_all_args loc c with_letin idslpl1 pl2 =
    let idslpl2 = List.map (intern_pat genv ntnvars empty_alias) pl2 in
    let (ids',pll) = product_of_cases_patterns aliases (idslpl1@idslpl2) in
    let pl' = List.map (fun (asubst,pl) ->
      (asubst, DAst.make ?loc @@ PatCstr (c,chop_params_pattern loc (fst c) pl with_letin,alias_of aliases))) pll in
    ids',pl' in
  let loc = pat.loc in
  match DAst.get pat with
    | RCPatAlias (p, id) ->
      let aliases' = merge_aliases aliases id in
      intern_pat genv ntnvars aliases' p
    | RCPatCstr (head, expl_pl, pl) ->
      if get_asymmetric_patterns () then
        let len = if List.is_empty expl_pl then Some (List.length pl) else None in
        let c,idslpl1 = find_constructor loc len head in
        let with_letin =
          check_constructor_length genv loc c (List.length idslpl1 + List.length expl_pl) pl in
        intern_cstr_with_all_args loc c with_letin idslpl1 (expl_pl@pl)
      else
        let c,idslpl1 = find_constructor loc None head in
        let with_letin, pl2 =
          add_implicits_check_constructor_length genv loc c (List.length idslpl1 + List.length expl_pl) pl in
        intern_cstr_with_all_args loc c with_letin idslpl1 (expl_pl@pl2)
    | RCPatAtom (Some ({loc;v=id},scopes)) ->
      let aliases = merge_aliases aliases (make ?loc @@ Name id) in
      set_var_scope ?loc id false scopes ntnvars;
      (aliases.alias_ids,[aliases.alias_map, DAst.make ?loc @@ PatVar (alias_of aliases)]) (* TO CHECK: aura-t-on id? *)
    | RCPatAtom (None) ->
      let { alias_ids = ids; alias_map = asubst; } = aliases in
      (ids, [asubst, DAst.make ?loc @@ PatVar (alias_of aliases)])
    | RCPatOr pl ->
      assert (not (List.is_empty pl));
      let pl' = List.map (intern_pat genv ntnvars aliases) pl in
      let (idsl,pl') = List.split pl' in
      let ids = List.hd idsl in
      check_or_pat_variables loc ids (List.tl idsl);
      (ids,List.flatten pl')

let intern_cases_pattern test_kind genv ntnvars env aliases pat =
  intern_pat genv ntnvars aliases
    (drop_notations_pattern (test_kind,test_kind) genv env pat)

let _ =
  intern_cases_pattern_fwd :=
    fun test_kind ntnvars env p ->
    intern_cases_pattern test_kind (Global.env ()) ntnvars env empty_alias p

let intern_ind_pattern genv ntnvars env pat =
  let test_kind_top ?loc = function
    | GlobRef.IndRef _  -> ()
    | GlobRef.ConstructRef _ | GlobRef.ConstRef _ | GlobRef.VarRef _ ->
      (* A non-inductive global reference at top is an error *)
      error_invalid_pattern_notation ?loc () in
  let test_kind_inner ?loc = function
    | GlobRef.ConstructRef _ -> ()
    | GlobRef.IndRef _ | GlobRef.ConstRef _ | GlobRef.VarRef _ ->
      (* A non-constructor global reference deep in a pattern is seen as a variable *)
      raise Not_found in
  let no_not =
    try
      drop_notations_pattern (test_kind_top,test_kind_inner) genv env pat
    with InternalizationError (NotAConstructor _) as exn ->
      let _, info = Exninfo.capture exn in
      error_bad_inductive_type ~info ()
  in
  let loc = no_not.CAst.loc in
  match DAst.get no_not with
    | RCPatCstr (head, expl_pl, pl) ->
      let c = (function GlobRef.IndRef ind -> ind | _ -> error_bad_inductive_type ?loc ()) head in
      let with_letin, pl2 = add_implicits_check_ind_length genv loc c
        (List.length expl_pl) pl in
      let idslpl = List.map (intern_pat genv ntnvars empty_alias) (expl_pl@pl2) in
      (with_letin,
       match product_of_cases_patterns empty_alias idslpl with
       | ids,[asubst,pl] -> (c,ids,asubst,chop_params_pattern loc c pl with_letin)
       | _ -> error_bad_inductive_type ?loc ())
    | x -> error_bad_inductive_type ?loc ()

(**********************************************************************)
(* Utilities for application                                          *)

let get_implicit_name n imps =
  Some (Impargs.name_of_implicit (List.nth imps (n-1)))

let set_hole_implicit i b c =
  let loc = c.CAst.loc in
  match DAst.get c with
  | GRef (r, _) -> Loc.tag ?loc (Evar_kinds.ImplicitArg (r,i,b),IntroAnonymous,None)
  | GApp (r, _) ->
    let loc = r.CAst.loc in
    begin match DAst.get r with
    | GRef (r, _) ->
      Loc.tag ?loc (Evar_kinds.ImplicitArg (r,i,b),IntroAnonymous,None)
    | _ -> anomaly (Pp.str "Only refs have implicits.")
    end
  | GVar id -> Loc.tag ?loc (Evar_kinds.ImplicitArg (GlobRef.VarRef id,i,b),IntroAnonymous,None)
  | _ -> anomaly (Pp.str "Only refs have implicits.")

let exists_implicit_name id =
  List.exists (fun imp -> is_status_implicit imp && Id.equal id (name_of_implicit imp))

let extract_explicit_arg imps args =
  let rec aux = function
  | [] -> Id.Map.empty, []
  | (a,e)::l ->
      let (eargs,rargs) = aux l in
      match e with
      | None -> (eargs,a::rargs)
      | Some {loc;v=pos} ->
          let id = match pos with
          | ExplByName id ->
              if not (exists_implicit_name id imps) then
                user_err ?loc
                  (str "Wrong argument name: " ++ Id.print id ++ str ".");
              if Id.Map.mem id eargs then
                user_err ?loc  (str "Argument name " ++ Id.print id
                ++ str " occurs more than once.");
              id
          | ExplByPos (p,_id) ->
              let id =
                try
                  let imp = List.nth imps (p-1) in
                  if not (is_status_implicit imp) then failwith "imp";
                  name_of_implicit imp
                with Failure _ (* "nth" | "imp" *) ->
                  user_err ?loc
                    (str"Wrong argument position: " ++ int p ++ str ".")
              in
              if Id.Map.mem id eargs then
                user_err ?loc  (str"Argument at position " ++ int p ++
                  str " is mentioned more than once.");
              id in
          (Id.Map.add id (loc, a) eargs, rargs)
  in aux args

(**********************************************************************)
(* Main loop                                                          *)

let internalize globalenv env pattern_mode (_, ntnvars as lvar) c =
  let rec intern env = CAst.with_loc_val (fun ?loc -> function
    | CRef (ref,us) ->
        let (c,imp,subscopes),_ =
          intern_applied_reference ~isproj:None intern env (Environ.named_context_val globalenv)
            lvar us [] ref
        in
          apply_impargs c env imp subscopes [] loc

    | CFix ({ CAst.loc = locid; v = iddef}, dl) ->
        let lf = List.map (fun ({CAst.v = id},_,_,_,_) -> id) dl in
        let dl = Array.of_list dl in
        let n =
          try List.index0 Id.equal iddef lf
          with Not_found as exn ->
            let _, info = Exninfo.capture exn in
            let info = Option.cata (Loc.add_loc info) info locid in
            Exninfo.iraise (InternalizationError (UnboundFixName (false,iddef)),info)
        in
        let env = restart_lambda_binders env in
        let idl_temp = Array.map
            (fun (id,recarg,bl,ty,_) ->
               let recarg = Option.map (function { CAst.v = v; loc } -> match v with
                 | CStructRec i -> i
                 | _ -> user_err ?loc Pp.(str "Well-founded induction requires Program Fixpoint or Function.")) recarg
               in
               let before, after = split_at_annot bl recarg in
               let (env',rbefore) = List.fold_left intern_local_binder (env,[]) before in
               let n = Option.map (fun _ -> List.count (fun c -> match DAst.get c with
                   | GLocalAssum _ -> true
                   | _ -> false (* remove let-ins *))
                   rbefore) recarg in
               let (env',rbl) = List.fold_left intern_local_binder (env',rbefore) after in
               let bl = List.rev (List.map glob_local_binder_of_extended rbl) in
               let bl_impls = remember_binders_impargs env' bl in
               (n, bl, intern_type env' ty, bl_impls)) dl in
        (* We add the recursive functions to the environment *)
        let env_rec = List.fold_left_i (fun i en name ->
           let (_,bli,tyi,_) = idl_temp.(i) in
           let binder_index,fix_args = impls_binder_list 1 bli in
           let impls = impls_type_list ~args:fix_args binder_index tyi in
           push_name_env ntnvars impls en (CAst.make @@ Name name)) 0 env lf in
        let idl = Array.map2 (fun (_,_,_,_,bd) (n,bl,ty,before_impls) ->
            (* We add the binders common to body and type to the environment *)
            let env_body = restore_binders_impargs env_rec before_impls in
            (n,bl,ty,intern {env_body with tmp_scope = None} bd)) dl idl_temp in
        DAst.make ?loc @@
        GRec (GFix
                (Array.map (fun (ro,_,_,_) -> ro) idl,n),
              Array.of_list lf,
              Array.map (fun (_,bl,_,_) -> bl) idl,
              Array.map (fun (_,_,ty,_) -> ty) idl,
              Array.map (fun (_,_,_,bd) -> bd) idl)

    | CCoFix ({ CAst.loc = locid; v = iddef }, dl) ->
        let lf = List.map (fun ({CAst.v = id},_,_,_) -> id) dl in
        let dl = Array.of_list dl in
        let n =
          try List.index0 Id.equal iddef lf
          with Not_found as exn ->
            let _, info = Exninfo.capture exn in
            let info = Option.cata (Loc.add_loc info) info locid in
            Exninfo.iraise (InternalizationError (UnboundFixName (true,iddef)), info)
        in
        let env = restart_lambda_binders env in
        let idl_tmp = Array.map
          (fun ({ CAst.loc; v = id },bl,ty,_) ->
            let (env',rbl) = List.fold_left intern_local_binder (env,[]) bl in
            let bl = List.rev (List.map glob_local_binder_of_extended rbl) in
            let bl_impls = remember_binders_impargs env' bl in
            (bl,intern_type env' ty,bl_impls)) dl in
        let env_rec = List.fold_left_i (fun i en name ->
          let (bli,tyi,_) = idl_tmp.(i) in
          let binder_index,cofix_args = impls_binder_list 1 bli in
          push_name_env ntnvars (impls_type_list ~args:cofix_args binder_index tyi)
            en (CAst.make @@ Name name)) 0 env lf in
        let idl = Array.map2 (fun (_,_,_,bd) (b,c,bl_impls) ->
          (* We add the binders common to body and type to the environment *)
          let env_body = restore_binders_impargs env_rec bl_impls in
          (b,c,intern {env_body with tmp_scope = None} bd)) dl idl_tmp in
        DAst.make ?loc @@
        GRec (GCoFix n,
              Array.of_list lf,
              Array.map (fun (bl,_,_) -> bl) idl,
              Array.map (fun (_,ty,_) -> ty) idl,
              Array.map (fun (_,_,bd) -> bd) idl)
    | CProdN ([],c2) -> anomaly (Pp.str "The AST is malformed, found prod without binders.")
    | CProdN (bl,c2) ->
        let (env',bl) = List.fold_left intern_local_binder (switch_prod_binders env,[]) bl in
        expand_binders ?loc mkGProd bl (intern_type env' c2)
    | CLambdaN ([],c2) -> anomaly (Pp.str "The AST is malformed, found lambda without binders.")
    | CLambdaN (bl,c2) ->
        let (env',bl) = List.fold_left intern_local_binder (reset_tmp_scope (switch_lambda_binders env),[]) bl in
        expand_binders ?loc mkGLambda bl (intern env' c2)
    | CLetIn (na,c1,t,c2) ->
        let inc1 = intern_restart_binders (reset_tmp_scope env) c1 in
        let int = Option.map (intern_type_restart_binders env) t in
        DAst.make ?loc @@
        GLetIn (na.CAst.v, inc1, int,
          intern_restart_binders (push_name_env ntnvars (impls_term_list 1 inc1) env na) c2)
    | CNotation (_,(InConstrEntry,"- _"), ([a],[],[],[])) when is_non_zero a ->
      let p = match a.CAst.v with CPrim (Number (_, p)) -> p | _ -> assert false in
       intern env (CAst.make ?loc @@ CPrim (Number (SMinus,p)))
    | CNotation (_,(InConstrEntry,"( _ )"),([a],[],[],[])) -> intern env a
    | CNotation (_,ntn,args) ->
        let c = intern_notation intern env ntnvars loc ntn args in
        let x, impl, scopes = find_appl_head_data c in
        apply_impargs x env impl scopes [] loc
    | CGeneralization (b,a,c) ->
        intern_generalization intern env ntnvars loc b a c
    | CPrim p ->
        fst (Notation.interp_prim_token ?loc p (env.tmp_scope,env.scopes))
    | CDelimiters (key, e) ->
        intern {env with tmp_scope = None;
                  scopes = find_delimiters_scope ?loc key :: env.scopes} e
    | CAppExpl ((isproj,ref,us), args) ->
        let (f,_,args_scopes),args =
          let args = List.map (fun a -> (a,None)) args in
          intern_applied_reference ~isproj intern env (Environ.named_context_val globalenv)
            lvar us args ref
        in
        check_not_notation_variable f ntnvars;
        (* Rem: GApp(_,f,[]) stands for @f *)
        if args = [] then DAst.make ?loc @@ GApp (f,[]) else
          smart_gapp f loc (intern_args env args_scopes (List.map fst args))

    | CApp ((isproj,f), args) ->
      let isproj,f,args = match f.CAst.v with
        (* Compact notations like "t.(f args') args" *)
        | CApp ((Some _ as isproj',f), args') when not (Option.has_some isproj) ->
          isproj',f,args'@args
        (* Don't compact "(f args') args" to resolve implicits separately *)
        | _ -> isproj,f,args in
      let (c,impargs,args_scopes),args =
        match f.CAst.v with
        | CRef (ref,us) ->
          intern_applied_reference ~isproj intern env
            (Environ.named_context_val globalenv) lvar us args ref
        | CNotation (_,ntn,ntnargs) ->
          assert (Option.is_empty isproj);
          let c = intern_notation intern env ntnvars loc ntn ntnargs in
          find_appl_head_data c, args
        | _ ->
           assert (Option.is_empty isproj);
           let f = intern_no_implicit env f in
           let f, _, args_scopes = find_appl_head_data f in
           (f,[],args_scopes), args
      in
      apply_impargs c env impargs args_scopes args loc

    | CRecord fs ->
       let st = Evar_kinds.Define (not (Program.get_proofs_transparency ())) in
       let fields =
         sort_fields ~complete:true loc fs
                     (fun _idx fieldname constructorname ->
                         let open Evar_kinds in
                         let fieldinfo : Evar_kinds.record_field =
                             {fieldname=Option.get fieldname; recordname=inductive_of_constructor constructorname}
                             in
                         CAst.make ?loc @@ CHole (Some
                 (Evar_kinds.QuestionMark { Evar_kinds.default_question_mark with
                     Evar_kinds.qm_obligation=st;
                     Evar_kinds.qm_record_field=Some fieldinfo
                }) , IntroAnonymous, None))
       in
       begin
          match fields with
            | None -> user_err ?loc ~hdr:"intern" (str"No constructor inference.")
            | Some (n, constrname, args) ->
                let args_scopes = find_arguments_scope constrname in
                let pars = List.make n (CAst.make ?loc @@ CHole (None, IntroAnonymous, None)) in
                let args = intern_args env args_scopes (List.rev_append pars args) in
                let hd = DAst.make @@ GRef (constrname,None) in
                DAst.make ?loc @@ GApp (hd, args)
       end
    | CCases (sty, rtnpo, tms, eqns) ->
        let as_in_vars = List.fold_left (fun acc (_,na,inb) ->
          (Option.fold_left (fun acc { CAst.v = y } -> Name.fold_right Id.Set.add y acc) acc na))
          Id.Set.empty tms in
        (* as, in & return vars *)
        let forbidden_vars = Option.cata free_vars_of_constr_expr as_in_vars rtnpo in
        let tms,ex_ids,aliases,match_from_in = List.fold_right
          (fun citm (inds,ex_ids,asubst,matchs) ->
            let ((tm,ind),extra_id,(ind_ids,alias_subst,match_td)) =
              intern_case_item env forbidden_vars citm in
            (tm,ind)::inds,
            Id.Set.union ind_ids (Option.fold_right Id.Set.add extra_id ex_ids),
            merge_subst alias_subst asubst,
            List.rev_append match_td matchs)
          tms ([],Id.Set.empty,Id.Map.empty,[]) in
        let env' = Id.Set.fold
          (fun var bli -> push_name_env ntnvars [] bli (CAst.make @@ Name var))
          (Id.Set.union ex_ids as_in_vars)
          (restart_lambda_binders env)
        in
        (* PatVars before a real pattern do not need to be matched *)
        let stripped_match_from_in =
          let rec aux = function
            | [] -> []
            | (_, c) :: q when is_patvar c -> aux q
            | l -> l
          in aux match_from_in in
        let rtnpo = Option.map (replace_vars_constr_expr aliases) rtnpo in
        let rtnpo = match stripped_match_from_in with
          | [] -> Option.map (intern_type (slide_binders env')) rtnpo (* Only PatVar in "in" clauses *)
          | l ->
             (* Build a return predicate by expansion of the patterns of the "in" clause *)
             let thevars, thepats = List.split l in
             let sub_rtn = (* Some (GSort (Loc.ghost,GType None)) *) None in
             let sub_tms = List.map (fun id -> (DAst.make @@ GVar id),(Name id,None)) thevars (* "match v1,..,vn" *) in
             let main_sub_eqn = CAst.make @@
               ([],thepats, (* "|p1,..,pn" *)
                Option.cata (intern_type_no_implicit env')
                  (DAst.make ?loc @@ GHole(Evar_kinds.CasesType false,IntroAnonymous,None))
                  rtnpo) (* "=> P" if there were a return predicate P, and "=> _" otherwise *) in
             let catch_all_sub_eqn =
               if List.for_all (irrefutable globalenv) thepats then [] else
                  [CAst.make @@ ([],List.make (List.length thepats) (DAst.make @@ PatVar Anonymous), (* "|_,..,_" *)
                   DAst.make @@ GHole(Evar_kinds.ImpossibleCase,IntroAnonymous,None))]   (* "=> _" *) in
             Some (DAst.make @@ GCases(RegularStyle,sub_rtn,sub_tms,main_sub_eqn::catch_all_sub_eqn))
        in
        let eqns' = List.map (intern_eqn (List.length tms) env) eqns in
        DAst.make ?loc @@
        GCases (sty, rtnpo, tms, List.flatten eqns')
    | CLetTuple (nal, (na,po), b, c) ->
        let env' = reset_tmp_scope env in
        (* "in" is None so no match to add *)
        let ((b',(na',_)),_,_) = intern_case_item env' Id.Set.empty (b,na,None) in
        let p' = Option.map (fun u ->
          let env'' = push_name_env ntnvars [] env'
            (CAst.make na') in
          intern_type (slide_binders env'') u) po in
        DAst.make ?loc @@
        GLetTuple (List.map (fun { CAst.v } -> v) nal, (na', p'), b',
                   intern (List.fold_left (push_name_env ntnvars []) env nal) c)
    | CIf (c, (na,po), b1, b2) ->
      let env' = reset_tmp_scope env in
      let ((c',(na',_)),_,_) = intern_case_item env' Id.Set.empty (c,na,None) in (* no "in" no match to ad too *)
      let p' = Option.map (fun p ->
          let env'' = push_name_env ntnvars [] env
            (CAst.make na') in
          intern_type (slide_binders env'') p) po in
        DAst.make ?loc @@
        GIf (c', (na', p'), intern env b1, intern env b2)
    | CHole (k, naming, solve) ->
        let k = match k with
        | None ->
           let st = Evar_kinds.Define (not (Program.get_proofs_transparency ())) in
           (match naming with
           | IntroIdentifier id -> Evar_kinds.NamedHole id
           | _ -> Evar_kinds.QuestionMark { Evar_kinds.default_question_mark with Evar_kinds.qm_obligation=st; })
        | Some k -> k
        in
        let solve = match solve with
        | None -> None
        | Some gen ->
          let (ltacvars, ntnvars) = lvar in
          (* Preventively declare notation variables in ltac as non-bindings *)
          Id.Map.iter (fun x (used_as_binder,_,_) -> used_as_binder := false) ntnvars;
          let extra = ltacvars.ltac_extra in
          (* We inform ltac that the interning vars and the notation vars are bound *)
          (* but we could instead rely on the "intern_sign" *)
          let lvars = Id.Set.union ltacvars.ltac_bound ltacvars.ltac_vars in
          let lvars = Id.Set.union lvars (Id.Map.domain ntnvars) in
          let ltacvars = Id.Set.union lvars env.ids in
          (* Propagating enough information for mutual interning with tac-in-term *)
          let intern_sign = {
            Genintern.intern_ids = env.ids;
            Genintern.notation_variable_status = ntnvars
          } in
          let ist = {
            Genintern.genv = globalenv;
            ltacvars;
            extra;
            intern_sign;
          } in
          let (_, glb) = Genintern.generic_intern ist gen in
          Some glb
        in
        DAst.make ?loc @@
        GHole (k, naming, solve)
    (* Parsing pattern variables *)
    | CPatVar n when pattern_mode ->
        DAst.make ?loc @@
        GPatVar (Evar_kinds.SecondOrderPatVar n)
    | CEvar (n, []) when pattern_mode ->
        DAst.make ?loc @@
        GPatVar (Evar_kinds.FirstOrderPatVar n.CAst.v)
    (* end *)
    (* Parsing existential variables *)
    | CEvar (n, l) ->
        DAst.make ?loc @@
        GEvar (n, List.map (on_snd (intern_no_implicit env)) l)
    | CPatVar _ ->
      Loc.raise ?loc (InternalizationError IllegalMetavariable)
    (* end *)
    | CSort s ->
        DAst.make ?loc @@
        GSort s
    | CCast (c1, c2) ->
        DAst.make ?loc @@
        GCast (intern env c1, map_cast_type (intern_type (slide_binders env)) c2)
    | CArray(u,t,def,ty) ->
      DAst.make ?loc @@ GArray(u, Array.map (intern env) t, intern env def, intern env ty)
    )
  and intern_type env = intern (set_type_scope env)

  and intern_type_no_implicit env = intern (restart_no_binders (set_type_scope env))

  and intern_no_implicit env = intern (restart_no_binders env)

  and intern_restart_binders env = intern (restart_lambda_binders env)

  and intern_type_restart_binders env = intern (restart_prod_binders (set_type_scope env))

  and intern_local_binder env bind : intern_env * Glob_term.extended_glob_local_binder list =
    intern_local_binder_aux intern ntnvars env bind

  (* Expands a multiple pattern into a disjunction of multiple patterns *)
  and intern_multiple_pattern env n pl =
    let env = { pat_ids = None; pat_scopes = (None,env.scopes) } in
    let idsl_pll = List.map (intern_cases_pattern test_kind_tolerant globalenv ntnvars env empty_alias) pl in
    let loc = loc_of_multiple_pattern pl in
    check_number_of_pattern loc n pl;
    product_of_cases_patterns empty_alias idsl_pll

  (* Expands a disjunction of multiple pattern *)
  and intern_disjunctive_multiple_pattern env loc n mpl =
    assert (not (List.is_empty mpl));
    let mpl' = List.map (intern_multiple_pattern env n) mpl in
    let (idsl,mpl') = List.split mpl' in
    let ids = List.hd idsl in
    check_or_pat_variables loc ids (List.tl idsl);
    (ids,List.flatten mpl')

  (* Expands a pattern-matching clause [lhs => rhs] *)
  and intern_eqn n env {loc;v=(lhs,rhs)} =
    let eqn_ids,pll = intern_disjunctive_multiple_pattern env loc n lhs in
    (* Linearity implies the order in ids is irrelevant *)
    let eqn_ids = List.map (fun x -> x.v) eqn_ids in
    check_linearity lhs eqn_ids;
    let env_ids = List.fold_right Id.Set.add eqn_ids env.ids in
    List.map (fun (asubst,pl) ->
      let rhs = replace_vars_constr_expr asubst rhs in
      let rhs' = intern_no_implicit {env with ids = env_ids} rhs in
      CAst.make ?loc (eqn_ids,pl,rhs')) pll

  and intern_case_item env forbidden_names_for_gen (tm,na,t) =
    (* the "match" part *)
    let tm' = intern_no_implicit env tm in
    (* the "as" part *)
    let extra_id,na =
      let loc = tm'.CAst.loc in
      match DAst.get tm', na with
      | GVar id, None when not (Id.Map.mem id (snd lvar)) -> Some id, CAst.make ?loc @@ Name id
      | GRef (GlobRef.VarRef id, _), None -> Some id, CAst.make ?loc @@ Name id
      | _, None -> None, CAst.make Anonymous
      | _, Some ({ CAst.loc; v = na } as lna) -> None, lna in
    (* the "in" part *)
    let match_td,typ = match t with
    | Some t ->
        let with_letin,(ind,ind_ids,alias_subst,l) =
          intern_ind_pattern globalenv ntnvars (env_for_pattern (set_type_scope env)) t in
        let (mib,mip) = Inductive.lookup_mind_specif globalenv ind in
        let nparams = (List.length (mib.Declarations.mind_params_ctxt)) in
        (* for "in Vect n", we answer (["n","n"],[(loc,"n")])

           for "in Vect (S n)", we answer ((match over "m", relevant branch is "S
           n"), abstract over "m") = ([("m","S n")],[(loc,"m")]) where "m" is
           generated from the canonical name of the inductive and outside of
           {forbidden_names_for_gen} *)
        let (match_to_do,nal) =
          let rec canonize_args case_rel_ctxt arg_pats forbidden_names match_acc var_acc =
            let add_name l = function
              | { CAst.v = Anonymous } -> l
              | { CAst.loc; v = (Name y as x) } -> (y, DAst.make ?loc @@ PatVar x) :: l in
            match case_rel_ctxt,arg_pats with
              (* LetIn in the rel_context *)
              | LocalDef _ :: t, l when not with_letin ->
                canonize_args t l forbidden_names match_acc ((CAst.make Anonymous)::var_acc)
              | [],[] ->
                (add_name match_acc na, var_acc)
              | (LocalAssum (cano_name,ty) | LocalDef (cano_name,_,ty)) :: t, c::tt ->
                begin match DAst.get c with
                | PatVar x ->
                  let loc = c.CAst.loc in
                  canonize_args t tt forbidden_names
                    (add_name match_acc CAst.(make ?loc x)) (CAst.make ?loc x::var_acc)
                | _ ->
                  let fresh =
                    Namegen.next_name_away_with_default_using_types "iV" cano_name.binder_name forbidden_names (EConstr.of_constr ty) in
                  canonize_args t tt (Id.Set.add fresh forbidden_names)
                    ((fresh,c)::match_acc) ((CAst.make ?loc:(cases_pattern_loc c) @@ Name fresh)::var_acc)
                end
              | _ -> assert false in
          let _,args_rel =
            List.chop nparams (List.rev mip.Declarations.mind_arity_ctxt) in
          canonize_args args_rel l forbidden_names_for_gen [] [] in
        (Id.Set.of_list (List.map (fun id -> id.CAst.v) ind_ids),alias_subst,match_to_do),
        Some (CAst.make ?loc:(cases_pattern_expr_loc t) (ind,List.rev_map (fun x -> x.v) nal))
    | None ->
      (Id.Set.empty,Id.Map.empty,[]), None in
    (tm',(na.CAst.v, typ)), extra_id, match_td

  and intern_impargs c env l subscopes args =
    let eargs, rargs = extract_explicit_arg l args in
    if !parsing_explicit then
      if Id.Map.is_empty eargs then intern_args env subscopes rargs
      else user_err Pp.(str "Arguments given by name or position not supported in explicit mode.")
    else
    let rec aux n impl subscopes eargs rargs =
      let (enva,subscopes') = apply_scope_env env subscopes in
      match (impl,rargs) with
      | (imp::impl', rargs) when is_status_implicit imp ->
          begin try
            let id = name_of_implicit imp in
            let (_,a) = Id.Map.find id eargs in
            let eargs' = Id.Map.remove id eargs in
            intern_no_implicit enva a :: aux (n+1) impl' subscopes' eargs' rargs
          with Not_found ->
          if List.is_empty rargs && Id.Map.is_empty eargs && not (maximal_insertion_of imp) then
            (* Less regular arguments than expected: complete *)
            (* with implicit arguments if maximal insertion is set *)
            []
          else
              (DAst.map_from_loc (fun ?loc (a,b,c) -> GHole(a,b,c))
                (set_hole_implicit (n,get_implicit_name n l) (force_inference_of imp) c)
              ) :: aux (n+1) impl' subscopes' eargs rargs
          end
      | (imp::impl', a::rargs') ->
          intern_no_implicit enva a :: aux (n+1) impl' subscopes' eargs rargs'
      | (imp::impl', []) ->
          if not (Id.Map.is_empty eargs) then
            (let (id,(loc,_)) = Id.Map.choose eargs in
               user_err ?loc (str "Not enough non implicit \
            arguments to accept the argument bound to " ++
                 Id.print id ++ str"."));
          []
      | ([], rargs) ->
          assert (Id.Map.is_empty eargs);
          intern_args env subscopes rargs
    in aux 1 l subscopes eargs rargs

  and apply_impargs c env imp subscopes l loc =
    let imp = select_impargs_size (List.length (List.filter (fun (_,x) -> x == None) l)) imp in
    let l = intern_impargs c env imp subscopes l in
      smart_gapp c loc l

  and smart_gapp f loc = function
    | [] -> f
    | l ->
      let loc' = f.CAst.loc in
      match DAst.get f with
      | GApp (g, args) -> DAst.make ?loc:(Loc.merge_opt loc' loc) @@ GApp (g, args@l)
      | _ -> DAst.make ?loc:(Loc.merge_opt (loc_of_glob_constr f) loc) @@ GApp (f, l)

  and intern_args env subscopes = function
    | [] -> []
    | a::args ->
        let (enva,subscopes) = apply_scope_env env subscopes in
        (intern_no_implicit enva a) :: (intern_args env subscopes args)

  in
  intern env c

(**************************************************************************)
(* Functions to translate constr_expr into glob_constr                    *)
(**************************************************************************)

let extract_ids env =
  List.fold_right Id.Set.add
    (Termops.ids_of_rel_context (Environ.rel_context env))
    Id.Set.empty

let scope_of_type_kind env sigma = function
  | IsType -> Notation.current_type_scope_name ()
  | OfType typ -> compute_type_scope env sigma typ
  | WithoutTypeConstraint | UnknownIfTermOrType -> None

let allowed_binder_kind_of_type_kind = function
  | IsType -> Some AbsPi
  | OfType _ | WithoutTypeConstraint -> Some AbsLambda
  | UnknownIfTermOrType -> None

let empty_ltac_sign = {
  ltac_vars = Id.Set.empty;
  ltac_bound = Id.Set.empty;
  ltac_extra = Genintern.Store.empty;
}

let intern_gen kind env sigma
               ?(impls=empty_internalization_env) ?(pattern_mode=false) ?(ltacvars=empty_ltac_sign)
               c =
  let tmp_scope = scope_of_type_kind env sigma kind in
  let k = allowed_binder_kind_of_type_kind kind in
  internalize env {ids = extract_ids env; unb = false;
                         tmp_scope = tmp_scope; scopes = [];
                         impls; binder_block_names = Some (k,Id.Map.domain impls)}
    pattern_mode (ltacvars, Id.Map.empty) c

let intern_constr env sigma c = intern_gen WithoutTypeConstraint env sigma c
let intern_type env sigma c = intern_gen IsType env sigma c
let intern_pattern globalenv patt =
  let env = {pat_ids = None; pat_scopes = (None, [])} in
  intern_cases_pattern test_kind_tolerant globalenv Id.Map.empty env empty_alias patt

(*********************************************************************)
(* Functions to parse and interpret constructions *)

(* All evars resolved *)

let interp_gen kind env sigma ?(impls=empty_internalization_env) c =
  let c = intern_gen kind ~impls env sigma c in
  understand ~expected_type:kind env sigma c

let interp_constr ?(expected_type=WithoutTypeConstraint) env sigma ?(impls=empty_internalization_env) c =
  interp_gen expected_type env sigma c

let interp_type env sigma ?(impls=empty_internalization_env) c =
  interp_gen IsType env sigma ~impls c

let interp_casted_constr env sigma ?(impls=empty_internalization_env) c typ =
  interp_gen (OfType typ) env sigma ~impls c

(* Not all evars expected to be resolved *)

let interp_open_constr ?(expected_type=WithoutTypeConstraint) env sigma c =
  understand_tcc env sigma (intern_gen expected_type env sigma c)

(* Not all evars expected to be resolved and computation of implicit args *)

let interp_constr_evars_gen_impls ?(flags=Pretyping.all_no_fail_flags) env sigma
    ?(impls=empty_internalization_env) expected_type c =
  let c = intern_gen expected_type ~impls env sigma c in
  let imps = Implicit_quantifiers.implicits_of_glob_constr ~with_products:(expected_type == IsType) c in
  let sigma, c = understand_tcc ~flags env sigma ~expected_type c in
  sigma, (c, imps)

let interp_constr_evars_impls ?(program_mode=false) env sigma ?(impls=empty_internalization_env) c =
  let flags = { Pretyping.all_no_fail_flags with program_mode } in
  interp_constr_evars_gen_impls ~flags env sigma ~impls WithoutTypeConstraint c

let interp_casted_constr_evars_impls ?(program_mode=false) env evdref ?(impls=empty_internalization_env) c typ =
  let flags = { Pretyping.all_no_fail_flags with program_mode } in
  interp_constr_evars_gen_impls ~flags env evdref ~impls (OfType typ) c

let interp_type_evars_impls ?(flags=Pretyping.all_no_fail_flags) env sigma ?(impls=empty_internalization_env) c =
  interp_constr_evars_gen_impls ~flags env sigma ~impls IsType c

(* Not all evars expected to be resolved, with side-effect on evars *)

let interp_constr_evars_gen ?(program_mode=false) env sigma ?(impls=empty_internalization_env) expected_type c =
  let c = intern_gen expected_type ~impls env sigma c in
  let flags = { Pretyping.all_no_fail_flags with program_mode } in
  understand_tcc ~flags env sigma ~expected_type c

let interp_constr_evars ?program_mode env evdref ?(impls=empty_internalization_env) c =
  interp_constr_evars_gen ?program_mode env evdref WithoutTypeConstraint ~impls c

let interp_casted_constr_evars ?program_mode env sigma ?(impls=empty_internalization_env) c typ =
  interp_constr_evars_gen ?program_mode env sigma ~impls (OfType typ) c

let interp_type_evars ?program_mode env sigma ?(impls=empty_internalization_env) c =
  interp_constr_evars_gen ?program_mode env sigma IsType ~impls c

(* Miscellaneous *)

let intern_constr_pattern env sigma ?(as_type=false) ?(ltacvars=empty_ltac_sign) c =
  let c = intern_gen (if as_type then IsType else WithoutTypeConstraint)
            ~pattern_mode:true ~ltacvars env sigma c in
  pattern_of_glob_constr c

let interp_constr_pattern env sigma ?(expected_type=WithoutTypeConstraint) c =
  let c = intern_gen expected_type ~pattern_mode:true env sigma c in
  let flags = { Pretyping.no_classes_no_fail_inference_flags with expand_evars = false } in
  let sigma, c = understand_tcc ~flags env sigma ~expected_type c in
  (* FIXME: it is necessary to be unsafe here because of the way we handle
     evars in the pretyper. Sometimes they get solved eagerly. *)
  pattern_of_constr env sigma (EConstr.Unsafe.to_constr c)

let intern_core kind env sigma ?(pattern_mode=false) ?(ltacvars=empty_ltac_sign)
      { Genintern.intern_ids = ids; Genintern.notation_variable_status = vl } c =
  let tmp_scope = scope_of_type_kind env sigma kind in
  let impls = empty_internalization_env in
  let k = allowed_binder_kind_of_type_kind kind in
  internalize env
    {ids; unb = false; tmp_scope; scopes = []; impls;
     binder_block_names = Some (k,Id.Set.empty)}
    pattern_mode (ltacvars, vl) c

let interp_notation_constr env ?(impls=empty_internalization_env) nenv a =
  let ids = extract_ids env in
  (* [vl] is intended to remember the scope of the free variables of [a] *)
  let vl = Id.Map.map (fun typ -> (ref false, ref None, typ)) nenv.ninterp_var_type in
  let impls = Id.Map.fold (fun id _ impls -> Id.Map.remove id impls) nenv.ninterp_var_type impls in
  let c = internalize env
    {ids; unb = false; tmp_scope = None; scopes = []; impls; binder_block_names = None}
    false (empty_ltac_sign, vl) a in
  (* Splits variables into those that are binding, bound, or both *)
  (* Translate and check that [c] has all its free variables bound in [vars] *)
  let a, reversible = notation_constr_of_glob_constr nenv c in
  (* binding and bound *)
  let out_scope = function None -> None,[] | Some (a,l) -> a,l in
  let unused = match reversible with NonInjective ids -> ids | _ -> [] in
  let vars = Id.Map.mapi (fun id (used_as_binder, sc, typ) ->
    (!used_as_binder && not (List.mem_f Id.equal id unused), out_scope !sc)) vl in
  (* Returns [a] and the ordered list of variables with their scopes *)
  vars, a, reversible

(* Interpret binders and contexts  *)

let interp_binder env sigma na t =
  let t = intern_gen IsType env sigma t in
  let t' = locate_if_hole ?loc:(loc_of_glob_constr t) na t in
  understand ~expected_type:IsType env sigma t'

let interp_binder_evars env sigma na t =
  let t = intern_gen IsType env sigma t in
  let t' = locate_if_hole ?loc:(loc_of_glob_constr t) na t in
  understand_tcc env sigma ~expected_type:IsType t'

let my_intern_constr env lvar acc c =
  internalize env acc false lvar c

let intern_context env impl_env binders =
  let lvar = (empty_ltac_sign, Id.Map.empty) in
  let ids =
    (* We assume all ids around are parts of the prefix of the current
       context being interpreted *)
     extract_ids env in
  let lenv, bl = List.fold_left
            (fun (lenv, bl) b ->
               let (env, bl) = intern_local_binder_aux (my_intern_constr env lvar) Id.Map.empty (lenv, bl) b in
               (env, bl))
            ({ids; unb = false;
              tmp_scope = None; scopes = []; impls = impl_env;
              binder_block_names = Some (Some AbsPi,ids)}, []) binders in
  (lenv.impls, List.map glob_local_binder_of_extended bl)

let interp_glob_context_evars ?(program_mode=false) env sigma bl =
  let open EConstr in
  let flags = { Pretyping.all_no_fail_flags with program_mode } in
  let env, sigma, par, impls =
    List.fold_left
      (fun (env,sigma,params,impls) (na, k, b, t) ->
       let t' =
         if Option.is_empty b then locate_if_hole ?loc:(loc_of_glob_constr t) na t
         else t
       in
       let sigma, t = understand_tcc ~flags env sigma ~expected_type:IsType t' in
        match b with
          None ->
              let r = Retyping.relevance_of_type env sigma t in
              let d = LocalAssum (make_annot na r,t) in
              let impls =
                match k with
                | NonMaxImplicit -> CAst.make (Some (na,false)) :: impls
                | MaxImplicit -> CAst.make (Some (na,true)) :: impls
                | Explicit -> CAst.make None :: impls
              in
                (push_rel d env, sigma, d::params, impls)
          | Some b ->
              let sigma, c = understand_tcc ~flags env sigma ~expected_type:(OfType t) b in
              let r = Retyping.relevance_of_type env sigma t in
              let d = LocalDef (make_annot na r, c, t) in
                (push_rel d env, sigma, d::params, impls))
      (env,sigma,[],[]) (List.rev bl)
  in
  sigma, ((env, par), List.rev impls)

let interp_context_evars ?program_mode ?(impl_env=empty_internalization_env) env sigma params =
  let int_env,bl = intern_context env impl_env params in
  let sigma, x = interp_glob_context_evars ?program_mode env sigma bl in
  sigma, (int_env, x)


(** Local universe and constraint declarations. *)

let interp_univ_constraints env evd cstrs =
  let interp (evd,cstrs) (u, d, u') =
    let ul = Pretyping.interp_known_glob_level evd u in
    let u'l = Pretyping.interp_known_glob_level evd u' in
    let cstr = (ul,d,u'l) in
    let cstrs' = Univ.Constraint.add cstr cstrs in
    try let evd = Evd.add_constraints evd (Univ.Constraint.singleton cstr) in
        evd, cstrs'
    with Univ.UniverseInconsistency e as exn ->
      let _, info = Exninfo.capture exn in
      CErrors.user_err ~hdr:"interp_constraint" ~info
        (Univ.explain_universe_inconsistency (Termops.pr_evd_level evd) e)
  in
  List.fold_left interp (evd,Univ.Constraint.empty) cstrs

let interp_univ_decl env decl =
  let open UState in
  let binders : lident list = decl.univdecl_instance in
  let evd = Evd.from_env ~binders env in
  let evd, cstrs = interp_univ_constraints env evd decl.univdecl_constraints in
  let decl = { univdecl_instance = binders;
    univdecl_extensible_instance = decl.univdecl_extensible_instance;
    univdecl_constraints = cstrs;
    univdecl_extensible_constraints = decl.univdecl_extensible_constraints }
  in evd, decl

let interp_univ_decl_opt env l =
  match l with
  | None -> Evd.from_env env, UState.default_univ_decl
  | Some decl -> interp_univ_decl env decl
