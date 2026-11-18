"""Run a KQL file from docs/kql against the lab Log Analytics workspace.

Uses the Azure CLI for the access token (az login first). Placeholders such as
<run-id> or <x-apim-request-id> are replaced with --param values.

  python tools/query_logs.py docs/kql/requests-by-run.kql --workspace-id <guid> --param run-id=<id>
  python tools/query_logs.py docs/kql/www-authenticate-rewrite.kql -g <rg> -w <workspace-name>
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request


def az(*args: str) -> str:
    exe = shutil.which("az") or shutil.which("az.cmd")
    if not exe:
        raise SystemExit("Azure CLI not found")
    return subprocess.run([exe, *args], check=True, capture_output=True, text=True).stdout.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kql_file")
    parser.add_argument("--workspace-id", help="Log Analytics workspace (customer) ID")
    parser.add_argument("-g", "--resource-group", help="resolve the workspace ID from resource group + name")
    parser.add_argument("-w", "--workspace-name")
    parser.add_argument("--param", action="append", default=[], help="placeholder=value, e.g. run-id=abc123")
    parser.add_argument("--timespan", default="P1D", help="ISO 8601 duration (default P1D)")
    parser.add_argument("--limit", type=int, default=50, help="rows to print")
    args = parser.parse_args(argv)

    workspace = args.workspace_id
    if not workspace:
        if not (args.resource_group and args.workspace_name):
            raise SystemExit("pass --workspace-id or -g/-w")
        workspace = az("monitor", "log-analytics", "workspace", "show", "-g", args.resource_group,
                       "-n", args.workspace_name, "--query", "customerId", "-o", "tsv")

    with open(args.kql_file, encoding="utf-8-sig") as handle:
        query = handle.read()
    for item in args.param:
        key, _, value = item.partition("=")
        query = query.replace(f"<{key}>", value)

    token = az("account", "get-access-token", "--resource", "https://api.loganalytics.io",
               "--query", "accessToken", "-o", "tsv")
    request = urllib.request.Request(
        f"https://api.loganalytics.io/v1/workspaces/{workspace}/query", method="POST",
        data=json.dumps({"query": query, "timespan": args.timespan}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as resp:
            result = json.load(resp)
    except urllib.error.HTTPError as err:
        print(err.read().decode("utf-8", "replace"), file=sys.stderr)
        return 1

    table = result["tables"][0]
    columns = [c["name"] for c in table["columns"]]
    for row in table["rows"][: args.limit]:
        print(json.dumps(dict(zip(columns, row)), default=str))
    print(f"-- {len(table['rows'])} row(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
