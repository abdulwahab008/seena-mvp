CREATE TABLE "submissions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"org_id" uuid NOT NULL,
	"exam_id" uuid NOT NULL,
	"created_by" uuid NOT NULL,
	"student_name" text,
	"storage_key" text NOT NULL,
	"source_url" text,
	"status" text DEFAULT 'pending' NOT NULL,
	"total_marks" integer,
	"obtained_marks" numeric(6, 2),
	"result" jsonb,
	"ocr_method" text,
	"failure_reason" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"graded_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "submissions" ADD CONSTRAINT "submissions_org_id_organizations_id_fk" FOREIGN KEY ("org_id") REFERENCES "public"."organizations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "submissions" ADD CONSTRAINT "submissions_exam_id_exams_id_fk" FOREIGN KEY ("exam_id") REFERENCES "public"."exams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "submissions" ADD CONSTRAINT "submissions_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "submissions_org_idx" ON "submissions" USING btree ("org_id");--> statement-breakpoint
CREATE INDEX "submissions_exam_idx" ON "submissions" USING btree ("exam_id");