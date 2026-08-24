# Running wacrm on AWS with self-hosted Supabase

This directory stands the whole thing up in your own AWS account: the
CRM **and** the Supabase it depends on. Nothing runs on supabase.com
and nothing runs on Hostinger.

---

## What gets built

```
                    Route 53  (your domain)
                         │
                    ACM certificate
                         │
        ┌────────────────┴────────────────┐
        │   Application Load Balancer     │
        │   crm.example.com      → :3000  │
        │   supabase.example.com → :8000  │
        └────────────────┬────────────────┘
                         │  (public subnets, 2 AZs)
        ┌────────────────┴────────────────────────┐
        │  EC2  t3.medium  —  docker compose      │
        │                                         │
        │   kong        :8000   API gateway       │
        │   gotrue      :9999   auth              │
        │   postgrest   :3000   REST              │
        │   realtime    :4000   websockets        │
        │   storage-api :5000   file storage      │
        │   app         :3000   the CRM           │
        └───────┬─────────────────────────┬───────┘
                │                         │
      RDS PostgreSQL 17            S3 bucket
      (private subnets)            (media objects)
      pgvector, logical
      replication on

  SES ──── auth email        EventBridge ──── cron pingers
  Secrets Manager ──── every generated credential
```

**Roughly $75–95/month** in ap-south-1: EC2 t3.medium ~$30, RDS
db.t4g.small ~$25, ALB ~$18, EBS+S3+data ~$10. No NAT gateway — that
is a deliberate ~$35/month saving, see `network.tf`.

## Why the app needs the _whole_ Supabase stack

A partial self-host does not work here. From reading the code:

| Piece                   | Where it is load-bearing                                                                                    |
| ----------------------- | ----------------------------------------------------------------------------------------------------------- |
| **Postgres + pgvector** | 40 migrations; `vector` for AI knowledge search (migration 030)                                             |
| **GoTrue**              | `profiles.user_id` is a FK to `auth.users`; a trigger on that table creates every profile                   |
| **PostgREST**           | every `.from()` call and ~15 `.rpc()` calls                                                                 |
| **Realtime**            | `supabase_realtime` publication on `messages`, `conversations`, `flows`, `notifications`, `member_presence` |
| **Storage**             | 3 buckets created _in SQL_ — `avatars`, `flow-media`, `chat-media`                                          |
| **Kong**                | the single origin `NEXT_PUBLIC_SUPABASE_URL` points at                                                      |

---

## Before you start

You need:

1. **An AWS account** with admin credentials configured locally
   (`aws configure`, then check with `aws sts get-caller-identity`).
2. **A domain with a Route 53 public hosted zone in that account.**
   Terraform looks the zone up by name; it does not create it. If your
   registrar is elsewhere, create the hosted zone first and point the
   registrar's nameservers at Route 53's four NS records.
   Public HTTPS is not optional — Meta refuses to register a WhatsApp
   webhook without a publicly trusted certificate.
3. **Terraform >= 1.6** and **AWS CLI v2** on your machine.
4. **A Meta app** with WhatsApp Business, for the App Secret in step 7.

---

## Step 1 — Configure

```bash
git clone https://github.com/ajaychanumolu/wacrm.git
cd wacrm/deploy/aws/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. The only value you _must_ change is
`domain_name`. Sensible defaults cover the rest.

```hcl
domain_name      = "example.com"        # your real domain
aws_region       = "ap-south-1"
ses_from_address = "no-reply@example.com"
app_repo_url     = "https://github.com/ajaychanumolu/wacrm.git"
```

## Step 2 — Apply

```bash
terraform init
terraform plan      # read this; it creates ~60 resources
terraform apply
```

Expect **15–25 minutes**. RDS takes ~10 of that, and ACM validation
waits on DNS propagation. Terraform blocks on both, which is correct
— the instance boots into a bootstrap that needs the database.

When it finishes:

```
app_url              = "https://crm.example.com"
supabase_url         = "https://supabase.example.com"
whatsapp_webhook_url = "https://crm.example.com/api/whatsapp/webhook"
ssm_session_command  = "aws ssm start-session --target i-0abc... --region ap-south-1"
```

> **If ACM validation hangs past ~10 minutes**, your domain's
> nameservers are not pointing at this hosted zone. Check with
> `dig NS example.com +short` against the `NS` records shown in the
> Route 53 console.

## Step 3 — Watch the first boot

`terraform apply` returns once the _instance_ exists, but cloud-init
is still installing Docker, bootstrapping the database and building
the Next.js image. That takes another **8–15 minutes** — the app
build is the slow part, and it is why the instance has 4 GB of swap.

```bash
aws ssm start-session --target <instance-id> --region ap-south-1

