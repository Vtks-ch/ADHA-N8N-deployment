# Rollback

1. Identify the last known-good n8n image/chart version.
2. Restore the corresponding environment values.
3. Run Helm upgrade/install with the known-good version through the approved pipeline.
4. Validate pods, DB, Redis, Blob, webhooks, and task runners.
5. Do not delete the production namespace or persistent data as a first rollback action.
