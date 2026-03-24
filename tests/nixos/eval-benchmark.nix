# Benchmark test for nix eval performance.
# Evaluates the testsystem NixOS config (1 warmup + 3 timed runs).
# The result is printed to the test log as JSON.
test@{ config, lib, hostPkgs, nixComponents, nixpkgs, ... }:

let
  # Build a NixOS system from testsystem.nix using the same nixpkgs
  # but with the locally-built nix overlaid in.
  testsystemDrv = (import nixpkgs {
    system = "x86_64-linux";
  }).lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ../../testsystem.nix ];
  };

  # We need the testsystem's toplevel drv path for correctness checking.
  # But more importantly we need all the .nix source files available in the VM.
  # The flake source itself is what we'll eval inside the VM.
  nixSrc = builtins.path {
    path = ../..;
    name = "nix-src";
    filter = path: type:
      let
        baseName = builtins.baseNameOf path;
        relPath = lib.removePrefix (toString ../..) (toString path);
      in
      # Include only what's needed for the flake eval
      baseName == "flake.nix"
      || baseName == "flake.lock"
      || baseName == "testsystem.nix"
      # Include packaging files needed by the flake
      || lib.hasPrefix "/packaging" relPath
      || lib.hasPrefix "/doc" relPath
      || lib.hasPrefix "/maintainers" relPath
      || lib.hasPrefix "/src" relPath
      || lib.hasPrefix "/scripts" relPath
      || lib.hasPrefix "/misc" relPath
      || baseName == "meson.build"
      || baseName == "meson.options"
      || baseName == "meson_options.txt"
      || baseName == ".version"
      || type == "directory";
  };
in
{
  name = "eval-benchmark";

  nodes.machine = { config, pkgs, ... }: {
    virtualisation.writableStore = true;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    environment.systemPackages = [
      config.nix.package
    ];

    # Make the flake source available in the VM
    system.extraDependencies = [
      nixSrc
    ];
  };

  testScript = ''
    import json
    import re

    machine.wait_for_unit("multi-user.target")

    # Copy the source to a writable location
    machine.succeed("cp -r ${nixSrc} /tmp/nix-src")
    machine.succeed("chmod -R u+w /tmp/nix-src")

    eval_cmd = "nix eval '/tmp/nix-src#nixosConfigurations.testsystem.config.system.build.toplevel.drvPath' 2>/dev/null"

    # Warmup run (populates eval cache, filesystem cache, etc.)
    machine.log("Starting warmup run...")
    machine.succeed(eval_cmd)
    machine.log("Warmup complete.")

    # 3 timed runs
    times = []
    for i in range(3):
        result = machine.succeed(
            f"bash -c 'start=$(date +%s%N); {eval_cmd}; end=$(date +%s%N); echo $(( end - start ))'"
        )
        # The last line is the nanosecond duration
        ns = int(result.strip().split('\n')[-1])
        t = ns / 1_000_000_000
        times.append(t)
        machine.log(f"Run {i+1}: {t:.3f}s")

    avg = sum(times) / len(times)
    machine.log(f"BENCHMARK RESULT: average={avg:.3f}s runs={times}")

    # Write structured result
    result_json = json.dumps({"avg_seconds": round(avg, 3), "runs": [round(t, 3) for t in times]})
    machine.succeed(f"echo '{result_json}' > /tmp/benchmark-result.json")
    machine.log(f"BENCHMARK_JSON: {result_json}")
  '';
}
