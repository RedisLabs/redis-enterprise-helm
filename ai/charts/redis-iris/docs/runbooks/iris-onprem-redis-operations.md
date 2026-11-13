# redis-iris metadata Redis: credential rotation and planned outage

Use these procedures for the metadata Redis of a redis-iris install: the database that holds the
Identity Service's keys, every product's metadata, Agent Memory's job queue, and the UI session
store (TDD MOD-19479, "Metadata Redis operations"). The products read its URLs, credentials
included, from Secrets you supply, and only at startup, so a change reaches them through a restart
in a fixed order.

`iris/helm/tests/kind.sh REDIS_OPS=1` runs both procedures nightly on KinD, with queued Agent Memory
jobs in flight (MOD-20419). Each step there cites the step it executes here.

The examples use release `iris` in namespace `redis-ai`.

## The Secrets that name the metadata Redis

Update every one your values reference. The Secret names are yours; these are the values that
point at them.

| Component | Values field | What it holds |
| --- | --- | --- |
| Identity Service | `identityService.metadata.existingSecret` | `metadata.urls` |
| Agent Memory | `memory.secrets.secretName` | `metadata`, `databases`, `background_jobs` URLs |
| Agent Memory queue monitor (only with `memory.controlplane.queueMonitor.enabled`) | `memory.controlplane.queueMonitor.redis.existingSecret` | `REDIS_URL`, the `background_jobs` Redis |
| Agent Playbook | `playbook.storage.existingSecret` | `storage.metadata` (and `storage.content`, a second database) |
| Playbook worker (extraction) | `playbook.worker.existingSecret` | `worker.redis` (the extraction queue) |
| Lens | `lens.storage.existingSecret` | `storage.metadata` in both planes |
| Context Gateway | `contextGateway.metadataDB.existingSecret` | `metadata_db` |
| Intent Router | `intent.storage.existingSecret` | `storage.metadata` (control plane), `runtime.redis` (data plane) |
| UI (IdP login) | `ui.sso.redis.existingSecret` | the session store URLs |

## Rotate the credential

Nothing is unavailable during the rotation: both users work until step 5.

1. Create a second database user with the same permissions as the current one. On Redis
   Enterprise, add the user to the database's role; on open-source Redis:

   ```bash
   redis-cli --user <current-user> --pass <current-password> ACL SETUSER <new-user> on '><new-password>' '~*' '&*' '+@all'
   redis-cli --user <current-user> --pass <current-password> ACL SAVE
   ```

2. Write the new user and password into every Secret in the table above, in place
   (`kubectl apply` or your secret manager), for example
   `redis://<new-user>:<new-password>@<host>:<port>`.

3. Restart in this order, waiting for each group to finish before the next:

   ```bash
   restart() { local d present=()
               for d in "$@"; do kubectl -n redis-ai get deployment/$d >/dev/null 2>&1 && present+=("$d"); done
               for d in "${present[@]}"; do kubectl -n redis-ai rollout restart deployment/$d; done
               for d in "${present[@]}"; do kubectl -n redis-ai rollout status deployment/$d --timeout=5m; done; }
   restart iris-identity-service
   restart redis-agent-memory-controlplane redis-agent-playbook-controlplane redis-lens-controlplane \
     redis-context-gateway-controlplane redis-intent-router-controlplane
   restart redis-agent-memory redis-agent-memory-worker redis-agent-memory-asynqdash redis-agent-playbook-dataplane \
     redis-agent-playbook-worker redis-lens-dataplane redis-lens-worker redis-context-gateway-dataplane \
     redis-intent-router-dataplane
   restart iris-ui iris-ui-auth
   ```

   `restart` skips a Deployment that is not installed: a product you have not enabled, the Playbook
   worker without `global.iris.extraction.enabled`, `iris-ui-auth` without IdP login, and Memory's queue
   monitor (`redis-agent-memory-asynqdash`) unless you enabled it. The queue monitor reads `REDIS_URL` and the optional
   `REDIS_USERNAME` from its own Secret at startup, so it keeps the old user until it restarts.
   Jobs queued before the restart stay queued and run once the workers are back.

4. Verify the suite: `helm test iris -n redis-ai --logs`.

5. **Do not delete the old user yet** ([MOD-20791](https://redislabs.atlassian.net/browse/MOD-20791)): Agent Memory
   stores keep the database URLs, credentials included, they were created with, so every store created before the
   rotation would fail with `Database Authentication Failed`. Until that is fixed, keep the old user. Once it is,
   delete the old user after every Pod runs with the new one (step 3 complete), then save:

   ```bash
   redis-cli --user <new-user> --pass <new-password> ACL DELUSER <current-user>
   redis-cli --user <new-user> --pass <new-password> ACL SAVE
   ```

   A Pod still using the old user starts failing here, so check first that none is older than
   step 3: `kubectl -n redis-ai get pods -o custom-columns=NAME:.metadata.name,STARTED:.status.startTime`.

## Planned outage

For maintenance that stops the metadata Redis (an upgrade without replication, a host move). The
suite reports the outage and recovers by itself; nothing needs restarting.

1. Plan the window. Agent Memory and Playbook jobs already queued stay in the database when it
   persists (append-only file or replication) and run after it returns; new writes fail during the
   window.
2. Stop the database.
3. The suite reports it: the Identity Service, the Memory control plane, Playbook (both planes and
   the worker), Intent Router, and the Lens planes turn unready, so their Services stop routing to
   them, and Memory API requests fail. Pods are not restarted. Until
   [MOD-20800](https://redislabs.atlassian.net/browse/MOD-20800), the Memory data plane, both Context
   Gateway planes, and the Lens worker stay Ready and answer errors instead.
4. Start the database again. Readiness recovers without intervention, usually within a minute:
   `kubectl -n redis-ai wait pod -l app.kubernetes.io/instance=iris --field-selector=status.phase=Running --for=condition=Ready --timeout=5m`.
5. Verify: `helm test iris -n redis-ai --logs`. Queued jobs complete on their own.
