open Core_kernel.Std
open Bap.Std
open Regular.Std
open Bap_traces.Std
open Bap_future.Std

module SM = Monad.State
open SM.Monad_infix

type event = Trace.event [@@deriving bin_io, compare, sexp]
type 'a u = 'a Bil.Result.u
type 'a r = 'a Bil.Result.r
type 'a e = (event option, 'a) SM.t
type error = Veri_error.t
type matched = Veri_policy.matched [@@deriving bin_io, compare, sexp]
type rule = Veri_rule.t [@@deriving bin_io, compare, sexp]

let create_move_event tag cell' data' =  
  Value.create tag Move.({cell = cell'; data = data';})

let find tag evs cond =
  let open Option in
  List.find evs ~f:(fun ev -> match Value.get tag ev with
      | None -> false
      | Some mv -> cond mv) >>| fun ev -> Value.get_exn tag ev

let create_mem_store = create_move_event Event.memory_store
let create_mem_load  = create_move_event Event.memory_load
let create_reg_read  = create_move_event Event.register_read
let create_reg_write = create_move_event Event.register_write
let find_reg_read  = find Event.register_read
let find_reg_write = find Event.register_write
let find_mem_load  = find Event.memory_load
let find_mem_store = find Event.memory_store
let value = Bil.Result.value

