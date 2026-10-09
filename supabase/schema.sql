


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "info";


ALTER SCHEMA "info" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "profiles";


ALTER SCHEMA "profiles" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "scripts";


ALTER SCHEMA "scripts" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "stats";


ALTER SCHEMA "stats" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "stripe";


ALTER SCHEMA "stripe" OWNER TO "supabase_admin";


CREATE TYPE "profiles"."roles" AS ENUM (
    'premium',
    'contributor',
    'tester',
    'scripter',
    'moderator',
    'administrator'
);


ALTER TYPE "profiles"."roles" OWNER TO "supabase_admin";


COMMENT ON TYPE "profiles"."roles" IS 'Profile roles';



CREATE TYPE "scripts"."category" AS ENUM (
    'combat',
    'boss',
    'minigame',
    'moneymaker',
    'tool',
    'magic',
    'prayer',
    'mining',
    'fishing',
    'woodcutting',
    'hunter',
    'farming',
    'cooking',
    'smithing',
    'fletching',
    'firemaking',
    'herblore',
    'crafting',
    'construction',
    'agility',
    'slayer',
    'thieving',
    'runecrafting',
    'sailing'
);


ALTER TYPE "scripts"."category" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."category" IS 'Script categories';



CREATE TYPE "scripts"."stage" AS ENUM (
    'prototype',
    'alpha',
    'beta',
    'stable',
    'archived'
);


ALTER TYPE "scripts"."stage" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."stage" IS 'Release lifecycle';



CREATE TYPE "scripts"."status" AS ENUM (
    'official',
    'community'
);


ALTER TYPE "scripts"."status" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."status" IS 'Script status';



CREATE TYPE "scripts"."type" AS ENUM (
    'premium',
    'free'
);


ALTER TYPE "scripts"."type" OWNER TO "supabase_admin";


COMMENT ON TYPE "scripts"."type" IS 'Script type';



CREATE TYPE "stripe"."currency" AS ENUM (
    'eur',
    'usd',
    'cad',
    'aud'
);


ALTER TYPE "stripe"."currency" OWNER TO "supabase_admin";


CREATE TYPE "stripe"."cycle" AS ENUM (
    'week',
    'month',
    'year'
);


ALTER TYPE "stripe"."cycle" OWNER TO "supabase_admin";


COMMENT ON TYPE "stripe"."cycle" IS 'Recurring payment intervals';



CREATE OR REPLACE FUNCTION "profiles"."add_balance"("account" "text", "amount" bigint) RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
      WITH u AS (UPDATE profiles.balances SET balance = balance + amount WHERE stripe = account RETURNING 1)
      SELECT EXISTS (SELECT 1 FROM u);
$$;


