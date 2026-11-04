# Copyright 2026 Angel Krustev / VerticalTurn Inc.
# SPDX-License-Identifier: Apache-2.0
"""Secure Insurance Claims Copilot - Streamlit front end.

Flow: Entra ID sign-in (MSAL public client, PKCE, no secret) -> JWT posted to PEP Plane A
(/sessions/init) -> opaque session_ref kept in session state -> chat prompts plus the session_ref
are sent over HTTPS to the AgentCore Runtime, authenticated with the user's Entra ID token as a bearer
token (no AWS credentials on this machine). AgentCore validates the token at the edge and never hands it
to the agent. The agent reaches PEP Plane B through a proxy; this app never does.
Row/column security is enforced by Lake Formation behind the PEP; nothing is filtered here.
"""
import base64
import json
import os
import threading
import time
import uuid
from urllib.parse import quote, urlparse

import msal
import requests
import streamlit as st
from dotenv import load_dotenv

load_dotenv()

ENTRA_CLIENT_ID = os.getenv("ENTRA_CLIENT_ID", "")
ENTRA_TENANT_ID = os.getenv("ENTRA_TENANT_ID", "")
ENTRA_AUTHORITY = os.getenv("ENTRA_AUTHORITY") or (
    f"https://login.microsoftonline.com/{ENTRA_TENANT_ID}" if ENTRA_TENANT_ID else ""
)
PEP_PLANE_A_URL = (os.getenv("PEP_PLANE_A_URL") or "").rstrip("/")
# Optional CA certificate for the PEP's TLS only (a self-signed ALB certificate). It is deliberately not
# REQUESTS_CA_BUNDLE, which would also replace the trusted CAs for Entra ID and break sign-in.
PEP_CA_BUNDLE = os.getenv("PEP_CA_BUNDLE") or True
BEDROCK_AGENT_ID = os.getenv("BEDROCK_AGENT_ID", "")  # full AgentCore Runtime ARN

# Register this URL on the Entra app as a "Mobile and desktop applications" redirect URI.
REDIRECT_URI = "http://localhost:8501/"
# MSAL adds openid, profile and offline_access itself; passing them raises ValueError.
AUTH_SCOPES = ["email"]
PENDING_FLOW_TTL = 600

EXAMPLES = [
    "Show me the top 5 claims with the highest fraud risk score",
    "Which tables can I query?",
    "Total claim payments by payment type",
]

st.set_page_config(page_title="Secure Insurance Claims Copilot", page_icon="ðŸ›¡ï¸", layout="wide")

for key, default in {
    "messages": [],
    "session_ref": None,
    "session_issued_at": 0.0,
    "session_ttl": 0,
    "id_token": None,
    "id_token_exp": 0.0,
    "user_label": "",
    "login_url": None,
    "login_error": None,
    "runtime_session_id": None,
}.items():
    st.session_state.setdefault(key, default)


@st.cache_resource
def _pending_flows() -> dict:
    """PKCE flows awaiting their redirect. The redirect lands in a fresh browser session, so
    the flow (which holds the code verifier) is kept server-side, keyed by the OAuth state."""
    return {"lock": threading.Lock(), "flows": {}}


@st.cache_resource
def _msal_app() -> msal.PublicClientApplication:
    return msal.PublicClientApplication(ENTRA_CLIENT_ID, authority=ENTRA_AUTHORITY)


def _store_flow(flow: dict) -> None:
    pending = _pending_flows()
    now = time.time()
    with pending["lock"]:
        pending["flows"] = {k: v for k, v in pending["flows"].items() if now - v[1] < PENDING_FLOW_TTL}
        pending["flows"][flow["state"]] = (flow, now)


def _take_flow(state: str):
    pending = _pending_flows()
    with pending["lock"]:
        entry = pending["flows"].pop(state, None)
    if entry and time.time() - entry[1] < PENDING_FLOW_TTL:
        return entry[0]
    return None


def start_login() -> None:
    if not (ENTRA_CLIENT_ID and ENTRA_AUTHORITY):
        st.session_state["login_error"] = "ENTRA_CLIENT_ID and ENTRA_TENANT_ID/ENTRA_AUTHORITY must be set in .env."
        return
    flow = _msal_app().initiate_auth_code_flow(
        AUTH_SCOPES, redirect_uri=REDIRECT_URI, prompt="select_account"
    )
    if "auth_uri" not in flow:
        st.session_state["login_error"] = flow.get("error_description", "Could not start the Entra ID sign-in.")
        return
    _store_flow(flow)
    st.session_state["login_url"] = flow["auth_uri"]