module Disasm = struct  
  module Dis = Disasm_expert.Basic
  open Dis
  type t = (asm, kinds) Dis.t

  let insn dis mem = 
    match Dis.insn_of_mem dis mem with
    | Error er -> Error (`Disasm_error er)
    | Ok r -> match r with
      | mem', Some insn, `finished -> Ok (mem',insn)
      | _, None, _ -> 
        let er = Error.of_string "nothing was disasmed" in
        Error (`Disasm_error er)
      | _, _, `left _ -> Error `Overloaded_chunk

  let insn_name = Dis.Insn.name 
end

module Report = struct
  type t = {
    bil  : bil;
    insn : string;
    left : event list;
    right: event list;
    data : (rule * matched) list;
    code : string;
  } [@@deriving bin_io, compare, fields, sexp]

  include Regular.Make(struct 
      type nonrec t = t [@@deriving bin_io, compare, sexp]

      let compare = compare
      let hash = Hashtbl.hash
      let module_name = Some "Veri.Report"
      let version = "0.1"

      let pp_code fmt s =
        let pp fmt s =
          String.iter ~f:(fun c -> Format.fprintf fmt "%X " (Char.to_int c)) s in
        Format.fprintf fmt "@[<h>%a@]" pp s

      let pp_evs fmt evs =
        List.iter ~f:(fun ev -> 
            Format.(fprintf std_formatter "%a; " Value.pp ev)) evs

      let pp_data fmt (rule, matched) =
        let open Veri_policy in
        Format.fprintf fmt "%a\n%a" Veri_rule.pp rule Matched.pp matched

      let pp fmt t =
        Format.fprintf fmt "@[<v>%s %a@,left: %a@,right: %a@,%a@]@."
          t.insn pp_code t.code pp_evs t.left pp_evs t.right Bil.pp t.bil;
        List.iter ~f:(pp_data fmt) t.data;
        Format.print_newline ()

    end)
end

module Events = Value.Set

class context policy trace = object(self:'s)
  inherit Veri_traci.context trace as super
  val events = Events.empty
  val other  = None
  val stream = Stream.create ()
  val descr : string option = None
  val error : error option = None
  val bil   : bil = []
  val code  : Chunk.t option = None
  val stat  : Veri_stat.t = Veri_stat.create ()

  method set_code c = {< code = Some c >}
  method code = code

  method private make_report data =
    Report.Fields.create ~bil ~data
      ~right:(self#events |> Set.to_list)
      ~left:(Option.(value_exn self#other)#events |> Set.to_list)
      ~insn:(Option.value_exn descr)
      ~code:(Option.value_exn code |> Chunk.data)

  method merge: 's =
    let stat =
      match error with 
      | Some er -> Veri_stat.notify stat er
      | None ->
        match descr with
        | None -> stat
        | Some name ->
          let events = Option.(value_exn self#other)#events in
          let events' = self#events in
          match Veri_policy.denied policy name events events' with
          | [] -> Veri_stat.success stat name
          | results ->
            let report = self#make_report results in
            Signal.send (snd stream) report;
            Veri_stat.failbil stat name  in
    {<other = None; error = None; descr = None; bil = [];
      events = Events.empty; stat = stat; code = None >}

  method stat = stat  
  method events: Events.t = events
  method split = {<other = Some self; events = Events.empty; >}
  method other = other
  method set_description s = {<descr = Some s >}
  method register_event ev = {< events = Set.add events ev; >}

  method discard_event: (event -> bool) -> 's = fun f ->
    match Set.find events ~f with
    | None -> self
    | Some ev -> {< events = Set.remove events ev >}

  method notify_error er = {<error = Some er >}
  method set_bil bil = {< bil = bil >}
  method reports : Report.t stream = fst stream
end

let target_info arch = 
  let module Target = (val target_of_arch arch) in
  Target.CPU.mem, Target.lift 

let memory_of_chunk endian chunk = 
  Bigstring.of_string (Chunk.data chunk) |>
  Memory.create endian (Chunk.addr chunk) 

let other_events c = match c#other with 
  | None -> []
  | Some c -> Set.to_list c#events

let is_previous_mv tag test ev =
  match Value.get tag ev with
  | None -> false
  | Some mv -> Move.cell mv = test

let is_previous_write = is_previous_mv Event.register_write 
let is_previous_load  = is_previous_mv Event.memory_load 
let self_events c = Set.to_list c#events
let same_var  var  mv = var  = Move.cell mv
let same_addr addr mv = addr = Move.cell mv
let is_never_read events var = find_reg_read events (same_var var) = None

class ['a] t arch dis is_interesting =
  let endian = Arch.endian arch in
  let mem_var, lift = target_info arch in

  object(self)
    constraint 'a = #context
    inherit ['a] Veri_traci.t arch as super

    method private update_event ev =
      if is_interesting ev then SM.update (fun c -> c#register_event ev)
      else SM.return () 

    (** [resolve_var var] - returns a result, bound with [var].
        Sequence of searches is the following:
        1) among read events that occured at current step in the same context,
           with the same variable;
        2) among read events that occures at current step, in other context,
           with the same variable;
        3) in current context, for the same variable *)
    method private resolve_var : var -> 'a r = fun var ->
      SM.get () >>= fun ctxt ->
      match find_reg_read (self_events ctxt) (same_var var) with
      | Some mv -> self#eval_exp (Bil.int (Move.data mv))
      | None -> 
        match find_reg_read (other_events ctxt) (same_var var) with
        | Some mv -> self#eval_exp (Bil.int (Move.data mv))
        | None -> super#lookup var

    (** [lookup var] - returns a result, bound with variable.
        Search starts from self events, if it was write access to given 
        variable at current step. And if it was, then result of write 
        access returned and no read event is emitted.
        Otherwise searching continues as written above for [resolve_var], 
        with emitting register_read event. *)
    method! lookup var : 'a r =
      SM.get () >>= fun ctxt ->
      match find_reg_write (self_events ctxt) (same_var var) with
      | Some mv -> self#eval_exp (Bil.int (Move.data mv))
      | None ->
        self#resolve_var var >>= fun r ->
        match value r with
        | Bil.Imm data ->
          if not (Var.is_virtual var) then
            self#update_event (create_reg_read var data) >>= fun () ->
            SM.return r
          else SM.return r
        | Bil.Mem _ | Bil.Bot -> SM.return r

    method! update var result : 'a u =
      super#update var result >>= fun () ->
      match value result with
      | Bil.Imm data -> 
        if not (Var.is_virtual var) then
          SM.update (fun c -> c#discard_event (is_previous_write var)) >>= fun () ->
          self#update_event (create_reg_write var data)
        else SM.return ()
      | Bil.Mem _ | Bil.Bot -> SM.return ()

    method private eval_mem_event tag addr data : 'a e =
      match value addr, value data with
      | Bil.Imm addr, Bil.Imm data ->
        let ev = create_move_event tag addr data in
        SM.return (Some ev)
      | _ -> SM.return None

    method! eval_store ~mem ~addr data endian size =
      super#eval_store ~mem ~addr data endian size >>= fun r ->
      self#eval_exp addr >>= fun addr ->
      self#eval_exp data >>= fun data ->
      self#eval_mem_event Event.memory_store addr data >>=
      function
      | None -> SM.return r
      | Some ev -> self#update_event ev >>= fun () -> SM.return r

    method private store_and_load ~mem ~addr mv endian size =
      let data = Bil.int (Move.data mv) in
      super#eval_store ~mem ~addr data endian size >>= fun r -> 
      match value r with
      | Bil.Mem _ -> super#update mem_var r >>= fun () -> 
        super#eval_load ~mem ~addr endian size
      | Bil.Imm _ | Bil.Bot -> SM.return r 

    (** [resolve_addr addr] - returns a result, bound with [addr].
        Sequence of searches is the following: 
        1) among load events that occured at current step, in the same context,
           with the same address;
        2) among load events that occures at current step, in other context, 
           with the same address;
        3) in current context. *)
    method private resolve_addr ~mem ~addr endian size =
      self#eval_exp addr >>= fun addr_res ->
      match value addr_res with
      | Bil.Bot | Bil.Mem _ -> SM.return addr_res
      | Bil.Imm addr' ->
        SM.get () >>= fun ctxt ->
        match find_mem_load (self_events ctxt) (same_addr addr') with
        | Some mv -> self#store_and_load ~mem ~addr mv endian size
        | None ->
          match find_mem_load (other_events ctxt) (same_addr addr') with
          | None -> super#eval_load ~mem ~addr endian size
          | Some mv -> self#store_and_load ~mem ~addr mv endian size

    (** [eval_load ~mem ~addr endian size] - returns a result bound with [addr].
        Search starts from self events, if it was write access to given
        address at current step. And if it was, then result of write access 
        returned and no load event is emitted.
        Otherwise searching continues as written above for [resolve_addr], 
        with emitting memory load event. *)
    method! eval_load ~mem ~addr endian size =
      SM.get () >>= fun ctxt -> 
      self#eval_exp addr >>= fun addr_res ->
      match value addr_res with
      | Bil.Bot | Bil.Mem _ -> SM.return addr_res
      | Bil.Imm addr' ->
        match find_mem_store (self_events ctxt) (same_addr addr') with
        | Some mv -> self#eval_exp (Bil.int (Move.data mv))
        | None ->
          self#resolve_addr mem addr endian size >>= fun r ->          
          self#eval_mem_event Event.memory_load addr_res r >>= fun ev ->
          match ev with
          | Some ev -> self#update_event ev >>= fun () -> SM.return r
          | None -> SM.return r

    method private eval_insn (mem, insn) = 
      let name = Disasm.insn_name insn in
      SM.update (fun c -> c#set_description name) >>= fun () ->
      match lift mem insn with
      | Error er ->
        SM.update (fun c -> c#notify_error (`Lifter_error (name, er)))
      | Ok bil ->
        SM.update (fun c -> c#set_bil bil) >>= fun () ->
        self#eval bil

    method private eval_chunk chunk =
      SM.update (fun c -> c#set_code chunk) >>= fun () -> 
      match memory_of_chunk endian chunk with
      | Error er -> SM.update (fun c -> c#notify_error (`Damaged_chunk er))
      | Ok mem -> 
        match Disasm.insn dis mem with
        | Error er -> SM.update (fun c -> c#notify_error er)
        | Ok insn -> self#eval_insn insn

    method! eval_event ev = 
      let is_after_code () = 
        SM.get () >>= fun c -> 
        c#code <> None |> SM.return in
      match Value.get Event.code_exec ev with
      | Some code -> 
        self#verify_frame >>= fun () -> 
        SM.update (fun c -> c#set_code code)
      | None ->
        is_after_code () >>= fun r ->
        if r then self#update_event ev
        else SM.return ()

    method private eval_events evs = 
      List.fold ~init:(SM.return ())
        ~f:(fun sm ev -> sm >>= fun () -> 
             super#eval_event ev >>= fun () ->
             self#update_event ev) evs

    method private verify_frame : 'a u =
      SM.get () >>= fun ctxt -> 
      let code, side = ctxt#code, Set.to_list ctxt#events in
      match code with
      | Some code -> 
        SM.update (fun c -> c#split) >>= fun () ->
        self#eval_chunk code       >>= fun () ->
        SM.update (fun c -> c#merge)
      | None -> SM.return ()

    method! eval_trace trace =
      super#eval_trace trace >>= fun () -> self#verify_frame

  end
