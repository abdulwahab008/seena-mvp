CREATE TABLE "book_pages" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"book_id" uuid NOT NULL,
	"org_id" uuid NOT NULL,
	"page_number" integer NOT NULL,
	"text" text NOT NULL,
	"ocr_method" text NOT NULL,
	"ocr_model" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "chunkings" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"book_id" uuid NOT NULL,
	"org_id" uuid NOT NULL,
	"strategy" text DEFAULT 'page-aware-600-80' NOT NULL,
	"strategy_config" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"embedding_model" text NOT NULL,
	"embedding_dimensions" integer NOT NULL,
	"namespace" text NOT NULL,
	"chunk_count" integer DEFAULT 0 NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"is_default" boolean DEFAULT false NOT NULL,
	"failure_reason" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"ready_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "chunks_meta" ADD COLUMN "chunking_id" uuid;--> statement-breakpoint
ALTER TABLE "book_pages" ADD CONSTRAINT "book_pages_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "book_pages" ADD CONSTRAINT "book_pages_org_id_organizations_id_fk" FOREIGN KEY ("org_id") REFERENCES "public"."organizations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chunkings" ADD CONSTRAINT "chunkings_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chunkings" ADD CONSTRAINT "chunkings_org_id_organizations_id_fk" FOREIGN KEY ("org_id") REFERENCES "public"."organizations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "book_pages_book_page_uniq" ON "book_pages" USING btree ("book_id","page_number");--> statement-breakpoint
CREATE INDEX "book_pages_book_idx" ON "book_pages" USING btree ("book_id");--> statement-breakpoint
CREATE INDEX "chunkings_book_idx" ON "chunkings" USING btree ("book_id");--> statement-breakpoint
CREATE INDEX "chunkings_book_default_idx" ON "chunkings" USING btree ("book_id","is_default");--> statement-breakpoint
CREATE INDEX "chunks_chunking_idx" ON "chunks_meta" USING btree ("chunking_id");