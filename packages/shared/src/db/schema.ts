import {
  pgTable,
  text,
  timestamp,
  uuid,
  integer,
  boolean,
  jsonb,
  numeric,
  pgEnum,
  index,
  uniqueIndex,
} from 'drizzle-orm/pg-core';
import { relations, sql } from 'drizzle-orm';

export const roleEnum = pgEnum('role', ['admin', 'teacher']);
export const bookStatusEnum = pgEnum('book_status', ['uploading', 'processing', 'ready', 'failed']);
export const examStatusEnum = pgEnum('exam_status', ['draft', 'finalized', 'archived']);
export const exportFormatEnum = pgEnum('export_format', ['pdf', 'docx']);

export const organizations = pgTable('organizations', {
  id: uuid('id').primaryKey().defaultRandom(),
  clerkOrgId: text('clerk_org_id').unique(),
  name: text('name').notNull(),
  logoUrl: text('logo_url'),
  plan: text('plan').notNull().default('free'),
  // Cost guard: max exams an org may generate per calendar month.
  monthlyExamLimit: integer('monthly_exam_limit').notNull().default(100),
  // Hard USD backstop across all LLM calls per calendar month (catches regen spam).
  monthlyCostCapUsd: numeric('monthly_cost_cap_usd', { precision: 10, scale: 2 })
    .notNull()
    .default(sql`'15'`),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
});

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  clerkId: text('clerk_id').notNull().unique(),
  email: text('email').notNull(),
  name: text('name'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
});

export const memberships = pgTable(
  'memberships',
  {
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    role: roleEnum('role').notNull().default('teacher'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    pk: uniqueIndex('memberships_user_org_uniq').on(t.userId, t.orgId),
  }),
);

export const books = pgTable(
  'books',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    uploadedBy: uuid('uploaded_by')
      .notNull()
      .references(() => users.id, { onDelete: 'set null' as never }),
    title: text('title').notNull(),
    grade: integer('grade'),
    subject: text('subject').notNull(),
    board: text('board').notNull(),
    language: text('language').notNull().default('en'),
    sourceUrl: text('source_url').notNull(),
    storageKey: text('storage_key').notNull(),
    status: bookStatusEnum('status').notNull().default('uploading'),
    pageCount: integer('page_count'),
    needsOcr: boolean('needs_ocr').notNull().default(false),
    chunkCount: integer('chunk_count').notNull().default(0),
    failureReason: text('failure_reason'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    processedAt: timestamp('processed_at', { withTimezone: true }),
  },
  (t) => ({
    orgIdx: index('books_org_idx').on(t.orgId),
    statusIdx: index('books_status_idx').on(t.status),
  }),
);

export const chunksMeta = pgTable(
  'chunks_meta',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    bookId: uuid('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    chunkingId: uuid('chunking_id'),
    page: integer('page').notNull(),
    chapterLabel: text('chapter_label'),
    exerciseLabel: text('exercise_label'),
    tokenCount: integer('token_count').notNull(),
    text: text('text').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    bookIdx: index('chunks_book_idx').on(t.bookId),
    bookPageIdx: index('chunks_book_page_idx').on(t.bookId, t.page),
    chunkingIdx: index('chunks_chunking_idx').on(t.chunkingId),
  }),
);

export const bookPages = pgTable(
  'book_pages',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    bookId: uuid('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    pageNumber: integer('page_number').notNull(),
    text: text('text').notNull(),
    ocrMethod: text('ocr_method').notNull(),
    ocrModel: text('ocr_model'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    bookPageUniq: uniqueIndex('book_pages_book_page_uniq').on(t.bookId, t.pageNumber),
    bookIdx: index('book_pages_book_idx').on(t.bookId),
  }),
);

export const chunkings = pgTable(
  'chunkings',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    bookId: uuid('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    strategy: text('strategy').notNull().default('page-aware-600-80'),
    strategyConfig: jsonb('strategy_config').notNull().default({}),
    embeddingModel: text('embedding_model').notNull(),
    embeddingDimensions: integer('embedding_dimensions').notNull(),
    namespace: text('namespace').notNull(),
    chunkCount: integer('chunk_count').notNull().default(0),
    status: text('status').notNull().default('pending'),
    isDefault: boolean('is_default').notNull().default(false),
    failureReason: text('failure_reason'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    readyAt: timestamp('ready_at', { withTimezone: true }),
  },
  (t) => ({
    bookIdx: index('chunkings_book_idx').on(t.bookId),
    bookDefaultIdx: index('chunkings_book_default_idx').on(t.bookId, t.isDefault),
  }),
);

export const bookPageRelations = relations(bookPages, ({ one }) => ({
  book: one(books, { fields: [bookPages.bookId], references: [books.id] }),
}));

export const chunkingRelations = relations(chunkings, ({ one, many }) => ({
  book: one(books, { fields: [chunkings.bookId], references: [books.id] }),
  chunks: many(chunksMeta),
}));

export const exams = pgTable(
  'exams',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    createdBy: uuid('created_by')
      .notNull()
      .references(() => users.id, { onDelete: 'set null' as never }),
    bookId: uuid('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    title: text('title').notNull(),
    patternId: text('pattern_id').notNull(),
    totalMarks: integer('total_marks').notNull(),
    chapter: text('chapter'),
    exercise: text('exercise'),
    difficulty: text('difficulty').notNull().default('mixed'),
    language: text('language').notNull().default('en'),
    status: examStatusEnum('status').notNull().default('draft'),
    payload: jsonb('payload').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    orgIdx: index('exams_org_idx').on(t.orgId),
    bookIdx: index('exams_book_idx').on(t.bookId),
  }),
);

