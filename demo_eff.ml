(* Shared demo for the effect-based cores. Same code, two back ends:
     cat minilwt_eff_keep.ml  demo_eff.ml | ocaml -I +unix unix.cma -stdin
     cat minilwt_eff_break.ml demo_eff.ml | ocaml -I +unix unix.cma -stdin
   The second (breaking) runs the two sleeps in series, so "both" takes twice
   as long: that is the broken implicit concurrency. *)

(* return / bind / yield / sleep in one chain. *)
let () =
  let r =
    run (fun () ->
        yield ();
        Printf.printf "after yield\n%!";
        let* () = sleep 0.05 in
        Printf.printf "after sleep 50ms\n%!";
        let* x = return 40 in
        let* y = return 2 in
        return (x + y))
  in
  Printf.printf "result = %d (expected 42)\n%!" r

(* Implicit concurrency: two tasks that each bind on a sleep, run "together".
   keep: ~0.15s (concurrent). break: ~0.30s (serialised). *)
let () =
  let task label d =
    let* () = sleep d in
    Printf.printf "  %s done\n%!" label;
    return ()
  in
  let both a b =
    let* () = a in
    let* () = b in
    return ()
  in
  let t0 = Unix.gettimeofday () in
  run (fun () -> both (task "a" 0.15) (task "b" 0.15));
  Printf.printf "both of two 0.15s sleeps took %.2fs\n%!"
    (Unix.gettimeofday () -. t0)
