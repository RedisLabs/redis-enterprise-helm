# UI On-Prem Helm chart

This chart deploys the on-prem Iris UI gateway: a single nginx pod that serves
the Iris UI SPA's static build, its runtime product config, and reverse
proxies `/api/<product>/*` to configured service backends. There is
ClusterIP-only `Service`, and an optional Ingress (see below) for reaching it
through the customer's ingress controller. It deliberately does not deploy or
generate anything else: no product control planes, no TLS certificates beyond
an optional BYO CA reference, no license material.

See the sibling `iris/ui/src/types/config.ts` contract this chart's `/config.json`
must match exactly.

## Install

The chart is published as `redis-ai/redis-iris-ui` in the public Helm repository, and
its gateway image as `redislabs/iris-ui-gateway`; no source build or registry
credentials are needed. Declare at least one product (see
[Declaring products](#declaring-products)) in a values file:

```bash
helm repo add redis-ai https://helm.redis.io/ai
helm repo update
helm search repo redis-ai/redis-iris-ui --versions
```

```yaml
# ui-values.yaml
products:
  - key: memory
    label: "Agent Memory"
    product: agent_memory
    authScheme: bearer
    healthPath: /health/readiness
    upstream:
      host: redis-agent-memory-controlplane.<namespace>.svc.cluster.local
      port: 9100
      scheme: http
```

```bash
helm install iris-ui redis-ai/redis-iris-ui --version <version> \
  --namespace <namespace> -f ui-values.yaml
```

A release's `image.tag` defaults to the chart's published version, so the chart
and the gateway image stay in step. Resources are named `<release>-redis-iris-ui`
(`fullnameOverride` replaces that name). Set `tests.enabled=true` and
run `helm test <release>` to check the gateway's `/healthz`.

## Declaring products

Everything the gateway does is driven by `values.yaml`'s `products[]` — the
same list feeds both the reverse-proxy map and the SPA-facing `/config.json`
(upstream fields never appear in the latter):

```yaml
products:
  - key: memory                 # matches /api/<key>/*
    label: "Agent Memory"       # SPA product-nav display name
    product: agent_memory       # agent_memory | playbook | lens | identity | context_gateway | intent (data-plane routes share their product's value)
    authScheme: bearer          # bearer | apiKey
    healthPath: /health/readiness # readiness route at the upstream's root; also drives an
                                 # exact-match proxy location bypassing basePath below
    upstream:
      service: redis-agent-memory-controlplane  # a Service in the release namespace: <fullnameOverride>-controlplane
      # host: redis-agent-memory-controlplane.<namespace>.svc.cluster.local  # instead of service, for an upstream in another namespace
      port: 9100
      basePath: ""               # empty or "/<path>" with no trailing slash; the Agent Memory SDK paths carry /v2
      scheme: http                # http | https
      caSecretName: ""            # https only: a Secret with a "ca.crt" key to trust
      insecureSkipVerify: false   # https only: skip verification entirely (explicit escape hatch)
```

Each upstream names either `service` or `host`. `service` is a Service in the
release namespace: the gateway reaches it as
`<service>.<release namespace>.svc.<clusterDomain>`. `host` is a
fully qualified name, for an upstream in another namespace; it wins when both
are set. nginx's resolver does not apply the pod's DNS search domains, so a
bare name in `host` is rejected.

### Under redis-iris

When the chart runs as the `ui` dependency of the `redis-iris` umbrella
(`global.iris` is set), the umbrella derives:

| Value | Under redis-iris |
| --- | --- |
| `products` | the routes of the enabled products: `memory`; `playbook` and `playbook-dp`; always `api-keys`. An entry overrides a route by `key` and may change only `label`, `showInNavigation`, and `maxRequestBodyBytes`; a duplicate or unknown key, or any other differing field, fails. An entry for a disabled product is kept and adds no route. |
| `sso.issuer`, `sso.accessTokenIssuer`, `sso.audience`, `sso.roleClaims`, `sso.allowInsecureTransport` | `global.iris.auth.oidc` (insecure transport when a URL ui-auth fetches, the discovery issuer or `jwksURI`, is `http://`; an `http://` access-token issuer is only compared with a token's `iss` and needs none) |
| `sso.tls.caCertSecret` | `global.tls.caCertSecret` |
| `sso.roleMappings` | `global.iris.auth.roleBindings`, per enabled product and `identity`, suite scope copied under each |
| `clusterDomain`, `publicURL` | `global.iris.clusterDomain`, `global.iris.publicURL` |
| `ingress.host`, `ingress.className`, `ingress.tls.secretName` | the `global.iris.publicURL` host, `global.iris.ingress.*` |

Leave these unset: a value that differs fails the render and names the
`ui.<path>` field. With `sso.enabled` (the umbrella's default) the render fails,
naming the field, unless `global.iris.auth.oidc.{issuer,jwksURI}`,
`global.iris.publicURL`, and `sso.{clientId,clientCredential.existingSecret,redis.existingSecret}`
are set; Admin Token mode (`sso.enabled: false`) needs none of them.

For `scheme: https`, exactly one of `caSecretName` or `insecureSkipVerify: true`
is required — the chart fails `helm template`/`helm install` otherwise (see
`templates/validation.yaml`). There is no silent default trust.

Each product route may set `maxRequestBodyBytes` (default 1 MiB, the existing
nginx default). Configure it to match that upstream product's request-body limit;
the gateway does not discover product limits automatically. For Playbook DP,
set `8388608` to match its existing 8 MiB request limit. A maximum-size 5 MiB
Skill ZIP occupies about 6.67 MiB as base64, plus its JSON envelope. DP continues
to enforce the separate archive, expanded-content, and metadata limits.
Oversized gateway requests return HTTP 413 with
`application/problem+json` and type `/errors/payload-too-large`, matching the
Playbook DP problem type. This setting stays server-side and does not change
another route's limit or override the upstream service's own limits.
The Playbook example in `values.yaml` sends inventory/settings to CP and content
requests to DP. Set `showInNavigation: false` on the DP route so `/config.json`
shows one Playbook product while nginx still serves `/api/playbook-dp/*`. Both
routes stay on the UI origin, so the browser needs no CORS policy. Configure
TLS at the browser ingress and verified upstream TLS when required by the
deployment; `caSecretName` applies to the DP route too.

The Intent Router example does the same with `intent` (CP, port 9400) and the hidden
`intent-data` (DP, port 9401), both `product: intent`. With SSO on, the gateway adds
the operator's access token to both routes and the console asks for no data-plane
credential; enable `dataplane.oidc` in the Intent chart so the data plane accepts it.
Only `product_admin` and `suite_admin` can read intents, examples, and match, so
operators and viewers see the Router list but not a Router's intents.
Without SSO the console asks for an agent key for each Router.

An `api-keys` route (`product: identity`, `basePath: ""`, `healthPath: /health/readiness`)
sends `/api/api-keys/*` to the control API of the standalone
[`iris-identity-service`](../../../identity-service/helm/README.md) release, on
port 9200 of its Service: `service: <fullname>` in the UI's namespace, or
`host: <fullname>.<namespace>.svc.<clusterDomain>` in another one. Use the
IdS release's actual Service name (`kubectl get svc -n <namespace>`): its
`fullnameOverride` if set, otherwise the release name when it contains the chart
name (`iris-identity-service`, or the IdS chart's `nameOverride`), otherwise
`<release>-<chart name>`. A release named after the chart gives
`iris-identity-service`. Memory and
Playbook no longer embed an Identity Service. The SPA lists the route as "API
Keys" for users who can see Agent Memory, Playbook or Context Gateway. In Admin
Token mode (`sso.enabled: false`) the `/api-keys` page asks for the Identity
Service control token: the IdS chart's `control.existingSecret`, or its generated
`<fullname>-control-token` Secret. With SSO on, the gateway forwards the IdP
access token instead, so the IdS release must enable `controlAuth.oidc` with
`sso.audience` as its audience and the access token's issuer,
`coalesce(sso.accessTokenIssuer, sso.issuer)`, as its issuer, and define
`controlAuth.roleBindings` for the groups that manage keys (see
[Operator login and subject grants](../../../identity-service/helm/README.md#operator-login-and-subject-grants)
for its tenant source and product-scoped bindings). `identity` has no UI
permissions of its own, so `sso.roleMappings` needs no `identity` entry: the page's
key actions follow the user's permissions on the products a key grants. Those
permissions only decide what the UI shows: the Identity Service allows every key
operation, including listing, for a signed-in user only to a `suite_admin` or to a
`product_admin` bound to the product in `controlAuth.roleBindings`. A `product_admin` that exists only in
`sso.roleMappings` sees the key actions and is refused, so bind the same groups in
both places. A deployment binding can also give a user `deployment_admin`, which the
Identity Service allows to list and revoke keys but not to create, update or rotate
them; the UI does not know this role and shows such a user no key actions. Without an
`api-keys` route, the SPA hides the entry and the page.

A `lens` route (`product: lens`, `basePath: ""`) sends `/api/lens/*` to the Lens
data plane root, because the Lens SDK paths carry `/iris/data/v1beta1/lens/instances/<id>`. Set
`instanceId` on the route to the Lens chart's `instance.id`; it defaults to
`default`, the Lens chart's own default. The SPA reads that instance and asks
for a Lens read key on its `/lens` page.

For Context Gateway, use route key `context-gateway` and permission product
`context_gateway`; its backend product identity is `context-gateway`. Keep
`showInNavigation: false` because this integration provides session-authenticated
API access without a management screen. Follow the
[paired Gateway and UI configuration example](../../../context-gateway/helm/README.md#enable-idp-administration-and-shared-ui-sessions)
for the full OIDC settings, role mappings, proxy route and verification steps.

## Role mapping

The UI shows a user the screens and actions their IdP groups allow. `sso.roleClaims`
(default `roles` and `groups`) names the access-token claims that carry the groups, and
`sso.roleMappings` maps each group to an Iris role per product:

```yaml
sso:
  roleMappings:
    agent_memory: {iris-admins: product_admin, memory-ops: operator}
    playbook: {iris-admins: product_admin}
```

A group no mapping lists grants nothing, and a product with no mapping gives its users no
permissions in the UI. Groups match case-insensitively. The roles are `suite_admin`,
`product_admin`, `operator` and `viewer`.

**This mapping must match each product's backend configuration.** Agent Memory and
Playbook use `roleClaims` and `roleMappings`; Context Gateway uses
`controlplane.config.auth.oidc.role_claims` and `role_mappings`. The backends enforce access from their own copy; this one
only decides what the UI shows. The two are separate until the unified Helm chart
([MOD-16621](https://redislabs.atlassian.net/browse/MOD-16621)) renders one mapping for every
chart. A mismatch shows a user screens whose calls the backend then refuses, or hides ones it
would allow. Roles are read at sign-in and again each time the access token is refreshed, so a
change to a user's groups shows within one access-token lifetime.

## Exposing the UI

The chart renders a ClusterIP `Service` only. To reach the UI at a stable HTTPS
hostname, enable the optional Ingress:

```yaml
publicURL: https://iris.corp.example   # the URL operators use; https:// only
ingress:
  enabled: true
  className: <your ingress class>
  host: iris.corp.example              # required when enabled
  annotations: {}                      # controller-specific settings, passed through as given
  tls:
    secretName: iris-tls               # existing TLS Secret; omit for no tls block
```

- The Ingress is one host rule, path `/`, forwarding to the UI Service's port
  (`service.port`). It is only a rule for **your** ingress controller, which Iris does
  not ship, and the chart sets no controller annotations. All path routing
  (`/api/<key>/*`) stays in the UI nginx.
- You own DNS, the certificate and the controller. No internet-facing URL is required.
- `publicURL` is empty by default. When set it must be `https://` (or
  `http://localhost[:port]` for local development) and must be a dedicated hostname:
  no path, query or fragment. Rendering fails otherwise.
- Supported front doors: this Ingress only. The Service stays `ClusterIP`
  (`NodePort` and `LoadBalancer` are rejected by the schema). An OpenShift Route, Gateway
  API `HTTPRoute`, mesh gateway or external load balancer is authored by you and pointed
  at the UI Service.
- The UI is served at its own hostname; a path prefix is not supported.
- Request body size and timeouts are enforced by your controller before they reach the UI
  nginx (for example ingress-nginx caps bodies at 1 MiB by default), so raise them there
  to match any `maxRequestBodyBytes` you set on a product.
- The Ingress publishes the console and each product's health route. With SSO off,
  operators supply product credentials. With SSO on, the shell signs operators in
  and nginx forwards the session's access token to product APIs. The console and
  health routes remain accessible without a session; use your ingress controller
  or network policy to limit who can reach them.
- Without the Ingress, reach the UI with `kubectl port-forward`.

### Security headers

The UI nginx sets these on the app's own responses (the SPA's pages and static assets
and `/config.json`), whether or not SSO is enabled:

| Header | Value |
|---|---|
| `Content-Security-Policy` | `default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; base-uri 'self'; form-action 'self'; frame-ancestors 'none'` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `same-origin` |
| `Strict-Transport-Security` | `max-age=31536000`, only when `publicURL` is `https://` |

- Proxied `/api/<key>/*` responses are the products' own and get none of these.
- `base-uri` and `form-action` are `'self'`: neither falls back to `default-src`.
- `'unsafe-inline'` styles are needed because the design system injects `<style>` tags at
  run time; scripts stay `'self'` only.
- The design system's CSS still `@import`s Google Fonts. The policy does not allow those
  hosts, so the console makes no third-party request and shows system fonts. Allow
  `https://fonts.googleapis.com` in `style-src` and `https://fonts.gstatic.com` in
  `font-src` in `templates/configmap-nginx.yaml` only if you want the web fonts.
- The chart sets no CORS headers, and none of its responses carry credentialed CORS.
- Your ingress may add its own headers; the chart does not remove them.

## Sign-in with your IdP (SSO)

`sso.enabled` (default `false`) adds the UI auth service next to the gateway: a Deployment,
a ClusterIP Service, a ConfigMap, a generated session-key Secret and a NetworkPolicy. With SSO
off none of them render and the UI works as before (operators paste each product's admin token).

This section is the values reference. For the procedure (registering Iris with your IdP,
secrets, ingress limits, recovery when the IdP is down) see the
[operator SSO guide](../../../docs/iris-onprem-ui-sso-guide.md).

With SSO on, nginx checks every product call. The shell checks `/auth/me` and
redirects operators without a session to `/auth/login`, preserving the current
path and query for their return after sign-in. After logout, the shell shows a
Sign in button so operators can start a new session.

- `/auth/*` is proxied to the UI auth service (sign-in, callback, `me`, logout).
- Each `/api/<key>/*` call first goes to an internal `auth_request` check. The service answers `401` (no
  session), `403` (not a configured product route, or a write without the CSRF token and a same-origin
  request) or `200` with the session's access token, which nginx sends to the product as
  `Authorization: Bearer`. The browser's `Cookie` and `X-CSRF-Token` are never passed to a product.
- A route with `protectedResourceMetadata: true` gets one more location,
  `GET /api/<key>/.well-known/oauth-protected-resource/...`, for the product's RFC 9728 metadata. That
  location is not session-checked, takes only `GET`, and passes no `Authorization`, `Cookie` or
  `X-CSRF-Token` to the product. Every other path of the route stays session-checked. The Context Gateway
  data plane route (`context-gateway-dp`) sets it: the console reads a Gateway's sign-in metadata there
  without a credential, while `/api/context-gateway-dp/iris/data/v1/context-gateway/gateways/<id>/mcp` and the rest of the data
  plane still need a session.
- The check drops the request body but keeps the browser's headers: the CSRF and origin checks need
  `Origin`, `Sec-Fetch-Site` and `X-CSRF-Token`.
- The console, its static assets and `/config.json` need no session. Product health routes need none
  either, but do not carry the session cookie.
- `/config.json` becomes `{"products": [...], "sso": {"enabled": <bool>}}`, each product with its `product`.
  The shell still reads the bare array an older chart renders, but an older gateway image cannot read
  this shape: upgrade the chart and `image.tag` together.

Required when `sso.enabled` is `true` (rendering fails otherwise): a `publicURL`, `sso.issuer`
(https; the UI auth service fetches its discovery document), `sso.clientId`, `sso.audience` (default `api://redis-iris`), `sso.clientCredential.existingSecret`,
`sso.redis.existingSecret` and at least one entry in `products`, all with `authScheme: bearer` (nginx sends the access token as a bearer, which an `apiKey` product rejects). Register
`<publicURL>/auth/callback` as the redirect URI at the IdP.

| Value | Purpose |
|---|---|
| `sso.clientCredential.existingSecret` + `clientSecretKey` / `privateKeyKey` | IdP client secret, or a PEM private key for `private_key_jwt`. Always yours: it cannot be generated. **Entra ID client secrets expire after at most 2 years, and then every sign-in fails: prefer a certificate credential (`privateKeyKey`), or track the secret's expiry in a calendar and rotate it before then.** |
| `sso.session.existingSecret` + `secretKey` | Session encryption key. Empty: the chart generates `<release>-redis-iris-ui-auth-session-key` and keeps it on upgrade. |
| `sso.redis.existingSecret` + `urlsKey` | Session Redis URL(s). They carry credentials, so they come from a Secret; use `rediss://` under FIPS. |
| `sso.tls.caCertSecret` + `caCertKey` | Private CA for the IdP or Redis, added to the system roots. |
| `sso.scopes` (replaces the default list, and must keep `openid`), `sso.claims`, `sso.session.idleTimeout`, `sso.session.absoluteLifetime` | Passed to the service as they are. |
| `sso.audience`, `sso.audienceParameter`, `sso.accessTokenIssuer` | Passed to the service as `audience`, `audience_parameter` (`none` is left out) and `access_token_issuer`. The service checks the access token's `aud` against `sso.audience` at sign-in and refuses the sign-in on a mismatch, so the value must be the one your IdP puts in `aud`. `sso.accessTokenIssuer` may be `http://` or `https://`: it is an identifier compared with the token's `iss` and never fetched. On AD FS set it to the discovery document's `access_token_issuer` (`http://<host>/adfs/services/trust`) and keep `sso.issuer` on the HTTPS discovery issuer. The backends' `issuer` must be the same value. |
| `sso.roleClaims`, `sso.roleMappings` | Passed to the service. It maps the access token's `roleClaims` to Iris roles with `roleMappings` (`{product: {group: role}}`, the shape the product charts use; keys must be `product` values used in `products`) and gives the user permissions per product. See [Role mapping](#role-mapping). |
| `uiAuth.image`, `uiAuth.replicas`, `uiAuth.resources` | The workload. `uiAuth.image.tag` defaults to `image.tag`. |
| `podDisruptionBudget.enabled` | A PodDisruptionBudget (`maxUnavailable: 1`) for the gateway and ui-auth when their replicas are above 1. Off by default; redis-iris turns it on. |
| `nginx.limits.*` | Body size, response-header buffers (a large access token and the sign-in redirects and cookies must fit; at least 4 buffers) and timeouts for `/auth/*` and the session check on every product call. Upload routes keep only each product's `maxRequestBodyBytes`; there is no upload timeout setting. Your ingress controller enforces its own limits first, so raise those to match. |
| `uiAuth.networkPolicy.enabled`, `uiAuth.networkPolicy.egress` | Ingress is allowed only from the gateway pods. Egress is unrestricted unless you list CIDRs for the IdP and Redis; then it is limited to those plus DNS. Network policy sees the pod IP after a Service's address is translated, so an in-cluster Redis needs its pod CIDR here, not its Service's ClusterIP. |

- **Rendering outside `helm install` / `helm upgrade` (Argo CD, Flux, Helmfile, `helm template`,
  `--dry-run`): set `sso.session.existingSecret`.** The chart keeps a generated session key across upgrades
  only because Helm's `lookup` finds the Secret already in the cluster. `lookup` returns nothing in those
  renderers, so every render or sync would generate a new key and sign every user out. Create the Secret
  yourself (for example `kubectl create secret generic iris-ui-session-key --from-literal=key="$(openssl rand -base64 32)"`)
  and point `sso.session.existingSecret` at it. (`helm.sh/resource-policy: keep` would not help: it only
  keeps the Secret on uninstall and does not change what a render generates.)
- **The session key** is the exact bytes of the Secret value, a trailing newline included, and every
  replica must mount the same Secret. Replacing it signs every user out; stop all replicas, then start
  them, rather than rolling.
- **Rate limiting sign-in:** the UI auth service caps unfinished sign-ins at 1,000 a minute across all
  replicas. That cap is global, not per client: nginx sits behind your ingress and does not trust forwarded
  addresses, so it cannot tell clients apart. Limit `/auth/login` per client on your ingress controller.
- **The session Redis** needs no persistence or backups: losing it only signs users out. The service
  exits at start-up if Redis does not answer, so pods restart while Redis is down.

### Operating the session store and the UI auth service

- **Redis ACL.** The service's Redis user needs `HSET`, `HGET`, `HGETALL`, `DEL`, `PEXPIRE`, `EXPIRE`,
  `INCR`, `EXISTS`, `EVAL`/`EVALSHA`, `MULTI`, `EXEC` and `PING`. Without the script or transaction
  commands the start-up ping passes and every sign-in then fails. Give nobody else write access to the
  `iris-ui-auth:` keys: a ciphertext copied between session records still decrypts.
- **Persistence.** Turn persistence and backups off (`save ""`, `appendonly no`): the store only holds
  sessions, and losing it signs users out.
- **Rotating the session key.** Replace the Secret value, then stop every UI auth replica (`kubectl scale
  --replicas=0`) and start them again. Do not roll them: a replica that cannot read a record deletes it,
  so old and new replicas would delete each other's sessions. The same applies to an upgrade that changes
  the session record format.
- **FIPS runtime posture.** The image links the Go FIPS module but the chart runs it with `GODEBUG=fips140=off`; there is no value to switch it on yet. Under FIPS the service accepts only `rediss://` session URLs.
- **`clusterDomain`** (default `cluster.local`) completes the auth Service's name for the gateway's nginx, whose resolver does not apply the pod's DNS search domains. Set it if your cluster uses another DNS domain; it also completes product `upstream.service` names. Empty means `cluster.local` (`global.iris.clusterDomain` under the `redis-iris` umbrella).
- **The gateway resolves the auth Service at run time.** The gateway's nginx (1.27.3 or later; the image is
  1.27) keeps connections alive to the service through an `upstream` block that re-resolves its name
  (`resolve`, every 10 seconds), so a missing auth Service does not stop the gateway from starting and a
  recreated one is picked up without a restart. Until the Service exists, product calls fail with `500`
  while the console, `/config.json` and health routes keep serving.
- **The nginx-to-auth-service hop is plain HTTP inside the cluster.** The UI auth service has no TLS
  listener, so the chart offers no `https` option for it. Browser TLS ends at your ingress; use a
  NetworkPolicy (on by default) to limit who can reach the service, or a mesh that adds mTLS
  transparently.
- **Start-up needs Redis.** The service exits if Redis does not answer or the key file is unreadable, so
  its pods restart while Redis is down. Signed-in users are denied meanwhile; the console and `/config.json`
  keep serving, and product health routes stay reachable.
- **Private CAs.** `sso.tls.caCertSecret` is added to the system roots for both the IdP and Redis
  connections, so one bundle can cover a private IdP and a private Redis.
- **Turning SSO off.** `helm upgrade` with `sso.enabled=false` returns the console to pasted admin tokens.
  The product control planes keep accepting them.
- **`sso.allowInsecureTransport`** exists only so the self-hosted test IdP (`development/test-idp`, plain
  http) can be used in local and KinD runs. Never set it for a real IdP.

## Local commands

From the repo root:

```bash
task ui:test:chart:lint  # helm lint with representative overrides
task ui:test:chart       # + offline template-render assertions and Go tests
task ui:build:docker     # build the gateway image
```

## Testing

- `tests/template-render.sh` — offline `helm lint`/`helm template` assertions
  (products present/absent, http vs. https, CA vs. insecure-skip, the optional
  Ingress and `publicURL` rules, and a bare `helm lint` with no overrides at all). Run on every push via
  `ui-ci.yml`'s `helm-chart-test`, no cluster needed.
- `../tests/lifecycle.sh` — a docker-only reverse-proxy smoke against two
  stub upstreams (one plain HTTP, one HTTPS behind a locally-generated CA),
  proving the rendered nginx config actually works, not just renders. Run on
  every push via `ui-ci.yml`'s `gateway-lifecycle`.
- `tests/kind-smoke.sh` — the same proof, but a real `helm install` on a KinD
  cluster with real Secret-mounted volumes and `kubectl port-forward`. It also
  signs users into Keycloak and exercises the session proxy against the real
  Context Gateway control plane: roles, tenant isolation, CSRF, expiry, refresh
  and logout. Branch Checks runs it through `.github/workflows/ui-helm-e2e.yml`
  for changes to the UI, UI auth, or Context Gateway control plane (same
  convention as `playbook-onprem-helm-test.yml`).
- `templates/tests/health.yaml` — a `helm test` hook (set `tests.enabled=true`)
  that curls the gateway's own `/healthz` through its Service. Not run by this
  repo's CI (which already covers the same ground via the two scripts above);
  it exists so an operator can self-verify a `helm install` in their own
  cluster with `helm test`, matching every sibling on-prem chart
  (`memory/helm`, `playbook/helm`, `lens/helm`).

### Run the Gateway session test locally

Run from the repository root after completing [onboarding](../../../ONBOARDING.md).
Use the approved Nix/direnv environment, a running Docker daemon, KinD, kubectl,
Helm, Bash, curl, jq and OpenSSL. The Docker CLI must support
`docker image save --platform`. Supply `NPM_AUTH_TOKEN` through your private
environment for the UI build; do not print it or enable shell tracing. Keep host
ports `8190` (IdP), `8080` (SSO callback) and `39300` (proxy smoke) free.

The harness installs the test IdP itself. Its issuer is
`http://idp.localhost:8190/realms/iris`: host curl resolves it to loopback, and
`development/test-idp/kind/install.sh` configures CoreDNS for pods. Do not start
the separate Compose IdP on port `8190`. KinD nodes must be able to pull the
Keycloak image in `development/test-idp/kind/keycloak.yaml`
(`quay.io/keycloak/keycloak:26.3.5`) and `redis:8`.

Use a checkout shared with the Docker VM, especially with Colima. The command
places `TMPDIR` inside that checkout so temporary files are visible to Docker;
this requires the checkout to be mounted in the VM. It uses an isolated
kubeconfig, refuses to reuse an existing test cluster, and removes its cluster
and temporary files on exit.

```bash
direnv exec . rtk proxy bash <<'BASH'
set -euo pipefail
set +x
umask 077

mkdir -p out
ui_test_dir="$(mktemp -d "$PWD/out/ui-helm-e2e.XXXXXX")"
export KUBECONFIG="$ui_test_dir/kubeconfig"
export TMPDIR="$ui_test_dir"
ui_test_cluster=iris-ui-helm-e2e
ui_cluster_created=false

cleanup() {
  ui_test_status=$?
  if "$ui_cluster_created"; then
    kind delete cluster --name "$ui_test_cluster" || ui_test_status=1
  fi
  rm -rf "$ui_test_dir"
  exit "$ui_test_status"
}
trap cleanup EXIT

ui_clusters="$(kind get clusters)"
if grep -Fxq "$ui_test_cluster" <<<"$ui_clusters"; then
  echo "Refusing to reuse existing cluster: $ui_test_cluster" >&2
  exit 1
fi

ui_test_platform="linux/$(docker version --format '{{.Server.Arch}}')"
export DOCKER_DEFAULT_PLATFORM="$ui_test_platform"

task context-gateway:generate
task ui:build:docker
task ui-auth:build:docker
docker build --target development \
  -t iris-context-gateway-controlplane-onprem:local \
  -f context-gateway/controlplane-onprem/Dockerfile .
docker build -t context-gateway-ts-upstream:helm-test \
  context-gateway/tests/fixtures/ts-upstream
docker pull traefik/whoami:latest

helm repo add redis-ai https://helm.redis.io/ai --force-update
helm dependency build iris/ui/helm

ui_cluster_created=true
kind create cluster --name "$ui_test_cluster" \
  --config development/test-idp/kind/cluster.yaml --wait 180s
docker image save --platform "$ui_test_platform" \
  --output "$ui_test_dir/ui-images.tar" \
  ui-gateway:latest iris-ui-auth:latest \
  iris-context-gateway-controlplane-onprem:local \
  context-gateway-ts-upstream:helm-test traefik/whoami:latest
kind load image-archive "$ui_test_dir/ui-images.tar" --name "$ui_test_cluster"

UI_KIND_CONTEXT="kind-$ui_test_cluster" \
UI_KIND_AUTH_IMAGE_REPO=iris-ui-auth \
  bash iris/ui/helm/tests/kind-smoke.sh
BASH
```

A successful run ends with `OK`, followed by cluster cleanup. The local UI Auth
task builds `iris-ui-auth:latest`, so the explicit image override is required.
The four local images and the echo image must all be loaded before invoking the
harness; the Gateway and MCP fixture Deployments do not pull their images.
