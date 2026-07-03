(* Mini-Lwt on OCaml 5 effects: SEMANTICS-BREAKING variant.
   Same monadic interface as minilwt.ml, but [bind] awaits (suspends the
   fiber), so concurrent branches run in series: [both (a >>= f) (b >>= g)]
   no longer starts a and b together. Compare with minilwt.ml (classic) and
   minilwt_eff_keep.ml (effects, semantics preserved). *)

type 'a t = { mutable state : 'a state }
and 'a state = Done of 'a | Waiting of ('a -> unit) list

let return v = { state = Done v }

let wakeup p v =
  match p.state with
  | Done _ -> invalid_arg "wakeup: already resolved"
  | Waiting waiters ->
      p.state <- Done v;
      List.iter (fun f -> f v) (List.rev waiters)

let on_resolve p f =
  match p.state with
  | Done v -> f v
  | Waiting waiters -> p.state <- Waiting (f :: waiters)

(* --- Effects --- *)

type _ Effect.t += Await : 'a t -> 'a Effect.t | Yield : unit Effect.t

let await p =
  match p.state with Done v -> v | Waiting _ -> Effect.perform (Await p)

let yield () = Effect.perform Yield

(* THE difference with the classic bind: on a pending promise the whole fiber
   suspends here, so a sibling branch cannot start until this one resolves.
   Implicit concurrency is lost. *)
let bind p f = f (await p)
let ( let* ) = bind

(* --- Scheduler --- *)

let ready = Queue.create () (* fibers ready to resume *)
let timers = ref [] (* (deadline, wake) pairs for sleep *)

let sleep delay =
  let p = { state = Waiting [] } in
  timers := (Unix.gettimeofday () +. delay, fun () -> wakeup p ()) :: !timers;
  p

(* [main] runs inside a fiber, under a handler written with the
   [match ... with effect ...] syntax (OCaml >= 5.3). On Await, park the
   continuation as a waiter that re-enqueues it once the promise resolves; on
   Yield, re-enqueue it at once. The run queue and timer loop are the same as
   the classic minilwt.ml. *)
let run main =
  let result = ref None in
  let fiber () =
    match result := Some (await (main ())) with
    | () -> ()
    | effect Await p, k ->
        on_resolve p (fun v -> Queue.add (fun () -> Effect.Deep.continue k v) ready)
    | effect Yield, k -> Queue.add (fun () -> Effect.Deep.continue k ()) ready
  in
  Queue.add fiber ready;
  let rec loop () =
    if not (Queue.is_empty ready) then (
      Queue.pop ready ();
      loop ())
    else
      match List.sort (fun (a, _) (b, _) -> compare a b) !timers with
      | [] -> ()
      | (t, wake) :: rest ->
          timers := rest;
          let dt = t -. Unix.gettimeofday () in
          if dt > 0. then Unix.sleepf dt;
          wake ();
          loop ()
  in
  loop ();
  match !result with Some v -> v | None -> failwith "run: deadlock"
