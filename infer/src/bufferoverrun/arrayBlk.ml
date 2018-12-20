(*
 * Copyright (c) 2016-present, Programming Research Laboratory (ROPAS)
 *                             Seoul National University, Korea
 * Copyright (c) 2017-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
(* Abstract Array Block *)
open! IStd
open AbsLoc
open! AbstractDomain.Types
module Bound = Bounds.Bound
module F = Format
module L = Logging

module ArrInfo = struct
  type t = C of {offset: Itv.t; size: Itv.t; stride: Itv.t} | Java of {length: Itv.t} | Top
  [@@deriving compare]

  let top : t = Top

  let make_c : offset:Itv.t -> size:Itv.t -> stride:Itv.t -> t =
   fun ~offset ~size ~stride -> C {offset; size; stride}


  let make_java : length:Itv.t -> t = fun ~length -> Java {length}

  let join : t -> t -> t =
   fun a1 a2 ->
    if phys_equal a1 a2 then a2
    else
      match (a1, a2) with
      | ( C {offset= offset1; size= size1; stride= stride1}
        , C {offset= offset2; size= size2; stride= stride2} ) ->
          C
            { offset= Itv.join offset1 offset2
            ; size= Itv.join size1 size2
            ; stride= Itv.join stride1 stride2 }
      | Java {length= length1}, Java {length= length2} ->
          Java {length= Itv.join length1 length2}
      | _ ->
          Top


  let widen : prev:t -> next:t -> num_iters:int -> t =
   fun ~prev ~next ~num_iters ->
    if phys_equal prev next then next
    else
      match (prev, next) with
      | ( C {offset= offset1; size= size1; stride= stride1}
        , C {offset= offset2; size= size2; stride= stride2} ) ->
          C
            { offset= Itv.widen ~prev:offset1 ~next:offset2 ~num_iters
            ; size= Itv.widen ~prev:size1 ~next:size2 ~num_iters
            ; stride= Itv.widen ~prev:stride1 ~next:stride2 ~num_iters }
      | Java {length= length1}, Java {length= length2} ->
          Java {length= Itv.widen ~prev:length1 ~next:length2 ~num_iters}
      | _ ->
          Top


  let ( <= ) : lhs:t -> rhs:t -> bool =
   fun ~lhs ~rhs ->
    if phys_equal lhs rhs then true
    else
      match (lhs, rhs) with
      | ( C {offset= offset1; size= size1; stride= stride1}
        , C {offset= offset2; size= size2; stride= stride2} ) ->
          Itv.le ~lhs:offset1 ~rhs:offset2 && Itv.le ~lhs:size1 ~rhs:size2
          && Itv.le ~lhs:stride1 ~rhs:stride2
      | Java {length= length1}, Java {length= length2} ->
          Itv.le ~lhs:length1 ~rhs:length2
      | _, Top ->
          true
      | _ ->
          false


  let map_offset : f:(Itv.t -> Itv.t) -> t -> t =
   fun ~f arr ->
    match arr with
    | C {offset; size; stride} ->
        C {offset= f offset; size; stride}
    | Java _ ->
        L.(die InternalError) "Unexpected pointer arithmetics on Java array"
    | Top ->
        Top


  let plus_offset : t -> Itv.t -> t = fun arr i -> map_offset arr ~f:(Itv.plus i)

  let minus_offset : t -> Itv.t -> t =
   fun arr i -> map_offset arr ~f:(fun offset -> Itv.minus offset i)


  let diff : t -> t -> Itv.t =
   fun arr1 arr2 ->
    match (arr1, arr2) with
    | C {offset= offset1}, C {offset= offset2} ->
        Itv.minus offset1 offset2
    | Java _, _ | _, Java _ ->
        L.(die InternalError) "Unexpected pointer arithmetics on Java array"
    | Top, _ | _, Top ->
        Itv.top


  let subst : t -> Bound.eval_sym -> t =
   fun arr eval_sym ->
    match arr with
    | C {offset; size; stride} ->
        C {offset= Itv.subst offset eval_sym; size= Itv.subst size eval_sym; stride}
    | Java {length} ->
        Java {length= Itv.subst length eval_sym}
    | Top ->
        Top


  let pp : F.formatter -> t -> unit =
   fun f arr ->
    match arr with
    | C {offset; size} ->
        F.fprintf f "offset : %a, size : %a" Itv.pp offset Itv.pp size
    | Java {length} ->
        F.fprintf f "length : %a" Itv.pp length
    | Top ->
        F.pp_print_string f SpecialChars.down_tack


  let get_symbols : t -> Itv.SymbolSet.t =
   fun arr ->
    match arr with
    | C {offset; size; stride} ->
        let s1 = Itv.get_symbols offset in
        let s2 = Itv.get_symbols size in
        let s3 = Itv.get_symbols stride in
        Itv.SymbolSet.union3 s1 s2 s3
    | Java {length} ->
        Itv.get_symbols length
    | Top ->
        Itv.SymbolSet.empty


  let normalize : t -> t =
   fun arr ->
    match arr with
    | C {offset; size; stride} ->
        C {offset= Itv.normalize offset; size= Itv.normalize size; stride= Itv.normalize stride}
    | Java {length} ->
        Java {length= Itv.normalize length}
    | Top ->
        Top


  let prune_offset : f:(Itv.t -> Itv.t -> Itv.t) -> t -> t -> t =
   fun ~f arr1 arr2 ->
    match arr2 with
    | C {offset= offset2} ->
        map_offset arr1 ~f:(fun offset1 -> f offset1 offset2)
    | Java _ | Top ->
        arr1


  let prune_comp : Binop.t -> t -> t -> t =
   fun c arr1 arr2 -> prune_offset arr1 arr2 ~f:(Itv.prune_comp c)


  let prune_eq : t -> t -> t = fun arr1 arr2 -> prune_offset arr1 arr2 ~f:Itv.prune_eq

  let prune_ne : t -> t -> t = fun arr1 arr2 -> prune_offset arr1 arr2 ~f:Itv.prune_ne

  let set_length : Itv.t -> t -> t =
   fun size arr ->
    match arr with
    | C {offset; stride} ->
        C {offset; size; stride}
    | Java _ ->
        Java {length= size}
    | Top ->
        Top


  let transform_length : f:(Itv.t -> Itv.t) -> t -> t =
   fun ~f arr ->
    match arr with
    | C {offset; size; stride} ->
        C {offset; size= f size; stride}
    | Java {length} ->
        Java {length= f length}
    | Top ->
        Top


  (* Set new stride only when the previous stride is a constant interval. *)
  let set_stride : Z.t -> t -> t =
   fun new_stride arr ->
    match arr with
    | C {offset; size; stride} ->
        Option.value_map (Itv.is_const stride) ~default:arr ~f:(fun stride ->
            assert ((not Z.(equal stride zero)) && not Z.(equal new_stride zero)) ;
            if Z.equal new_stride stride then arr
            else
              let set itv = Itv.div_const (Itv.mult_const itv stride) new_stride in
              C {offset= set offset; size= set size; stride= Itv.of_big_int new_stride} )
    | Java _ ->
        L.(die InternalError) "Unexpected cast on Java array"
    | Top ->
        Top


  let offsetof = function C {offset} -> offset | Java _ -> Itv.zero | Top -> Itv.top

  let sizeof = function C {size} -> size | Java {length} -> length | Top -> Itv.top

  let byte_size = function
    | C {size; stride} ->
        Itv.mult size stride
    | Java _ ->
        L.(die InternalError) "Unexpected byte-size operation on Java array"
    | Top ->
        Itv.top


  let lift_cmp_itv cmp_itv arr1 arr2 =
    match (arr1, arr2) with
    | ( C {offset= offset1; size= size1; stride= stride1}
      , C {offset= offset2; size= size2; stride= stride2} )
      when Itv.eq stride1 stride2 && Itv.eq size1 size2 ->
        cmp_itv offset1 offset2
    | Java {length= length1}, Java {length= length2} when Itv.eq length1 length2 ->
        cmp_itv Itv.zero Itv.zero
    | _ ->
        Boolean.Top
end

include AbstractDomain.Map (Allocsite) (ArrInfo)

let bot : t = empty

let unknown : t = add Allocsite.unknown ArrInfo.top bot

let is_bot : t -> bool = is_empty

let make_c : Allocsite.t -> offset:Itv.t -> size:Itv.t -> stride:Itv.t -> t =
 fun a ~offset ~size ~stride -> singleton a (ArrInfo.make_c ~offset ~size ~stride)


let make_java : Allocsite.t -> length:Itv.t -> t =
 fun a ~length -> singleton a (ArrInfo.make_java ~length)


let join_itv : f:(ArrInfo.t -> Itv.t) -> t -> Itv.t =
 fun ~f a -> fold (fun _ arr -> Itv.join (f arr)) a Itv.bot


let offsetof = join_itv ~f:ArrInfo.offsetof

let sizeof = join_itv ~f:ArrInfo.sizeof

let sizeof_byte = join_itv ~f:ArrInfo.byte_size

let plus_offset : t -> Itv.t -> t = fun arr i -> map (fun a -> ArrInfo.plus_offset a i) arr

let minus_offset : t -> Itv.t -> t = fun arr i -> map (fun a -> ArrInfo.minus_offset a i) arr

let diff : t -> t -> Itv.t =
 fun arr1 arr2 ->
  let diff_join k a2 acc =
    match find k arr1 with
    | a1 ->
        Itv.join acc (ArrInfo.diff a1 a2)
    | exception Caml.Not_found ->
        Itv.top
  in
  fold diff_join arr2 Itv.bot


let get_pow_loc : t -> PowLoc.t =
 fun array ->
  let pow_loc_of_allocsite k _ acc = PowLoc.add (Loc.of_allocsite k) acc in
  fold pow_loc_of_allocsite array PowLoc.bot


let subst : t -> Bound.eval_sym -> PowLoc.eval_locpath -> t =
 fun a eval_sym eval_locpath ->
  let subst1 l info acc =
    let info' = ArrInfo.subst info eval_sym in
    match Allocsite.get_param_path l with
    | None ->
        add l info' acc
    | Some path ->
        let locs = eval_locpath path in
        let add_allocsite l acc = match l with Loc.Allocsite a -> add a info' acc | _ -> acc in
        PowLoc.fold add_allocsite locs acc
  in
  fold subst1 a empty


let get_symbols : t -> Itv.SymbolSet.t =
 fun a ->
  fold (fun _ ai acc -> Itv.SymbolSet.union acc (ArrInfo.get_symbols ai)) a Itv.SymbolSet.empty


let normalize : t -> t = fun a -> map ArrInfo.normalize a

let do_prune : (ArrInfo.t -> ArrInfo.t -> ArrInfo.t) -> t -> t -> t =
 fun arr_info_prune a1 a2 ->
  match is_singleton_or_more a2 with
  | IContainer.Singleton (k, v2) ->
      update k (Option.map ~f:(fun v -> arr_info_prune v v2)) a1
  | _ ->
      a1


let prune_comp : Binop.t -> t -> t -> t = fun c a1 a2 -> do_prune (ArrInfo.prune_comp c) a1 a2

let prune_eq : t -> t -> t = fun a1 a2 -> do_prune ArrInfo.prune_eq a1 a2

let prune_ne : t -> t -> t = fun a1 a2 -> do_prune ArrInfo.prune_ne a1 a2

let set_length : Itv.t -> t -> t = fun length a -> map (ArrInfo.set_length length) a

let set_stride : Z.t -> t -> t = fun stride a -> map (ArrInfo.set_stride stride) a

let lift_cmp_itv cmp_itv cmp_loc arr1 arr2 =
  match (is_singleton_or_more arr1, is_singleton_or_more arr2) with
  | IContainer.Singleton (as1, ai1), IContainer.Singleton (as2, ai2) ->
      Boolean.EqualOrder.(
        of_equal
          {on_equal= ArrInfo.lift_cmp_itv cmp_itv ai1 ai2; on_not_equal= cmp_loc.on_not_equal}
          (Allocsite.eq as1 as2))
  | _ ->
      Boolean.Top


let transform_length : f:(Itv.t -> Itv.t) -> t -> t =
 fun ~f a -> map (ArrInfo.transform_length ~f) a
