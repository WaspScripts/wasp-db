# wasp-db

Open-source schema for the self-hosted Supabase instance behind the WASP projects.

This repo contains **structure only** — tables, columns, functions, triggers, views,
RLS policies, and foreign table definitions — with **no row data**. It's meant to let
anyone inspect the database design or spin up a matching instance from scratch.

## What's included

- Schemas: `public`, `profiles`, `scripts`, `stats`, `stripe`, `info`
- All tables, columns, constraints, indexes, sequences
- All views
- All functions (including trigger functions)
- All triggers
- All Row Level Security (RLS) policies
- Foreign table definitions for the Stripe wrapper (`stripe` schema) — these reference
  a foreign server by name only; no credentials are included (see below)

Supabase's own internal schemas (`auth`, `storage`, `realtime`, `extensions`, `vault`,
`cron`, `net`, `pgbouncer`, `pgsodium`, etc.) are intentionally excluded. These are
recreated automatically by Supabase's own Docker images when you spin up a fresh
self-hosted instance — they don't belong to this project.

## What's NOT included (by design)

- Any row data
- Supabase's internal schemas and their migrations
- Any secrets or credentials. The `stripe` schema's foreign tables reference a
  `SERVER "stripe_wrapper_server"` that is defined separately (outside this dump) and
  backed by a [Supabase Vault](https://supabase.com/docs/guides/database/vault) secret
  reference — never a literal API key.

## Rebuilding a fresh instance

1. Stand up a self-hosted Supabase instance using the
   [official Docker setup](https://supabase.com/docs/guides/self-hosting/docker).
2. Install any required extensions your schemas depend on (e.g. the
   [Stripe Wrapper](https://supabase.com/docs/guides/database/extensions/wrappers/stripe)
   if you want the `stripe` schema's foreign tables to actually resolve data).
3. Apply the migrations in `supabase/migrations/` in order, e.g.:

   ```bash
   supabase db push --db-url "postgresql://postgres:<password>@<host>:<port>/postgres"
   ```

4. If you use the Stripe Wrapper, create the foreign server and Vault secret yourself —
   see Supabase's Wrappers docs linked above. This repo does not include that setup
   since it's credential-specific to each deployment.

## Keeping the schema in sync

`supabase/schema.sql` is the live, always-current snapshot of the schema. It's kept up
to date automatically by `.github/workflows/schema-sync.yml`, which:

1. Runs every 24 hours (and can be triggered manually from the Actions tab).
2. Dumps the schema for `public,profiles,scripts,stats,stripe,info` using credentials
   stored as repo secrets (never committed, never printed in logs).
3. Runs a grep-based secret scan over the fresh dump as a safety net before committing.
4. Commits and pushes `supabase/schema.sql` only if it actually changed.

### Required repo secrets

Set these under Settings → Secrets and variables → Actions:

| Secret | Description |
| --- | --- |
| `DB_HOST` | IP or hostname of the self-hosted Postgres instance |
| `DB_PORT` | Port Postgres is listening on |
| `DB_USER` | Postgres role to connect as (e.g. `postgres`) |
| `DB_PASSWORD` | Password for that role |

The workflow builds the connection string from these at run time, so none of them ever
appear in this repo or in workflow logs.

### Manual dump

To regenerate the snapshot locally instead of waiting for the scheduled run:

```bash
supabase db dump \
  --db-url "postgresql://<user>:<password>@<host>:<port>/postgres" \
  --schema public,profiles,scripts,stats,stripe,info \
  -f supabase/schema.sql
```

Always grep new dumps for `secret|api_key|password|token|key_id` before committing,
to catch anything that shouldn't be published — the automated workflow does this too,
but double-check manual runs yourself.

## Migrations

`supabase/migrations/` holds the one-off, manually curated baseline migration used to
originally seed a fresh instance. It is not updated automatically — `supabase/schema.sql`
is the source of truth for "what does the schema look like right now."
