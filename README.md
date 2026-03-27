# syntella-kit

Opinionated bootstrap for running OpenClaw on a DigitalOcean Ubuntu droplet with **Discord as the primary interface**.

## What this setup does

- Installs OpenClaw non-interactively
- Keeps gateway private (`gateway.bind=loopback`, token auth)
- Configures Discord bot token
- Joins a Tailscale tailnet during bootstrap for private control-plane access
- Restricts Discord ingress to a single guild/channel allowlist
- Enables Discord DMs only for the configured human allowlist
- Installs `/usr/local/bin/syntella-exec` for owner-DM `/exec` shell command execution (timeout + output cap + audit log)
- Sets `tools.exec` defaults to `host=gateway security=full ask=off` for non-interactive operator execution
- Installs a local Operator Bridge (`127.0.0.1:8787`) with `/spawn-agent` endpoint for dedicated-agent provisioning
- Spawn path now uses per-agent OpenClaw homes (`~/.openclaw-<agent_id>`) to prevent main-token/config collisions
- Child guild/channel allowlist is written as one JSON object (avoids numeric dotted-key issues), then validated before success
- Spawn flow still aborts if the main bot token changes during spawn (safety guard)
- Exposes the Syntella API for main-site portal access over Tailscale on port `8788`
- Keeps the Syntella API firewalled to `tailscale0` and loopback
- Optionally sets up a legacy workspace frontend on nginx when `FRONTEND_ENABLED=1`
- When `FRONTEND_ALLOWED_IP` is set, that frontend is IP-allowlisted; when it is omitted, the frontend is public
- Sends a startup ping message to the configured Discord channel after bootstrap (includes tailnet/API context, and frontend URL only if explicitly enabled)
- Installs a global `/usr/local/bin/openclaw` shim (so root/sudo users can run `openclaw ...` without switching users)

## Required inputs

- `DISCORD_BOT_TOKEN`
- `DISCORD_TARGET` in one of these formats:
  - `<guildId>/<channelId>`
  - `<guildId>:<channelId>`
  - `guild:<guildId>/channel:<channelId>`
- `DISCORD_HUMAN_ID` (owner user id for DM allowlist / privileged commands)
- optional model provider keys:
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
  - `MOONSHOT_API_KEY`
- `SYNTELLA_PORTAL_API_TOKEN` (shared raw token used by the main site to authenticate to this droplet)
- `TS_AUTHKEY` (Tailscale auth key for non-interactive join)
- `TS_HOSTNAME` (recommended format: `syntella-<org-slug>`)

Bootstrap seeds a provider-first model catalog for OpenAI, Anthropic, and Moonshot. If no provider key is supplied yet, the catalog still exists and can be connected later from the portal by adding one API key per provider.
The canonical seeded defaults live in `config/default-model-catalog.json`, so new provider models can be added in one place and then refreshed into droplets.

Auth is standardized via `/etc/openclaw/openclaw.env` (root-owned, group-readable by `openclaw`) and sourced by shell startup + bootstrap launchers, so child/spawned agents can inherit the same API key consistently.

## Quick Start (fewest inputs)

```bash
# 1) SSH into new droplet as root
ssh root@YOUR_DROPLET_IP

# 2) Set required values
export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export DISCORD_TARGET="YOUR_GUILD_ID/YOUR_CHANNEL_ID"
export DISCORD_HUMAN_ID="YOUR_DISCORD_USER_ID"
export OPENAI_API_KEY="YOUR_OPENAI_API_KEY"
export ANTHROPIC_API_KEY="YOUR_ANTHROPIC_API_KEY"
export MOONSHOT_API_KEY="YOUR_MOONSHOT_API_KEY"
export SYNTELLA_PORTAL_API_TOKEN="YOUR_SHARED_DROPLET_TOKEN"
export TS_AUTHKEY="tskey-..."
export TS_HOSTNAME="syntella-example-client"
# 3) Run bootstrap
curl -fsSL https://raw.githubusercontent.com/DanielH3o/syntella/main/scripts/bootstrap-root.sh | bash
```

## Optional: deterministic SSH key install for `openclaw` user

```bash
export OPENCLAW_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)"
export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export DISCORD_TARGET="YOUR_GUILD_ID/YOUR_CHANNEL_ID"
export DISCORD_HUMAN_ID="YOUR_DISCORD_USER_ID"
export OPENAI_API_KEY="YOUR_OPENAI_API_KEY"
export ANTHROPIC_API_KEY="YOUR_ANTHROPIC_API_KEY"
export MOONSHOT_API_KEY="YOUR_MOONSHOT_API_KEY"
export SYNTELLA_PORTAL_API_TOKEN="YOUR_SHARED_DROPLET_TOKEN"
export TS_AUTHKEY="tskey-..."
export TS_HOSTNAME="syntella-example-client"
curl -fsSL https://raw.githubusercontent.com/DanielH3o/syntella/main/scripts/bootstrap-root.sh | bash
```

After bootstrap, Syntella-managed admin files are in:

- `~/.openclaw/workspace/admin`

Customer-owned project space lives in:

- `~/.openclaw/workspace/project`

Bootstrap now preserves customer workspace state by default. System-managed admin assets are updated in place, while the customer project workspace is left alone.

Bootstrap writes startup context docs at workspace root:

- `~/.openclaw/workspace/AGENTS.md`
- `~/.openclaw/workspace/SOUL.md`
- `~/.openclaw/workspace/USER.md`
- `~/.openclaw/workspace/MEMORY.md`
- `~/.openclaw/workspace/memory/YYYY-MM-DD.md` (today + yesterday)

