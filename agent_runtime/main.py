# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
"""Secure Insurance Claims Copilot - AgentCore Runtime agent (HTTP protocol, port 8080).

Orchestrates a Bedrock model (Converse API) that discovers the schema and queries data
through the PEP's Plane B MCP tools (list_tables, describe_table, query_lake_formation).

Token blindness: this process only ever holds the opaque session_ref. It is injected into
every Plane B call in code, so the model can neither read nor change it. No JWT, STS or
identity-propagation logic lives here; the PEP handles all of that.
"""
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# Plane B is reached only through this Lambda proxy, which presents its own verified role to the PEP.
PEP_PROXY_FUNCTION = os.environ.get("PEP_PROXY_FUNCTION", "")
DATABASE = os.environ.get("PEP_DEFAULT_DATABASE", "insurance_analytics")
MODEL_ID = os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-4-6")
MODEL_MAX_TOKENS = int(os.environ.get("MODEL_MAX_TOKENS") or "4096")
MODEL_TEMPERATURE = float(os.environ.get("MODEL_TEMPERATURE") or "0")
# Optional: recent Claude models reject a request that sets both temperature and topP, so empty means "not sent".
MODEL_TOP_P = os.environ.get("MODEL_TOP_P", "").strip()
INFERENCE_CONFIG = {"maxTokens": MODEL_MAX_TOKENS, "temperature": MODEL_TEMPERATURE}
if MODEL_TOP_P:
    INFERENCE_CONFIG["topP"] = float(MODEL_TOP_P)
MAX_TOOL_ROUNDS = int(os.environ.get("MAX_TOOL_ROUNDS", "10"))
MAX_HISTORY_MESSAGES = int(os.environ.get("MAX_HISTORY_MESSAGES", "40"))
MAX_TOOL_RESULT_CHARS = 60000
SESSION_ID_HEADER = "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"

log = logging.getLogger("claims-agent")

SYSTEM_PROMPT = f"""You are the Secure Insurance Claims Copilot, an analyst for the AWS Athena database `{DATABASE}`. You answer questions about insurance claims, fraud risk and claim payments by discovering the schema, writing Athena (Trino) SQL and running it through governed tools.

TOOLS
- list_tables: lists the tables the signed-in user may see. Takes no parameters.
- describe_table: returns the columns and types of one table. Required parameter: table.
- query_lake_formation: runs one read-only SQL statement. Required parameters: session_ref and sql.

WORKFLOW
1. Never assume the schema. Before writing SQL, call list_tables, then call describe_table for every table you plan to use. Use only the table and column names those tools return. Discover again if a query fails on a name.
2. Write ONE statement: SELECT or WITH ... SELECT. No DDL, no DML, no multiple statements, no SHOW/DESCRIBE/EXPLAIN, and never information_schema.
3. Reference tables as "{DATABASE}"."<table>". Double-quote identifiers that contain a hyphen or other special characters.
4. Always include a LIMIT (at most 100 unless the user asks for fewer) and prefer filters and aggregation over wide result sets.
5. Always set session_ref to the literal text CURRENT_SESSION. The platform supplies the real value. You never know it, and you must never ask the user for credentials, tokens or a session reference.
6. Values come back as text. Cast them in SQL when you need numbers or dates (for example CAST(col AS DOUBLE), CAST(col AS DATE)).

ACCESS CONTROL
- AWS Lake Formation enforces access outside of you. Tables, rows and columns may be missing, null or masked for the current user. Report exactly what the tools return. Never try to work around restrictions and never guess hidden values.
- If a tool returns ok=false, explain it in plain language. "Query execution failed due to invalid syntax or permissions" and "Request failed due to invalid input or permissions" are deliberately generic: you may fix an obvious syntax mistake and retry once, otherwise tell the user they may not have access. If the session is invalid or expired, ask the user to sign in again.

ANSWER STYLE
- Present results as a concise markdown table followed by one or two key insights.
- Say clearly when a result is empty or appears restricted."""

TOOL_CONFIG = {
    "tools": [
        {"toolSpec": {
            "name": "list_tables",
            "description": "List the tables in the database that the signed-in user may see. Call this before writing SQL.",
            "inputSchema": {"json": {"type": "object", "properties": {}}},
        }},
        {"toolSpec": {
            "name": "describe_table",
            "description": "Get the column names and types of one table, exactly as returned by list_tables.",
            "inputSchema": {"json": {
                "type": "object",
                "properties": {"table": {"type": "string", "description": "Table name from list_tables."}},
                "required": ["table"],
            }},
        }},
        {"toolSpec": {
            "name": "query_lake_formation",
            "description": "Run ONE read-only Athena (Trino) SELECT statement. Lake Formation filters rows and columns for the signed-in user.",
            "inputSchema": {"json": {
                "type": "object",
                "properties": {
                    "session_ref": {"type": "string", "description": "Always pass the literal value CURRENT_SESSION."},
                    "sql": {"type": "string", "description": "A single read-only SELECT statement with a LIMIT clause."},
                },
                "required": ["session_ref", "sql"],
            }},
        }},
    ]
}


_lambda = None


def _lambda_client():
    global _lambda
    if _lambda is None:
        # The default read timeout (60 s) is shorter than an Athena query (up to about 90 s).
        _lambda = boto3.client("lambda", config=Config(read_timeout=130, retries={"max_attempts": 1}))
    return _lambda


