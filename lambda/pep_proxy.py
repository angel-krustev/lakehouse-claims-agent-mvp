# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
"""Plane B proxy, one deployment per agent. Only that agent's role may invoke this function (IAM verifies who),
and it forwards the call to the PEP's Plane B with its own execution role ARN as x-amzn-caller-arn and the
agent's role ARN as x-pep-agent-role-arn. Both identities come from the function's configuration, never from
the request. Keep in sync with PepProxyFunction in template.yaml."""
import json
import os
import re
import urllib.error
import urllib.request

BASE = os.environ["PEP_PLANE_B_URL"].rstrip("/")
CALLER = os.environ["CALLER_ARN"]
AGENT = os.environ["AGENT_ROLE_ARN"]
DB = os.environ["PEP_DEFAULT_DATABASE"]
if not re.fullmatch(r"arn:aws[\w-]*:iam::\d{12}:role/[\w+=,.@/-]+", AGENT):
    raise RuntimeError("AGENT_ROLE_ARN must be a full IAM role ARN")
TOOLS = {"list_tables": (), "describe_table": ("table",), "query_lake_formation": ("sql", "max_rows")}


def handler(event, context):
    tool = event.get("tool")
    if tool not in TOOLS:
        return {"ok": False, "error": f"Unknown tool '{tool}'"}
    args = event.get("arguments") or {}
    body = {"session_ref": str(event.get("session_ref", "")), "database": DB}
    body.update({k: args[k] for k in TOOLS[tool] if k in args})
    req = urllib.request.Request(
        f"{BASE}/mcp/tools/{tool}/call",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "x-amzn-caller-arn": CALLER, "x-pep-agent-role-arn": AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return {"ok": False, "error": f"Broker returned HTTP {exc.code}.", "retryable": exc.code in (429, 502)}
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        return {"ok": False, "error": f"Broker unreachable ({type(exc).__name__})."}