Customer website/frontend files, reports, and project assets should live in `~/.openclaw/workspace/project`.
Syntella admin stays separate at `/admin`.

## Manual path

```bash
ssh root@YOUR_DROPLET_IP
adduser openclaw
usermod -aG sudo openclaw
su - openclaw

git clone https://github.com/DanielH3o/syntella-droplet.git
cd syntella
export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export DISCORD_TARGET="YOUR_GUILD_ID/YOUR_CHANNEL_ID"
export DISCORD_HUMAN_ID="YOUR_DISCORD_USER_ID"
export OPENAI_API_KEY="YOUR_OPENAI_API_KEY"
export ANTHROPIC_API_KEY="YOUR_ANTHROPIC_API_KEY"
export MOONSHOT_API_KEY="YOUR_MOONSHOT_API_KEY"
export SYNTELLA_PORTAL_API_TOKEN="YOUR_SHARED_DROPLET_TOKEN"
export TS_AUTHKEY="tskey-..."
export TS_HOSTNAME="syntella-example-client"
bash scripts/bootstrap-openclaw.sh
```

After bootstrap, record the printed MagicDNS hostname and use it in the site repo as:

```text
http://syntella-example-client:8788
```

## Local development

You can work on the frontend and local dashboard logic without rebuilding a droplet.

```bash
bash scripts/dev-server.sh
```

That starts a single local server on `http://127.0.0.1:3000` which:

- serves the frontend from this repo
- reads agents from `~/.openclaw/workspace/agents/registry.json`
- reads and writes tasks in `~/.openclaw/workspace/tasks.db`

Useful routes:

- `http://127.0.0.1:3000/`
- `http://127.0.0.1:3000/admin`
- `http://127.0.0.1:3000/api/departments`
- `http://127.0.0.1:3000/api/tasks`

Optional env vars:

- `SYNTELLA_WORKSPACE=/path/to/workspace`
- `SYNTELLA_DEV_PORT=3001`
- `SYNTELLA_PORTAL_API_TOKEN=...` when testing authenticated `/api/*`

If your local OpenClaw processes are already writing to `~/.openclaw/workspace`, the dashboard will use that real data. If `registry.json` does not exist yet, the UI still runs but Departments will be empty until agents register.

## v1 Hardening / Verification

After bootstrap, run:

```bash
sudo -u openclaw -H bash /home/openclaw/syntella/scripts/smoke-test.sh
```

This checks gateway listener, Discord config, project files, and local/public frontend responses.

For tailnet API checks:

```bash
curl http://127.0.0.1:8788/health
curl -H "Authorization: Bearer ${SYNTELLA_PORTAL_API_TOKEN}" http://127.0.0.1:8788/api/health
sudo tailscale status
sudo cat /etc/openclaw/tailscale.env
```

## Shared API key strategy (recommended)

Use one canonical OpenClaw home and one canonical env file:

- `OPENCLAW_HOME=/home/openclaw/.openclaw`
- `OPENCLAW_PROFILE=main`
- `OPENAI_API_KEY=...`
- `ANTHROPIC_API_KEY=...`
- `MOONSHOT_API_KEY=...`
- env file path: `/etc/openclaw/openclaw.env`

When starting extra profiles/processes, source the env file first:

```bash
set -a
source /etc/openclaw/openclaw.env
set +a
openclaw --profile <profile> gateway --port <port>
```

This avoids auth drift from ad-hoc homes such as `~/.openclaw-agent2`.

## Operator Bridge (spawn-only)

Bootstrap installs a localhost-only bridge for deterministic dedicated-agent creation:

- Health: `GET http://127.0.0.1:8787/health`
- Spawn: `POST http://127.0.0.1:8787/spawn-agent`
- Auth token: `/etc/openclaw/operator-bridge.env` (`OPERATOR_BRIDGE_TOKEN`)

Example:

```bash
source /etc/openclaw/operator-bridge.env
curl -sS -X POST "http://127.0.0.1:${OPERATOR_BRIDGE_PORT}/spawn-agent" \
  -H "Authorization: Bearer ${OPERATOR_BRIDGE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"nova","role":"research helper","discord_token":"YOUR_BOT_TOKEN"}'
```

## Troubleshooting

### `Permission denied (publickey)` for `openclaw`

```bash
ssh -i ~/.ssh/id_ed25519 -v openclaw@YOUR_DROPLET_IP
ls -ld /home/openclaw/.ssh
ls -l /home/openclaw/.ssh/authorized_keys
```

If needed, re-run root bootstrap with explicit key injection (`OPENCLAW_AUTHORIZED_KEY=...`).

### Discord messages not reaching agent

- Verify bot is invited to the target guild/channel
- Verify token is correct
- Verify target IDs are correct
- Verify bot can post in the configured channel
- If bootstrap did not send the startup ping, test manually:

```bash
openclaw message send --channel discord --target "channel:YOUR_CHANNEL_ID" --message "test"
```

- On droplet:

```bash
openclaw status
openclaw gateway status || true
tail -n 120 ~/.openclaw/logs/gateway.log
```

## Files

- `scripts/bootstrap-openclaw.sh` — main installer (Discord-first)
- `scripts/bootstrap-root.sh` — non-interactive root bootstrap
- `scripts/smoke-test.sh` — post-bootstrap verification checks
- `cloud-init/user-data.yaml` — optional unattended first boot
- `docs/rollout-plan.md` — roadmap
