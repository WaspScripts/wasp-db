# wasp-db

Open-source schema for the self-hosted Supabase instance behind the WaspScripts projects which is hosted through a self-hosted Coolify instance.

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
- RLS policies on Supabase's `storage` schema (`supabase/storage_policies.sql`)
- Foreign table definitions for the Stripe wrapper (`stripe` schema) — these reference
  a foreign server by name only; no credentials are included (see below)

Supabase's own internal schemas (`auth`, `storage`, `realtime`, `extensions`, `vault`,
`cron`, `net`, `pgbouncer`, `pgsodium`, etc.) are intentionally excluded. These are
recreated automatically by Supabase's own Docker images when you spin up a fresh
self-hosted instance — they don't belong to this project. The one exception is the RLS
policies on `storage` tables (e.g. `storage.objects`), which are project-specific and
are kept in `supabase/storage_policies.sql`.

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

4. Apply `supabase/storage_policies.sql` to recreate the storage bucket access rules.
5. If you use the Stripe Wrapper, create the foreign server and Vault secret yourself —
   see Supabase's Wrappers docs linked above. This repo does not include that setup
   since it's credential-specific to each deployment.

## Keeping the schema in sync

`supabase/schema.sql` is the live, always-current snapshot of the schema. It's kept up
to date by the `wasp-db-sync` container, which runs inside the Supabase stack
(`docker-compose.yml`) and reaches Postgres over the internal Docker network, so the
database never needs to be exposed to the internet. Its script,
`volumes/wasp-db-sync/sync.sh`:

1. Dumps the schema for `public,profiles,scripts,stats,stripe,info` with the same
   `pg_dump` flags and `sed` cleanup that `supabase db dump` uses, so the output format
   is identical.
2. Dumps the `storage` schema separately and extracts only its RLS statements into
   `supabase/storage_policies.sql`.
3. Runs a grep-based secret scan over the fresh dumps as a safety net before committing.
4. Commits and pushes `supabase/schema.sql` and `supabase/storage_policies.sql` only if
   they actually changed.

It runs every 24 hours as a Coolify scheduled task. To run it on demand, open the
`wasp-db-sync` container's terminal and run:

```bash
sync
```

### Required environment variable

| Variable             | Description                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------ |
| `WASP_DB_DEPLOY_KEY` | Base64 of the private key of a write-enabled deploy key for this repo (`base64 -w0 <key>`) |

The database credentials come from the stack's existing `SERVICE_PASSWORD_POSTGRES`, so
nothing database-related is stored outside the server.

## Migrations

`supabase/migrations/` holds the one-off, manually curated baseline migration used to
originally seed a fresh instance. It is not updated automatically — `supabase/schema.sql`
is the source of truth for "what does the schema look like right now."
