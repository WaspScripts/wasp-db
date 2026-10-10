#!/usr/bin/env bash
set -euo pipefail

WORK=/tmp/wasp-db

mkdir -p ~/.ssh
printf '%s' "$DEPLOY_KEY" | base64 -d > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > ~/.ssh/known_hosts

dump() {
	pg_dump \
		--schema-only \
		--quote-all-identifier \
		--role "postgres" \
		--exclude-schema "" \
		--schema="$1" \
	| sed -E 's/^\\(un)?restrict .*$/-- &/' \
	| sed -E 's/^CREATE SCHEMA "/CREATE SCHEMA IF NOT EXISTS "/' \
	| sed -E 's/^CREATE TABLE "/CREATE TABLE IF NOT EXISTS "/' \
	| sed -E 's/^CREATE SEQUENCE "/CREATE SEQUENCE IF NOT EXISTS "/' \
	| sed -E 's/^CREATE VIEW "/CREATE OR REPLACE VIEW "/' \
	| sed -E 's/^CREATE FUNCTION "/CREATE OR REPLACE FUNCTION "/' \
	| sed -E 's/^CREATE TRIGGER "/CREATE OR REPLACE TRIGGER "/' \
	| sed -E 's/^CREATE PUBLICATION "supabase_realtime/-- &/' \
	| sed -E 's/^CREATE EVENT TRIGGER /-- &/' \
	| sed -E 's/^         WHEN TAG IN /-- &/' \
	| sed -E 's/^   EXECUTE FUNCTION /-- &/' \
	| sed -E 's/^ALTER EVENT TRIGGER /-- &/' \
	| sed -E 's/^ALTER PUBLICATION "supabase_realtime_/-- &/' \
	| sed -E 's/^ALTER FOREIGN DATA WRAPPER (.+) OWNER TO /-- &/' \
	| sed -E 's/^ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin"/-- &/' \
	| sed -E 's/^GRANT ALL ON FOREIGN DATA WRAPPER (.+) TO "postgres" WITH GRANT OPTION/-- &/' \
	| sed -E "s/^GRANT (.+) ON (.+) \"()\"/-- &/" \
	| sed -E "s/^REVOKE (.+) ON (.+) \"()\"/-- &/" \
	| sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pg_tle").+/\1;/' \
	| sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pgsodium").+/\1;/' \
	| sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pgmq").+/\1;/' \
	| sed -E 's/^COMMENT ON EXTENSION (.+)/-- &/' \
	| sed -E 's/^CREATE POLICY "cron_job_/-- &/' \
	| sed -E 's/^ALTER TABLE "cron"/-- &/' \
	| sed -E 's/^SET transaction_timeout = 0;/-- &/' \
	| sed -E "/^--/d"
}

rm -rf "$WORK"
git clone --quiet --depth 1 "$GIT_REPO" "$WORK"
cd "$WORK"

echo "Dumping schemas..."
dump 'public|profiles|scripts|stats|stripe|info' > supabase/schema.sql

echo "Dumping storage policies..."
{
	echo "-- RLS policies for Supabase's storage schema (extracted from a full storage dump)."
	echo
	dump 'storage' | awk '
		/^CREATE POLICY / || /^ALTER TABLE .* ENABLE ROW LEVEL SECURITY;/ { capture = 1 }
		capture { print; if (/;[[:space:]]*$/) { capture = 0; print "" } }
	'
} > supabase/storage_policies.sql

if grep -inE "secret|api_key|password|token|key_id" supabase/schema.sql supabase/storage_policies.sql \
	| grep -ivE "secret_key|secret text|decrypted_secret|WEBHOOK_SECRET|generate_hmac|path_tokens|x-simba-secret', *[a-z_]+\b"; then
	echo "Potential secret found in schema dump, aborting." >&2
	exit 1
fi

git add supabase/schema.sql supabase/storage_policies.sql
if git diff --cached --quiet; then
	echo "No schema changes detected."
	exit 0
fi

git -c user.name="wasp-db-sync" -c user.email="wasp-db-sync@users.noreply.github.com" \
	commit --quiet -m "Sync schema snapshot [automated]"
git push --quiet
echo "Schema snapshot pushed."
