open Base
open Torch
module E = Vec_env_gym_pyml

let atari_game = "SpaceInvadersNoFrameskip-v4"
let num_steps = 5
let updates = 1_000_000
let num_procs = 16
let num_stack = 4

type actor_critic =
  { actor : Tensor.t
  ; critic : Tensor.t }

let model vs ~actions =
  let conv1 = Layer.conv2d_ vs ~ksize:8 ~stride:4 ~input_dim:num_stack 32 in
  let conv2 = Layer.conv2d_ vs ~ksize:4 ~stride:2 ~input_dim:32 64 in
  let conv3 = Layer.conv2d_ vs ~ksize:3 ~stride:1 ~input_dim:64 64 in
  let linear1 = Layer.linear vs ~input_dim:(64 * 7 * 7) 512 in
  let critic_linear = Layer.linear vs ~input_dim:512 1 in
  let actor_linear = Layer.linear vs ~input_dim:512 actions in
  fun xs ->
    let ys =
      Tensor.to_device xs ~device:(Var_store.device vs)
      |> Layer.apply conv1
      |> Tensor.relu
      |> Layer.apply conv2
      |> Tensor.relu
      |> Layer.apply conv3
      |> Tensor.relu
      |> Tensor.flatten
      |> Layer.apply linear1
      |> Tensor.relu
    in
    {critic = Layer.apply critic_linear ys; actor = Layer.apply actor_linear ys}

module Frame_stack : sig
  type t

  val create : unit -> t
  val update : t -> ?masks:Tensor.t -> Tensor.t -> Tensor.t
end = struct
  type t = Tensor.t

  let create () = Tensor.zeros [num_procs; num_stack; 84; 84] ~kind:Float

  let update t ?masks img =
    Option.iter masks ~f:(fun masks ->
        Tensor.(t *= view masks ~size:[num_procs; 1; 1; 1]) );
    let stack_slice i = Tensor.narrow t ~dim:1 ~start:i ~length:1 in
    for frame_index = 1 to num_stack - 1 do
      Tensor.copy_ (stack_slice (frame_index - 1)) ~src:(stack_slice frame_index)
    done;
    Tensor.copy_ (stack_slice (num_stack - 1)) ~src:img;
    t
end

let set tensor i src = Tensor.copy_ (Tensor.get tensor i) ~src

