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
What follows is **the text version of those slides** — one section per slide,
in order, with some extra prose the slides leave to the speaker. See also the
[Files](#files) section at the end.

---

## Slide 1 — minilwt

Three tiny promise schedulers, one idea at a time.

Classic monadic Lwt, and two ways to put it on OCaml 5 effects: one that
**breaks** the semantics and one that **keeps** them.

## Slide 2 — Why compare?

- Lwt is **promises + a monadic `bind`**. The type `'a Lwt.t` marks, in the
  signature, that a function is asynchronous. Lwt users rely on that.
- OCaml 5 brought **effects** (Eio, Miou, ...) and, with them, fast direct-style
  schedulers. Can we get that speed while keeping Lwt's monadic type and 100%
  compatibility with existing code?
- To reason about it, shrink Lwt to its essence and compare three cores that
  differ in exactly one function: `bind`.

## Slide 3 — A promise, minimally

All three cores share the same promise cell and the same two operations. A
promise is a mutable cell that is either resolved (`Done v`) or still pending
(`Waiting` on a list of callbacks to run once it resolves).

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

`on_resolve` is the workhorse: it hides the resolved-vs-pending distinction, so
the rest of the code never special-cases it.

## Slide 4 — Two ways to suspend: `sleep` and `yield`

Shared by all three: a queue of ready tasks (for `yield`) and a list of timers
(for `sleep`). Each returns a pending promise and schedules its own wake-up —
`yield` on the next loop turn, `sleep` when its deadline is due.

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

The `failwith` is a **deadlock** check: if `p` is still pending but both the
ready queue and the timer list are empty, nothing can ever wake `p` (those are
the only sources of a future `wakeup`). Rather than hang forever, `run` reports
it. A real scheduler would not stop here — it would block waiting for external
I/O events; minilwt has none, so empty queues really do mean "stuck".

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

## Slide 7 — bind, explained: why two `on_resolve`?

This is the one subtle line, so it is worth unfolding. `bind : 'a t -> ('a -> 'b t) -> 'b t`
must return a `'b t` **immediately**, without blocking. But at call time `p` may
still be pending, so we do not have `v` yet, so we cannot call `f v` yet, so we
have no `'b t` to hand back. The fix: allocate a placeholder `r`, return it now,
and promise to fill it later.

Filling it means crossing **two levels of waiting**, one `on_resolve` each:

```ocaml
let bind p f =                 (* f : 'a -> 'b t  — returns a PROMISE *)
  let r = { state = Waiting [] } in
  on_resolve p (fun v ->               (* 1. wait for p : 'a *)
    on_resolve (f v) (wakeup r));      (* 2. then wait for (f v), copy into r *)
  r
```

1. **First `on_resolve p`** — wait for `p` to produce `v : 'a`.
2. Compute `f v`. This is not a value: it is **another promise** `'b t` (maybe
   itself pending — another `sleep`, some I/O...). So we must wait for it too.
   **Second `on_resolve (f v)`** — when it produces its value `w : 'b`, copy it
   into `r` with `wakeup r` (partially applied: `wakeup r : 'b -> unit`).

The second `on_resolve` is precisely the monadic **flatten** (join): `f v` is a
`'b t`, `r` is a `'b t`, and we make `r` mirror `f v`.

Compare with `map` (not in the file), whose function returns a plain value:

```ocaml
let map g p =                  (* g : 'a -> 'b, a VALUE *)
  let r = { state = Waiting [] } in
  on_resolve p (fun v -> wakeup r (g v));    (* ONE wait: g v is ready *)
  r
```

`map` needs only one `on_resolve`. That is exactly functor (one level) vs monad
(two levels). Writing `on_resolve p (fun v -> wakeup r (f v))` for `bind` would
even be a **type error**: `wakeup r` expects a `'b`, but `f v` is a `'b t`. The
compiler forces the second level on you.

(Thanks to `on_resolve`'s `Done` branch, the same code also handles the
already-resolved case with no special-casing: the callback just runs on the
spot.)

## Slide 8 — Enter effects

OCaml 5 lets you **`perform` an effect** to suspend the current fiber; a
**handler** decides what to do with the captured continuation `k`.

```ocaml
type _ Effect.t += Await : 'a t -> 'a Effect.t | Yield : unit Effect.t

let await p = match p.state with
  | Done v -> v
  | Waiting _ -> Effect.perform (Await p)
```

`perform` suspends the current fiber and hands its continuation `k` to the
enclosing handler, which parks `k` as a waiter and re-enqueues it (with
`Effect.Deep.continue k v`) once the awaited promise resolves. Resuming `k`
re-enters under the same handler.

## Slide 9 — The effect `run`: running fibers

A *fiber* is a lightweight thread of control, started under the handler. V1 had
no separate `loop`: its `run` *was* the loop (slide 5). Here the driving policy
is the same (drain the ready queue, else fire the nearest timer), but written as
an inner `loop`, because the result now comes back through a ref rather than
from `run`'s own return. On top of that, the effect `run` adds only the handler
and a fiber wrapper around `main`. So it takes `unit -> 'a t` (not `'a t`): the
awaits must happen *inside* the fiber, under the handler.

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
  (* same policy as V1's run (slide 5): ready first, else nearest timer *)
  let rec loop () =
    if not (Queue.is_empty ready) then (Queue.pop ready (); loop ())
    else match List.sort (fun (a, _) (b, _) -> compare a b) !timers with
      | [] -> ()
      | (t, wake) :: rest ->
          timers := rest;
          let dt = t -. Unix.gettimeofday () in
          if dt > 0. then Unix.sleepf dt;
          wake (); loop ()
  in
  loop ();
  match !result with Some v -> v | None -> failwith "run: deadlock"
```

This scheduler skeleton is generic — Eio and Miou have the same shape; what
makes it Lwt is the promise `'a t` and the monadic `bind`, not the engine.

## Slide 10 — Version 2: effects, but it breaks the semantics (`minilwt_eff_break.ml`)

```ocaml
let bind p f = f (await p)
```

That is the whole bind. It is tempting: the shortest possible definition, and
the native stack is preserved across the `await`.

But on a **pending** promise, `await` **suspends the whole fiber**: `bind` does
not return until `p` resolves. So `both (a >>= f) (b >>= g)` cannot start `b`
until `a` is finished. The branches run **in series**. Implicit concurrency is
silently lost.

## Slide 11 — The bug, on the clock

The demo (`demo_eff.ml`) builds `both` and a `task` out of the very same five
primitives, then times two tasks that each sleep:

```ocaml
let task label d =
  let* () = sleep d in Printf.printf "%s done\n" label; return ()
let both a b = let* () = a in let* () = b in return ()

run (fun () -> both (task "a" 0.15) (task "b" 0.15))
```

- `minilwt_eff_keep.ml` (and the classic core): about **0.15 s** — concurrent.
- `minilwt_eff_break.ml`: about **0.30 s** — serialised.

Why: OCaml evaluates the two arguments of `both` *before* calling it. With the
non-blocking `bind`, each `task ...` call starts its `sleep` timer and returns a
pending promise right away, so **both timers are armed at once** → 0.15 s. With
`bind = f (await p)`, evaluating the first `task ...` suspends the fiber on its
`sleep`; the second `task ...` (and its timer) is only reached 0.15 s later →
0.30 s. That single difference is the whole gap, made visible on the clock.

## Slide 12 — Version 3: effects, semantics preserved ("mbind") (`minilwt_eff_keep.ml`)

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

## Slide 13 — Side by side

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

## Slide 14 — Takeaways

- The **preserving** effect `bind` *is* the classic `bind`. Effects do not
  replace the monad; they add a direct-style `await` escape hatch and a lean
  scheduler underneath, while the monadic type keeps marking async in the
  signature.
- The one-liner `bind = f (await p)` is seductive but **silently changes what a
  program means** (it destroys implicit concurrency).
- This is the boiled-down teaching model of a larger experiment: a full
  effects-based Lwt core with an io_uring back end.

## Slide 15 — Run it

```sh
cat minilwt.ml            demo.ml     | ocaml -I +unix unix.cma -stdin
cat minilwt_eff_keep.ml   demo_eff.ml | ocaml -I +unix unix.cma -stdin
cat minilwt_eff_break.ml  demo_eff.ml | ocaml -I +unix unix.cma -stdin
```

`ocaml a.ml b.ml` does not work as a runner: the toplevel treats only the first
file as the script and the rest as command-line arguments. Hence the
concatenate-and-pipe form.

---

## Files

| File | What it is |
|---|---|
| [`minilwt.ml`](minilwt.ml) | Version 1: classic monadic core (no effects). |
| [`minilwt_eff_break.ml`](minilwt_eff_break.ml) | Version 2: effects, semantics broken (`bind = f (await p)`). |
| [`minilwt_eff_keep.ml`](minilwt_eff_keep.ml) | Version 3: effects, semantics preserved ("mbind"). |
| [`demo.ml`](demo.ml) | Smoke test for the classic core (all four primitives + timer ordering). |
| [`demo_eff.ml`](demo_eff.ml) | Shared smoke test for both effect cores; defines `both`/`task` and times the concurrency (keep ~0.15 s, break ~0.30 s). |
| [`slides.html`](slides.html) | Self-contained HTML slide deck (open in a browser; `←`/`→`, space, `f` for fullscreen). |

## Scope

These are teaching examples, kept as small as possible. They deliberately omit
everything not needed to make the point: rejection and error handling (`fail` /
`catch`), cancellation, promise proxying, fiber-local storage, real I/O, and the
array-backed run queue of a production scheduler. `Unix` is used only for a
clock and to block the process between timers.

## Requirements

OCaml >= 5.3 (needed by the effect cores) and the `unix` library, both shipped
with the compiler.

## License

MIT. See [LICENSE](LICENSE).
