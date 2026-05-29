CREATE TABLE "custom_patterns" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"org_id" uuid NOT NULL,
	"created_by" uuid NOT NULL,
	"name" text NOT NULL,
	"format" text DEFAULT 'paper' NOT NULL,
	"board" text DEFAULT 'OTHER' NOT NULL,
	"grade" integer,
	"subject" text,
	"total_marks" integer NOT NULL,
	"sections" jsonb NOT NULL,
	"notes" text,
	"is_default" boolean DEFAULT false NOT NULL,
	"archived" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "custom_patterns" ADD CONSTRAINT "custom_patterns_org_id_organizations_id_fk" FOREIGN KEY ("org_id") REFERENCES "public"."organizations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "custom_patterns" ADD CONSTRAINT "custom_patterns_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "custom_patterns_org_idx" ON "custom_patterns" USING btree ("org_id");--> statement-breakpoint
CREATE INDEX "custom_patterns_format_idx" ON "custom_patterns" USING btree ("org_id","format");