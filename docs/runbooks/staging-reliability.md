# Staging reliability and recovery exercise

Use this exercise to qualify a Task release and its rollback, verify recovery, and capture a
performance reference. Record timestamps in UTC, the active image digests, the request rates and
the results in the release record. This procedure requires an operator and a provisioned staging
environment. The checkout alone does not establish that a staging host exists.

## Prerequisites

- A synthetic organization, a representative list with tasks in `progress` and `review`, a task key
  in that list, and a read-only API token with `tasks:read` access. Keep this dataset stable during
  each exercise and retain the fixture revision for later comparisons.
- Two Bash probe runners with Node.js 24 and a copy of this checkout. Run one outside the staging
  host against `https://api.<staging-domain>` and the other on the staging internal network against
  `http://api-gateway:3000`. Both exercise the gateway's normal authentication and authorization path.
- An operator with access to the Task **Deploy** workflow, staging logs and a disposable Docker host
  for the GitOps and backup tests. The disposable host must not run Cadenway environments. The tests
  use fixed container and project names and remove them.
- For the recovery drill, an isolated host with a `staging` Compose project and PostgreSQL, its own
  SOPS identity and read-only access to a staging backup or a copy in a separate drill bucket. The
  host must have its own credentials and must not share the live staging or production database.
  The operator supplies the backup identity through the existing restore playbook.

## 1. Qualify deployment and rollback

1. On the staging host, record the currently running Task container IDs and image digests. Retain
   the previous release version from the service release record for the rollback workflow.

   ```bash
   docker ps --filter label=com.docker.compose.project=cadenway-staging \
     --filter label=com.docker.compose.service=task-service \
     --format '{{.ID}} {{.Image}} {{.Status}}'
   docker inspect --format '{{.Id}} {{.Image}}' \
     $(docker ps -q --filter label=com.docker.compose.project=cadenway-staging \
       --filter label=com.docker.compose.service=task-service)
   ```

2. From this checkout on each runner, start the [deployment probe](../../agent/tests/staging-probe.mjs)
   before deployment. Use the same IDs on both runners and choose a duration that covers the entire
   deployment and rollback. The probe starts list and task-detail reads once per second, with a
   five-second timeout per request.

   ```bash
   export CW_PROBE_PUBLIC_ORIGIN='https://api.<staging-domain>'
   export CW_PROBE_ORGANIZATION_ID='<synthetic-organization-id>'
   export CW_PROBE_LIST_ID='<synthetic-list-id>'
   export CW_PROBE_TASK_KEY='<synthetic-task-key>'
   set +x
   read -r -s -p 'Read-only token as a JSON array: ' CW_PROBE_PUBLIC_TOKENS
   printf '\n'
   export CW_PROBE_PUBLIC_TOKENS
   probe_status=0
   node agent/tests/staging-probe.mjs probe --duration 900 > rollout-probe.jsonl || probe_status=$?
   unset CW_PROBE_PUBLIC_TOKENS
   test "$probe_status" -eq 0
   ```

   Replace the public origin with `http://api-gateway:3000` on the internal runner. Each runner
   writes its own log. The prompt expects a one-element JSON array. The token is passed in the
   process environment. The log contains route labels, timestamps, statuses and outcome categories.

   For a direct Task check, set `CW_PROBE_INTERNAL_ORIGIN=http://task-service:3013` and
   `CW_PROBE_INTERNAL_TOKEN_FILE` to an operator-managed token file in `/run`, then run the same
   probe. Use a short-lived Task bearer from an authorized staging issuer with the synthetic actor
   and organization. Have that issuer atomically refresh the file before expiry throughout the
   drill. The probe reads the bearer and opens a fresh connection for each direct request, so the
   check observes Docker DNS changes during rollout. Running the direct probe separately lets it
   use only those two variables plus the same list and task IDs.

3. Trigger the Task service **Deploy** workflow with the candidate version. Record the workflow
   result and staging GitOps `applied` or `failed` outcome. Keep probing during startup. Record the
   active image IDs after the candidate becomes healthy.
4. Trigger the same workflow with the previous version and continue probing until it is healthy.
   Record its GitOps outcome and active image IDs. Require a successful exit from both probes and
   verify that their timestamps bracket both transitions. Review non-200 responses, partial responses,
   transport errors and skipped slots. Confirm the old version is active and the selected list and
   task remain readable. Investigate any interruption and repeat the exercise before promotion.
5. Keep the probe logs with the release record. Workflow promotion to production follows the
   service's existing approval path.

