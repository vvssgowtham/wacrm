# Running wacrm on one EC2 instance, reachable by IP

Everything — the CRM, Postgres, and the whole Supabase stack — on a
single EC2 box you own. Nothing runs on supabase.com. No domain, no
load balancer, no RDS, no S3.

About **45 minutes**, roughly 15 of it hands-on. Around **$35/month**.

> Have a domain, or want managed Postgres and a load balancer? Use
> [`../aws/`](../aws) instead — it is the same application with
> Route 53 + ACM + ALB + RDS + SES, driven by Terraform, at $75–95/month.
> This directory is the small version.

---

## Read this first

**There is no HTTPS.** A TLS certificate requires a domain name, and
this deployment has only an IP address. That means:

- **Passwords and session tokens cross the internet in cleartext.**
  Anyone positioned between a user and the server can read them.
- **WhatsApp will not work.** Meta refuses to register a webhook
  against anything but a publicly trusted HTTPS endpoint.
- **No email.** No domain means no verified SES sender, so signup
  auto-confirms and team invite links must be copied by hand.

That is an acceptable trade for an internal tool locked to known IP
addresses, which is how the security group below is set up. It is not
acceptable for a CRM open to the public internet. The
[HTTPS appendix](#appendix--adding-https-later-without-buying-a-domain)
fixes all three in about fifteen minutes and costs nothing.

---

## What gets built

```
                    Internet
                       │
       ┌───────────────┴────────────────────────┐
       │  Elastic IP  (fixed — see step 5)      │
       │  EC2 t3.medium, Amazon Linux 2023      │
       │                                        │
       │   :3000  app        the CRM            │  ← browser
       │   :8000  kong       API gateway        │  ← browser, directly
       │            ├── auth       :9999  GoTrue
       │            ├── rest       :3000  PostgREST
       │            ├── realtime   :4000  live inbox
       │            └── storage    :5000  uploads → local volume
       │                                        │
       │   127.0.0.1:5432  postgres (pgvector)  │  ← loopback only
       │                                        │
       │   cron  → /api/automations/cron  every minute
       │   cron  → /api/flows/cron        every minute
       │   cron  → backup.sh              02:30 daily
       └────────────────────────────────────────┘
```

**Port 8000 is not optional.** The browser calls Kong directly — that
is what `NEXT_PUBLIC_SUPABASE_URL` points at, and it is not proxied
through the app. If 8000 is closed, the login page renders and
nothing on it works. This is the single most common way to get stuck.

### Why the whole Supabase stack

A partial self-host does not work for this app:

| Piece | Where it is load-bearing |
| --- | --- |
| **Postgres + pgvector** | 39 migrations; `vector` for AI knowledge search (migration 030) |
| **GoTrue** | `profiles.user_id` is a FK to `auth.users`; a trigger there creates every profile |
| **PostgREST** | every `.from()` call and ~15 `.rpc()` calls |
| **Realtime** | `supabase_realtime` publication on `messages`, `conversations`, `flows`, `notifications`, `member_presence` |
| **Storage** | three buckets created *in SQL* — `avatars`, `flow-media`, `chat-media` |
| **Kong** | the single origin `NEXT_PUBLIC_SUPABASE_URL` points at |

---

## Before you start

1. An **AWS account**. You do not need Terraform, the AWS CLI, or
   Docker on your laptop — only an SSH client.
2. **A public GitHub fork** of this repo. The instance clones it while
   it sets itself up; no git credentials are configured on the box.
3. About 50 GB of EBS and an instance you are willing to pay ~$35/month
   for. The free-tier `t2.micro` / `t3.micro` are far too small — a
   Next.js build plus Postgres plus six containers will not fit in 1 GB.

---

## Step 1 — Push your code first

The instance clones from GitHub. **Anything not pushed is not there.**

```bash
git add deploy/selfhost/
git status                # confirm: no .env, no secrets, no .tfstate
git commit -m "Add IP-only self-hosted deployment"
git push origin main
```

**Checkpoint** — open `https://github.com/vvssgowtham/wacrm/tree/main/deploy/selfhost`.
If that 404s, setup will fail at the clone.

## Step 2 — Key pair

EC2 console → **Key Pairs** → Create key pair. Name `wacrm-key`, type
RSA, format `.pem`.

It downloads once and cannot be downloaded again. Then:

```bash
chmod 400 ~/Downloads/wacrm-key.pem
```

## Step 3 — Security group

EC2 console → **Security Groups** → Create security group, name
`wacrm-sg`. Inbound rules:

| Type | Port | Source | Why |
| --- | --- | --- | --- |
| SSH | 22 | My IP | administration |
| Custom TCP | 3000 | My IP | the CRM |
| Custom TCP | 8000 | My IP | Kong — **the browser calls this directly** |

Leave outbound at the default (all traffic).

Use *My IP* while you set things up. To let colleagues in, add their
addresses as further rules rather than opening `0.0.0.0/0` — with no
HTTPS, that is the difference between "internal tool" and "passwords
on the open internet".

Note that most home and office connections have a dynamic IP. If you
can suddenly no longer reach the box, check whether yours changed
before assuming the server is broken.

## Step 4 — Launch the instance

EC2 console → **Launch instance**.

| Field | Value |
| --- | --- |
| Name | `wacrm` |
| AMI | **Amazon Linux 2023** |
| Instance type | **t3.medium** (2 vCPU / 4 GB) |
| Key pair | `wacrm-key` |
| Network | default VPC, a public subnet, **auto-assign public IP: Enable** |
| Security group | select existing → `wacrm-sg` |
| Storage | **50 GB gp3** |

50 GB is not generous — Docker images, the build cache and the
nightly backups all live there.

## Step 5 — Elastic IP — do not skip this

EC2 console → **Elastic IPs** → Allocate → then Actions → Associate,
and pick the `wacrm` instance.

`NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SITE_URL` are compiled
into the browser bundle at build time, and both contain this IP. An
auto-assigned public IP changes every time the instance stops and
starts; an Elastic IP does not. If the address changes, the app breaks
until you edit `/etc/wacrm/deploy.env` and run `deploy.sh --rebuild`.

An Elastic IP is free while it is attached to a running instance.

## Step 6 — Run setup

```bash
ssh -i ~/Downloads/wacrm-key.pem ec2-user@<ELASTIC_IP>

sudo dnf install -y git
sudo git clone https://github.com/vvssgowtham/wacrm.git /opt/wacrm/src
sudo /opt/wacrm/src/deploy/selfhost/setup.sh <ELASTIC_IP>
```

`setup.sh` installs Docker, generates every secret, writes the config,
installs the systemd unit and cron entries, then hands off to
`deploy.sh`.

Expect **10–20 minutes**. `next build` on the box is the slow part.
Watch it from a second terminal with:

```bash
sudo tail -f /var/log/wacrm-deploy.log
```

**Checkpoint** — you want all six stages, then the final line:

```
--- [0/5] starting postgres
--- [1/5] bootstrap: roles, schemas, extensions, auth.uid()
--- [2/5] starting auth, rest, realtime, storage
--- [3/5] post-service grants
--- [4/5] applying supabase/migrations
--- [5/5] post-migration grants
=== deploy complete ===
```

## Step 7 — Verify

```bash
sudo /opt/wacrm/src/deploy/selfhost/doctor.sh
```

**Do not skip this.** It checks the failure modes that produce *empty
results rather than errors* — a missing `BYPASSRLS`, a table absent
from the realtime publication, a bucket that never got created. Those
stay invisible until real customer messages start disappearing.

Everything under Database, Storage buckets and Realtime should read
`ok`. The two probes under *Public URLs* are advisory and often warn:
an EC2 instance generally cannot reach its own Elastic IP from inside
the VPC. Test those from your laptop instead:

- `http://<ELASTIC_IP>:3000/login` → the login page
- `http://<ELASTIC_IP>:8000/auth/v1/health` → `{"...":"..."}` JSON

If the first works and the second does not, port 8000 is closed in the
security group.

## Step 8 — First login

1. Open `http://<ELASTIC_IP>:3000`
2. Go to `/signup` and create your owner account — it works
   immediately, no confirmation email
3. **Then close public signup**, or anyone with the IP can create an
   account:

```bash
sudo sed -i 's/^DISABLE_SIGNUP=false/DISABLE_SIGNUP=true/' /etc/wacrm/deploy.env
sudo /opt/wacrm/src/deploy/selfhost/deploy.sh --skip-migrations
```

Teammates still join through **Settings → Team → Invite**, which that
setting does not affect — though with no SMTP you will need to send
them the invite link yourself.

Worth confirming while you are here: open the inbox in two browser
tabs and change something in one. The other should update within a
second. That exercises Realtime, logical replication and the
WebSocket through Kong in one go, and it is the piece most likely to
be quietly broken.

---

## Everyday operation

```bash
ssh -i ~/Downloads/wacrm-key.pem ec2-user@<ELASTIC_IP>
cd /opt/wacrm/src/deploy/selfhost
```

| You want to… | Run |
| --- | --- |
| Deploy code you just pushed | `sudo ./deploy.sh --update` |
| Change a `NEXT_PUBLIC_*` value (or the IP) | `sudo ./deploy.sh --rebuild` |
| Restart containers only | `sudo ./deploy.sh --skip-migrations` |
| Health check | `sudo ./doctor.sh` |
| Tail app logs | `sudo docker compose logs -f app` |
| Back up now | `sudo ./backup.sh` |
| Update Supabase versions | `../aws/scripts/check-image-tags.sh`, then `sudo ./deploy.sh --pull` |

**Your normal loop:**

```
edit on laptop → git push origin main → ssh in → sudo ./deploy.sh --update
```

`--rebuild` is required specifically for `NEXT_PUBLIC_*` changes,
because Next.js bakes those into the browser bundle at build time. A
plain restart leaves users on the old values.

### Files on the box

| Path | What |
| --- | --- |
| `/etc/wacrm/secrets.json` | every generated secret, `chmod 600` |
| `/etc/wacrm/deploy.env` | non-secret config — edit this, then re-run `deploy.sh` |
| `/etc/cron.d/wacrm` | the two cron pingers + nightly backup |
| `/opt/wacrm/src` | the git clone |
| `/opt/wacrm/backups` | nightly dumps, 7 days retained |
| `/var/log/wacrm-deploy.log` | every `deploy.sh` run |
| `deploy/selfhost/.env` | generated by `deploy.sh`; never edit by hand |

### Back up `/etc/wacrm/secrets.json`

Copy it somewhere safe, off the instance. `ENCRYPTION_KEY` is the
AES-256-GCM key for every stored WhatsApp and AI provider token —
lose it and those tokens are unrecoverable, and every user has to
re-enter their credentials. `JWT_SECRET` is what the anon and
service_role keys are derived from.

### Backups

`backup.sh` runs nightly at 02:30 and keeps 7 days of `pg_dump` plus
the uploaded-files volume in `/opt/wacrm/backups`.

That directory is on the **same EBS volume as the data it backs up**,
so it protects against bad data, not against losing the instance. For
that, either copy the files off the box on a schedule, or turn on
**EBS snapshots**: EC2 console → Lifecycle Manager → create a daily
snapshot policy against the instance's volume. Restore instructions
are in the comment block at the bottom of `backup.sh`.

---

## Troubleshooting

**The build is killed with exit code 137.** Out of memory. `setup.sh`
creates 6 GB of swap; confirm with `swapon --show`. If it is present
and the build still dies, resize the instance to `t3.large`: stop it,
Actions → Instance settings → Change instance type, start it. The
Elastic IP survives.

**The login page loads but nothing works; the console shows failed
requests to `:8000`.** Port 8000 is closed in the security group, or
your IP changed. Check with `curl http://<ELASTIC_IP>:8000/auth/v1/health`
from your laptop.

**The inbox never updates live.** Realtime. Check `wal_level` is
`logical` and that a replication slot is active — `doctor.sh` reports
both. Then `sudo docker compose logs realtime`. Do not rename the
`realtime` container: it derives its tenant from the Host header, and
`container_name: realtime-dev.supabase-realtime` is load-bearing.

**Migration 001 fails with "relation auth.users does not exist".** The
app migrations ran before GoTrue created its schema. `deploy.sh`
orders this correctly; if you ran the SQL by hand, re-run
`sudo ./deploy.sh` and let it do the ordering.

**Everything is fine but the app returns empty lists.** Almost always
`service_role` losing `BYPASSRLS`, which `doctor.sh` checks
explicitly. Re-run `sudo ./deploy.sh` — `000_bootstrap.sql` is
idempotent and will restore it.

**A container keeps restarting.** `sudo docker compose logs <service>`.
`auth`, `rest`, `realtime` and `storage` all fail on a bad database
password; if you have edited `/etc/wacrm/secrets.json` by hand, the
roles in Postgres still have the old ones — re-run `sudo ./deploy.sh`,
which re-applies them from `000_bootstrap.sql`.

**Out of disk.** `df -h`. Usually old Docker build layers:
`sudo docker system prune -af` reclaims the most, and old backups in
`/opt/wacrm/backups` are the next place to look.

---

## Appendix — adding HTTPS later, without buying a domain

This removes the cleartext-password problem and unblocks WhatsApp, in
about fifteen minutes, for free.

`sslip.io` resolves any IP-shaped hostname to that IP — so
`crm.203-0-113-5.sslip.io` is a real, publicly resolvable hostname
that Let's Encrypt will issue a certificate for, with nothing to
register or pay for.

1. Open ports **80** and **443** in `wacrm-sg` to `0.0.0.0/0`. Both are
   required: Let's Encrypt validates over 80.
2. Add a `caddy` service to `docker-compose.yml` reverse-proxying
   `crm.<ip-with-dashes>.sslip.io` → `app:3000` and
   `supabase.<ip-with-dashes>.sslip.io` → `kong:8000`. Caddy obtains
   and renews certificates by itself.
3. Stop publishing 3000 and 8000 directly, and close them in the
   security group.
4. Update `/etc/wacrm/deploy.env`:
   ```sh
   APP_URL=https://crm.<ip-with-dashes>.sslip.io
   SUPABASE_PUBLIC_URL=https://supabase.<ip-with-dashes>.sslip.io
   APP_FQDN=crm.<ip-with-dashes>.sslip.io
   ```
5. `sudo ./deploy.sh --rebuild` — required, these are `NEXT_PUBLIC_*`
   values.

That also lets you flip the CSP in `next.config.ts` from
`Content-Security-Policy-Report-Only` to enforcing, and register the
WhatsApp webhook at `https://crm.<...>.sslip.io/api/whatsapp/webhook`
following [AWSMIGRATION.md](../../AWSMIGRATION.md) phase 7.

If you later buy a real domain, the same three variables are all that
change.
