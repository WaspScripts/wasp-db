-- RLS policies for Supabase's storage schema (extracted from a full storage dump).

CREATE POLICY "DELETE for supabase_admin vuzwg8_0" ON "storage"."objects" FOR DELETE USING ((("bucket_id" = 'scripts'::"text") AND (CURRENT_USER = 'supabase_admin'::"name")));

CREATE POLICY "INSER for SERVICE_USER zhrzhi_0" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'assets1400'::"text"));

CREATE POLICY "INSERT for OWNER vuzwg8_0" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'scripts'::"text") AND ("scripts"."is_author"("profiles"."uid"(), (("storage"."foldername"("name"))[1])::"uuid") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "INSERT for SCRIPTER 1xd00_0" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ("scripts"."is_author"("profiles"."uid"(), (("storage"."foldername"("name"))[2])::"uuid") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "INSERT for SERVICE USER 1r5xns0_0" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'plugins'::"text"));

CREATE POLICY "INSERT for SERVICE USER 1t5p3q_0" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'simba'::"text"));

CREATE POLICY "INSERT for SERVICE_USER 1bqp9qb_0" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "INSERT for SERVICE_USER im1wu6_1" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'wasplib'::"text"));

CREATE POLICY "INSERT for SERVICE_USER k1j406_0" ON "storage"."objects" FOR INSERT TO "service_role" WITH CHECK (("bucket_id" = 'wasp-launcher'::"text"));

CREATE POLICY "SELECT for ALLOWED vuzwg8_0" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'scripts'::"text") AND "profiles"."can_access"("profiles"."uid"(), (("storage"."foldername"("name"))[1])::"uuid")));

CREATE POLICY "SELECT for EVERYONE 1bqp9qb_0" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'assets'::"text"));

CREATE POLICY "SELECT for EVERYONE 1r5xns0_0" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'plugins'::"text"));

CREATE POLICY "SELECT for EVERYONE 1t5p3q_0" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'simba'::"text"));

CREATE POLICY "SELECT for EVERYONE 1xd00_0" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'imgs'::"text"));

CREATE POLICY "SELECT for EVERYONE im1wu6_0" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'wasplib'::"text"));

CREATE POLICY "SELECT for EVERYONE k1j406_0" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'wasp-launcher'::"text"));

CREATE POLICY "UPDATE  for SERVICE_USER 1bqp9qb_1" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'assets'::"text")) WITH CHECK (("bucket_id" = 'assets'::"text"));

CREATE POLICY "UPDATE for OWNER 1xd00_0" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'imgs'::"text") AND ("scripts"."is_author"("profiles"."uid"(), (("storage"."foldername"("name"))[2])::"uuid") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles")))) WITH CHECK ((("bucket_id" = 'imgs'::"text") AND ("scripts"."is_author"("profiles"."uid"(), (("storage"."foldername"("name"))[2])::"uuid") OR "profiles"."min_role"("profiles"."uid"(), 'moderator'::"profiles"."roles"))));

CREATE POLICY "UPDATE for SERVICE USER 1r5xns0_1" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'plugins'::"text")) WITH CHECK (("bucket_id" = 'plugins'::"text"));

CREATE POLICY "UPDATE for SERVICE USER 1t5p3q_1" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'simba'::"text")) WITH CHECK (("bucket_id" = 'simba'::"text"));

CREATE POLICY "UPDATE for SERVICE USER k1j406_0" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'wasp-launcher'::"text")) WITH CHECK (("bucket_id" = 'wasp-launcher'::"text"));

CREATE POLICY "UPDATE for SERVICE_USER im1wu6_0" ON "storage"."objects" FOR UPDATE TO "service_role" USING (("bucket_id" = 'wasplib'::"text")) WITH CHECK (("bucket_id" = 'wasplib'::"text"));

ALTER TABLE "storage"."buckets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."buckets_analytics" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."buckets_vectors" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."iceberg_namespaces" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."iceberg_tables" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."migrations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."objects" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."s3_multipart_uploads" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."s3_multipart_uploads_parts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "storage"."vector_indexes" ENABLE ROW LEVEL SECURITY;