export const submissions = pgTable(
  'submissions',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    examId: uuid('exam_id')
      .notNull()
      .references(() => exams.id, { onDelete: 'cascade' }),
    createdBy: uuid('created_by')
      .notNull()
      .references(() => users.id, { onDelete: 'set null' as never }),
    studentName: text('student_name'),
    storageKey: text('storage_key').notNull(),
    sourceUrl: text('source_url'),
    status: text('status').notNull().default('pending'), // pending | processing | graded | failed
    totalMarks: integer('total_marks'),
    obtainedMarks: numeric('obtained_marks', { precision: 6, scale: 2 }),
    result: jsonb('result'), // AI GradedResult shape from @seena/shared (immutable original)
    // Human-in-the-loop: teacher's corrected GradedResult. Null until reviewed.
    // `result` is kept as the AI original so AI-vs-human marks can be compared (calibration).
    reviewedResult: jsonb('reviewed_result'),
    reviewedBy: uuid('reviewed_by').references(() => users.id, { onDelete: 'set null' as never }),
    reviewedAt: timestamp('reviewed_at', { withTimezone: true }),
    ocrMethod: text('ocr_method'),
    failureReason: text('failure_reason'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    gradedAt: timestamp('graded_at', { withTimezone: true }),
  },
  (t) => ({
    orgIdx: index('submissions_org_idx').on(t.orgId),
    examIdx: index('submissions_exam_idx').on(t.examId),
  }),
);

export const submissionRelations = relations(submissions, ({ one }) => ({
  org: one(organizations, { fields: [submissions.orgId], references: [organizations.id] }),
  exam: one(exams, { fields: [submissions.examId], references: [exams.id] }),
  grader: one(users, { fields: [submissions.createdBy], references: [users.id] }),
}));

export const examExports = pgTable('exam_exports', {
  id: uuid('id').primaryKey().defaultRandom(),
  examId: uuid('exam_id')
    .notNull()
    .references(() => exams.id, { onDelete: 'cascade' }),
  format: exportFormatEnum('format').notNull(),
  url: text('url').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
});

export const customPatterns = pgTable(
  'custom_patterns',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    createdBy: uuid('created_by')
      .notNull()
      .references(() => users.id, { onDelete: 'set null' as never }),
    name: text('name').notNull(),
    format: text('format').notNull().default('paper'),
    board: text('board').notNull().default('OTHER'),
    grade: integer('grade'),
    subject: text('subject'),
    totalMarks: integer('total_marks').notNull(),
    sections: jsonb('sections').notNull(),
    notes: text('notes'),
    isDefault: boolean('is_default').notNull().default(false),
    archived: boolean('archived').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    orgIdx: index('custom_patterns_org_idx').on(t.orgId),
    formatIdx: index('custom_patterns_format_idx').on(t.orgId, t.format),
  }),
);

export const customPatternRelations = relations(customPatterns, ({ one }) => ({
  org: one(organizations, { fields: [customPatterns.orgId], references: [organizations.id] }),
  creator: one(users, { fields: [customPatterns.createdBy], references: [users.id] }),
}));

export const generations = pgTable(
  'generations',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organizations.id, { onDelete: 'cascade' }),
    userId: uuid('user_id').references(() => users.id, { onDelete: 'set null' as never }),
    examId: uuid('exam_id').references(() => exams.id, { onDelete: 'set null' as never }),
    kind: text('kind').notNull(),
    model: text('model').notNull(),
    inputTokens: integer('input_tokens').notNull().default(0),
    outputTokens: integer('output_tokens').notNull().default(0),
    latencyMs: integer('latency_ms').notNull().default(0),
    costUsd: numeric('cost_usd', { precision: 10, scale: 6 }).notNull().default(sql`'0'`),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => ({
    orgIdx: index('generations_org_idx').on(t.orgId),
  }),
);

export const orgRelations = relations(organizations, ({ many }) => ({
  memberships: many(memberships),
  books: many(books),
  exams: many(exams),
  generations: many(generations),
}));

export const userRelations = relations(users, ({ many }) => ({
  memberships: many(memberships),
}));

export const membershipRelations = relations(memberships, ({ one }) => ({
  user: one(users, { fields: [memberships.userId], references: [users.id] }),
  org: one(organizations, { fields: [memberships.orgId], references: [organizations.id] }),
}));

export const bookRelations = relations(books, ({ one, many }) => ({
  org: one(organizations, { fields: [books.orgId], references: [organizations.id] }),
  uploader: one(users, { fields: [books.uploadedBy], references: [users.id] }),
  chunks: many(chunksMeta),
  exams: many(exams),
}));

export const chunkRelations = relations(chunksMeta, ({ one }) => ({
  book: one(books, { fields: [chunksMeta.bookId], references: [books.id] }),
}));

export const examRelations = relations(exams, ({ one, many }) => ({
  org: one(organizations, { fields: [exams.orgId], references: [organizations.id] }),
  creator: one(users, { fields: [exams.createdBy], references: [users.id] }),
  book: one(books, { fields: [exams.bookId], references: [books.id] }),
  exports: many(examExports),
}));

export const examExportRelations = relations(examExports, ({ one }) => ({
  exam: one(exams, { fields: [examExports.examId], references: [exams.id] }),
}));
