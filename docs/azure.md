# Azure setup

Two auth modes. Pick one:

- **Recommended** — GitHub Actions OIDC (federated credentials). No client
  secret stored in GitHub.
- **Simple** — a service principal with a client secret, stored as one JSON
  secret.

If `AZURE_CLIENT_ID` is set the workflows use OIDC; otherwise they fall back
to `AZURE_CREDENTIALS`.

## Option A — Recommended (OIDC)

1. **App registration** — Microsoft Entra ID → App registrations → *New
   registration* (e.g. `agent-devbox-deploy`).
2. **Federated credential** — in the app: *Certificates & secrets → Federated
   credentials → Add credential* → scenario *GitHub Actions deploying Azure
   resources*:
   - Organization: your GitHub user/org
   - Repository: `agent-devbox`
   - Entity type: **Branch**, branch `main`
     (workflow_dispatch runs execute in the context of the chosen branch)
3. **Role assignment** — Subscriptions → your subscription → *Access control
   (IAM)* → assign the **Contributor** role to the app.
4. Add GitHub secrets:

   | Secret | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | the app's Application (client) ID |
   | `AZURE_TENANT_ID` | Directory (tenant) ID |
   | `AZURE_SUBSCRIPTION_ID` | subscription ID |
   | `SSH_PUBLIC_KEY` | your public key |

## Option B — Simple (service principal secret)

```bash
az ad sp create-for-rbac --name agent-devbox-deploy \
  --role Contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID> \
  --json-auth
```

Store the entire JSON output as the `AZURE_CREDENTIALS` secret, plus
`SSH_PUBLIC_KEY`.

## Deploy

*Actions → Deploy to Azure → Run workflow*:

| Input | Meaning | Default |
|---|---|---|
| Region | `westeurope`, `northeurope`, `germanywestcentral`, `eastus` | `westeurope` |
| Machine size | `Standard_B2s` (2/4) … `Standard_D4s_v5` (4/16) | `Standard_B2ms` |
| Disk | OS disk (Premium SSD), holds `/workspace` | `80` GB |
| Install Docker / Codex / Claude Code / OpenCode / Antigravity / Browser | toggles | ✔ / ✔ / ✔ / ✘ / ✘ / ✔ |

The first run creates a `agent-devbox-tfstate` resource group with a storage
account for Terraform state (name derived from your repo, so it is globally
unique). Re-runs update the existing VM.

All devbox resources live in their own `agent-devbox` resource group — easy to
audit and impossible to leak into other workloads.

## Connect / Destroy

Connect exactly as in the workflow summary (`ssh dev@<ip>`). Destroy via
*Actions → Destroy Azure environment* → type `destroy`. The tfstate resource
group is kept (storage costs are negligible).