ALTER FUNCTION "profiles"."add_balance"("account" "text", "amount" bigint) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."can_access"("script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
      SELECT profiles.can_access(auth.uid(), script_id);
$$;


ALTER FUNCTION "profiles"."can_access"("script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."can_access"("accesser_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
      WITH viewer AS (
              SELECT role FROM profiles.profiles WHERE id = accesser_id
      ),
      script AS (
              SELECT p.author, m.type, m.stage, s.published
              FROM scripts.scripts s
              JOIN scripts.metadata m ON m.id = s.id
              JOIN scripts.protected p ON p.id = s.id
              WHERE s.id = script_id
      ),
      granting AS (
              SELECT pr.id
              FROM stripe.products pr
              WHERE pr.active
                      AND (pr.script = script_id
                              OR pr.bundle IN (SELECT b.id FROM scripts.bundles b WHERE script_id = ANY(b.scripts)))
      )
      SELECT
              (accesser_id IS NOT DISTINCT FROM auth.uid() OR COALESCE(auth.role(), 'service_role') = 'service_role')
              AND COALESCE((
                      SELECT
                              sc.author = accesser_id
                              OR v.role >= 'moderator'::profiles.roles
                              OR (
                                      CASE sc.stage
                                              WHEN 'alpha'::scripts.stage THEN v.role >= 'tester'::profiles.roles
                                              WHEN 'beta'::scripts.stage THEN sc.published
                                              WHEN 'stable'::scripts.stage THEN sc.published
                                              ELSE false
                                      END
                                      AND (
                                              sc.type <> 'premium'::scripts.type
                                              OR v.role >= 'tester'::profiles.roles
                                              OR EXISTS (
                                                      SELECT 1 FROM profiles.subscriptions su
                                                      WHERE su.user_id = accesser_id AND su.date_end > now() AND su.product IN (SELECT id FROM granting)
                                              )
                                              OR EXISTS (
                                                      SELECT 1 FROM profiles.free_access fa
                                                      WHERE fa.user_id = accesser_id AND fa.date_end > now() AND fa.product IN (SELECT id FROM granting)
                                              )
                                      )
                              )
                      FROM script sc
                      LEFT JOIN viewer v ON true
              ), false);
$$;


ALTER FUNCTION "profiles"."can_access"("accesser_id" "uuid", "script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."can_view"("viewer_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'off'
    AS $$
BEGIN
	-- author check
	IF EXISTS ( 
		SELECT 1 FROM scripts.protected WHERE script_id = id AND author = viewer_id
	) THEN
		RETURN true;
	END IF;
	
	-- mod/admin check
	IF (profiles.min_role(viewer_id, 'moderator'::profiles.roles)) THEN
		RETURN true;
	END IF;

	IF (
		scripts.is_stage(script_id, 'archived'::scripts.stage) OR
		scripts.is_stage(script_id, 'prototype'::scripts.stage)
	) THEN
		RETURN false;
	END IF;

	-- tester/scripter and script alpha+ check
	IF (scripts.is_stage(script_id, 'alpha'::scripts.stage)) THEN
		IF (profiles.min_role(viewer_id, 'tester'::profiles.roles)) THEN
			RETURN true;
		END IF;
		RETURN false;
	END IF;

	IF EXISTS ( 
		SELECT 1 FROM scripts.scripts WHERE script_id = id AND published = true
	) THEN
		RETURN true;
	END IF;
	
	RETURN false;
END;
$$;


ALTER FUNCTION "profiles"."can_view"("viewer_id" "uuid", "script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."can_view_subscription"("accesser" "uuid", "owner" "uuid", "product" "text") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
  RETURN
	  (accesser = owner) OR
    EXISTS (
      SELECT 1
			FROM stripe.products
			WHERE ((product = id) AND (accesser = user_id))
    );
END;$$;


ALTER FUNCTION "profiles"."can_view_subscription"("accesser" "uuid", "owner" "uuid", "product" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."get_avatar"("userid" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
	data jsonb;
BEGIN
	SELECT identity_data
	INTO data    
	FROM auth.identities
	WHERE user_id = userid AND provider = 'discord'
	LIMIT 1;
					
	RETURN data ->> 'avatar_url';
END;

$$;


ALTER FUNCTION "profiles"."get_avatar"("userid" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."get_discord_id"("userid" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
DECLARE  
  result text;
BEGIN 
  SELECT provider_id INTO result
  FROM auth.identities 
  WHERE userid = user_id AND provider = 'discord';
  RETURN result;
END;
$$;


ALTER FUNCTION "profiles"."get_discord_id"("userid" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."get_roles_enum"() RETURNS "text"[]
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select enum_range(null::profiles.roles)::text[];
$$;


ALTER FUNCTION "profiles"."get_roles_enum"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."get_username"("userid" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$DECLARE
    data jsonb;
    result text;
BEGIN
    SELECT identity_data INTO data    
    FROM auth.identities
    WHERE user_id = userid AND provider = 'discord'
    LIMIT 1;
                    
    result := data -> 'custom_claims' ->> 'global_name';

    IF result IS NULL OR result = '' THEN
        result := split_part(data ->> 'name', '#', 1);
    END IF;

    RETURN result;
END;$$;


ALTER FUNCTION "profiles"."get_username"("userid" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    RETURN profiles.is_role(auth.uid(), target_role);
END;
$$;


ALTER FUNCTION "profiles"."is_role"("target_role" "profiles"."roles") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE(
    (
        SELECT p.role = target_role
        FROM profiles.profiles p
        WHERE p.id = user_id
    ),
    false
  );
$$;


ALTER FUNCTION "profiles"."is_role"("user_id" "uuid", "target_role" "profiles"."roles") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE(
        (
            SELECT p.role >= target_role
            FROM profiles.profiles p
            WHERE p.id = user_id
        ),
        false
    );
$$;


ALTER FUNCTION "profiles"."min_role"("user_id" "uuid", "target_role" "profiles"."roles") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."tr_profiles_post_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$BEGIN
	IF NEW.role IN ('scripter', 'moderator', 'administrator')
       AND (OLD.role IS DISTINCT FROM NEW.role)
       AND NOT EXISTS (
           SELECT 1 FROM profiles.scripters WHERE id = NEW.id
       )
    THEN
        INSERT INTO profiles.scripters (id, stripe, url)
        VALUES (
            NEW.id,
            NEW.id,
            regexp_replace(NEW.username, ' ', '-', 'g')
        );
        INSERT INTO profiles.balances (id, stripe)
        VALUES (
            NEW.id,
            NEW.id
        );
    END IF;

    RETURN NULL;
END;$$;


ALTER FUNCTION "profiles"."tr_profiles_post_update"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."tr_profiles_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    NEW.username := profiles.get_username(NEW.id);
    NEW.avatar := profiles.get_avatar(NEW.id);
    RETURN NEW;
END;
$$;


ALTER FUNCTION "profiles"."tr_profiles_pre_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."tr_scritpers_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$DECLARE
  name TEXT;
BEGIN
  SELECT username INTO name
  FROM profiles.profiles
  WHERE id = auth.uid();

  NEW.url := replace(name, ' ', '-');

  RETURN NEW;
END;$$;


ALTER FUNCTION "profiles"."tr_scritpers_pre_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "profiles"."uid"() RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
   RETURN auth.uid();
END;$$;


ALTER FUNCTION "profiles"."uid"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
    RETURN encode(extensions.hmac(message::bytea, secret_key::bytea, 'sha256'), 'base64');
END;
$$;


ALTER FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "public"."get_simba_hash"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    markdown text;
    latest_hash text;
BEGIN
    -- Fetch the Markdown content
    SELECT content::text
    INTO markdown
    FROM extensions.http_get('https://raw.githubusercontent.com/Villavu/Simba-Build-Archive/refs/heads/main/README.md') AS r;

    -- Extract the latest commit hash for the 'simba2000' branch
    WITH lines AS (
        SELECT regexp_matches(line, '(\d{4}/\d{2}-\d{2}) \| (simba2000) \| \[([a-f0-9]+)\]', 'g') AS m
        FROM regexp_split_to_table(markdown, E'\n') AS line
    ),
    parsed AS (
        SELECT 
            m[1]::text AS date,
            m[3]::text AS commit_hash
        FROM lines
    )
    SELECT commit_hash
    INTO latest_hash
    FROM parsed
    ORDER BY date DESC
    LIMIT 1;

    RETURN latest_hash;
END;
$$;


ALTER FUNCTION "public"."get_simba_hash"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "public"."get_wasplib_hash"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    xml_data text;
    matches text[];
BEGIN
    -- Get the Atom XML feed
    SELECT content::text
    INTO xml_data
    FROM extensions.http_get('https://github.com/WaspScripts/WaspLib/releases.atom');

    -- Extract the first <title>vX.Y.Z</title> — latest tag
    SELECT regexp_matches(xml_data, '<entry>.*?<title>([^<]+)</title>', 's')
    INTO matches;

    RETURN matches[1];  -- First capture group from first match
END;
$$;


ALTER FUNCTION "public"."get_wasplib_hash"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "public"."webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$DECLARE
    secret text;
    payload jsonb;
    request_id bigint;
    signature text;
    url text;
BEGIN
    SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name = 'WEBHOOK_SECRET' LIMIT 1;

    -- Generate the payload
    payload = jsonb_build_object(
            'old_record', old,
            'record', new,
            'type', tg_op,
            'table', tg_table_name,
            'schema', tg_table_schema
              );

    -- Generate the signature
    signature = generate_hmac(secret, payload::text);

    -- Build dynamic URL
    url := format(
        'https://waspscripts.com/api/supabase/%s/%s',
        tg_table_schema,
        tg_table_name
    );

    -- Send the webhook request
    SELECT http_post
    INTO request_id
    FROM
        net.http_post(
                url,
                payload,
                '{}',
                jsonb_build_object(
                        'Content-Type', 'application/json',
                        'X-Supabase-Signature', signature
                ),
                '4000'
        );

    -- Insert the request ID into the Supabase hooks table
    INSERT INTO supabase_functions.hooks
        (hook_table_id, hook_name, request_id)
    VALUES (tg_relid, tg_name, request_id);

    RETURN new;
END;$$;


ALTER FUNCTION "public"."webhook"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."cron_update_simba_versions"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$DECLARE
    markdown text;
BEGIN
    SELECT content::text
    INTO markdown
    FROM extensions.http_get(
        'https://raw.githubusercontent.com/Villavu/Simba-Build-Archive/refs/heads/main/README.md'
    ) AS r;

    WITH lines AS (
        SELECT regexp_matches(
            line,
            '(\d{4}/\d{2}-\d{2}) \| (simba2000) \| \[([a-f0-9]+)\]',
            'g'
        ) AS m
        FROM regexp_split_to_table(markdown, E'\n') AS line
    ),
    parsed AS (
        SELECT 
            m[1]::text AS date_str,
            m[3]::text AS commit_hash
        FROM lines
    ),
    cleaned AS (
        SELECT
            commit_hash AS version,
            to_timestamp(date_str, 'YYYY/MM-DD')::timestamptz AS created_at,
            '/' || date_str || '%20simba2000%20' || commit_hash || '/' AS url
        FROM parsed
    )
    INSERT INTO scripts.simba(version, created_at, url)
    SELECT version, created_at, url
    FROM cleaned
    ON CONFLICT (version) DO NOTHING;
END;$$;


ALTER FUNCTION "scripts"."cron_update_simba_versions"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."get_revision"("script_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$begin
	return (select revision
          from scripts.protected
			    where id = script_id);
end;$$;


ALTER FUNCTION "scripts"."get_revision"("script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
  RETURN
	EXISTS (SELECT 1
					FROM scripts.protected
					WHERE ((script_id = id) AND (user_id = author)));
END;$$;


ALTER FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_premium"("script_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
  RETURN
	EXISTS (
    SELECT 1
		FROM scripts.metadata
		WHERE (script_id = id) AND (type = 'premium'::scripts.type)
  );
END;$$;


ALTER FUNCTION "scripts"."is_premium"("script_id" "uuid") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$SELECT COALESCE(s.stage = target_stage, false)
    FROM scripts.metadata s
    WHERE s.id = script_id;$$;


ALTER FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."latest_wasplib"() RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$ SELECT version FROM scripts.wasplib ORDER BY created_at DESC LIMIT 1 $$;


ALTER FUNCTION "scripts"."latest_wasplib"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
SELECT COALESCE(
	(
		SELECT s.stage <= target_stage
		FROM scripts.metadata s
		WHERE s.id = script_id
	),
	false
);
$$;


ALTER FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$SELECT COALESCE(
        (
            SELECT s.stage >= target_stage
            FROM scripts.metadata s
            WHERE s.id = script_id
        ),
        false
    );$$;


ALTER FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_bundles_check_scripts"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
      IF auth.uid() IS NULL OR profiles.min_role(auth.uid(), 'moderator'::profiles.roles) THEN
              RETURN NEW;
      END IF;

      IF EXISTS (
              SELECT 1
              FROM unnest(NEW.scripts) AS s(id)
              WHERE NOT EXISTS (
                      SELECT 1 FROM scripts.protected p WHERE p.id = s.id AND p.author = NEW.author
              )
      ) THEN
              RAISE EXCEPTION 'Bundles can only contain scripts authored by the bundle author'
                      USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
END;
$$;


ALTER FUNCTION "scripts"."tr_bundles_check_scripts"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_bundles_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
	SELECT username, avatar
	INTO NEW.username, NEW.avatar
	FROM profiles.profiles
	WHERE id = auth.uid();
	
	RETURN NEW;
END;$$;


ALTER FUNCTION "scripts"."tr_bundles_pre_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_metadata_pre_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
  IF NEW.stage < OLD.stage THEN
    RAISE EXCEPTION
      'Invalid stage transition: % → % is not allowed',
      OLD.stage, NEW.stage
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     AND auth.uid() IS NOT NULL
     AND NOT profiles.is_role(auth.uid(), 'administrator'::profiles.roles) THEN
    RAISE EXCEPTION
      'Only administrators can change a script status'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN NEW;
END;$$;


ALTER FUNCTION "scripts"."tr_metadata_pre_update"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_protected_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
	SELECT username, avatar
	INTO NEW.username, NEW.avatar
	FROM profiles.profiles
	WHERE id = auth.uid();
	
	RETURN NEW;
END;$$;


ALTER FUNCTION "scripts"."tr_protected_pre_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
	DELETE FROM storage.objects
	WHERE ((bucket_id = 'imgs') AND
			((storage.foldername(name))[2] = OLD.id::text));
	
	DELETE FROM storage.objects
	WHERE ((bucket_id = 'scripts') AND
			((storage.foldername(name))[1] = OLD.id::text));
	
	RETURN OLD;
END;$$;


ALTER FUNCTION "scripts"."tr_scripts_delete"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_post_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
  INSERT INTO scripts.protected (id, revision) VALUES (NEW.id, 1);
  INSERT INTO scripts.metadata (id) VALUES (NEW.id);
  INSERT INTO scripts.versions (id, revision, simba) VALUES (NEW.id, 1, '0000000000');
  INSERT INTO stats.limits (id) VALUES (NEW.id);
  INSERT INTO stats.limits_custom (id) VALUES (NEW.id);
  INSERT INTO stats.values (id) VALUES (NEW.id);
  INSERT INTO stats.values_custom (id) VALUES (NEW.id);
  INSERT INTO stats.website (id) VALUES (NEW.id);

  RETURN NEW;
END;$$;


ALTER FUNCTION "scripts"."tr_scripts_post_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_scripts_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$DECLARE
  name TEXT;
BEGIN
  SELECT username INTO name
  FROM profiles.profiles
  WHERE id = auth.uid();

  NEW.url := replace(NEW.title, ' ', '-') || '-by-' || replace(name, ' ', '-');

  RETURN NEW;
END;$$;


ALTER FUNCTION "scripts"."tr_scripts_pre_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_simba_post_upsert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    secret text;
BEGIN
    SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name = 'SIMBA_FUNCTION_SECRET' LIMIT 1;

    PERFORM net.http_post(
        url := 'https://db.waspscripts.com/functions/v1/simba',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-simba-secret', secret
        ),
        body := jsonb_build_object('version', NEW.version)
    );

    RETURN NEW;
END;
$$;


ALTER FUNCTION "scripts"."tr_simba_post_upsert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "scripts"."tr_storage_objects_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$DECLARE
	script_id text;
	script_revision smallint;
	revision_path text;
	script_file text;
BEGIN
	IF new.bucket_id <> 'scripts' THEN
		RETURN NEW;
	END IF;
	
	script_id := (storage.foldername(NEW.name))[1];
	script_revision := (scripts.get_revision(script_id::uuid) + 1);
	revision_path := lpad(script_revision::text, 9, '0');
	script_file := storage.filename(NEW.name);
	
	NEW.name := script_id || '/' || revision_path || '/' || script_file;
	NEW.path_tokens := ARRAY[script_id, revision_path, script_file]::text[];

	UPDATE scripts.protected
	SET revision = script_revision, updated_at = NEW.created_at
	WHERE id = script_id::uuid;

	INSERT INTO scripts.versions (id, revision)
	SELECT script_id::uuid, script_revision
	WHERE NOT EXISTS (
		SELECT 1 FROM scripts.versions
		WHERE id = script_id::uuid
			AND revision = script_revision
	);

	RETURN NEW;
END;$$;


ALTER FUNCTION "scripts"."tr_storage_objects_insert"() OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."get_level"("experience" bigint) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
BEGIN
  RETURN floor(experience / (13034431 / 99));
END;
$$;


ALTER FUNCTION "stats"."get_level"("experience" bigint) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
      update stats.values v
      set experience = v.experience + add_experience,
          gold       = v.gold + add_gold,
          runtime    = v.runtime + add_runtime
      where v.id = script_id;

      if not found then
              raise exception 'No stats row for script %', script_id using errcode = 'P0002';
      end if;
end;
$$;


ALTER FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
      insert into stats.stats as s (id, experience, gold, runtime)
      values (user_id, add_experience, add_gold, add_runtime)
      on conflict (id) do update
      set experience = s.experience + excluded.experience,
          gold       = s.gold + excluded.gold,
          runtime    = s.runtime + excluded.runtime;
$$;


ALTER FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) OWNER TO "supabase_admin";


CREATE OR REPLACE FUNCTION "stripe"."tr_products_pre_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$BEGIN
	SELECT username, avatar
	INTO NEW.username, NEW.avatar
	FROM profiles.profiles
	WHERE id = NEW.user_id;

	SELECT stripe
	INTO NEW.stripe
	FROM profiles.scripters
	WHERE id = NEW.user_id;
	
	RETURN NEW;
END;$$;


ALTER FUNCTION "stripe"."tr_products_pre_insert"() OWNER TO "supabase_admin";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "info"."privacy_policy" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" smallint NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "info"."privacy_policy" OWNER TO "supabase_admin";


ALTER TABLE "info"."privacy_policy" ALTER COLUMN "version" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "info"."privacy_policy_version_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "info"."scripter_tos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" smallint NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "info"."scripter_tos" OWNER TO "supabase_admin";


ALTER TABLE "info"."scripter_tos" ALTER COLUMN "version" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "info"."scripter_tos_version_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "info"."user_tos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" smallint NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "info"."user_tos" OWNER TO "supabase_admin";


COMMENT ON TABLE "info"."user_tos" IS 'This is a duplicate of scripter_tos';



ALTER TABLE "info"."user_tos" ALTER COLUMN "version" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "info"."user_tos_version_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 32767
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "profiles"."balances" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "balance" bigint DEFAULT '0'::bigint NOT NULL,
    "stripe" "text" NOT NULL
);


ALTER TABLE "profiles"."balances" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "profiles"."free_access" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "product" "text" NOT NULL,
    "date_start" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "date_end" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "profiles"."free_access" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "profiles"."profiles" (
    "id" "uuid" NOT NULL,
    "stripe" "text" NOT NULL,
    "discord" "text" NOT NULL,
    "username" "text" NOT NULL,
    "avatar" "text" NOT NULL,
    "role" "profiles"."roles"
);


ALTER TABLE "profiles"."profiles" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "profiles"."scripters" (
    "id" "uuid" NOT NULL,
    "stripe" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL,
    "realname" "text",
    "github" "text",
    "paypal" "text",
    "description" "text",
    "content" "text",
    "url" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL,
    CONSTRAINT "scripters_content_length" CHECK ((("content" IS NULL) OR ("length"("content") <= 20000))),
    CONSTRAINT "scripters_description_length" CHECK ((("description" IS NULL) OR (("length"("description") >= 6) AND ("length"("description") <= 32)))),
    CONSTRAINT "scripters_github_check" CHECK ((("github" IS NULL) OR ("github" ~ '^[A-Za-z0-9-]{1,39}$'::"text")))
);


ALTER TABLE "profiles"."scripters" OWNER TO "supabase_admin";


CREATE MATERIALIZED VIEW "profiles"."random_scripters" AS
 SELECT "scripters"."id",
    "scripters"."stripe",
    "scripters"."url",
    "scripters"."realname",
    "scripters"."github",
    "scripters"."paypal",
    "scripters"."description",
    "scripters"."content"
   FROM "profiles"."scripters"
  ORDER BY ("random"())
 LIMIT 5
  WITH NO DATA;


ALTER MATERIALIZED VIEW "profiles"."random_scripters" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "profiles"."subscriptions" (
    "id" "text" NOT NULL,
    "user_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product" "text" NOT NULL,
    "price" "text" NOT NULL,
    "cancel" boolean DEFAULT false NOT NULL,
    "disabled" boolean DEFAULT false NOT NULL,
    "date_start" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "date_end" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "profiles"."subscriptions" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."metadata" (
    "id" "uuid" NOT NULL,
    "status" "scripts"."status" DEFAULT 'community'::"scripts"."status" NOT NULL,
    "type" "scripts"."type" DEFAULT 'free'::"scripts"."type" NOT NULL,
    "categories" "scripts"."category"[] DEFAULT '{}'::"scripts"."category"[] NOT NULL,
    "stage" "scripts"."stage" DEFAULT 'prototype'::"scripts"."stage" NOT NULL
);


ALTER TABLE "scripts"."metadata" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."protected" (
    "id" "uuid" NOT NULL,
    "author" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "revision" integer DEFAULT 0 NOT NULL,
    "username" "text" NOT NULL,
    "avatar" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "updated_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "scripts"."protected" OWNER TO "supabase_admin";


CREATE MATERIALIZED VIEW "scripts"."author_scripts" AS
 SELECT "protected"."author",
    "array_agg"("protected"."id") AS "scripts",
    "count"("protected"."id") AS "total",
    "count"("metadata"."id") FILTER (WHERE ("metadata"."type" = 'premium'::"scripts"."type")) AS "premium"
   FROM ("scripts"."protected" "protected"
     LEFT JOIN "scripts"."metadata" "metadata" ON (("protected"."id" = "metadata"."id")))
  GROUP BY "protected"."author"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "scripts"."author_scripts" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."bundles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "scripts" "uuid"[] NOT NULL,
    "username" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL,
    "avatar" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL
);


ALTER TABLE "scripts"."bundles" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."scripts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "url" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "content" "text" NOT NULL,
    "published" boolean DEFAULT false NOT NULL,
    CONSTRAINT "scripts_content_length" CHECK (("length"("content") <= 20000)),
    CONSTRAINT "scripts_description_length" CHECK ((("length"("description") >= 10) AND ("length"("description") <= 160))),
    CONSTRAINT "scripts_title_length" CHECK ((("length"("title") >= 4) AND ("length"("title") <= 31)))
);


ALTER TABLE "scripts"."scripts" OWNER TO "supabase_admin";


CREATE MATERIALIZED VIEW "scripts"."featured" AS
 WITH "recent_ids" AS (
         SELECT DISTINCT "p"."id"
           FROM "scripts"."protected" "p"
          WHERE ("p"."created_at" >= (CURRENT_DATE - '1 mon'::interval))
        )
 SELECT "s"."id",
    "s"."title"
   FROM ("scripts"."scripts" "s"
     JOIN "scripts"."metadata" "m" ON (("m"."id" = "s"."id")))
  WHERE (("s"."published" = true) AND ("m"."stage" = 'stable'::"scripts"."stage"))
  ORDER BY
        CASE
            WHEN ("s"."id" IN ( SELECT "recent_ids"."id"
               FROM "recent_ids")) THEN 0
            ELSE 1
        END, ("random"())
 LIMIT 10
  WITH NO DATA;


ALTER MATERIALIZED VIEW "scripts"."featured" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."plugins" (
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL
);


ALTER TABLE "scripts"."plugins" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."simba" (
    "version" character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "url" "text" NOT NULL,
    CONSTRAINT "simba_version_check" CHECK ((("version")::"text" ~ '^[0-9a-fA-F]{10}$'::"text"))
);


ALTER TABLE "scripts"."simba" OWNER TO "supabase_admin";


COMMENT ON TABLE "scripts"."simba" IS 'List of Simba versions';



CREATE TABLE IF NOT EXISTS "scripts"."versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "revision" integer NOT NULL,
    "simba" character varying NOT NULL,
    "wasplib" "text" DEFAULT "scripts"."latest_wasplib"() NOT NULL,
    "files" "text"[] DEFAULT '{''script.simba''}'::"text"[] NOT NULL,
    CONSTRAINT "versions_simba_check" CHECK ((("simba")::"text" ~ '^[0-9a-fA-F]{10}$'::"text"))
);


ALTER TABLE "scripts"."versions" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "scripts"."wasplib" (
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "simba" character varying(10) NOT NULL,
    CONSTRAINT "simba_is_hex_10" CHECK ((("simba")::"text" ~ '^[0-9a-fA-F]{10}$'::"text"))
);


ALTER TABLE "scripts"."wasplib" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."limits" (
    "id" "uuid" NOT NULL,
    "xp_min" integer DEFAULT 0 NOT NULL,
    "xp_max" integer DEFAULT 0 NOT NULL,
    "gp_min" bigint DEFAULT '0'::bigint NOT NULL,
    "gp_max" bigint DEFAULT '0'::bigint NOT NULL,
    CONSTRAINT "limits_ranges" CHECK ((("xp_min" >= 0) AND ("xp_max" <= 60000) AND ("gp_min" >= '-200000'::integer) AND ("gp_max" <= 600000) AND ("xp_min" <= "xp_max") AND ("gp_min" <= "gp_max")))
);


ALTER TABLE "stats"."limits" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."limits_custom" (
    "id" "uuid" NOT NULL,
    "trackers" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "minima" bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    "maxima" bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    CONSTRAINT "limits_custom_shape" CHECK ((("cardinality"("trackers") = "cardinality"("minima")) AND ("cardinality"("minima") = "cardinality"("maxima")) AND ("cardinality"("trackers") <= 50)))
);


ALTER TABLE "stats"."limits_custom" OWNER TO "supabase_admin";


COMMENT ON TABLE "stats"."limits_custom" IS 'Custom script stats';



CREATE TABLE IF NOT EXISTS "stats"."online" (
    "script_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "last_seen" timestamp with time zone NOT NULL
);


ALTER TABLE "stats"."online" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."stats" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "experience" bigint DEFAULT '0'::bigint NOT NULL,
    "gold" bigint DEFAULT '0'::bigint NOT NULL,
    "runtime" bigint DEFAULT '0'::bigint NOT NULL,
    "levels" integer GENERATED ALWAYS AS ("stats"."get_level"("experience")) STORED NOT NULL,
    "username" "text" DEFAULT ''::"text" NOT NULL
);


ALTER TABLE "stats"."stats" OWNER TO "supabase_admin";


CREATE MATERIALIZED VIEW "stats"."totals" AS
 SELECT COALESCE("subquery"."experience", (0)::bigint) AS "experience",
    COALESCE("subquery"."gold", (0)::bigint) AS "gold",
    COALESCE("stats"."get_level"(COALESCE("subquery"."experience", (0)::bigint)), 0) AS "levels",
    COALESCE("subquery"."runtime", (0)::bigint) AS "runtime"
   FROM ( SELECT ("sum"("stats"."experience"))::bigint AS "experience",
            ("sum"("stats"."gold"))::bigint AS "gold",
            ("sum"("stats"."runtime"))::bigint AS "runtime"
           FROM "stats"."stats") "subquery"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "stats"."totals" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."values" (
    "id" "uuid" NOT NULL,
    "experience" bigint DEFAULT '0'::bigint NOT NULL,
    "gold" bigint DEFAULT '0'::bigint NOT NULL,
    "runtime" bigint DEFAULT '0'::bigint NOT NULL,
    "levels" integer GENERATED ALWAYS AS ("stats"."get_level"("experience")) STORED
);


ALTER TABLE "stats"."values" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."values_custom" (
    "id" "uuid" NOT NULL,
    "values" bigint[] DEFAULT '{}'::bigint[] NOT NULL
);


ALTER TABLE "stats"."values_custom" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."website" (
    "id" "uuid" NOT NULL,
    "downloads" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "total" bigint GENERATED ALWAYS AS (COALESCE("array_length"("downloads", 1), 0)) STORED
);


ALTER TABLE "stats"."website" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stats"."website_monthly" (
    "id" "uuid" NOT NULL,
    "date" timestamp with time zone DEFAULT ("now"() AT TIME ZONE 'utc'::"text") NOT NULL,
    "downloads" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "total" bigint GENERATED ALWAYS AS (COALESCE("array_length"("downloads", 1), 0)) STORED
);


ALTER TABLE "stats"."website_monthly" OWNER TO "supabase_admin";


CREATE FOREIGN TABLE "stripe"."accounts_ex" (
    "id" "text",
    "business_type" "text",
    "country" "text",
    "email" "text",
    "type" "text",
    "created" timestamp without time zone,
    "attrs" "jsonb"
)
SERVER "stripe_wrapper_server"
OPTIONS (
    "id" '1022187',
    "object" 'accounts',
    "rowid_column" 'id',
    "schema" 'stripe'
);


ALTER FOREIGN TABLE "stripe"."accounts_ex" OWNER TO "supabase_admin";


CREATE FOREIGN TABLE "stripe"."customers_ex" (
    "id" "text",
    "email" "text",
    "name" "text",
    "description" "text",
    "created" timestamp without time zone,
    "attrs" "jsonb"
)
SERVER "stripe_wrapper_server"
OPTIONS (
    "id" '1022190',
    "object" 'customers',
    "rowid_column" 'id',
    "schema" 'stripe'
);


ALTER FOREIGN TABLE "stripe"."customers_ex" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stripe"."prices" (
    "id" "text" NOT NULL,
    "product" "text" NOT NULL,
    "amount" smallint DEFAULT '100'::smallint NOT NULL,
    "interval" "stripe"."cycle" DEFAULT 'week'::"stripe"."cycle" NOT NULL,
    "currency" "stripe"."currency" DEFAULT 'eur'::"stripe"."currency" NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "stripe"."prices" OWNER TO "supabase_admin";


CREATE FOREIGN TABLE "stripe"."prices_ex" (
    "id" "text",
    "active" boolean,
    "currency" "text",
    "product" "text",
    "unit_amount" bigint,
    "type" "text",
    "created" timestamp without time zone,
    "attrs" "jsonb"
)
SERVER "stripe_wrapper_server"
OPTIONS (
    "id" '1022193',
    "object" 'prices',
    "schema" 'stripe'
);


ALTER FOREIGN TABLE "stripe"."prices_ex" OWNER TO "supabase_admin";


CREATE TABLE IF NOT EXISTS "stripe"."products" (
    "id" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "stripe" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL,
    "bundle" "uuid",
    "script" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "name" "text" NOT NULL,
    "username" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL,
    "avatar" "text" DEFAULT ("auth"."uid"())::"text" NOT NULL
);


ALTER TABLE "stripe"."products" OWNER TO "supabase_admin";


CREATE FOREIGN TABLE "stripe"."products_ex" (
    "id" "text",
    "name" "text",
    "active" boolean,
    "default_price" "text",
    "description" "text",
    "created" timestamp without time zone,
    "updated" timestamp without time zone,
    "attrs" "jsonb"
)
SERVER "stripe_wrapper_server"
OPTIONS (
    "id" '1022196',
    "object" 'products',
    "rowid_column" 'id',
    "schema" 'stripe'
);


ALTER FOREIGN TABLE "stripe"."products_ex" OWNER TO "supabase_admin";


CREATE FOREIGN TABLE "stripe"."subscriptions" (
    "id" "text",
    "customer" "text",
    "currency" "text",
    "current_period_start" timestamp without time zone,
    "current_period_end" timestamp without time zone,
    "attrs" "jsonb"
)
SERVER "stripe_wrapper_server"
OPTIONS (
    "id" '1022199',
    "object" 'subscriptions',
    "rowid_column" 'id_ex',
    "schema" 'stripe'
);


ALTER FOREIGN TABLE "stripe"."subscriptions" OWNER TO "supabase_admin";


ALTER TABLE ONLY "info"."privacy_policy"
    ADD CONSTRAINT "privacy_policy_pkey" PRIMARY KEY ("id", "version");



ALTER TABLE ONLY "info"."privacy_policy"
    ADD CONSTRAINT "privacy_policy_version_key" UNIQUE ("version");



ALTER TABLE ONLY "info"."scripter_tos"
    ADD CONSTRAINT "scripter_tos_pkey" PRIMARY KEY ("id", "version");



ALTER TABLE ONLY "info"."scripter_tos"
    ADD CONSTRAINT "scripter_tos_version_key" UNIQUE ("version");



ALTER TABLE ONLY "info"."user_tos"
    ADD CONSTRAINT "user_tos_pkey" PRIMARY KEY ("id", "version");



ALTER TABLE ONLY "info"."user_tos"
    ADD CONSTRAINT "user_tos_version_key" UNIQUE ("version");



ALTER TABLE ONLY "profiles"."balances"
    ADD CONSTRAINT "balances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "profiles"."balances"
    ADD CONSTRAINT "balances_stripe_key" UNIQUE ("stripe");



ALTER TABLE ONLY "profiles"."free_access"
    ADD CONSTRAINT "free_access_id_key" UNIQUE ("id");



ALTER TABLE ONLY "profiles"."free_access"
    ADD CONSTRAINT "free_access_pkey" PRIMARY KEY ("id", "user_id", "product");



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_discord_key" UNIQUE ("discord");



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_id_key" UNIQUE ("id");



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("stripe", "discord");



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_stripe_key" UNIQUE ("stripe");



ALTER TABLE ONLY "profiles"."scripters"
    ADD CONSTRAINT "scripters_id_key" UNIQUE ("id");



ALTER TABLE ONLY "profiles"."scripters"
    ADD CONSTRAINT "scripters_pkey" PRIMARY KEY ("url", "stripe");



ALTER TABLE ONLY "profiles"."scripters"
    ADD CONSTRAINT "scripters_stripe_key" UNIQUE ("stripe");



ALTER TABLE ONLY "profiles"."scripters"
    ADD CONSTRAINT "scripters_url_key" UNIQUE ("url");



ALTER TABLE ONLY "profiles"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id", "user_id", "product", "price");



ALTER TABLE ONLY "profiles"."subscriptions"
    ADD CONSTRAINT "subscriptions_subscription_key" UNIQUE ("id");



ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_id_key" UNIQUE ("id");



ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_pkey" PRIMARY KEY ("id", "author");



ALTER TABLE ONLY "scripts"."metadata"
    ADD CONSTRAINT "metadata_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."plugins"
    ADD CONSTRAINT "plugins_pkey" PRIMARY KEY ("version");



ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_id_key" UNIQUE ("id");



ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_pkey" PRIMARY KEY ("id", "url");



ALTER TABLE ONLY "scripts"."scripts"
    ADD CONSTRAINT "scripts_url_key" UNIQUE ("url");



ALTER TABLE ONLY "scripts"."simba"
    ADD CONSTRAINT "simba_pkey" PRIMARY KEY ("version");



ALTER TABLE ONLY "scripts"."simba"
    ADD CONSTRAINT "simba_url_key" UNIQUE ("url");



ALTER TABLE ONLY "scripts"."versions"
    ADD CONSTRAINT "versions_pkey" PRIMARY KEY ("id", "revision");



ALTER TABLE ONLY "scripts"."wasplib"
    ADD CONSTRAINT "wasplib_pkey" PRIMARY KEY ("version");



ALTER TABLE ONLY "stats"."limits_custom"
    ADD CONSTRAINT "custom_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."values_custom"
    ADD CONSTRAINT "custom_values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."online"
    ADD CONSTRAINT "online_pkey" PRIMARY KEY ("script_id", "user_id");



ALTER TABLE ONLY "stats"."values"
    ADD CONSTRAINT "simba_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."limits"
    ADD CONSTRAINT "stats_limits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stats"."website_monthly"
    ADD CONSTRAINT "website_monthly_pkey" PRIMARY KEY ("id", "date");



ALTER TABLE ONLY "stats"."website"
    ADD CONSTRAINT "website_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stripe"."prices"
    ADD CONSTRAINT "prices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_id_key" UNIQUE ("id");



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id", "user_id", "stripe");



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_script_key" UNIQUE ("script");



CREATE INDEX "free_access_date_end_idx" ON "profiles"."free_access" USING "btree" ("date_end");



CREATE INDEX "free_access_id_idx" ON "profiles"."free_access" USING "btree" ("id");



CREATE INDEX "idx_profiles_free_access_product" ON "profiles"."free_access" USING "btree" ("product");



CREATE INDEX "idx_profiles_free_access_user_id" ON "profiles"."free_access" USING "btree" ("user_id");



CREATE INDEX "idx_profiles_subscriptions_product" ON "profiles"."subscriptions" USING "btree" ("product");



CREATE INDEX "idx_profiles_subscriptions_user_id" ON "profiles"."subscriptions" USING "btree" ("user_id");



CREATE INDEX "profiles_id_idx" ON "profiles"."profiles" USING "btree" ("id");



CREATE INDEX "subscriptions_date_end_idx" ON "profiles"."subscriptions" USING "btree" ("date_end");



CREATE INDEX "subscriptions_id_idx" ON "profiles"."subscriptions" USING "btree" ("id");



CREATE UNIQUE INDEX "idx_featured_id" ON "scripts"."featured" USING "btree" ("id");



CREATE INDEX "idx_plugins_created_at_desc" ON "scripts"."plugins" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_scripts_bundles_author" ON "scripts"."bundles" USING "btree" ("author");



CREATE INDEX "idx_scripts_protected_author" ON "scripts"."protected" USING "btree" ("author");



CREATE INDEX "idx_wasplib_created_at_desc" ON "scripts"."wasplib" USING "btree" ("created_at" DESC);



CREATE INDEX "online_last_seen_idx" ON "stats"."online" USING "btree" ("last_seen");



CREATE INDEX "online_script_time_idx" ON "stats"."online" USING "btree" ("script_id", "last_seen");



CREATE INDEX "online_user_last_seen_idx" ON "stats"."online" USING "btree" ("user_id", "last_seen");



CREATE INDEX "idx_stripe_prices_product" ON "stripe"."prices" USING "btree" ("product");



CREATE INDEX "idx_stripe_products_bundle" ON "stripe"."products" USING "btree" ("bundle");



CREATE INDEX "idx_stripe_products_stripe" ON "stripe"."products" USING "btree" ("stripe");



CREATE INDEX "idx_stripe_products_user_id" ON "stripe"."products" USING "btree" ("user_id");



CREATE OR REPLACE TRIGGER "tr_profiles_post_update" AFTER UPDATE ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_profiles_post_update"();



CREATE OR REPLACE TRIGGER "tr_profiles_pre_insert" BEFORE INSERT ON "profiles"."profiles" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_profiles_pre_insert"();



CREATE OR REPLACE TRIGGER "tr_scritpers_pre_insert" BEFORE INSERT ON "profiles"."scripters" FOR EACH ROW EXECUTE FUNCTION "profiles"."tr_scritpers_pre_insert"();

ALTER TABLE "profiles"."scripters" DISABLE TRIGGER "tr_scritpers_pre_insert";



CREATE OR REPLACE TRIGGER "tr_bundles_check_scripts" BEFORE INSERT OR UPDATE ON "scripts"."bundles" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_bundles_check_scripts"();



CREATE OR REPLACE TRIGGER "tr_bundles_pre_insert" BEFORE INSERT ON "scripts"."bundles" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_bundles_pre_insert"();



CREATE OR REPLACE TRIGGER "tr_metadata_pre_update" BEFORE UPDATE ON "scripts"."metadata" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_metadata_pre_update"();



CREATE OR REPLACE TRIGGER "tr_protected_pre_insert" BEFORE INSERT ON "scripts"."protected" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_protected_pre_insert"();



CREATE OR REPLACE TRIGGER "tr_scripts_delete" AFTER DELETE ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_delete"();

ALTER TABLE "scripts"."scripts" DISABLE TRIGGER "tr_scripts_delete";



CREATE OR REPLACE TRIGGER "tr_scripts_post_insert" AFTER INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_post_insert"();



CREATE OR REPLACE TRIGGER "tr_scripts_pre_insert" BEFORE INSERT ON "scripts"."scripts" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_scripts_pre_insert"();



CREATE OR REPLACE TRIGGER "tr_simba_post_upsert" AFTER INSERT OR UPDATE ON "scripts"."simba" FOR EACH ROW EXECUTE FUNCTION "scripts"."tr_simba_post_upsert"();



CREATE OR REPLACE TRIGGER "wh-scripts.simba" AFTER INSERT OR DELETE OR UPDATE ON "scripts"."simba" FOR EACH ROW EXECUTE FUNCTION "public"."webhook"();



CREATE OR REPLACE TRIGGER "wh-scripts.versions" AFTER INSERT OR DELETE OR UPDATE ON "scripts"."versions" FOR EACH ROW EXECUTE FUNCTION "public"."webhook"();



CREATE OR REPLACE TRIGGER "wh-scripts.wasplib" AFTER INSERT OR DELETE OR UPDATE ON "scripts"."wasplib" FOR EACH ROW EXECUTE FUNCTION "public"."webhook"();



CREATE OR REPLACE TRIGGER "tr_products_pre_insert" BEFORE INSERT ON "stripe"."products" FOR EACH ROW EXECUTE FUNCTION "stripe"."tr_products_pre_insert"();



ALTER TABLE ONLY "profiles"."balances"
    ADD CONSTRAINT "balances_id_fkey" FOREIGN KEY ("id") REFERENCES "profiles"."scripters"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "profiles"."free_access"
    ADD CONSTRAINT "free_access_product_fkey" FOREIGN KEY ("product") REFERENCES "stripe"."products"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "profiles"."free_access"
    ADD CONSTRAINT "free_access_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "profiles"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "profiles"."scripters"
    ADD CONSTRAINT "scripters_id_fkey" FOREIGN KEY ("id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "profiles"."subscriptions"
    ADD CONSTRAINT "subscriptions_product_fkey" FOREIGN KEY ("product") REFERENCES "stripe"."products"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "profiles"."subscriptions"
    ADD CONSTRAINT "subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."bundles"
    ADD CONSTRAINT "bundles_author_fkey" FOREIGN KEY ("author") REFERENCES "profiles"."scripters"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."metadata"
    ADD CONSTRAINT "metadata_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_author_fkey" FOREIGN KEY ("author") REFERENCES "profiles"."scripters"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."protected"
    ADD CONSTRAINT "protected_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "scripts"."versions"
    ADD CONSTRAINT "versions_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."limits_custom"
    ADD CONSTRAINT "custom_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."values_custom"
    ADD CONSTRAINT "custom_values_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."online"
    ADD CONSTRAINT "online_script_id_fkey" FOREIGN KEY ("script_id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."online"
    ADD CONSTRAINT "online_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."values"
    ADD CONSTRAINT "simba_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."stats"
    ADD CONSTRAINT "stats_id_fkey1" FOREIGN KEY ("id") REFERENCES "profiles"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."limits"
    ADD CONSTRAINT "stats_limits_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."website"
    ADD CONSTRAINT "website_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stats"."website_monthly"
    ADD CONSTRAINT "website_monthly_id_fkey" FOREIGN KEY ("id") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stripe"."prices"
    ADD CONSTRAINT "prices_product_fkey" FOREIGN KEY ("product") REFERENCES "stripe"."products"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_bundle_fkey" FOREIGN KEY ("bundle") REFERENCES "scripts"."bundles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_script_fkey" FOREIGN KEY ("script") REFERENCES "scripts"."scripts"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_stripe_fkey" FOREIGN KEY ("stripe") REFERENCES "profiles"."scripters"("stripe") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "stripe"."products"
    ADD CONSTRAINT "products_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "profiles"."scripters"("id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "INSERT for ADMINISTRATOR" ON "info"."privacy_policy" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "INSERT for ADMINISTRATOR" ON "info"."scripter_tos" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "INSERT for ADMINISTRATOR" ON "info"."user_tos" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "SELECT for EVERYONE" ON "info"."privacy_policy" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "info"."scripter_tos" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "info"."user_tos" FOR SELECT USING (true);



ALTER TABLE "info"."privacy_policy" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "info"."scripter_tos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "info"."user_tos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "DELETE for ADMINISTRATOR" ON "profiles"."scripters" FOR DELETE TO "authenticated" USING ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "INSERT for ADMINISTRATOR" ON "profiles"."balances" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "INSERT for ADMINISTRATOR" ON "profiles"."scripters" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."is_role"('administrator'::"profiles"."roles"));



CREATE POLICY "INSERT for SERVICE_USER" ON "profiles"."free_access" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "INSERT for SERVICE_USER" ON "profiles"."subscriptions" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "SELECT for EVERYONE" ON "profiles"."profiles" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "profiles"."scripters" FOR SELECT USING (true);



CREATE POLICY "SELECT for OWNER" ON "profiles"."balances" FOR SELECT TO "authenticated" USING ((("id" = "profiles"."uid"()) OR "profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles")));



CREATE POLICY "SELECT for OWNER" ON "profiles"."free_access" FOR SELECT TO "authenticated" USING (("profiles"."can_view_subscription"("profiles"."uid"(), "user_id", "product") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "SELECT for OWNER" ON "profiles"."subscriptions" FOR SELECT TO "authenticated" USING (("profiles"."can_view_subscription"("profiles"."uid"(), "user_id", "product") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "UPDATE for OWNER" ON "profiles"."scripters" FOR UPDATE TO "authenticated" USING ((("id" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))) WITH CHECK ((("id" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "UPDATE for SERVICE_USER" ON "profiles"."balances" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "UPDATE for SERVICE_USER" ON "profiles"."free_access" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "UPDATE for SERVICE_USER" ON "profiles"."scripters" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "UPDATE for SERVICE_USER" ON "profiles"."subscriptions" FOR UPDATE TO "service_role" USING (true);



ALTER TABLE "profiles"."balances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "profiles"."free_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "profiles"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "profiles"."scripters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "profiles"."subscriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "INSERT for OWNER" ON "scripts"."versions" FOR INSERT TO "authenticated" WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."bundles" FOR INSERT TO "authenticated" WITH CHECK (((("author" = "profiles"."uid"()) AND "profiles"."is_role"("profiles"."uid"(), 'scripter'::"profiles"."roles")) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."metadata" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."protected" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SCRIPTER" ON "scripts"."scripts" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SERVICE_USER" ON "scripts"."plugins" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "INSERT for SERVICE_USER" ON "scripts"."wasplib" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."metadata" FOR SELECT USING ("profiles"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."protected" FOR SELECT USING ("profiles"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."scripts" FOR SELECT USING ("profiles"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for ALLOWED" ON "scripts"."versions" FOR SELECT USING ("profiles"."can_view"("profiles"."uid"(), "id"));



CREATE POLICY "SELECT for EVERYONE" ON "scripts"."bundles" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "scripts"."plugins" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "scripts"."simba" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "scripts"."wasplib" FOR SELECT USING (true);



CREATE POLICY "SELECT for SERVICE_USER" ON "scripts"."simba" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."bundles" FOR UPDATE TO "authenticated" USING ((("author" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))) WITH CHECK ((("author" = "profiles"."uid"()) OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "UPDATE for AUTHOR" ON "scripts"."metadata" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for OWNER" ON "scripts"."scripts" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for OWNER" ON "scripts"."versions" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for SERVICE_USER" ON "scripts"."protected" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "scripts"."bundles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."metadata" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."plugins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."protected" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."scripts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."simba" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "scripts"."wasplib" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "INSERT for SCRIPTER" ON "stats"."limits" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SCRIPTER" ON "stats"."limits_custom" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SCRIPTER" ON "stats"."values" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SCRIPTER" ON "stats"."values_custom" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SCRIPTER" ON "stats"."website" FOR INSERT TO "authenticated" WITH CHECK ("profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles"));



CREATE POLICY "INSERT for SERVICE_USER" ON "stats"."online" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "INSERT for SERVICE_USER" ON "stats"."stats" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "SELECT for EVERYONE" ON "stats"."limits" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "stats"."limits_custom" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "stats"."stats" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "stats"."values" FOR SELECT USING (true);



CREATE POLICY "SELECT for EVERYONE" ON "stats"."values_custom" FOR SELECT USING (true);



CREATE POLICY "SELECT for OWNER" ON "stats"."online" FOR SELECT TO "authenticated" USING (("scripts"."is_author"("profiles"."uid"(), "script_id") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")));



CREATE POLICY "SELECT for OWNER" ON "stats"."website" FOR SELECT USING (("scripts"."is_author"("profiles"."uid"(), "id") OR "profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles")));



CREATE POLICY "SELECT for OWNER" ON "stats"."website_monthly" FOR SELECT TO "authenticated" USING (("profiles"."is_role"("profiles"."uid"(), 'administrator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for OWNER" ON "stats"."limits" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for OWNER" ON "stats"."limits_custom" FOR UPDATE TO "authenticated" USING (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id"))) WITH CHECK (("profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles") OR "scripts"."is_author"("profiles"."uid"(), "id")));



CREATE POLICY "UPDATE for SERVICE_USER" ON "stats"."online" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "UPDATE for SERVICE_USER" ON "stats"."stats" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "UPDATE for SERVICE_USER" ON "stats"."values" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "UPDATE for SERVICE_USER" ON "stats"."values_custom" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "stats"."limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."limits_custom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."online" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."stats" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."values" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."values_custom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."website" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stats"."website_monthly" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "SELECT for EVERYONE" ON "stripe"."prices" FOR SELECT USING (("active" OR "profiles"."min_role"("profiles"."uid"(), 'scripter'::"profiles"."roles")));



CREATE POLICY "SELECT for EVERYONE" ON "stripe"."products" FOR SELECT USING ("active");



ALTER TABLE "stripe"."prices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "stripe"."products" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "info" TO "anon";
GRANT USAGE ON SCHEMA "info" TO "authenticated";
GRANT USAGE ON SCHEMA "info" TO "service_role";



GRANT USAGE ON SCHEMA "profiles" TO "anon";
GRANT USAGE ON SCHEMA "profiles" TO "authenticated";
GRANT USAGE ON SCHEMA "profiles" TO "service_role";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "scripts" TO "anon";
GRANT USAGE ON SCHEMA "scripts" TO "authenticated";
GRANT USAGE ON SCHEMA "scripts" TO "service_role";



GRANT USAGE ON SCHEMA "stats" TO "anon";
GRANT USAGE ON SCHEMA "stats" TO "authenticated";
GRANT USAGE ON SCHEMA "stats" TO "service_role";



GRANT USAGE ON SCHEMA "stripe" TO "anon";
GRANT USAGE ON SCHEMA "stripe" TO "authenticated";
GRANT USAGE ON SCHEMA "stripe" TO "service_role";



REVOKE ALL ON FUNCTION "profiles"."add_balance"("account" "text", "amount" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "profiles"."add_balance"("account" "text", "amount" bigint) TO "service_role";



GRANT ALL ON FUNCTION "profiles"."can_access"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "profiles"."can_access"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."can_access"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "profiles"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."can_access"("accesser_id" "uuid", "script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."can_view_subscription"("accesser" "uuid", "owner" "uuid", "product" "text") TO "anon";
GRANT ALL ON FUNCTION "profiles"."can_view_subscription"("accesser" "uuid", "owner" "uuid", "product" "text") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."can_view_subscription"("accesser" "uuid", "owner" "uuid", "product" "text") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."get_avatar"("userid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "profiles"."get_avatar"("userid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."get_avatar"("userid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."get_discord_id"("userid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "profiles"."get_discord_id"("userid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."get_discord_id"("userid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."get_username"("userid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "profiles"."get_username"("userid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."get_username"("userid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "profiles"."tr_profiles_post_update"() TO "anon";
GRANT ALL ON FUNCTION "profiles"."tr_profiles_post_update"() TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."tr_profiles_post_update"() TO "service_role";



GRANT ALL ON FUNCTION "profiles"."tr_profiles_pre_insert"() TO "anon";
GRANT ALL ON FUNCTION "profiles"."tr_profiles_pre_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."tr_profiles_pre_insert"() TO "service_role";



GRANT ALL ON FUNCTION "profiles"."tr_scritpers_pre_insert"() TO "anon";
GRANT ALL ON FUNCTION "profiles"."tr_scritpers_pre_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."tr_scritpers_pre_insert"() TO "service_role";



GRANT ALL ON FUNCTION "profiles"."uid"() TO "anon";
GRANT ALL ON FUNCTION "profiles"."uid"() TO "authenticated";
GRANT ALL ON FUNCTION "profiles"."uid"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_simba_hash"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_simba_hash"() TO "postgres";
GRANT ALL ON FUNCTION "public"."get_simba_hash"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_wasplib_hash"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_wasplib_hash"() TO "postgres";
GRANT ALL ON FUNCTION "public"."get_wasplib_hash"() TO "service_role";



GRANT ALL ON FUNCTION "public"."webhook"() TO "postgres";
GRANT ALL ON FUNCTION "public"."webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."webhook"() TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."cron_update_simba_versions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "scripts"."cron_update_simba_versions"() TO "service_role";
GRANT ALL ON FUNCTION "scripts"."cron_update_simba_versions"() TO "postgres";



GRANT ALL ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."get_revision"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_author"("user_id" "uuid", "script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_premium"("script_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon";
GRANT ALL ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."is_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon";
GRANT ALL ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."max_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "service_role";



GRANT ALL ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "anon";
GRANT ALL ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."min_stage"("script_id" "uuid", "target_stage" "scripts"."stage") TO "service_role";



REVOKE ALL ON FUNCTION "scripts"."tr_bundles_check_scripts"() FROM PUBLIC;



GRANT ALL ON FUNCTION "scripts"."tr_bundles_pre_insert"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_bundles_pre_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_bundles_pre_insert"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."tr_metadata_pre_update"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_metadata_pre_update"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_metadata_pre_update"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."tr_protected_pre_insert"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_protected_pre_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_protected_pre_insert"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."tr_scripts_delete"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_scripts_delete"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_scripts_delete"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."tr_scripts_post_insert"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_scripts_post_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_scripts_post_insert"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."tr_scripts_pre_insert"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_scripts_pre_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_scripts_pre_insert"() TO "service_role";



GRANT ALL ON FUNCTION "scripts"."tr_storage_objects_insert"() TO "anon";
GRANT ALL ON FUNCTION "scripts"."tr_storage_objects_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "scripts"."tr_storage_objects_insert"() TO "service_role";



GRANT ALL ON FUNCTION "stats"."get_level"("experience" bigint) TO "anon";
GRANT ALL ON FUNCTION "stats"."get_level"("experience" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "stats"."get_level"("experience" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "stats"."increment_script_stats"("script_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "stats"."increment_user_stats"("user_id" "uuid", "add_experience" numeric, "add_gold" numeric, "add_runtime" numeric) TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "info"."privacy_policy" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "info"."privacy_policy" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "info"."privacy_policy" TO "service_role";



GRANT ALL ON SEQUENCE "info"."privacy_policy_version_seq" TO "anon";
GRANT ALL ON SEQUENCE "info"."privacy_policy_version_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "info"."privacy_policy_version_seq" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "info"."scripter_tos" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "info"."scripter_tos" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "info"."scripter_tos" TO "service_role";



GRANT ALL ON SEQUENCE "info"."scripter_tos_version_seq" TO "anon";
GRANT ALL ON SEQUENCE "info"."scripter_tos_version_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "info"."scripter_tos_version_seq" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "info"."user_tos" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "info"."user_tos" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "info"."user_tos" TO "service_role";



GRANT ALL ON SEQUENCE "info"."user_tos_version_seq" TO "anon";
GRANT ALL ON SEQUENCE "info"."user_tos_version_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "info"."user_tos_version_seq" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."balances" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."balances" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "profiles"."balances" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."free_access" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."free_access" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "profiles"."free_access" TO "service_role";



GRANT SELECT,DELETE,UPDATE ON TABLE "profiles"."profiles" TO "anon";
GRANT SELECT,DELETE,UPDATE ON TABLE "profiles"."profiles" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "profiles"."profiles" TO "service_role";



GRANT SELECT,INSERT,DELETE ON TABLE "profiles"."scripters" TO "anon";
GRANT SELECT,INSERT,DELETE ON TABLE "profiles"."scripters" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "profiles"."scripters" TO "service_role";



GRANT UPDATE("realname") ON TABLE "profiles"."scripters" TO "authenticated";



GRANT UPDATE("github") ON TABLE "profiles"."scripters" TO "authenticated";



GRANT UPDATE("paypal") ON TABLE "profiles"."scripters" TO "authenticated";



GRANT UPDATE("description") ON TABLE "profiles"."scripters" TO "authenticated";



GRANT UPDATE("content") ON TABLE "profiles"."scripters" TO "authenticated";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."random_scripters" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."random_scripters" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "profiles"."random_scripters" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."subscriptions" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "profiles"."subscriptions" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "profiles"."subscriptions" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."metadata" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."metadata" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."metadata" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."protected" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."protected" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."protected" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."author_scripts" TO "service_role";



GRANT SELECT,INSERT,DELETE ON TABLE "scripts"."bundles" TO "anon";
GRANT SELECT,INSERT,DELETE ON TABLE "scripts"."bundles" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."bundles" TO "service_role";



GRANT UPDATE("name") ON TABLE "scripts"."bundles" TO "authenticated";



GRANT UPDATE("scripts") ON TABLE "scripts"."bundles" TO "authenticated";



GRANT SELECT,INSERT,DELETE ON TABLE "scripts"."scripts" TO "anon";
GRANT SELECT,INSERT,DELETE ON TABLE "scripts"."scripts" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."scripts" TO "service_role";



GRANT UPDATE("title") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT UPDATE("description") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT UPDATE("content") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT UPDATE("published") ON TABLE "scripts"."scripts" TO "authenticated";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."featured" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."featured" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."featured" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."plugins" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."plugins" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."plugins" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."simba" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."simba" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."simba" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."versions" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."versions" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."versions" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."wasplib" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "scripts"."wasplib" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "scripts"."wasplib" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."limits" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."limits" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."limits" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."limits_custom" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."limits_custom" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."limits_custom" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."online" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."online" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."online" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."stats" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."stats" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."stats" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."totals" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."totals" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."totals" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."values" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."values" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."values" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."values_custom" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."values_custom" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."values_custom" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."website" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."website" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."website" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."website_monthly" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stats"."website_monthly" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stats"."website_monthly" TO "service_role";



GRANT SELECT ON TABLE "stripe"."prices" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stripe"."prices" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stripe"."prices" TO "service_role";



GRANT SELECT ON TABLE "stripe"."products" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "stripe"."products" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "stripe"."products" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "info" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "info" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "info" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "info" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "info" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "profiles" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "profiles" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "profiles" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "profiles" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "profiles" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "scripts" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "scripts" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "scripts" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "scripts" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "scripts" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stats" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stats" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stats" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stats" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stats" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stripe" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stripe" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stripe" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "stripe" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";




