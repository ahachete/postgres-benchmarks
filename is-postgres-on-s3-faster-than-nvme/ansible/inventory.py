#!/usr/bin/env python3
"""Dynamic Ansible inventory backed by `terraform output -json`.

Reads `ansible_inventory` (a structured object emitted by terraform/outputs.tf)
and renders the standard --list / --host JSON Ansible expects. The script must
be run with the repo root or terraform/ directory reachable; it auto-detects
by walking up from its own location.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def find_terraform_dir() -> Path:
    here = Path(__file__).resolve().parent
    candidates = [here.parent / "terraform", here / "../terraform"]
    for c in candidates:
        if (c / "main.tf").exists():
            return c.resolve()
    print(f"ERROR: could not find terraform/ directory near {here}", file=sys.stderr)
    sys.exit(1)


def pick_tf() -> str:
    """Prefer OpenTofu when present; fall back to Terraform.

    Honors the TF environment variable for forcing a specific binary (mirrors
    scripts/_lib.sh).
    """
    forced = os.environ.get("TF", "").strip()
    if forced:
        return forced
    for cand in ("tofu", "terraform"):
        if subprocess.run(
            ["which", cand], capture_output=True, text=True
        ).returncode == 0:
            return cand
    print("ERROR: neither 'tofu' nor 'terraform' in PATH", file=sys.stderr)
    sys.exit(1)


def terraform_output() -> dict:
    tf_dir = find_terraform_dir()
    tf = pick_tf()
    result = subprocess.run(
        [tf, f"-chdir={tf_dir}", "output", "-json", "ansible_inventory"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(
            f"ERROR: `{tf} output` failed (cwd={tf_dir}):\n{result.stderr}",
            file=sys.stderr,
        )
        sys.exit(1)
    return json.loads(result.stdout)


def build_inventory(tf: dict) -> dict:
    nodes = tf["nodes"]
    region = tf["region"]
    results_bucket = tf.get("results_bucket", tf["bucket"])

    hosts = {}
    for node in nodes:
        hosts[node["role"]] = {
            # AWS SSM connection plugin: target by instance ID; the plugin
            # negotiates an SSM session and tunnels stdin/stdout. No SSH key,
            # no port 22, no public IP needed (we keep the public IP for
            # diagnostics but SSM works equally on private-only instances).
            "ansible_connection": "community.aws.aws_ssm",
            "ansible_aws_ssm_instance_id": node["instance_id"],
            "ansible_aws_ssm_region": region,
            # The plugin uses S3 as scratch space for files >2 MB. Reuse our
            # results bucket — IAM already grants the instance r/w on it.
            "ansible_aws_ssm_bucket_name": results_bucket,
            "ansible_aws_ssm_bucket_sse": "AES256",
            "ansible_aws_ssm_plugin": "/usr/local/bin/session-manager-plugin",
            # Allow long-running apt installs (zfs-dkms compile, AWS CLI v2
            # download, etc.) to complete in a single SSM command.
            "ansible_aws_ssm_timeout": 1800,
            "ansible_python_interpreter": "/usr/bin/python3",
            # Hostvars surfaced to roles for context / templating.
            "ansible_host": node["public_ip"],
            "private_ip": node["private_ip"],
            "az": node["az"],
            "az_id": node.get("az_id", ""),
            "instance_id": node["instance_id"],
            "role": node["role"],
        }

    cluster = tf["cluster"]

    inv = {
        "_meta": {"hostvars": hosts},
        "all": {
            "children": ["postgres"],
            "vars": {
                "scenario": tf["scenario"],
                "scenario_family": tf.get("scenario_family", tf["scenario"]),
                "s3_class": tf.get("s3_class", ""),
                "s3_endpoint_url": tf.get("s3_endpoint_url", ""),
                "cluster": cluster,
                "bench_bucket": tf["bucket"],
                "results_bucket": results_bucket,
                "aws_region": region,
                "primary_az_id": tf.get("az_id", ""),
            },
        },
        "postgres": {
            "children": ["primary"] + (["replicas"] if cluster else []),
        },
        "primary": {"hosts": ["primary"]},
    }
    if cluster:
        inv["replicas"] = {"hosts": [n["role"] for n in nodes if n["role"] != "primary"]}

    return inv


def main() -> int:
    tf = terraform_output()
    inv = build_inventory(tf)

    if "--host" in sys.argv:
        idx = sys.argv.index("--host")
        host = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else ""
        print(json.dumps(inv["_meta"]["hostvars"].get(host, {})))
    else:
        print(json.dumps(inv, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
