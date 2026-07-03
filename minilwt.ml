(* Mini-Lwt: return, bind, sleep, yield in monadic style *)

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

let bind p f =
  let r = { state = Waiting [] } in
  on_resolve p (fun v -> on_resolve (f v) (wakeup r));
  r

let ( let* ) = bind

(* --- Scheduler --- *)

let ready = Queue.create () (* tasks woken up by yield *)
let timers = ref [] (* (deadline, wake) pairs for sleep *)

let yield () =
  let r = { state = Waiting [] } in
  Queue.add (fun () -> wakeup r ()) ready;
  r

let sleep delay =
  let r = { state = Waiting [] } in
  timers := (Unix.gettimeofday () +. delay, fun () -> wakeup r ()) :: !timers;
  r

let rec run p =
  match p.state with
  | Done v -> v
  | Waiting _ ->
      (if not (Queue.is_empty ready) then Queue.pop ready ()
       else
         match List.sort (fun (a, _) (b, _) -> compare a b) !timers with
         | [] -> failwith "run: nothing left to run"
         | (t, wake) :: rest ->
             timers := rest;
             let dt = t -. Unix.gettimeofday () in
             if dt > 0. then Unix.sleepf dt;
             wake ());
      run p
