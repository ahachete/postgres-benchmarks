# Convenience nix-shell for operators on Nix systems. Provides every binary
# the wrapper scripts (Make, scripts/bench-*.sh) expect, plus ansible-core
# with boto3/botocore in the SAME Python env (the community.aws.aws_ssm
# connection plugin imports boto3 at runtime — Ansible's Python must see it).
#
# Usage:
#   nix-shell           # drop into a shell with everything on PATH
#   nix-shell --run 'make up SCENARIO=nvme-ext4'   # one-shot
#
# Non-Nix operators: install equivalents via your OS package manager
# (ansible-core ≥ 2.16 + python3-boto3 + opentofu/terraform + aws CLI v2 +
# session-manager-plugin + jq + uv + rsync).

{ pkgs ? import <nixpkgs> {} }:

let
  pythonEnv = pkgs.python313.withPackages (ps: [
    ps.ansible-core
    ps.boto3
    ps.botocore
  ]);
in
pkgs.mkShell {
  packages = [
    pythonEnv
    pkgs.opentofu
    pkgs.awscli2
    pkgs.ssm-session-manager-plugin
    pkgs.jq
    pkgs.uv
    pkgs.rsync
    pkgs.gnumake
    pkgs.zstd
  ];

  shellHook = ''
    echo "Postgres benchmark dev shell — ansible $(ansible --version | head -1 | awk '{print $2}'), tofu $(tofu version | head -1 | awk '{print $2}'), aws v$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9.]+' | cut -d/ -f2)"

    # uv-installed wheels (numpy, matplotlib) ship .so files linked against
    # libstdc++ / libz / libgcc_s. On Nix these aren't on the default
    # loader path; expose them via LD_LIBRARY_PATH so `uv run …` works.
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
    ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # Share provider plugins across the two tofu roots (terraform/ and
    # terraform/persistent/) so we don't keep two copies of the ~700 MB
    # AWS provider on disk.
    export TF_PLUGIN_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/tofu-plugins"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
  '';
}