def call_plane_b(tool, args, session_ref, client=None):
    """Call a PEP Plane B tool through the proxy Lambda. session_ref always comes from trusted code, never from the model."""
    if tool == "list_tables":
        arguments = {}
    elif tool == "describe_table":
        arguments = {"table": str(args.get("table", ""))}
    elif tool == "query_lake_formation":
        arguments = {"sql": str(args.get("sql", "")), "max_rows": 100}
    else:
        return {"ok": False, "error": f"Unknown tool '{tool}'"}

    event = json.dumps({"tool": tool, "session_ref": session_ref, "arguments": arguments}).encode()
    for attempt in range(3):
        try:
            resp = (client or _lambda_client()).invoke(FunctionName=PEP_PROXY_FUNCTION, Payload=event)
            result = json.loads(resp["Payload"].read())
        except (BotoCoreError, ClientError, ValueError) as exc:
            return {"ok": False, "error": f"Broker proxy unreachable ({type(exc).__name__})."}
        if resp.get("FunctionError") or not isinstance(result, dict):
            return {"ok": False, "error": "Broker proxy failed."}
        if result.get("retryable") and attempt < 2:
            time.sleep(2 ** attempt)
            continue
        if result.get("retryable"):
            return {"ok": False, "error": "Broker is rate limiting requests; try again shortly."}
        return result
    return {"ok": False, "error": "Broker is rate limiting requests; try again shortly."}


def _tool_result_text(result):
    text = json.dumps(result)
    if len(text) > MAX_TOOL_RESULT_CHARS:
        text = text[:MAX_TOOL_RESULT_CHARS] + '..."[truncated]'
    return text


FILTERED_NOTICE = (
    "The model's content filter blocked this response, so I can't show an answer. "
    "Try rephrasing the question, or ask your administrator to use a different model."
)
FILTER_STOP_REASONS = ("content_filtered", "guardrail_intervened")


def run_agent(client, history, prompt, session_ref, plane_b=call_plane_b):
    """Run the Converse tool-use loop; mutates `history` and returns the final answer text."""
    history.append({"role": "user", "content": [{"text": prompt}]})
    answer = ""
    for round_no in range(1, MAX_TOOL_ROUNDS + 1):
        resp = client.converse(
            modelId=MODEL_ID,
            system=[{"text": SYSTEM_PROMPT}],
            messages=history,
            toolConfig=TOOL_CONFIG,
            inferenceConfig=INFERENCE_CONFIG,
        )
        stop = resp.get("stopReason")
        message = resp["output"]["message"]
        # Log the shape of each round, never the content (it can hold user data).
        log.info("round=%d model=%s stopReason=%s tools=%s", round_no, MODEL_ID, stop,
                 [b["toolUse"]["name"] for b in message["content"] if "toolUse" in b])
        if stop in FILTER_STOP_REASONS:
            # Replace the provider's canned text but keep the user/assistant turns alternating.
            history.append({"role": "assistant", "content": [{"text": FILTERED_NOTICE}]})
            return FILTERED_NOTICE
        history.append(message)
        answer = "".join(b["text"] for b in message["content"] if "text" in b) or answer
        if stop != "tool_use":
            return answer

        results = []
        for block in message["content"]:
            if "toolUse" not in block:
                continue
            use = block["toolUse"]
            outcome = plane_b(use["name"], use.get("input") or {}, session_ref)
            results.append({"toolResult": {
                "toolUseId": use["toolUseId"],
                "content": [{"text": _tool_result_text(outcome)}],
                "status": "success" if outcome.get("ok") else "error",
            }})
        history.append({"role": "user", "content": results})
    return answer or "I could not finish the analysis within the allowed number of steps. Please narrow the question."


_histories = {}
_lock = threading.Lock()
_bedrock = None


def _trim(history):
    # Keep the window starting at a plain user text turn so toolUse/toolResult pairs stay intact.
    if len(history) <= MAX_HISTORY_MESSAGES:
        return
    cut = len(history) - MAX_HISTORY_MESSAGES
    while cut < len(history) and not (
        history[cut]["role"] == "user" and any("text" in b for b in history[cut]["content"])
    ):
        cut += 1
    del history[:cut]


def handle_invocation(payload, runtime_session_id):
    global _bedrock
    prompt = (payload.get("prompt") or "").strip()
    session_ref = payload.get("session_ref") or ""
    if not prompt:
        return 400, {"status": "error", "error": "prompt is required"}
    if not session_ref:
        return 400, {"status": "error", "error": "session_ref is required"}
    if _bedrock is None:
        _bedrock = boto3.client("bedrock-runtime")

    with _lock:
        history = _histories.setdefault(runtime_session_id or "default", [])
    try:
        answer = run_agent(_bedrock, history, prompt, session_ref)
    except Exception:
        log.exception("agent invocation failed")
        history.clear()
        return 502, {"status": "error", "error": "The model invocation failed. Please try again."}
    _trim(history)
    return 200, {"status": "success", "response": answer}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/ping":
            self._send(200, {"status": "Healthy", "time_of_last_update": int(time.time())})
        else:
            self._send(404, {"error": "Not Found"})

    def do_POST(self):
        if self.path != "/invocations":
            self._send(404, {"error": "Not Found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._send(400, {"status": "error", "error": "Body must be valid JSON."})
            return
        code, body = handle_invocation(payload, self.headers.get(SESSION_ID_HEADER))
        self._send(code, body)

    def log_message(self, fmt, *args):
        # Never log request bodies or the session_ref.
        log.info("%s %s", self.command, self.path)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
