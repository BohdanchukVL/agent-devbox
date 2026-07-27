# AWS setup

Two auth modes. Pick one:

- **Simple** — long-lived access keys stored as GitHub secrets. Works in 2 minutes.
- **Recommended** — GitHub Actions OIDC + an IAM role. No long-lived keys in
  GitHub; the workflow gets short-lived credentials per run. Needs a one-time
  IAM setup.

If `AWS_ROLE_ARN` is set the workflows use OIDC; otherwise they fall back to
access keys.

## Option A — Simple (access keys)

1. IAM → Users → create a user (e.g. `agent-devbox-deploy`) → *Create access key*.
2. Attach permissions for EC2, VPC and S3 (for a personal account
   `AmazonEC2FullAccess` + `AmazonS3FullAccess` is the pragmatic choice; scope
   it down for anything shared).
3. Add GitHub secrets:

   | Secret | Value |
   |---|---|
   | `AWS_ACCESS_KEY_ID` | the access key id |
   | `AWS_SECRET_ACCESS_KEY` | the secret key |
   | `SSH_PUBLIC_KEY` | your public key |

## Option B — Recommended (OIDC role)

One-time setup in AWS:

1. **Add the GitHub OIDC provider** — IAM → Identity providers → Add provider:
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. **Create a role** — IAM → Roles → Create role → *Web identity* → the
   provider above. Restrict the trust policy to your fork:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
         "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<your-github-user>/agent-devbox:*" }
       }
     }]
   }
   ```

3. Attach EC2/VPC/S3 permissions to the role (same note as above).
4. Add GitHub secrets:

   | Secret | Value |
   |---|---|
   | `AWS_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/<role-name>` |
   | `SSH_PUBLIC_KEY` | your public key |

## Deploy

*Actions → Deploy to AWS → Run workflow*:

| Input | Meaning | Default |
|---|---|---|
| Region | where the instance lives | `eu-central-1` |
| Machine size | `t3.small` (2/2) … `t3.xlarge` (4/16) | `t3.medium` |
| Disk | root gp3 volume, holds `/workspace` | `80` GB |
| Install Docker / Codex / Claude Code / OpenCode / Antigravity / Browser | toggles | ✔ / ✔ / ✔ / ✘ / ✘ / ✔ |

The first run creates an S3 state bucket `tfstate-agent-devbox-<owner>`
(versioned, public access blocked, S3-native lockfile) in the deploy region.
Re-runs update the existing machine.

> The devbox gets its own tiny VPC (`10.80.0.0/16`), so it works even in
> accounts without a default VPC and tears down cleanly.
>
> The Terraform state is stored under a region-independent key. To **move**
> the devbox to another region, destroy it first, then deploy to the new
> region — deploying to a second region without destroying would try to
> "move" the existing machine.

## Connect / Destroy

Connect exactly as in the workflow summary (`ssh dev@<ip>`). Destroy via
*Actions → Destroy AWS environment* → type `destroy`, and pick the region you
deployed to. The state bucket is kept.
