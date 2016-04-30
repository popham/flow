module Ast = Spider_monkey_ast
module Anno = Type_annotation
module Flow = Flow_js
module Utils = Utils_js

open Reason_js
open Type
open Destructuring

type binding = string * Type.t * Loc.t
type param =
  | Simple of Type.t * binding
  | Complex of Type.t * binding list
  | Rest of Type.t * binding
type t = {
  this: Type.t;
  rev_list: param list;
  defaults: Ast.Expression.t Default.t SMap.t;
}

let empty this = {
  this;
  rev_list = [];
  defaults = SMap.empty
}

(* Ast.Function.t -> Func_params.t *)
let mk cx type_params_map implicit_this func =
  let add_param params pattern default = Ast.Pattern.(
    match pattern with
    | loc, Identifier (_, { Ast.Identifier.name; typeAnnotation; optional }) ->
      let reason = mk_reason (Utils.spf "parameter `%s`" name) loc in
      let t = Anno.mk_type_annotation cx type_params_map reason typeAnnotation
      in (match default with
      | None ->
        let t =
          if optional
          then OptionalT t
          else t
        in
        Hashtbl.replace (Context.type_table cx) loc t;
        let binding = name, t, loc in
        let rev_list = Simple (t, binding) :: params.rev_list in
        { params with rev_list }
      | Some expr ->
        (* TODO: assert (not optional) *)
        let binding = name, t, loc in
        { this = params.this;
          rev_list = Simple (OptionalT t, binding) :: params.rev_list;
          defaults = SMap.add name (Default.Expr expr) params.defaults })
    | loc, _ ->
      let reason = mk_reason "destructuring" loc in
      let t = type_of_pattern pattern
        |> Anno.mk_type_annotation cx type_params_map reason in
      let default = Option.map default Default.expr in
      let bindings = ref [] in
      let defaults = ref params.defaults in
      pattern |> destructuring cx t None default (fun _ loc name default t ->
        Hashtbl.replace (Context.type_table cx) loc t;
        bindings := (name, t, loc) :: !bindings;
        Option.iter default ~f:(fun default ->
          defaults := SMap.add name default !defaults
        )
      );
      let t = match default with
        | Some _ -> OptionalT t
        | None -> t (* TODO: assert (not optional) *)
      in
      let param = Complex (t, !bindings) in
      { this = params.this;
        rev_list = param :: params.rev_list;
        defaults = !defaults })
  in
  let add_rest params =
    function loc, { Ast.Identifier.name; typeAnnotation; _ } ->
      let reason = mk_reason (Utils.spf "rest parameter `%s`" name) loc in
      let t =
        Anno.mk_type_annotation cx type_params_map reason typeAnnotation
      in
      let param = Rest (Anno.mk_rest cx t, (name, t, loc)) in
      { params with rev_list = param :: params.rev_list }
  in
  let {Ast.Function.this; params; defaults; rest; _} = func in
  let defaults =
    if defaults = [] && params <> []
    then List.map (fun _ -> None) params
    else defaults
  in
  let this = Ast.Type.Function.ThisParam.(match this with
    | Implicit loc ->
        let reason = mk_reason "implicit `this` pseudo-parameter" loc in
        Flow.reposition cx reason implicit_this
    | Explicit (loc, { Ast.Type.Function.Param.typeAnnotation; _ }) ->
        let reason = mk_reason "explicit `this` pseudo-parameter" loc in
        let anno = Some (loc, typeAnnotation) in
        Anno.mk_type_annotation cx type_params_map reason anno
  ) in
  let func_params = {
    this;
    rev_list = [];
    defaults = SMap.empty
  } in
  let func_params = List.fold_left2 add_param func_params params defaults in
  match rest with
  | Some ident -> add_rest func_params ident
  | None -> func_params

(* Ast.Type.Function.t -> Func_params.t *)
let convert cx type_params_map ?(static=false) func = Ast.Type.Function.(
  let add_param params (loc, {Param.name; typeAnnotation; optional; _}) =
    let _, {Ast.Identifier.name; _} = name in
    let t = Anno.convert cx type_params_map typeAnnotation in
    let t = if optional then OptionalT t else t in
    let binding = name, t, loc in
    { params with rev_list = Simple (t, binding) :: params.rev_list }
  in
  let add_rest params (loc, {Param.name; typeAnnotation; _}) =
    let _, {Ast.Identifier.name; _} = name in
    let t = Anno.convert cx type_params_map typeAnnotation in
    let param = Rest (Anno.mk_rest cx t, (name, t, loc)) in
    { params with rev_list = param :: params.rev_list }
  in
  let this = match static, func.Ast.Type.Function.this with
    | _, ThisParam.Explicit (_, {Param.typeAnnotation; _}) ->
        Anno.convert cx type_params_map typeAnnotation
    | false, ThisParam.Implicit implicit_loc ->
        Anno.this cx type_params_map implicit_loc
    | true, ThisParam.Implicit implicit_loc ->
        ClassT (Anno.this cx type_params_map implicit_loc)
  in
  let params = List.fold_left add_param (empty this) func.params in
  match func.rest with
  | Some ident -> add_rest params ident
  | None -> params
)

let this params = params.this

let names params =
  params.rev_list |> List.rev |> List.map (function
    | Simple (_, (name, _, _))
    | Rest (_, (name, _, _)) -> name
  | Complex _ -> "_")

let tlist params =
  params.rev_list |> List.rev |> List.map (function
    | Simple (t, _)
    | Complex (t, _)
    | Rest (t, _) -> t)

let iter f params =
  params.rev_list |> List.rev |> List.iter (function
    | Simple (_, b)
    | Rest (_, b) -> f b
    | Complex (_, bs) -> List.iter f bs)

let with_default name f params =
  match SMap.get name params.defaults with
  | Some t -> f t
  | None -> ()

let subst_binding cx map (name, t, loc) = (name, Flow.subst cx map t, loc)

let subst cx map params =
  let this = Flow.subst cx map params.this in
  let rev_list = params.rev_list |> List.map (function
    | Simple (t, b) ->
      Simple (Flow.subst cx map t, subst_binding cx map b)
    | Complex (t, bs) ->
      Complex (Flow.subst cx map t, List.map (subst_binding cx map) bs)
    | Rest (t, b) ->
      Rest (Flow.subst cx map t, subst_binding cx map b)) in
  { params with this; rev_list }
