ALTER TABLE "submissions" ADD COLUMN "reviewed_result" jsonb;--> statement-breakpoint
ALTER TABLE "submissions" ADD COLUMN "reviewed_by" uuid;--> statement-breakpoint
ALTER TABLE "submissions" ADD COLUMN "reviewed_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "submissions" ADD CONSTRAINT "submissions_reviewed_by_users_id_fk" FOREIGN KEY ("reviewed_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;