"""redis-iris suite verification, run by `helm test` (templates/tests/suite-verify.yaml).

Proves the installed suite works end to end, with the Python standard library only, for each enabled
product (MEMORY_ENABLED, PLAYBOOK_ENABLED, LENS_ENABLED, CONTEXT_GATEWAY_ENABLED, INTENT_ENABLED):
  1. checks each control plane is ready, which includes a valid license;
  2. uses each admin token on its control plane: creates a store (Memory), a Playbook, a Gateway
     (Context Gateway, which must advertise CONTEXT_GATEWAY_PUBLIC_BASE_URL plus its path) and a
     Router (Intent Router), and reads the Lens instance;
  3. mints a key scoped to each with the Identity Service Control token, which makes the Identity
     Service validate the grant against that control plane (internal token);
  4. uses each key on its data plane, which makes the data plane introspect it at the Identity Service
     (data-plane credential): Memory writes and reads a session event, Playbook searches its FAQs,
     Lens lists the instance's agents (read only: Lens keeps what it ingests), Context Gateway lists
     the Gateway's MCP tools, and Intent Router upserts an intent and matches it once the Router is
     READY; a read-only Intent Router key is refused the write (403);
  5. with EXTRACTION_ENABLED (global.iris.extraction.enabled), proves the Playbook -> Memory trust without
     an LLM: an extraction binding of the store to the Playbook is created READY (the Memory control plane
     confirmed ownership to the Playbook control plane), and the Playbook worker's projected token, which
     this Pod runs with, reads the session from the Memory data plane;
  6. calls the UI gateway's health routes, sending no credential to any route.
Everything it creates carries a name unique to this run, and it deletes only the identifiers it recorded
when creating them, never a resource found by name: a customer's resource can share any name. The session,
keys, binding, store, and Playbook are removed on exit, failure and SIGTERM included. Each removal is attempted on
its own, so a transport error on one does not skip the others. A run killed outright (SIGKILL, node loss)
leaves its resources behind; they are named iris-suite-verify-<run> for the operator to remove.
"""

import http.client
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request
import uuid

NAME = "iris-suite-verify-" + uuid.uuid4().hex[:12]
MEMORY = os.environ.get("MEMORY_ENABLED") == "true"
PLAYBOOK = os.environ.get("PLAYBOOK_ENABLED") == "true"
EXTRACTION = os.environ.get("EXTRACTION_ENABLED") == "true"
IDS = os.environ["IDS_URL"]
MEMORY_CP = os.environ.get("MEMORY_CP_URL", "")
MEMORY_DP = os.environ.get("MEMORY_DP_URL", "")
PLAYBOOK_CP = os.environ.get("PLAYBOOK_CP_URL", "")
PLAYBOOK_DP = os.environ.get("PLAYBOOK_DP_URL", "")
LENS = os.environ.get("LENS_ENABLED") == "true"
LENS_CP = os.environ.get("LENS_CP_URL", "")
LENS_DP = os.environ.get("LENS_DP_URL", "")
GATEWAY = os.environ.get("CONTEXT_GATEWAY_ENABLED") == "true"
GATEWAY_CP = os.environ.get("CONTEXT_GATEWAY_CP_URL", "")
GATEWAY_DP = os.environ.get("CONTEXT_GATEWAY_DP_URL", "")
GATEWAY_PUBLIC = os.environ.get("CONTEXT_GATEWAY_PUBLIC_BASE_URL", "").rstrip("/")
INTENT = os.environ.get("INTENT_ENABLED") == "true"
INTENT_CP = os.environ.get("INTENT_CP_URL", "")
INTENT_DP = os.environ.get("INTENT_DP_URL", "")
# The one configured embedding model: a Router's vector space must be it.
INTENT_EMBEDDING = json.loads(os.environ.get("INTENT_EMBEDDING", "{}"))
# The first configured embedding model: the control plane refuses a Playbook with any other.
PLAYBOOK_EMBEDDING = json.loads(os.environ.get("PLAYBOOK_EMBEDDING", "{}"))
UI = os.environ["UI_URL"]
DATABASE = os.environ.get("MEMORY_DATABASE_ID", "")
TIMEOUT = 30


def secret(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


CONTROL = secret("/etc/suite-verify/control/token")
ADMIN = secret("/etc/suite-verify/admin/token") if MEMORY else ""
PLAYBOOK_ADMIN = secret("/etc/suite-verify/playbook-admin/token") if PLAYBOOK else ""
LENS_ADMIN = secret("/etc/suite-verify/lens-admin/token") if LENS else ""
GATEWAY_ADMIN = secret("/etc/suite-verify/context-gateway-admin/token") if GATEWAY else ""
INTENT_ADMIN = secret("/etc/suite-verify/intent-admin/token") if INTENT else ""
# MCP protocol 2026-07-28 is stateless: a client lists tools with no initialize.
MCP_TOOLS_LIST = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {"_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {"name": "iris-suite-verify", "version": "1.0.0"},
    "io.modelcontextprotocol/clientCapabilities": {}}}}