def _claims(id_token: str) -> dict:
    """Decode the payload for display only. The PEP is the party that validates the token."""
    try:
        payload = id_token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}


def _pep_error_message(exc: requests.RequestException) -> str:
    """Explain a failed Plane A call. Only the host is shown; the token is never in the URL or message."""
    host = urlparse(PEP_PLANE_A_URL).netloc or PEP_PLANE_A_URL
    detail = str(exc).lower()
    if isinstance(exc, requests.exceptions.SSLError):
        return (f"TLS verification failed for {host}. For a self-signed certificate, set PEP_CA_BUNDLE to it "
                "and use the hostname the certificate was issued for.")
    if isinstance(exc, requests.exceptions.Timeout):
        return f"Timed out reaching {host}. Check the VPN and that the PEP is running."
    if any(s in detail for s in ("getaddrinfo", "name or service not known", "failed to resolve", "nodename")):
        return f"Could not resolve {host}. Add it to your hosts file or check PEP_PLANE_A_URL in .env."
    if "refused" in detail or "actively refused" in detail:
        return f"Connection refused by {host}. Check PEP_PLANE_A_URL in .env points at the PEP's ALB, not localhost."
    return f"Could not reach the PEP at {host} ({type(exc).__name__}). Check PEP_PLANE_A_URL and the VPN."


def init_pep_session(id_token: str) -> bool:
    """POST the ID token to PEP Plane A and keep only the opaque session_ref."""
    if not PEP_PLANE_A_URL:
        st.session_state["login_error"] = "PEP_PLANE_A_URL is not set in .env."
        return False
    try:
        resp = requests.post(
            f"{PEP_PLANE_A_URL}/sessions/init", json={"token": id_token}, timeout=30, verify=PEP_CA_BUNDLE
        )
    except requests.RequestException as exc:
        st.session_state["login_error"] = _pep_error_message(exc)
        return False

    if resp.status_code == 200:
        data = resp.json()
        claims = _claims(id_token)
        exp = float(claims.get("exp", 0))
        # The chat is only usable while the token is valid, so cap the session at the token's expiry.
        st.session_state.update(
            session_ref=data["session_ref"],
            session_issued_at=time.time(),
            session_ttl=int(min(data.get("expires_in", 3600), max(0.0, exp - time.time()))),
            id_token=id_token,
            id_token_exp=exp,
            user_label=claims.get("name") or claims.get("preferred_username") or "Signed-in user",
            runtime_session_id=f"claims-{uuid.uuid4().hex}",
            messages=[],
        )
        return True

    errors = {
        401: "The PEP rejected the Entra ID token. Sign in again to get a fresh token.",
        422: "The PEP rejected the request as invalid.",
        429: "PEP rate limit reached. Wait a minute and try again.",
    }
    st.session_state["login_error"] = errors.get(resp.status_code, f"PEP Plane A returned HTTP {resp.status_code}.")
    return False


def sign_out() -> None:
    for key in ("session_ref", "login_url", "runtime_session_id", "id_token"):
        st.session_state[key] = None
    st.session_state.update(messages=[], session_issued_at=0.0, session_ttl=0, id_token_exp=0.0, user_label="")


def session_seconds_left() -> int:
    if not st.session_state["session_ref"]:
        return 0
    return max(0, int(st.session_state["session_issued_at"] + st.session_state["session_ttl"] - time.time()))


def handle_login_callback() -> None:
    code = st.query_params.get("code")
    state = st.query_params.get("state")
    if not (code and state):
        return

    params = {k: st.query_params[k] for k in st.query_params}
    st.query_params.clear()
    flow = _take_flow(state)
    if not flow:
        st.session_state["login_error"] = "The sign-in attempt expired or was already used. Please try again."
        return

    result = _msal_app().acquire_token_by_auth_code_flow(flow, params)
    id_token = result.get("id_token")
    if not id_token:
        st.session_state["login_error"] = result.get("error_description") or "Entra ID did not return an ID token."
        return
    init_pep_session(id_token)
    del id_token, result  # the session now holds the one copy needed for the agent's bearer auth


def _agent_url() -> str | None:
    parts = BEDROCK_AGENT_ID.split(":")
    if len(parts) < 6 or parts[0] != "arn":
        return None
    return (f"https://bedrock-agentcore.{parts[3]}.amazonaws.com/runtimes/"
            f"{quote(BEDROCK_AGENT_ID, safe='')}/invocations")


