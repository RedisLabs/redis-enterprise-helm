# redis-iris disaster recovery: restore a lost release namespace

Use this procedure when the release namespace of a redis-iris install is lost (deleted, or its
cluster rebuilt) while its databases survive. redis-iris keeps no state in the cluster beyond
Secrets: data, keys, and queued jobs live in the customer's Redis databases (TDD MOD-19479,
"Runtime operations, availability, and disaster recovery"). Restoring the Secrets and installing
the same chart with the same values brings the suite back with its data, and existing agent keys
keep working.

`iris/helm/tests/kind.sh REDIS_OPS=1` runs this procedure nightly on KinD: it deletes the release
namespace, restores it, and reads data written before the disaster with a key minted before it
(MOD-20419).

The examples use release `iris` in namespace `redis-ai`.

## Back up, ahead of time

Export every Secret of the release namespace and keep the export with your values file and the
installed chart archive (`helm pull redis-ai/redis-iris --version <installed version>`):

```bash
kubectl -n redis-ai get secrets -o json \
  | jq '{apiVersion: "v1", kind: "List", items: [.items[]
        | select(.type != "helm.sh/release.v1" and .type != "kubernetes.io/service-account-token")
        | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields,
              .metadata.ownerReferences, .metadata.namespace)]}' > iris-secrets.json
```

The export holds credentials in clear text (base64): store it as you store the database
passwords. It covers the Secrets you supplied and the ones the chart generated
(`app.kubernetes.io/component=credentials`), which the Identity Service and the products already
trust. Refresh it after every credential rotation.

## Restore

Restore into a namespace of the same name. Workload identity trusts the ServiceAccounts of that
namespace, and the products reach the Identity Service by a name that includes it; a different
namespace needs a new install, not a restore.

1. Recreate the namespace: `kubectl create namespace redis-ai`.
2. Apply the export: `kubectl -n redis-ai apply -f iris-secrets.json`.
3. Install the same chart version with the same values:
   `helm install iris ./redis-iris-<version>.tgz -n redis-ai -f values.yaml --wait --timeout 10m`.
   The chart finds its generated credentials and reuses them.
4. Verify: `helm test iris -n redis-ai --logs`, then read a known record with an existing agent key.

## Without the export

If the generated credential Secrets are lost too, the databases still hold the data, but the
products and the Identity Service no longer share their service credentials and internal tokens.
Install again with the same values: the chart generates new credentials, and agent keys, which the
Identity Service keeps in its database, keep working. This path is documented, not tested.