The internal Docker DNS may resolve a starting candidate before it is healthy. The internal runner
therefore provides a separate signal from the external Traefik route. See the
[deployment guide](../deployment.md#limits-to-know) for the current rollout limits.

## 2. Verify a failed candidate on a disposable host

From the repository root on the disposable Docker host, run the existing end-to-end test. It checks
that an unhealthy candidate is removed and the previous containers remain present.

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD/agent:/agent:ro" \
  docker:28.5.2-cli sh -c 'apk add --no-cache bash >/dev/null && bash /agent/tests/e2e.sh'
```

Require a zero exit status and retain the test output. The test's cleanup removes its own disposable
projects. If it fails, inspect the output on that host and rerun it after correcting the cause.

## 3. Restore and measure recovery

1. On the disposable Docker host, run the existing PostgreSQL and local S3 recovery test.

   ```bash
   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
     -v "$PWD/ansible/roles/backup:/backup:ro" docker:28.5.2-cli \
     sh -c 'apk add --no-cache bash >/dev/null && bash /backup/tests/e2e.sh'
   ```

   Require a zero exit status. The test cleans up its own containers.

2. On the isolated drill host, provision the separate backup access and encrypted environment
   configuration described in the prerequisites. Record the backup timestamp and the UTC time of
   the latest known synthetic Task write included in that backup. Record the incident reference time
   and restore start time. The restore drops and recreates the selected database on its target.
3. From the operator's Ansible controller, select the isolated inventory host and run the existing
   playbook with its backup identity and the selected timestamp.

   ```bash
   ansible-playbook ansible/playbooks/restore.yml --limit cadenway-restore-drill \
     -e cadenway_restore_environment=staging -e cadenway_restore_confirm=staging \
     -e cadenway_restore_timestamp="$CW_BACKUP_TIMESTAMP" \
     -e cadenway_restore_identity_file="$CW_BACKUP_IDENTITY_FILE" \
     -e '{"cadenway_restore_databases":["task"]}'
   ```

   `cadenway-restore-drill` must identify only the isolated host in the operator's inventory.
   The selected encrypted Task dump must have the expected synthetic data and be decryptable by the
   supplied identity. The playbook removes its copy of the identity from `/run` after the attempt.

4. Confirm Task readiness and migration compatibility on the drill host, then authenticate through
   its isolated gateway and read the reference list and task. Record the time those checks succeed.
   Recovery time is the elapsed time from restore start to successful functional verification. Data
   loss is the interval between the latest included known write and the incident reference time.
   Compare the latter with the provisional 24-hour target.
5. After recording the results, the operator tears down the dedicated drill stack and its isolated
   storage according to the host's lifecycle. A failed restore can leave the drill database empty;
   retry with a verified dump on that same isolated host.

## 4. Capture the performance reference

Use the same synthetic dataset, versions, runner locations and query mix for each comparison. The
Task repository's integration suite contains the 75,000-task PostgreSQL plan fixture. Record its
`EXPLAIN (ANALYZE, BUFFERS)` output for the tested version. Capture external API and downstream
traces for filtered lists, group counts and task detail.

1. Use two staging-approved runners with distinct source addresses as seen by Traefik. This sends
   at most 900 requests per minute from each runner under the 1,200-request introspection limit.
   Supply two distinct `tasks:read` tokens per runner, four in total, so each token stays below
   the 600-request-per-minute limit. Use tokens for the same synthetic organization with equivalent
   access to the list and task. Reserve these credentials for the benchmark.
2. Set the same public origin and organization, list and task IDs on both runners as in the probe.
   Synchronize the runners' clocks. Set `CW_PROBE_START_AT` to the same future ISO-8601 UTC timestamp
   on both runners, and set `CW_PROBE_WORKER` to `0` on one runner and `1` on the other. Use a
   two-element JSON array when prompted for credentials.

   ```bash
   set +x
   read -r -s -p 'Two read-only tokens as a JSON array: ' CW_PROBE_PUBLIC_TOKENS
   printf '\n'
   export CW_PROBE_PUBLIC_TOKENS
   benchmark_status=0
   node agent/tests/staging-probe.mjs benchmark --start-at "$CW_PROBE_START_AT" \
     --worker "$CW_PROBE_WORKER" > "worker-${CW_PROBE_WORKER}.json" || benchmark_status=$?
   unset CW_PROBE_PUBLIC_TOKENS
   test "$benchmark_status" -eq 0
   ```

   The driver runs three passes at each of 5, 15 and 30 requests per second, with one minute of
   warmup and five minutes of measurement per pass. It cycles equally between filtered list, status
   groups and task detail. List and groups filter `progress,review` and request up to 50 entries.

3. Gather the reports and merge them from this checkout.

   ```bash
   node agent/tests/staging-probe.mjs merge worker-0.json worker-1.json > benchmark.json
   ```

   The merge checks workload alignment and computes p50, p95 and p99 from the combined observations
   for each route and pass. It reports sent rates, statuses, transport errors and partial responses.
   A run with rate limiting or missed slots exits unsuccessfully. Resolve the cause before using
   the results as a reference.

4. Compare the same routes and rate levels before and after a change, using the median p95 of the
   three passes at each level. Review time in authentication, internal calls and PostgreSQL from
   the staging traces. A candidate passes when the target p95 improves by at least 15%, other
   measured p95 values regress by at most 5%, and errors and partial responses do not increase.