sudo tail -f /var/log/wacrm-deploy.log
```

You are looking for:

```
--- [1/5] bootstrap: roles, schemas, extensions, auth.uid()
--- [2/5] starting auth, rest, realtime, storage
--- [3/5] post-service grants
--- [4/5] applying supabase/migrations
--- [5/5] post-migration grants
=== deploy complete ===
```

## Step 4 — Verify

```bash
sudo /opt/wacrm/src/deploy/aws/scripts/doctor.sh
```

This checks the failure modes that produce **empty results rather
than errors** — a missing `BYPASSRLS`, a table absent from the
realtime publication, a bucket that never got inserted. Everything
should read `ok`. If not, jump to Troubleshooting.

## Step 5 — Create your account

Open `https://crm.example.com`, go to **/signup**, create your owner
account. It works immediately: `mailer_autoconfirm` defaults to
`true`.

Then **close public signup**:

```hcl
# terraform.tfvars
disable_signup = true
```

```bash
terraform apply
aws ssm start-session --target <instance-id>
sudo /opt/wacrm/src/deploy/aws/scripts/deploy.sh
```

Teammates join through the in-app invite link
(**Settings → Team → Invite**), which is unaffected by that setting.

> **Why autoconfirm is on.** The upstream app has no `/auth/callback`
> route, so the PKCE code GoTrue appends to a confirmation redirect
> has nothing to exchange it for and the link dead-ends. See
> "Known upstream gaps" below.

## Step 6 — Confirm the database is sane

The single most consequential setting is whether `service_role` can
get past RLS. If it cannot, the WhatsApp webhook, the automation and
flow engines and the AI auto-reply bot all **silently read and write
nothing** — no errors, just empty results.

`doctor.sh` checks it. To see it yourself:

```sql
SELECT rolname, rolbypassrls FROM pg_roles WHERE rolname = 'service_role';
```

## Step 7 — Meta credentials

The webhook rejects every request until `META_APP_SECRET` is set — it
verifies Meta's HMAC-SHA256 signature with it.

```bash
SECRET_ID=wacrm-prod/config
REGION=ap-south-1

aws secretsmanager get-secret-value --secret-id $SECRET_ID --region $REGION \
  --query SecretString --output text \
  | jq '.META_APP_SECRET="<your-app-secret>" | .META_APP_ID="<your-app-id>"' \
  | aws secretsmanager put-secret-value --secret-id $SECRET_ID --region $REGION \
      --secret-string file:///dev/stdin
```

Then apply it on the box:

```bash
aws ssm start-session --target <instance-id>
sudo /opt/wacrm/src/deploy/aws/scripts/deploy.sh
```

Now wire up Meta — **Meta for Developers → your app → WhatsApp →
Configuration → Edit**:

| Field        | Value                                                                     |
| ------------ | ------------------------------------------------------------------------- |
| Callback URL | `https://crm.example.com/api/whatsapp/webhook`                            |
| Verify token | any string; paste the same one into the CRM under **Settings → WhatsApp** |

Subscribe to the **`messages`** webhook field. Finally, enter your
Phone Number ID, WABA ID and access token in the CRM under
**Settings → WhatsApp**.

## Step 8 — Get out of the SES sandbox

New AWS accounts can only send to individually verified addresses.
Everything else is accepted and **silently dropped** — this is the
most common "invites never arrive" cause.

**SES console → Account dashboard → Request production access.**
Approval usually takes under 24 hours. Until then, verify recipients
one at a time under **Identities → Create identity → Email address**.

Terraform already published your DKIM and SPF records.

---

## Day-two operations

Everything runs from inside an SSM session:

```bash
aws ssm start-session --target <instance-id> --region ap-south-1
cd /opt/wacrm/src/deploy/aws/scripts
```

| Task                                           | Command                                                   |
| ---------------------------------------------- | --------------------------------------------------------- |
| Deploy the latest commit                       | `sudo ./deploy.sh --update`                               |
| Rebuild after changing a `NEXT_PUBLIC_*` value | `sudo ./deploy.sh --rebuild`                              |
| Restart containers only                        | `sudo ./deploy.sh --skip-migrations`                      |
| Health check                                   | `sudo ./doctor.sh`                                        |
| Update Supabase images                         | `./check-image-tags.sh`, then `sudo ./deploy.sh --pull`   |
| Tail app logs                                  | `docker compose --project-directory ../stack logs -f app` |
| Tail everything                                | `docker compose --project-directory ../stack logs -f`     |

`--rebuild` is required whenever `NEXT_PUBLIC_SUPABASE_URL`,
`NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` or
`NEXT_PUBLIC_APP_LOCALE` changes: Next.js inlines those into the
client bundle at build time, so a restart alone leaves the browser
talking to the old values.

### Backups

RDS keeps 7 days of automated backups (`db_backup_retention_days`).
The S3 bucket is versioned with a 30-day non-current expiry. Before
any risky change:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier wacrm-prod-db \
  --db-snapshot-identifier wacrm-prod-$(date +%Y%m%d-%H%M) \
  --region ap-south-1
