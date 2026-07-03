# minilwt

Ultra-minimal, single-file implementations of an [Lwt](https://github.com/ocsigen/lwt)-style
promise library, written to be shown on slides. Each core is one short `.ml`
file exposing only `return`, `bind` (`let*`), `sleep`, `yield` and `run`.

There are **three cores**, meant to be compared side by side:

| File | `bind` | Implicit concurrency |
|---|---|---|
| [`minilwt.ml`](minilwt.ml) | callback (classic) | preserved |
| [`minilwt_eff_break.ml`](minilwt_eff_break.ml) | `f (await p)` (suspends) | **broken** |
| [`minilwt_eff_keep.ml`](minilwt_eff_keep.ml) | callback (= classic) | preserved |

A visual slide deck is in [`slides.html`](slides.html) (open it in a browser).
What follows is **the text version of those slides**.

---

## Slide 1 — minilwt

Three tiny promise schedulers, one idea at a time.

Classic monadic Lwt, and two ways to put it on OCaml 5 effects.

## Slide 2 — Why

- Lwt is **promises + a monadic `bind`**. The type `'a Lwt.t` marks, in the
  signature, that a function is asynchronous. Lwt users rely on that.
- OCaml 5 brought **effects** (Eio, Miou, ...) and, with them, fast direct-style
  schedulers. Can we get that speed while keeping Lwt's monadic type and 100%
  compatibility with existing code?
- To reason about it, shrink Lwt to its essence and compare three cores that
  differ in exactly one function: `bind`.

## Slide 3 — A promise, minimally

All three cores share the same promise cell and the same two operations.

```ocaml
type 'a t = { mutable state : 'a state }
and 'a state = Done of 'a | Waiting of ('a -> unit) list

let return v = { state = Done v }

(* resolve a pending promise and fire its callbacks *)
let wakeup p v = match p.state with
  | Done _ -> invalid_arg "wakeup: already resolved"
  | Waiting waiters ->
      p.state <- Done v; List.iter (fun f -> f v) (List.rev waiters)

(* run a callback now if resolved, else register it *)
let on_resolve p f = match p.state with
  | Done v -> f v
  | Waiting waiters -> p.state <- Waiting (f :: waiters)
```

## Slide 4 — Two ways to suspend: `sleep` and `yield`

Shared by all three: a queue of ready tasks (for `yield`) and a list of timers
(for `sleep`). Each returns a pending promise and schedules its own wake-up.

```ocaml
let ready  = Queue.create ()   (* tasks from yield *)
let timers = ref []            (* (deadline, wake) for sleep *)

let sleep delay =              (* resolves after [delay] seconds *)
  let p = { state = Waiting [] } in
  timers := (Unix.gettimeofday () +. delay, fun () -> wakeup p ()) :: !timers;
  p

let yield () =                 (* resolves on the next tick *)
  let p = { state = Waiting [] } in
  Queue.add (fun () -> wakeup p ()) ready;
  p
```

## Slide 5 — The run loop (`run`)

Also shared by all three. `run` drains the ready queue; when it is empty, it
sleeps until the earliest timer is due and fires it; it stops when the main
promise is `Done`.

```ocaml
let rec run p = match p.state with
  | Done v -> v
  | Waiting _ ->
      (if not (Queue.is_empty ready) then Queue.pop ready ()
       else match List.sort (fun (a, _) (b, _) -> compare a b) !timers with
         | [] -> failwith "run: nothing left to run"
         | (t, wake) :: rest ->
             timers := rest;
             let dt = t -. Unix.gettimeofday () in
             if dt > 0. then Unix.sleepf dt;
             wake ());
      run p
```

## Slide 6 — Version 1: classic monadic (`minilwt.ml`)

`bind` posts a callback and **returns a fresh result promise at once**. The
caller keeps running, so sibling branches all start: this is Lwt's *implicit
concurrency*. No effects anywhere. `run : 'a t -> 'a` takes the promise directly.

```ocaml
let bind p f =
  let r = { state = Waiting [] } in
  on_resolve p (fun v -> on_resolve (f v) (wakeup r));
  r

let ( let* ) = bind
```

A chain of `bind`s is a chain of callbacks, fired as promises resolve.

## Slide 7 — Enter effects

OCaml 5 lets you **`perform` an effect** to suspend the current fiber; a
**handler** decides what to do with the captured continuation `k`. Since OCaml
5.3 a handler is written as an ordinary `match`, whose three kinds of cases map
one-to-one to the `{ retc; exnc; effc }` handler record:

```ocaml
type _ Effect.t += Await : 'a t -> 'a Effect.t | Yield : unit Effect.t

let await p = match p.state with
  | Done v -> v
  | Waiting _ -> Effect.perform (Await p)

(* a handler is just a match: *)
match compute () with
| v            -> ...    (* retc: normal result *)
| exception e  -> ...    (* exnc: an exception (omitted below => propagates) *)
| effect E, k  -> ...    (* effc: effect E, with its continuation k *)
```

Resuming `k` re-enters the computation under that same handler.

## Slide 8 — The effect `run`: running fibers

The effect cores reuse the **exact same ready/timers loop** as version 1. They
only add a fiber wrapper around `main`, whose handler is written with the
`match ... with effect ...` syntax. So `run` takes `unit -> 'a t` (not `'a t`):
the awaits must happen *inside* the fiber.

```ocaml
let run main =                       (* run : (unit -> 'a t) -> 'a *)
  let result = ref None in
  let fiber () =
    match result := Some (await (main ())) with
    | () -> ()                       (* main resolved *)
    | effect Await p, k ->           (* park k; resume when p resolves *)
        on_resolve p (fun v -> Queue.add (fun () -> Effect.Deep.continue k v) ready)
    | effect Yield, k ->
        Queue.add (fun () -> Effect.Deep.continue k ()) ready
  in
  Queue.add fiber ready;
  loop ();                           (* the SAME ready/timers loop as V1 *)
  match !result with Some v -> v | None -> failwith "run: deadlock"
```

The three `match` cases *are* the whole handler: no record, no GADT annotation.

## Slide 9 — Version 2: effects, but it breaks the semantics (`minilwt_eff_break.ml`)

```ocaml
let bind p f = f (await p)
```

That is the whole bind. It is tempting: the shortest possible definition, and
the native stack is preserved across the `await`.

But on a **pending** promise, `await` **suspends the whole fiber**: `bind` does
not return until `p` resolves. So `both (a >>= f) (b >>= g)` cannot start `b`
until `a` is finished. The branches run **in series**. Implicit concurrency is
silently lost.

## Slide 10 — The bug, on the clock

`demo_eff.ml` runs `both (task "a" 0.15) (task "b" 0.15)`, two tasks that each
`sleep` then print:

- `minilwt_eff_break.ml`: about **0.30 s** (a, then b) — serialised.
- classic Lwt would run them together, in about 0.15 s.

## Slide 11 — Version 3: effects, semantics preserved ("mbind") (`minilwt_eff_keep.ml`)

Same effect machinery as version 2. But `bind` is **byte-for-byte the classic
callback bind of version 1**:

```ocaml
let bind p f =
  let r = { state = Waiting [] } in
  on_resolve p (fun v -> on_resolve (f v) (wakeup r));
  r
```

Non-blocking again, so concurrency is preserved: `both` takes about **0.15 s**.
And `await` is still available as an **opt-in, direct-style escape hatch** (for
loops, native `try/with`, real backtraces) that `bind` itself never uses.

## Slide 12 — Side by side

```ocaml
(* classic (V1) and effects-preserving (V3): same bind *)
let bind p f =
  let r = { state = Waiting [] } in
  on_resolve p (fun v -> on_resolve (f v) (wakeup r));
  r

(* effects, semantics broken (V2): bind awaits, so it serialises *)
let bind p f = f (await p)
```

| | V1 classic | V2 broken | V3 preserved |
|---|---|---|---|
| `bind` | callback | `f (await p)` | callback (= V1) |
| implicit concurrency | preserved | **broken** | preserved |
| `run` | `'a t -> 'a` | `(unit -> 'a t) -> 'a` | `(unit -> 'a t) -> 'a` |
| `yield` | `unit -> unit t` | `unit -> unit` | `unit -> unit` |
| direct-style `await` | no | yes (it *is* bind) | yes (opt-in) |

## Slide 13 — Takeaways

- The **preserving** effect `bind` *is* the classic `bind`. Effects do not
  replace the monad; they add a direct-style `await` escape hatch and a lean
  scheduler underneath, while the monadic type keeps marking async in the
  signature.
- The one-liner `bind = f (await p)` is seductive but **silently changes what a
  program means** (it destroys implicit concurrency).
- This is the boiled-down teaching model of a larger experiment: a full
  effects-based Lwt core with an io_uring back end.

## Slide 14 — Run it

```sh
cat minilwt.ml            demo.ml     | ocaml -I +unix unix.cma -stdin
cat minilwt_eff_keep.ml   demo_eff.ml | ocaml -I +unix unix.cma -stdin
cat minilwt_eff_break.ml  demo_eff.ml | ocaml -I +unix unix.cma -stdin
```

`ocaml a.ml b.ml` does not work as a runner: the toplevel treats only the first
file as the script and the rest as command-line arguments. Hence the
concatenate-and-pipe form.

---

## Scope

These are teaching examples, kept as small as possible. They deliberately omit
everything not needed to make the point: rejection and error handling (`fail` /
`catch`), cancellation, promise proxying, fiber-local storage, real I/O, and the
array-backed run queue of a production scheduler. `Unix` is used only for a
clock and to block the process between timers.

## Requirements

OCaml >= 5.0 (for effects) and the `unix` library, both shipped with the
compiler.

## License

MIT. See [LICENSE](LICENSE).
