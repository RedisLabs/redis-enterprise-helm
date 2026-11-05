# redis-iris uninstall: remove a release and what it leaves behind

Use this procedure to remove a redis-iris install from its namespace. `helm uninstall` removes the
release's workloads, Services, Ingresses, and configuration, but keeps two kinds of object on
purpose: the credential Secrets the chart generated (`helm.sh/resource-policy: keep`, so an
uninstall and reinstall keeps every product and agent key working) and the Pods and RBAC objects
of the last `helm test`. Your own Secrets and your databases are never touched.

`iris/helm/tests/kind.sh REDIS_OPS=1` runs this procedure nightly on KinD and checks that step 2
lists exactly what the uninstall left, and that step 3 leaves only your own objects (MOD-20419).

The examples use release `iris` in namespace `redis-ai`.

1. Uninstall: `helm uninstall iris -n redis-ai --wait --timeout 5m`. The workload Pods take a few seconds
   more to terminate; wait until `kubectl -n redis-ai get pods -l app.kubernetes.io/instance=iris` lists only
   the `helm test` Pods (`Completed`).

2. List what is left:

   ```bash
   kubectl -n redis-ai get secrets -l app.kubernetes.io/instance=iris,app.kubernetes.io/component=credentials
   kubectl -n redis-ai get pods,serviceaccounts,roles,rolebindings,configmaps -l app.kubernetes.io/instance=iris
   ```

   Stop here to reinstall later with the same credentials. Continue to remove everything.

3. Delete it:

   ```bash
   kubectl -n redis-ai delete secrets -l app.kubernetes.io/instance=iris,app.kubernetes.io/component=credentials
   kubectl -n redis-ai delete pods,serviceaccounts,roles,rolebindings,configmaps -l app.kubernetes.io/instance=iris
   ```

   After this, a new install generates new admin tokens, a new Control token, and new service
   credentials. Agent keys live in the Identity Service's database, not in these Secrets.

4. The databases keep the suite's data. Delete it with your database tooling when you
   decommission the install; the Secrets you supplied (the database URLs, the license, the IdP
   client) are yours to delete as well.