def ask_agent(prompt: str) -> str:
    """POST the prompt and the opaque session_ref to the JWT-protected AgentCore endpoint."""
    url = _agent_url()
    if not url:
        return "âš ï¸ BEDROCK_AGENT_ID must be the full AgentRuntimeArn."
    if not st.session_state["id_token"] or time.time() >= st.session_state["id_token_exp"]:
        return "âš ï¸ Your sign-in expired. Sign out and sign in again."
    try:
        resp = requests.post(
            url,
            params={"qualifier": "DEFAULT"},
            headers={
                "Authorization": f"Bearer {st.session_state['id_token']}",
                "Content-Type": "application/json",
                "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": st.session_state["runtime_session_id"],
            },
            json={"prompt": prompt, "session_ref": st.session_state["session_ref"]},
            timeout=300,
        )
    except requests.RequestException as exc:
        return f"âš ï¸ The agent could not be reached ({type(exc).__name__})."
    if resp.status_code in (401, 403):
        return "âš ï¸ The agent rejected your sign-in token. Sign out and sign in again."
    if resp.status_code != 200:
        return f"âš ï¸ The agent returned HTTP {resp.status_code}: {resp.text[:300]}"

    try:
        body = resp.json()
    except ValueError:
        return resp.text
    if isinstance(body, dict):
        return body.get("response") or f"âš ï¸ {body.get('error', 'The agent returned no answer.')}"
    return str(body)


def render_sidebar() -> None:
    with st.sidebar:
        st.header("ðŸ›¡ï¸ Claims Copilot")
        if st.session_state["session_ref"]:
            left = session_seconds_left()
            st.success(f"Signed in as **{st.session_state['user_label']}**", icon="âœ…")
            st.caption(f"Session expires in {left // 60} min. It cannot be extended; sign in again afterwards.")
            if st.button("Sign out", use_container_width=True):
                sign_out()
                st.rerun()
        st.divider()
        st.caption(
            "Your Entra ID token goes to the PEP (Plane A) and to AgentCore's sign-in check, which "
            "drops it before the agent runs. The agent sees an opaque `session_ref`, never your token. "
            "Lake Formation filters the data for your identity."
        )


def render_login() -> None:
    st.title("ðŸ›¡ï¸ Secure Insurance Claims Copilot")
    st.caption(
        "Conversational analysis of the insurance_analytics Lakehouse. Per-user row and column "
        "security is enforced by the Zero-Trust Broker and AWS Lake Formation."
    )
    if st.session_state["login_error"]:
        st.error(st.session_state["login_error"], icon="â›”")

    st.subheader("Sign in")
    st.info(
        "You choose the account during the Microsoft sign-in (including MFA). Your real Entra ID identity "
        "decides what data you can see.",
        icon="â„¹ï¸",
    )

    if st.session_state["login_url"]:
        st.link_button("Continue to Microsoft sign-in âžœ", st.session_state["login_url"], type="primary")
        st.caption("The sign-in opens in a new tab and brings you back to the chat there.")
    elif st.button("Sign in with Microsoft", type="primary"):
        st.session_state["login_error"] = None
        start_login()
        st.rerun()


def render_chat() -> None:
    st.title("ðŸ’¬ Ask about claims")
    if session_seconds_left() == 0:
        st.warning("Your PEP session has expired. Sign out and sign in again.", icon="â³")
        return

    for message in st.session_state["messages"]:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])

    prompt = st.chat_input("Ask about claims, fraud risk or paymentsâ€¦")
    if not st.session_state["messages"]:
        st.caption("Try:")
        for example in EXAMPLES:
            if st.button(example, key=f"ex-{example}"):
                prompt = example

    if prompt:
        st.session_state["messages"].append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)
        with st.chat_message("assistant"):
            with st.spinner("Discovering the schema and querying the Lakehouseâ€¦"):
                answer = ask_agent(prompt)
            st.markdown(answer)
        st.session_state["messages"].append({"role": "assistant", "content": answer})
        st.rerun()


handle_login_callback()
render_sidebar()
if st.session_state["session_ref"]:
    if BEDROCK_AGENT_ID:
        render_chat()
    else:
        st.error("BEDROCK_AGENT_ID is not set in .env (use the AgentRuntimeArn stack output).", icon="â›”")
else:
    render_login()