let train ~device =
  let envs = E.create atari_game ~num_processes:num_procs in
  let action_space = E.action_space envs in
  Stdio.printf "Action space: %d\n%!" action_space;
  let vs = Var_store.create ~name:"a2c" () ~device in
  let model = model vs ~actions:action_space in
  let optimizer = Optimizer.adam vs ~learning_rate:1e-4 in
  let frame_stack = Frame_stack.create () in
  let obs = E.reset envs in
  Tensor.print_shape obs ~name:"obs";
  ignore (Frame_stack.update frame_stack obs : Tensor.t);
  let s_states =
    Tensor.zeros [num_steps + 1; num_procs; num_stack; 84; 84] ~kind:Float
  in
  let s_rewards = Tensor.zeros [num_steps; num_procs] in
  let sum_rewards = Tensor.zeros [num_procs] in
  let total_rewards = ref 0. in
  let total_episodes = ref 0. in
  let s_actions = Tensor.zeros [num_steps; num_procs] ~kind:Int64 in
  let s_masks = Tensor.zeros [num_steps; num_procs] in
  for index = 1 to updates do
    for s = 0 to num_steps - 1 do
      let {actor; critic = _} =
        Tensor.no_grad (fun () -> model (Tensor.get s_states s))
      in
      let probs = Tensor.softmax actor ~dim:(-1) in
      let actions =
        Tensor.multinomial probs ~num_samples:1 ~replacement:true |> Tensor.squeeze_last
      in
      let {E.obs; reward; is_done} =
        E.step envs ~actions:(Tensor.to_int1_exn actions |> Array.to_list)
      in
      Tensor.(sum_rewards += reward);
      (total_rewards :=
         !total_rewards +. Tensor.(sum (sum_rewards * is_done) |> to_float0_exn));
      (total_episodes := !total_episodes +. Tensor.(sum is_done |> to_float0_exn));
      let masks = Tensor.(f 1. - is_done) in
      Tensor.(sum_rewards *= masks);
      let obs = Frame_stack.update frame_stack obs ~masks in
      set s_actions s actions;
      set s_states (s + 1) obs;
      set s_rewards s reward;
      set s_masks s masks
    done;
    let s_returns =
      let r = Tensor.zeros [num_steps + 1; num_procs] in
      let {actor = _; critic} =
        Tensor.no_grad (fun () -> model (Tensor.get s_states (-1)))
      in
      set r (-1) (Tensor.view critic ~size:[num_procs]);
      for s = num_steps - 1 downto 0 do
        set r s Tensor.((get r Int.(s + 1) * f 0.99 * get s_masks s) + get s_rewards s)
      done;
      r
    in
    let {actor; critic} =
      model
        ( Tensor.narrow s_states ~dim:0 ~start:0 ~length:num_steps
        |> Tensor.view ~size:[num_steps * num_procs; num_stack; 84; 84] )
    in
    let critic = Tensor.view critic ~size:[num_steps; num_procs] in
    let actor = Tensor.view actor ~size:[num_steps; num_procs; -1] in
    let log_probs = Tensor.log_softmax actor ~dim:(-1) in
    let probs = Tensor.softmax actor ~dim:(-1) in
    let action_log_probs =
      let index = Tensor.unsqueeze s_actions ~dim:(-1) |> Tensor.to_device ~device in
      Tensor.gather log_probs ~dim:2 ~index |> Tensor.squeeze_last
    in
    let dist_entropy =
      Tensor.(~-(log_probs * probs) |> sum2 ~dim:[-1] ~keepdim:false |> mean)
    in
    let advantages =
      let s_returns =
        Tensor.narrow s_returns ~dim:0 ~start:0 ~length:num_steps
        |> Tensor.to_device ~device
      in
      Tensor.(s_returns - critic)
    in
    let value_loss = Tensor.(advantages * advantages) |> Tensor.mean in
    let action_loss = Tensor.(~-(detach advantages * action_log_probs)) |> Tensor.mean in
    let loss = Tensor.(scale value_loss 0.5 + action_loss - scale dist_entropy 0.01) in
    Optimizer.backward_step optimizer ~loss ~clip_grad:(Value 0.5);
    Caml.Gc.full_major ();
    set s_states 0 (Tensor.get s_states (-1));
    if index % 10_000 = 0
    then
      Serialize.save_multi
        ~named_tensors:(Var_store.all_vars vs)
        ~filename:(Printf.sprintf "a2c-%d.ckpt" index);
    if index % 500 = 0
    then (
      Stdio.printf
        "%d %f (%.0f episodes)\n%!"
        index
        (!total_rewards /. !total_episodes)
        !total_episodes;
      total_rewards := 0.;
      total_episodes := 0. )
  done

let valid ~filename ~device =
  let envs = E.create atari_game ~num_processes:1 in
  let action_space = E.action_space envs in
  let vs = Var_store.create ~frozen:true ~name:"a2c" () ~device in
  let model = model vs ~actions:action_space in
  Serialize.load_multi_ ~named_tensors:(Var_store.all_vars vs) ~filename;
  let frame_stack = Frame_stack.create () in
  let obs = ref (E.reset envs) in
  for _index = 1 to 1_000 do
    let {actor; critic = _} = Frame_stack.update frame_stack !obs |> model in
    let probs = Tensor.softmax actor ~dim:(-1) in
    let actions =
      Tensor.multinomial probs ~num_samples:1 ~replacement:true |> Tensor.squeeze_last
    in
    (* let actions = Tensor.(argmax1 actor ~dim:(-1) ~keepdim:false |> to_int1_exn) in *)
    let step = E.step envs ~actions:(Tensor.to_int1_exn actions |> Array.to_list) in
    let reward = (Tensor.to_float1_exn step.reward).(0) in
    if Float.( <> ) reward 0. then Stdio.printf "Reward: %f\n%!" reward;
    obs := step.E.obs
  done

let () =
  let device =
    if Cuda.is_available ()
    then (
      Stdio.printf "Using cuda, devices: %d\n%!" (Cuda.device_count ());
      Cuda.set_benchmark_cudnn true;
      Torch_core.Device.Cuda )
    else Torch_core.Device.Cpu
  in
  if Array.length Caml.Sys.argv > 1
  then valid ~filename:Caml.Sys.argv.(1) ~device
  else train ~device
