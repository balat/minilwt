(* Mini-Lwt on OCaml 5 effects: SEMANTICS-PRESERVING variant ("mbind").
   Same effect machinery as minilwt_eff_break.ml, but [bind] is the exact
   classic callback bind of minilwt.ml: non-blocking, so implicit concurrency
   is preserved ([both (a >>= f) (b >>= g)] starts both branches). Effects only
   ADD the [await] direct-style escape hatch on top. Compare the three files. *)

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

(* Exactly minilwt.ml's bind: post a callback and return at once, never suspend.
   The caller keeps running, so sibling branches all start: concurrency preserved.
   [await] above is still there for direct style, but [bind] never performs it. *)
let bind p f =
  let r = { state = Waiting [] } in
  on_resolve p (fun v -> on_resolve (f v) (wakeup r));
  r

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