```

### Rotating the Supabase keys

The anon and service_role keys are JWTs signed with `JWT_SECRET`.
Change that secret and both rotate at once — along with every live
user session, so everyone is logged out.

```bash
aws secretsmanager get-secret-value --secret-id wacrm-prod/config --region ap-south-1 \
  --query SecretString --output text \
  | jq --arg s "$(openssl rand -hex 32)" '.JWT_SECRET=$s' \
  | aws secretsmanager put-secret-value --secret-id wacrm-prod/config --region ap-south-1 \
      --secret-string file:///dev/stdin

# JWT_SECRET feeds the anon key, which is inlined at build time.
sudo /opt/wacrm/src/deploy/aws/scripts/deploy.sh --rebuild
```

> Do **not** rotate `ENCRYPTION_KEY` casually. It is the AES-256-GCM
> key over stored WhatsApp and AI provider tokens; changing it orphans
> every one of them and each account has to re-enter its credentials.

---

## Troubleshooting

### Everything returns "permission denied for table …"

The post-migration grants did not run. RLS and `GRANT` are separate
gates and both have to be open — RLS filters rows, `GRANT` decides
whether the table can be addressed at all.

```bash
sudo -E psql "$DB_URL" -f /opt/wacrm/src/deploy/aws/sql/020_post_app_grants.sql
```

### Inbound WhatsApp messages never appear

Almost always `service_role` losing to RLS. Run `doctor.sh`. Then:

```bash
docker compose --project-directory /opt/wacrm/src/deploy/aws/stack logs app | grep -i webhook
```

A 401 from Meta means `META_APP_SECRET` is wrong or unset (step 7).

### The inbox does not update live

Realtime is not consuming the WAL. In order of likelihood:

1. `rds.logical_replication` never took effect — it is a static
   parameter and needs a reboot. Check:
   ```sql
   SHOW wal_level;   -- must be 'logical'
   ```
   If it says `replica`, reboot RDS from the console.
2. `supabase_admin` lacks replication rights:
   ```sql
   SELECT * FROM pg_replication_slots;   -- expect one, active
   ```
3. The container was renamed. Realtime reads its tenant from the Host
   header's first label; `container_name` must stay
   `realtime-dev.supabase-realtime`.

### The build gets OOM-killed (exit code 137)

`next build` outgrew 4 GB of RAM plus 4 GB of swap. Move to
`t3.large` in `terraform.tfvars` and `terraform apply`.

### ALB target is unhealthy

```bash
curl -i http://localhost:3000/login          # app target group
curl -i http://localhost:8000/auth/v1/health # supabase target group
```

The `/auth/v1/health` route is deliberately outside Kong's key-auth
because an ALB health check cannot send an `apikey` header.

### `terraform apply` fails on the SPF record

The apex already has a TXT record and Route 53 permits only one per
name. Set `manage_spf_record = false` and merge
`include:amazonses.com` into your existing SPF string by hand.

---

## Known upstream gaps

These are pre-existing in the wacrm template — they behave identically
on supabase.com and are **not** caused by the move to AWS. Flagging
them because they shape the configuration above.

1. **No `/auth/callback` route, no `/reset-password` page.**
   `forgot-password` redirects to `${origin}/auth/callback?next=/reset-password`
   and neither exists. Password recovery therefore dead-ends. This is
   why `mailer_autoconfirm` defaults to `true` — email-link flows have
   nowhere to land. Both routes are small additions if you want them.

2. **Server-side Supabase calls hairpin through the ALB.** The app
   reads `NEXT_PUBLIC_SUPABASE_URL` on the server too, so a server
   component's query leaves the instance, hits the ALB and comes back.
   It works and costs a few milliseconds. Adding an internal-only
   override would mean touching every call site.

---

## File map

```
deploy/aws/
├── terraform/          VPC, RDS, S3, SES, IAM, EC2, ALB, EventBridge
│   ├── templates/user-data.sh.tftpl   first-boot: packages, swap, clone
│   └── terraform.tfvars.example
├── sql/
│   ├── 000_bootstrap.sql          ← read this one. Everything
│   │                                supabase/postgres would have done.
│   ├── 010_post_service_grants.sql  after gotrue/storage migrate
│   └── 020_post_app_grants.sql      after the app's migrations
├── stack/
│   ├── docker-compose.yml    the six services
│   └── kong.template.yml     API gateway routes
└── scripts/
    ├── deploy.sh             the orchestrator — read its header for
    │                         why the ordering is what it is
    ├── doctor.sh             checks the silent failure modes
    ├── gen-jwt.sh            mints the anon / service_role keys
    ├── check-image-tags.sh   pinned versions vs upstream
    └── wacrm.service         restart-on-reboot unit
```

## Tearing it down

```bash
cd deploy/aws/terraform
terraform destroy
```

RDS has `deletion_protection = true` and takes a final snapshot. To
actually delete it, set `db_deletion_protection = false`, apply, then
destroy. The S3 bucket must be emptied first:

```bash
aws s3 rm s3://$(terraform output -raw s3_bucket) --recursive
```
