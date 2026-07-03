(* Demo / smoke test for minilwt.ml.
   Run with: cat minilwt.ml demo.ml | ocaml -I +unix unix.cma -stdin *)

(* return / bind / yield / sleep all in one chain. *)
let () =
  let result =
    run
      (let* () = yield () in
       Printf.printf "after yield\n%!";
       let* () = sleep 0.05 in
       Printf.printf "after sleep 50ms\n%!";
       let* x = return 40 in
       let* y = return 2 in
       return (x + y))
  in
  Printf.printf "result = %d (expected 42)\n%!" result

(* Concurrency: the shorter sleep must fire before the longer one. *)
let () =
  let order = ref [] in
  let record name () =
    order := name :: !order;
    return ()
  in
  run
    (let* () = bind (sleep 0.03) (record "long") in
     return ());
  (* register both before running so they race in the same loop *)
  order := [];
  ignore (bind (sleep 0.03) (record "long"));
  ignore (bind (sleep 0.01) (record "short"));
  run (sleep 0.05);
  Printf.printf "wake order = [%s] (expected short; long)\n%!"
    (String.concat "; " (List.rev !order))
