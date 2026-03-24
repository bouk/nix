# Benchmark test for nix eval performance.
# Evaluates the testsystem NixOS config (1 warmup + 3 timed runs).
# The result is printed to the test log as JSON.
test@{ config, lib, hostPkgs, nixComponents, nixpkgs, ... }:

let
  testsystemNix = ../../testsystem.nix;

  # A minimal flake that just defines nixosConfigurations.testsystem
  benchFlake = hostPkgs.writeText "flake.nix" ''
    {
      inputs.nixpkgs.url = "${nixpkgs}";
      outputs = { nixpkgs, ... }: {
        nixosConfigurations.testsystem = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./testsystem.nix ];
        };
      };
    }
  '';
in
{
  name = "eval-benchmark";

  nodes.machine = { config, pkgs, ... }: {
    virtualisation.writableStore = true;
    virtualisation.memorySize = 8192;
    virtualisation.cores = 8;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")

    # Set up a minimal flake with just testsystem.nix
    machine.succeed("mkdir -p /tmp/bench")
    machine.succeed("cp ${benchFlake} /tmp/bench/flake.nix")
    machine.succeed("cp ${testsystemNix} /tmp/bench/testsystem.nix")

    eval_cmd = "nix eval /tmp/bench#nixosConfigurations.testsystem.config.system.build.toplevel.drvPath 2>/dev/null"

    # Warmup run (populates eval cache, filesystem cache, etc.)
    machine.log("Starting warmup run...")
    machine.succeed(eval_cmd)
    machine.log("Warmup complete.")

    # 3 timed runs
    times: list[float] = []
    for run_idx in range(3):
        run_result: str = machine.succeed(
            f"bash -c 'start=$(date +%s%N); {eval_cmd}; end=$(date +%s%N); echo $(( end - start ))'"
        )
        ns = int(run_result.strip().split('\n')[-1])
        elapsed: float = ns / 1_000_000_000
        times.append(elapsed)
        machine.log(f"Run {run_idx+1}: {elapsed:.3f}s")

    avg: float = sum(times) / len(times)
    machine.log(f"BENCHMARK RESULT: average={avg:.3f}s runs={times}")

    result_json = json.dumps({"avg_seconds": round(avg, 3), "runs": [round(sec, 3) for sec in times]})
    machine.log(f"BENCHMARK_JSON: {result_json}")

    # Write result to $out so it ends up in the nix build result/ symlink
    out_dir: str = os.environ.get("out", "/tmp")
    with open(os.path.join(out_dir, "benchmark-result.json"), "w") as f:
        f.write(result_json)
  '';
}