MCP_HEADERS = {"Accept": "application/json, text/event-stream", "Mcp-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"}
# The Playbook worker's projected ServiceAccount token (audience api://memory-dp), read when used: it rotates.
WORKER_TOKEN = "/etc/suite-verify/worker/token"


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def request(method, url, token=None, payload=None, headers=None):
    """Returns (status, body): parsed JSON, else text (the gateway's /healthz, an MCP event stream), else None.

    A 2xx body is never printed: it can hold a key."""
    headers = {"Content-Type": "application/json", **(headers or {})}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            body = response.read()
            if not body:
                return response.status, None
            try:
                return response.status, json.loads(body)
            except ValueError:
                return response.status, body.decode(errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")[:500]


def expect(status, want, what, body=None):
    if status != want:
        fail(f"{what} answered {status}, want {want}" + (f": {body}" if body and not 200 <= status < 300 else ""))


def remove(what, url, token):
    """Deletes one resource; returns False, after reporting why, if it may still exist."""
    try:
        status, _ = request("DELETE", url, token)
    except (OSError, http.client.HTTPException) as error:  # URLError and timeouts are OSErrors
        print(f"FAIL: removing the {what} ({url}) raised {error!r}", file=sys.stderr)
        return False
    if status not in (200, 202, 204, 404):  # 202: an extraction binding is deleted asynchronously
        print(f"FAIL: removing the {what} ({url}) answered {status}", file=sys.stderr)
        return False
    print(f"removed the {what}")
    return True


def mint(cleanup, what, grant):
    """Mints a key with one grant, registers its removal, and returns its token."""
    status, body = request("POST", f"{IDS}/v1/api-keys", CONTROL, {"name": NAME, "grants": [grant]})
    expect(status, 201, f"minting a {what} key (the Identity Service validates it with {grant['product']})", body)
    cleanup.append((f"{grant['product']} key", f"{IDS}/v1/api-keys/{body['keyId']}", CONTROL))
    print(f"OK: minted {what} key {body['keyId']}; the Identity Service validated the {grant['product']} grant")
    return body["token"]


def wait_router_ready(router):
    """Polls the Router until the data plane has applied it (state READY)."""
    url = f"{INTENT_CP}/iris/v1/intent/routers/{router}"
    state = None
    for _ in range(60):
        status, body = request("GET", url, INTENT_ADMIN)
        expect(status, 200, "reading the Router with the Intent Router admin token", body)
        state = body.get("state")
        if state == "READY":
            return
        time.sleep(2)
    fail(f"Router {router} is {state} after 120s, want READY")


def check_extraction(cleanup, playbook, store, session_url):
    """Playbook -> Memory machine trust, global.iris.extraction (MOD-20409)."""
    bindings = f"{PLAYBOOK_CP}/iris/v1/agent-playbooks/playbooks/{playbook}/extraction/bindings"
    status, body = request("POST", bindings, PLAYBOOK_ADMIN, {
        "source": {"kind": "REDIS_AGENT_MEMORY", "storeId": store}, "job": {"kind": "FAQ", "idleWindowSeconds": 60}})
    expect(status, 201, "creating an extraction binding (the Playbook control plane checks store ownership with the "
           "Memory control plane over workload identity, audience api://memory-cp)", body)
    cleanup.append(("extraction binding", f"{bindings}/{body['bindingId']}", PLAYBOOK_ADMIN))
    if body.get("state") != "READY":
        fail(f"the extraction binding was created {body.get('state')}, want READY")
    print(f"OK: extraction binding {body['bindingId']} READY; the Memory control plane trusted the Playbook control plane")
    status, body = request("GET", session_url, secret(WORKER_TOKEN))
    if status == 401:
        fail("the Memory data plane rejected the Playbook worker's token (401): global.iris.workloadIdentity "
             "{issuer,jwksURI} must match the cluster's ServiceAccount issuer; run the suite preflight")
    expect(status, 200, "reading the session with the Playbook worker's token", body)
    print("OK: the Memory data plane accepted the Playbook worker's projected token")


def main(cleanup):
    # Readiness gates on the license probe, so a 200 means each control plane accepted its license.
    for product, url in (("Memory", MEMORY_CP), ("Playbook", PLAYBOOK_CP), ("Lens", LENS_CP),
                         ("Context Gateway", GATEWAY_CP), ("Intent Router", INTENT_CP)):
        if url:
            status, body = request("GET", f"{url}/health/readiness")
            expect(status, 200, f"{product} control plane readiness (license included)", body)
            print(f"OK: {product} control plane ready, license valid")

    if MEMORY:
        stores = f"{MEMORY_CP}/iris/v1/agent-memory/stores"
        status, body = request("POST", stores, ADMIN, {"name": NAME, "database": {"databaseId": DATABASE}})
        expect(status, 201, "creating a store with the admin token", body)
        store = body["storeId"]
        cleanup.append(("store", f"{stores}/{store}", ADMIN))
        print(f"OK: Memory control plane admin API (store {store})")
        memory_key = mint(cleanup, "store-scoped", {
            "product": "memory", "resourceType": "mem-store", "resourceId": store, "actions": ["read", "write"]})

    if PLAYBOOK:
        payload = {"name": NAME, "embedding": PLAYBOOK_EMBEDDING}
        status, body = request("POST", f"{PLAYBOOK_CP}/iris/v1/agent-playbooks/playbooks", PLAYBOOK_ADMIN, payload)
        expect(status, 201, "creating a Playbook with the Playbook admin token", body)
        playbook = body["playbookId"]
        cleanup.append(("Playbook", f"{PLAYBOOK_CP}/iris/v1/agent-playbooks/playbooks/{playbook}", PLAYBOOK_ADMIN))
        status, body = request("GET", f"{PLAYBOOK_CP}/iris/v1/agent-playbooks/playbooks", PLAYBOOK_ADMIN)
        expect(status, 200, "listing Playbooks with the Playbook admin token", body)
        if playbook not in [p["playbookId"] for p in body["items"]]:
            fail(f"the Playbook list does not hold the created Playbook {playbook}")
        print(f"OK: Playbook control plane admin API (Playbook {playbook})")
        playbook_key = mint(cleanup, "Playbook-scoped", {
            "product": "playbook", "resourceType": "playbook", "resourceId": playbook, "actions": ["read"]})

    if LENS:
        status, body = request("GET", f"{LENS_CP}/iris/v1beta1/lens/instance", LENS_ADMIN)
        expect(status, 200, "reading the Lens instance with the Lens admin token", body)
        print("OK: Lens control plane admin API")
        lens_key = mint(cleanup, "Lens read", {
            "product": "lens", "resourceType": "lens-instance", "resourceId": "default", "actions": ["read"]})

    if GATEWAY:
        gateways = f"{GATEWAY_CP}/iris/v1/context-gateway/gateways"
        status, body = request("POST", gateways, GATEWAY_ADMIN, {"name": NAME})
        expect(status, 201, "creating a Gateway with the Context Gateway admin token", body)
        gateway = body["gatewayId"]
        # A Gateway delete names the revision it removes.
        cleanup.append(("Gateway", f"{gateways}/{gateway}?expectedRevision={body['revision']}", GATEWAY_ADMIN))
        mcp_path = f"/iris/data/v1/context-gateway/gateways/{gateway}/mcp"
        if body.get("mcpEndpoint") != GATEWAY_PUBLIC + mcp_path:
            fail(f"Gateway {gateway} advertises {body.get('mcpEndpoint')}, want {GATEWAY_PUBLIC + mcp_path} "
                 "(contextGateway.publicBaseURL plus the Gateway path)")
        print(f"OK: Context Gateway control plane admin API (Gateway {gateway} advertises the public endpoint)")
        gateway_key = mint(cleanup, "Gateway-scoped", {
            "product": "context-gateway", "resourceType": "gateway", "resourceId": gateway, "actions": ["use"]})

    if INTENT:
        routers = f"{INTENT_CP}/iris/v1/intent/routers"
        status, body = request("POST", routers, INTENT_ADMIN, {"name": NAME, "vectorSpace": INTENT_EMBEDDING})
        expect(status, 201, "creating a Router with the Intent Router admin token", body)
        router = body["routerId"]
        cleanup.append(("Router", f"{routers}/{router}", INTENT_ADMIN))
        print(f"OK: Intent Router control plane admin API (Router {router})")
        intent_grant = {"product": "intent", "resourceType": "intent-router", "resourceId": router}
        intent_key = mint(cleanup, "Router-scoped", {**intent_grant, "actions": ["full"]})
        intent_read_key = mint(cleanup, "read-only Router-scoped", {**intent_grant, "actions": ["read"]})

    if os.environ.get("SUITE_VERIFY_FAIL_AFTER_MINT") == "1":
        fail("SUITE_VERIFY_FAIL_AFTER_MINT=1: failing after the mint, as a cleanup check")

    if MEMORY:
        session = "suite-verify-" + uuid.uuid4().hex[:16]
        marker = "suite-verify-" + uuid.uuid4().hex
        event = {
            "sessionId": session,
            "actorId": NAME,
            "role": "USER",
            "content": [{"text": marker}],
            "createdAt": "2026-01-01T00:00:00Z",
        }
        sessions = f"{MEMORY_DP}/iris/data/v1/agent-memory/stores/{store}/sessions"
        # Register before writing: a lost response may still leave a session behind.
        cleanup.append(("session", f"{sessions}/{session}", memory_key))
        status, body = request("POST", sessions, memory_key, event)
        expect(status, 201, "writing a session event with the key", body)
        status, body = request("GET", f"{sessions}/{session}", memory_key)
        expect(status, 200, "reading the session with the key", body)
        if marker not in json.dumps(body):
            fail("the session read back without the written event")
        print("OK: Memory data plane wrote and read a session event with the key (introspected by the Identity Service)")

    if PLAYBOOK:
        status, body = request("POST", f"{PLAYBOOK_DP}/iris/data/v1/agent-playbooks/playbooks/{playbook}/faqs/search", playbook_key,
                               {"query": "suite-verify"})
        expect(status, 200, "searching the Playbook's FAQs with the key", body)
        print("OK: Playbook data plane searched with the key (introspected by the Identity Service)")

    if LENS:
        status, body = request("GET", f"{LENS_DP}/iris/data/v1beta1/lens/instances/default/agents", lens_key)
        expect(status, 200, "listing the Lens instance's agents with the key", body)
        print("OK: Lens data plane read with the key (introspected by the Identity Service)")

    if GATEWAY:
        status, body = request("POST", GATEWAY_DP + mcp_path, gateway_key, MCP_TOOLS_LIST, MCP_HEADERS)
        expect(status, 200, "listing the Gateway's MCP tools with the key", body)
        if '"tools"' not in (body if isinstance(body, str) else json.dumps(body)):
            fail("the Gateway's MCP tools/list answered without a tools list")
        print("OK: Context Gateway data plane listed the Gateway's MCP tools with the key (introspected by the Identity Service)")

    if INTENT:
        wait_router_ready(router)
        intents = f"{INTENT_DP}/iris/data/v1/intent/routers/{router}/intents/suite_verify"
        example = {"examples": ["where is my order", "track my package"], "minScore": 0.3}
        status, body = request("PUT", intents, intent_read_key, example)
        expect(status, 403, "upserting an intent with the read-only key", body)
        status, body = request("PUT", intents, intent_key, example)
        if status not in (200, 201):
            fail(f"upserting an intent with the key answered {status}, want 200 or 201: {body}")
        status, body = request("POST", f"{INTENT_DP}/iris/data/v1/intent/routers/{router}/match", intent_key,
                               {"query": "where is my order"})
        expect(status, 200, "matching with the key", body)
        matched = (body.get("items") or [{}])[0].get("name")
        if matched != "suite_verify":
            fail(f"matching answered {matched}, want suite_verify")
        print("OK: Intent Router data plane matched an intent with the key and refused the read-only key's write (403)")

    if EXTRACTION:
        check_extraction(cleanup, playbook, store, f"{sessions}/{session}")
    else:
        print("SKIP: extraction (global.iris.extraction.enabled is false)")

    paths = ["/healthz", "/api/api-keys/health/readiness"]
    if MEMORY:
        paths.append("/api/memory/health/readiness")
    if PLAYBOOK:
        paths += ["/api/playbook/health/readiness", "/api/playbook-dp/health/readiness"]
    if LENS:
        paths.append("/api/lens/health/readiness")
    if GATEWAY:
        paths += ["/api/context-gateway/health/readiness", "/api/context-gateway-dp/health/liveness"]
    if INTENT:
        paths += ["/api/intent/health/readiness", "/api/intent-data/health/readiness"]
    for path in paths:
        status, body = request("GET", UI + path)
        expect(status, 200, f"UI gateway {path}", body)
    print("OK: UI gateway health routes, called without a credential")


def run():
    # before-hook-creation deletes a still-running pod with SIGTERM; exit through finally so it cleans up.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    cleanup = []
    try:
        main(cleanup)
    finally:
        # A list, not a generator: every removal runs even after one fails.
        if not all([remove(*entry) for entry in reversed(cleanup)]):
            sys.exit(1)
    print("PASS: redis-iris suite verified")


if __name__ == "__main__":
    run()
