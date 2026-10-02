# Seena Exams → Seena Academy — Feature Gap Analysis

_Four independent product/platform reviews of what is missing, produced against a verified map of what the code actually does today. Nothing already built is listed as a gap._

---


---

# Part 1 — Gaps in Seena Exams as an assessment product

ROOT = `/Users/apple/Projects/Seena Exams/.claude/worktrees/school-mgmt-audit-requirements-05b88d` (paths below are `$ROOT/…`).

Scope check: I excluded things already built — answer key page, N shuffled anti-leak versions, human-in-the-loop grading review, cognitive/ToS targets, custom pattern CRUD, question-bank storage, Urdu font in the PDF, org export/delete, retention purge.

# A. The paper you actually print

**1. No student copy vs teacher copy — the answer key is welded to every paper.** `ExamDocument` unconditionally emits `questionPage` + `answerKeyPage` for every version (`$ROOT/apps/web/lib/pdf/exam-pdf.tsx`), and the export body only accepts `{format, versions}` (`$ROOT/apps/web/app/api/exams/[id]/export/route.ts`). A teacher cannot hand the exported PDF to the photocopier — the correct answers print on the back of every student's paper. This alone makes the product unusable for its primary act. **S**

**2. No candidate-identity / paper-metadata header.** The info bar prints Total Marks, Questions, Sections, Date. Every FBISE/Punjab/school paper needs Name, Roll No., Class & Section, Time Allowed, Paper Code, Invigilator/Signature, and "Attempt all questions in the answer book". Papers without a roll-no. line cannot be collected and reconciled. **S**

**3. No print/layout controls.** One hardcoded A4 11pt Times stylesheet: no answer space or ruled lines for short/long answers (junior grades write on the question paper), no MCQ response strip / OMR sheet, no section-per-page breaks, no font-size or margin control, no booklet imposition. Schools print thousands of pages and the format is fixed by the exam controller, not by us. **M**

**4. No editable export.** `export_format` enum contains `docx` but only `renderExamPdf` exists. In practice the coordinator retypes the paper in Word/InPage to fix one question — at which point the tool is bypassed. **M**

# B. Question content fidelity (blocks Maths / Physics / Chemistry entirely)

**5. No math, chemistry or diagram representation anywhere.** `Question.prompt` is a bare `z.string()` (`$ROOT/packages/shared/src/schemas/exam.ts`), rendered as `<Text>` in the PDF; no LaTeX/MathML/SMILES field, no image field on a question, and the ingest pipeline persists page **text** only (`book_pages.text`), so every textbook figure, circuit, graph and structural formula is discarded at OCR time. You cannot produce a Physics numerical with a proper equation, a Chemistry mechanism, or any "refer to the figure" question. This is the largest single blocker for the three subjects teachers most want papers for. **L**

**6. No multi-part questions, no shared stimulus.** `ExamSection.questions` is a flat array; there is no `parts[]`, no stem-plus-(a)(b)(c) with per-part marks, no data table/passage shared across questions. FBISE long questions and every Cambridge structured question are multi-part — the schema literally cannot express a real 8-mark question. **M**

**7. No optionality ("Attempt any 5 of 8").** `PatternSection` is `{type,title,instructions,questionCount,marksPerQuestion}` (`$ROOT/packages/shared/src/patterns/index.ts`) and marks are summed straight. Sections B and C of every FBISE/Punjab paper are choice-based, so both the printed instruction and the total-marks arithmetic are wrong on day one. **S–M**

**8. Single literal answer, no accepted-alternatives.** `answer: z.string()`. No synonym/tolerance list ("water / H₂O / پانی", "9.8 ±0.1"), so both the printed key and the LLM grader mark correct answers wrong. **S**

# C. Marking scheme & moderation

**9. No marking scheme — only a model answer.** `LongQuestion.rubric` exists in the Zod schema and in the tool JSON schema (`$ROOT/apps/web/lib/generation/exam-tool.ts:56`) and is referenced **nowhere else in the repo**: not rendered on the answer-key page, not shown in the UI, not read by `grade-submission`. There are no step marks ("1 for formula, 2 for substitution, 1 for units"). Two teachers marking the same class produce different results, and no HOD can moderate. **M**

**10. No moderation / approval workflow.** `exam_status` is `draft|finalized|archived` but `PATCH /api/exams/[id]` lets any org member set any status with no transition rules, no reviewer identity, no approval timestamp, and **no lock** — a "finalized" paper stays fully editable and re-exportable. Combined with authorization being org-wide (any teacher can edit or delete any other teacher's paper), there is no chain of custody. Pakistani schools require HOD/exam-controller sign-off before a paper goes to print. **M**

**11. No paper-confidentiality controls or audit trail.** Export mints a 24h signed URL, stores it forever in `exam_exports.url` readable by every org member; no watermark, no per-copy serial, no record of who exported/printed which paper when. Paper leakage is the single existential risk in this market and there is currently zero deterrent or forensics. **M**

**12. No revision history on an exam.** `exams.payload` is overwritten in place by every PATCH and every question regeneration. `exam_exports` rows point at PDFs whose source payload has since changed, so nobody can reconstruct which paper was actually printed. (Distinct from the shuffled A/B variants, which do exist.) **M**

# D. Shuffled versions are generated but unmarkable

**13. Version identity is never persisted and the grader always marks against version A.** `shuffleExam` runs at export time only; the seed, the version count and the per-version question order are not stored (`exam_exports` records only `format` + `url`), and `grade-submission` rebuilds the key from the unshuffled `exams.payload`. So the anti-leak feature is a trap: hand out Version B and every auto-graded sheet is wrong. Needs persisted versions + version-aware keys + a way to record which student got which version. **M**

# E. Candidates, sittings, invigilation

**14. No candidate roster / roll numbers — the keystone gap.** The only student data is `submissions.student_name`, free text typed per upload. Two spellings are two students; nothing links a child across papers. Result cards, per-student analytics, re-sits and attendance are all blocked on this one missing table. Note this is *not* the SIS the product deliberately avoids — an exam product still needs a candidate list per sitting. **M**

**15. No exam sitting/session.** An `exam` is a document, not an event: no scheduled date, no duration/time allowed, no class or section it is for, no venue, no seating plan, no invigilator, no absentee marking. You cannot answer "who sat this paper and who was absent", which is the first question after any exam. **L**

**16. No bulk answer-sheet ingestion, no sheet-to-student matching.** `POST /api/exams/[id]/submissions` takes one `storageKey` plus one optional name; the UI uploads one file at a time. A 40-student class is 40 uploads with 40 hand-typed names. No multi-file drop, no scan-a-stack-and-split, no QR/barcode roll-number header on the printed paper to auto-attribute sheets. This is the difference between a demo and post-exam use. **M–L**

**17. No manual marks entry.** `submissions.obtained_marks` is written only by the grading job, or by the review PATCH which hard-requires `status === 'graded'` first (`$ROOT/apps/web/app/api/submissions/[id]/route.ts`). A teacher who marked on paper — the overwhelmingly common case — has no way to record marks in Seena at all. Every downstream result/analytics feature is therefore reachable only through the AI-OCR path. **S**

**18. No re-sit / retake / improvement handling.** No attempt number, no link to a prior attempt, no best-of/latest rule, no "generate a supplementary paper from the same blueprint but different questions". Re-sits are routine (failing 33%, missed exam, improvement paper). **M**

# F. Results

**19. No grade boundaries or grading scale.** `GradedResult` stops at `percentage` (`$ROOT/packages/shared/src/schemas/grading.ts`). No A1/A/B/C/D/E/F table, no FBISE/Punjab boundaries, no 33% pass rule, no Cambridge thresholds, no per-org override. A raw percentage is not something a parent or a school register accepts. **S**

**20. No result card, no tabulation/award sheet, no CSV.** The only PDF renderer in the repo is the exam paper. There is no per-student report, no class marks register (the "award list" every Pakistani school produces and signs), no CSV/Excel export of marks for the school's own records, and no aggregation across papers or subjects. **M**

**21. No class-level result view.** The submissions panel is a flat list of rows. No class average, highest/lowest, pass percentage, distribution, or position-in-class — position is culturally mandatory here and its absence is noticed immediately. **S–M**

# G. Analytics (data is already captured, then thrown away)

**22. No item / topic analysis.** `GradedResult.questions[]` carries per-question awarded vs max, and each `Question` carries `cognitiveLevel`, `difficulty` and `source_pages`, with `exams.chapter` on top. Nothing aggregates any of it: no "class scored 38% on Chapter 5", no per-topic weakness report, no item difficulty or discrimination index, no MCQ distractor analysis, no per-student trend across papers. Highest value-per-effort gap in the product — the schema already holds the inputs. **M**

**23. Dashboard shows no assessment signal.** `/dashboard` renders book count, exam count and quota (`$ROOT/apps/web/app/(dashboard)/dashboard/page.tsx`). Nothing about papers awaiting review, sheets marked vs unmarked, recent results, or failed grading jobs — the teacher's actual work queue is invisible. **S**

# H. Question bank

**24. The bank is write-only — you cannot build a paper from it.** `/api/bank` exposes POST and DELETE only; nothing reads a bank question back into an exam, and `exams.book_id` is NOT NULL so every paper must be LLM-generated from an ingested textbook. A teacher's curated, vetted questions are a dead archive. Needs: compose-from-bank, mixed AI+bank papers, and manual question authoring (today `exam-view` can edit a prompt string only — no add, delete, reorder, no editing options/answers/marks, no adding a section). **M**

**25. No bank curation metadata or dedup.** Bank rows store denormalized subject/board/grade/chapter/type plus the raw payload. No topic tags, no usage count / last-used date, no "don't repeat anything used in the last two papers", no approve/reject state, no edit (create and delete only), no duplicate detection — saving the same MCQ twice yields two rows. Repetition across term papers is an instant credibility hit with parents. **M**

# I. Past papers & pattern authority

**26. No past-paper import.** The only ingest path is `book-process`, which treats every PDF as a textbook to chunk and embed. There is no parser that reads a past paper into `Exam` / `bank_questions` structure, no board past-paper library, no "generate in the style of the last five years". Past papers, not textbooks, are the number-one input Pakistani teachers work from. **L**

**27. Patterns are unverified approximations with thin coverage.** 16 hardcoded `PatternSpec`s, several self-flagged (`notes: 'Approximate FBISE SSC physics pattern. Tune to actual examination scheme.'`), no per-subject schemes, no Cambridge syllabus codes (0625/9701 etc.), no Punjab/NBF chapter map, and Sindh/KP/AJK are in the `Board` enum with zero patterns behind them. A teacher whose board or subject isn't covered gets a generic paper their exam controller rejects. Needs a maintained, versioned, board-sourced pattern library rather than TS literals. **M–L**

# J. Integrity beyond the copyright guard

**28. No cross-paper repetition or copy detection.** `copyright-guard.ts` only compares a freshly generated paper against the chunks retrieved for that one generation. Nothing checks whether the paper repeats questions from the school's own previous papers or from the bank, nothing compares the N shuffled versions against each other, and — what "plagiarism" actually means to a school — nothing compares *student answers* to each other to flag copying in the hall. There is also no UFM/unfair-means incident log. **M**

# K. Accessibility & language

**29. No accessible-paper variants.** One hardcoded stylesheet: no large-print (18pt+) edition, no high-contrast or dyslexia-friendly typeface, no extra-time/scribe/reader annotation on the paper, no tagged-PDF structure. Boards mandate concession papers for special-needs candidates and there is no path to produce one. **M**

**30. Urdu support is a font swap, not real bilingual capability.** `exams.language` is one column; the PDF applies `NotoNaskhArabic` + `textAlign:'right'` (`styles.rtl`) with no bidi handling — MCQ option letters, numerals, marks-in-brackets and mixed English terms all render in the wrong order. `'mixed'` merely asks the LLM for a parenthetical translation; there is no per-question `{ur, en}` pair, so you cannot print one paper for the Urdu-medium section and the same paper for the English-medium section. The font is also fetched from jsDelivr at render time, so Urdu papers fail on any egress-restricted deploy. (Related known bug: the copyright guard is a total no-op on Urdu script.) **M**

---

Tightest critical path to "a real Pakistani school can run one exam end to end": **1 → 2 → 17 → 14 → 19 → 20** (student-copy export, paper header fields, manual marks entry, candidate roster, grade boundaries, result card) — all S/M, none requiring the LLM pipeline to change. **5, 6, 7** are what gate credibility with science and senior-grade teachers. **13** should be treated as urgent since the shipped shuffled-versions feature is currently a correctness trap.

---

# Part 2 — What a full school management system needs (zero coverage today)

# School Management System — Zero-Coverage Requirements Backlog

**Scope note.** Every item below is at **zero** in this repo — not partial, not stubbed. The codebase contains 12 tables, all of which serve exam generation and auto-grading; there is no person, student, class, money, or calendar concept anywhere (repo map §8 confirms by exhaustive grep). The existing product contributes to exactly one-and-a-half modules of ~25 (M10 marks-entry source, M11 assessment content). Everything else, including all platform foundations, is greenfield.

**Effort legend:** S = ≤1 dev-week · M = 2–5 dev-weeks · L = 6+ dev-weeks, or needs a third-party integration/dedicated squad.

---

## M0 — Platform foundations (blocking prerequisites for every other module)

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| F-01 | Person/party registry | One canonical human record that student, guardian, staff, alumni roles hang off | The same person is a parent, a teacher, and an alumnus; without it you duplicate and de-sync identity in six modules | M |
| F-02 | Role & permission model | ~15 roles (principal, coordinator, accountant, librarian, warden, driver, nurse, parent, student…) with granular per-resource permissions | Today there are exactly two roles and authorization is `orgId` scoping only — an accountant would be able to edit exam papers and a parent to read every child's record | L |
| F-03 | Row-level security | DB-enforced tenancy and per-role visibility, not application `where org_id =` | With students, fees and medical data, one missed filter is a breach, not a bug | M |
| F-04 | Audit trail | Immutable who-changed-what-when on marks, fees, attendance, discipline, documents | Mark and fee tampering are the two most common school-ERP fraud vectors; boards and auditors demand traceability | M |
| F-05 | Numbering sequences | Configurable, gapless series for GR no, admission no, roll no, invoice, receipt, certificate | Statutory registers require unbroken serial numbers; ad-hoc UUIDs are not acceptable to inspectors | S |
| F-06 | Generic document service | Attachments of any type (images, docs) with size/type limits, virus scan, thumbnails, expiry | Every module needs uploads; current storage is PDF-only and hardcoded to books/answer sheets | M |
| F-07 | Notification infrastructure | Queue, templates, provider adapters, delivery log, retry, cost accounting | Nothing in the system can currently send a single message to anyone — no email, no SMS, no push | M |
| F-08 | Scheduler / recurring jobs | Named schedules for fee generation, term rollover, report runs, reminder sweeps | One hardcoded 3am retention cron exists; the ERP needs dozens of business-calendar-driven jobs | S |
| F-09 | Bulk import/export | CSV/Excel importers with dry-run, validation report, rollback, per-entity templates | You cannot onboard a 2,000-student school by typing; this is the #1 sales blocker | M |
| F-10 | Localization + Urdu RTL | i18n framework, Urdu/English UI, RTL layout, Urdu-capable PDF fonts | Target market is Pakistani schools; parent-facing SMS, report cards and certificates are commonly Urdu | M |
| F-11 | School calendar service | Academic calendar, weekends per branch, gazetted/local holidays, half-days, Hijri dates | Attendance, timetable, fees and payroll all compute against working days | S |
| F-12 | Per-school configuration | Timezone, currency, week start, grading scale, address, branding, print headers | The app is hardcoded UTC (a confirmed defect) and has no branding surface beyond a logo URL | S |
| F-13 | Print/report engine | Batch-printable A4/legal layouts, Urdu shaping, page headers, watermarks, duplex | Report cards, challans, ID cards, registers are all printed in bulk; current PDF layer renders one exam paper in Latin script | M |
| F-14 | Barcode/QR + ID card printing | Code128/QR generation, card templates, batch print with photos | Drives library issue, transport scan, challan reconciliation, gate entry | S |
| F-15 | Global search | Cross-entity search by name, GR no, CNIC, phone, invoice | Front-desk staff live in search; without it every lookup is a nav-tree crawl | S |
| F-16 | Support impersonation | Time-boxed, audited "login as" for support staff | Unavoidable for supporting non-technical school admins, dangerous without audit | S |
| F-17 | Offline / low-bandwidth mode | PWA shell, offline attendance and marks entry with sync/conflict resolution | Many Pakistani campuses have unreliable connectivity; attendance must not depend on the network | L |
| F-18 | SaaS subscription & billing | Per-school plans, seats/student-count metering, invoices, dunning, suspension | `organizations.plan` is a string with no payment path; the business cannot charge anyone | M |
| F-19 | Backup, restore & DR runbook | Automated Postgres + object-storage backups, tested restore, RPO/RTO targets | Holding a school's fee ledger and student records without a restore story is existential risk | M |
| F-20 | Consent & minor data protection | Guardian consent capture, purpose limitation, per-field visibility, subject-access requests | The system will hold health, biometric and financial data on minors; current legal pages only cover exam scans | M |

---

## M1 — Multi-campus / branch

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| MC-01 | Campus/branch entity | Branch under a trust/group, with own address, head, EMIS code, registration | Almost every paying Pakistani school chain is multi-branch; single-tenant-per-branch fragments reporting | M |
| MC-02 | Branch-scoped access | Users assigned to one or many branches; all queries branch-filtered | A branch principal must not see another branch's fees or staff salaries | M |
| MC-03 | Head-office consolidated view | Roll-up dashboards and reports across branches with drill-down | The owner buys the system for this view; it is the primary purchase driver for chains | M |
| MC-04 | Shared vs branch-local masters | Decide per-master (fee heads, grading scale, subjects) whether it's group-wide or overridable | Chains want central policy with local exceptions; hardcoding either way loses deals | M |
| MC-05 | Inter-branch student/staff transfer | Move a record between branches preserving history, ledger, and documents | Families relocate between city branches constantly; re-admission loses history and arrears | M |
| MC-06 | Per-branch P&L | Revenue, expense, headcount, and margin per campus | Franchise/chain owners manage by branch profitability | M |
| MC-07 | Franchise/licensee hierarchy | Group → region → branch tree with royalty/fee reporting | Franchise models charge per-student royalties that must be computed from enrollment | M |

---

## M2 — Academic structure

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| AC-01 | Academic session/year | Named year (2026–27) with start/end, status (planning/active/closed) | Every student, fee, exam and attendance record must be session-scoped or history is meaningless | M |
| AC-02 | Terms / semesters / quarters | Sub-periods of a session with weightage toward the final result | Report cards and fee installments are term-driven | S |
| AC-03 | Class / grade levels | Playgroup → Grade 12 ladder with ordering and next-class mapping | The spine of promotion, fee structures, timetable and reporting | S |
| AC-04 | Sections | Class subdivisions (9-A, 9-B) with capacity, class teacher, room | Attendance, timetable and marks entry are all section-scoped; nothing works without it | S |
| AC-05 | Streams / groups | Pre-Medical, Pre-Engineering, Commerce, Arts, Computer Science | Determines subject sets and board registration for grades 9–12 in Pakistan | S |
| AC-06 | Subject master | Subjects with code, type (compulsory/elective/co-curricular), theory/practical split, max marks | Marks, timetable, teacher allocation and report cards all key off subjects | S |
| AC-07 | Class–subject mapping | Which subjects a class/stream takes, with marks weightage and pass criteria | Report card totals and pass/fail are computed from this, not from free text | M |
| AC-08 | Teacher–subject–section allocation | Who teaches what, where, with period load | Drives timetable, marks-entry permissions, substitution and workload analytics | M |
| AC-09 | Student–section allocation | Enrollment of a student into session × class × section × stream with roll number | Currently a student is a nullable free-text string on a submission | M |
| AC-10 | Shifts | Morning/evening shift with separate timings, staff, sections | Very common in Pakistani private schools; doubles capacity on one campus | M |
| AC-11 | Room / classroom master | Rooms, labs, capacity, facilities | Required for timetable clash-free allocation and exam seating | S |
| AC-12 | Houses | Red/Green/Blue house assignment and points | Drives sports, discipline merits and school culture reporting | S |
| AC-13 | Curriculum / syllabus plan | Chapter-and-topic plan per subject per term with target dates | Coordinators track syllabus coverage; also the hook the existing RAG book library should attach to | M |
| AC-14 | Lesson planning & approval | Teacher lesson plans submitted, reviewed, approved by coordinator | A core coordinator workflow and a common inspection requirement | M |
| AC-15 | Session rollover engine | Clone masters, promote/detain students, carry arrears, archive old session | Done wrong, this corrupts a whole school's data annually; must be transactional and reversible | L |

---

## M3 — Admissions & enquiry

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| AD-01 | Enquiry capture | Walk-in/phone/web/WhatsApp lead with source, class sought, contact | Admissions is the school's revenue funnel; today it's a paper register | S |
| AD-02 | Lead pipeline & follow-up | Stages, owner, tasks, reminders, lost reasons | Conversion depends on chasing; unchased leads are lost revenue | M |
| AD-03 | Online application form | Public form with document upload and configurable fields per class | Parents expect to apply without visiting; also the main organic acquisition path | M |
| AD-04 | Application fee collection | Non-refundable processing fee with online payment and receipt | Filters serious applicants and funds the admissions office | M |
| AD-05 | Entry test scheduling & scoring | Test slots, admit slips, score entry, cutoffs | Selective schools admit on test merit; this is where the existing exam engine can plug in | M |
| AD-06 | Interview scheduling & scoring | Parent/child interview slots, panel, rubric | Standard second stage in mid- and high-tier private schools | S |
| AD-07 | Merit list & seat allotment | Ranked list, seats per class, allotment, waiting list promotion | The decision moment of the whole funnel; manual spreadsheets cause disputes | M |
| AD-08 | Offer / rejection letters | Templated, batch-sent with deadline to accept | Legally and reputationally sensitive; must be consistent and logged | S |
| AD-09 | Document checklist & verification | Required docs per class (B-form, prev. result, TC), status per applicant | Missing documents block board registration later; catch it at admission | S |
| AD-10 | Applicant → student conversion | One-click creation of student, enrollment, guardian, and first invoice | Prevents re-keying and is where most manual-entry errors originate | M |
| AD-11 | Sibling / staff-child detection | Auto-flag concession eligibility at application time | Discount policy is nearly universal and must not depend on the clerk remembering | S |
| AD-12 | Admissions analytics | Funnel conversion by source, class, and campaign; cost per admission | Marketing spend decisions for the school owner | S |

---

## M4 — Student information

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| ST-01 | Student master | Bio data, DOB, gender, religion, blood group, mother tongue, photo, address | There is no student entity of any kind in the repo; this is the single largest gap | M |
| ST-02 | National identity capture | NADRA B-form / CNIC / passport with format validation and uniqueness | Mandatory for board registration and provincial EMIS returns | S |
| ST-03 | Enrollment record | Session × class × section × stream × roll number × status, one row per year | Separating person from enrollment is what makes history, promotion and transcripts possible | M |
| ST-04 | Student status lifecycle | Active, on-leave, left, struck-off, rusticated, passed-out, alumni, with dates and reason | Fee, attendance and headcount reports are all wrong without a clean status model | M |
| ST-05 | Previous school & prior academics | Last school, TC number, last class passed, marks | Required on admission forms and for board registration | S |
| ST-06 | Student document vault | B-form, birth certificate, TC, photos, certificates, with expiry and verification flags | Schools are legally required to hold these; parents constantly re-request copies | S |
| ST-07 | Roll number allotment | Rule-based (alphabetical, merit, manual) with per-section renumbering | Roll numbers order every register, seating plan and result sheet | S |
| ST-08 | GR / admission & withdrawal register | Statutory serial register of every admission and withdrawal | Inspectable legal record in Pakistani provinces; must be exportable in prescribed format | M |
| ST-09 | Student transfer | Section change, class change, branch change with effective dates and history | Mid-year section balancing is routine and must not rewrite history | M |
| ST-10 | Withdrawal & readmission | Structured leaving with clearance, dues check, TC issue, and re-entry path | Withdrawal without a dues check is direct revenue leakage | M |
| ST-11 | Sibling linkage | Link students sharing a guardian | Powers sibling discounts, consolidated invoices, and one parent login | S |
| ST-12 | Custom fields | Per-school extra attributes without code changes | Every school asks for three fields nobody else wants; otherwise it's a support queue | M |
| ST-13 | Student 360 timeline | One screen: attendance, marks, fees, discipline, health, communication | The screen the principal actually uses in a parent meeting | M |
| ST-14 | Student portal login | Student-scoped account seeing only own data | There is no student user type at all today | M |
| ST-15 | Student ID cards | Photo cards with QR/barcode, batch generation per section | Needed for library, transport, exam and gate identification | S |
| ST-16 | Bulk promotion / detention | Section-wise promote with exceptions, detain, and roll-forward of dues | Annual peak operation; manual handling is a week of clerical work and errors | M |

---

## M5 — Guardian accounts

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| GD-01 | Guardian entity & relationship | Father/mother/guardian with relation type, custody status, per-student link | Communication, billing and legal responsibility all route through the guardian, not the child | M |
| GD-02 | Guardian login & multi-child switcher | One account, all children across classes and branches | Parents refuse separate logins per child; this is a hard usability requirement | M |
| GD-03 | Guardian profile & occupation/income | Employer, designation, income band, CNIC | Needed for need-based scholarships and for board/EMIS returns | S |
| GD-04 | Emergency contacts & pickup authorization | Ranked contacts and who may collect the child | Child-safety requirement; schools are liable for wrong handover | S |
| GD-05 | Contact preferences & consent | Per-channel opt-in (SMS/WhatsApp/email/push), quiet hours, primary contact | Regulatory and practical: message-blasting non-consenting numbers gets sender IDs blocked | S |
| GD-06 | Consolidated family ledger | One outstanding balance and one payment across siblings | Parents pay once for three children; per-student-only billing is a support nightmare | M |
| GD-07 | Parent–teacher meeting scheduling | PTM slots, booking, attendance, teacher remarks recorded | Structured feedback loop that schools market as a differentiator | M |
| GD-08 | Guardian-initiated change requests | Parent submits address/phone change, staff approves | Keeps contact data fresh without giving parents write access | S |
| GD-09 | Guardian document & signature capture | Digital acknowledgement of circulars, consent forms, trip permissions | Replaces the "signed slip returned tomorrow" loop and creates an audit record | M |

---

## M6 — Staff HR & payroll

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| HR-01 | Employee master | Staff bio, CNIC, contact, photo, emergency contact, bank account | Teachers exist today only as Clerk auth rows with a role enum | M |
| HR-02 | Employment record | Designation, department, joining date, contract type/end, probation, reporting line | Payroll, leave quota and access rights all derive from it | M |
| HR-03 | Qualifications & certifications | Degrees, teaching licences, trainings, expiry tracking | Board and regulator inspections check teacher qualification records | S |
| HR-04 | Staff documents | Contract, CNIC copy, degrees, police verification, medical fitness | Statutory file every school must hold per employee | S |
| HR-05 | Leave types & quotas | Casual/earned/medical/maternity with accrual, carry-forward, encashment | Leave drives substitution and payroll deductions | M |
| HR-06 | Leave application workflow | Apply → approve → notify → auto-trigger substitution and attendance | The most-used staff-facing feature after attendance | M |
| HR-07 | Salary structure | Components: basic, house rent, conveyance, allowances, deductions, per-grade templates | Cannot run payroll without a component model; flat salary fields don't survive first audit | M |
| HR-08 | Payroll run & payslips | Monthly run with attendance/leave/loan inputs, lock, payslip PDF, re-run correction | Highest-stakes recurring operation in the system after fee collection | L |
| HR-09 | Statutory deductions | Income tax slabs (FBR), EOBI, provincial social security, provident fund, gratuity | Getting these wrong exposes the school to penalties; they change annually | L |
| HR-10 | Loans & advances | Staff loan issue, installment recovery through payroll | Extremely common in Pakistani schools and currently tracked in notebooks | M |
| HR-11 | Bank transfer file / salary sheet | Bank-format disbursement file and signed salary register | How salary actually leaves the building | M |
| HR-12 | Appraisal & KPI | Review cycles, ratings, goals, classroom-observation scores | Feeds increments and retention decisions; also an accreditation requirement | M |
| HR-13 | Disciplinary & warning letters | Staff-side incident records, warnings, show-cause, outcomes | Required for defensible termination | S |
| HR-14 | Resignation, exit & clearance | Notice, clearance checklist (library, assets, dues), final settlement, experience letter | Prevents assets and advances walking out the door | M |
| HR-15 | Duty roster | Non-teaching duties: exam invigilation, morning assembly, gate, event | Fairness disputes over duty allocation are a real staff-relations issue | M |
| HR-16 | Staff self-service portal | Own payslips, leave balance, timetable, attendance, documents | Removes the largest source of HR-desk interruptions | M |
| HR-17 | Recruitment / applicant tracking | Vacancies, applications, interview stages, offer | Lower priority but expected in larger chains | M |

---

## M7 — Timetable & substitution

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| TT-01 | Period / bell structure | Periods per day per shift, durations, breaks, assembly, Friday variation | The grid everything else is placed on; Friday timings differ in Pakistan | S |
| TT-02 | Timetable builder | Manual drag-drop grid with real-time clash detection (teacher, room, section) | A published timetable with clashes is an immediate credibility loss | L |
| TT-03 | Automatic generation | Constraint solver honoring teacher load, subject frequency, lab blocks, preferences | Manual scheduling for 40 sections takes a coordinator two weeks a year | L |
| TT-04 | Teacher availability & load rules | Max periods/day and /week, unavailable slots, part-time staff | Prevents burnout complaints and union/HR disputes | M |
| TT-05 | Room & lab allocation | Assign rooms per period with capacity and equipment constraints | Two classes in one lab is the classic timetable failure | M |
| TT-06 | Double / lab / activity periods | Multi-period blocks and split-class practicals | Science and computer practicals cannot be scheduled without it | M |
| TT-07 | Publish & distribute | Per-teacher, per-section, per-room printable views plus app view | The timetable is only useful once everyone can see their slice | S |
| TT-08 | Substitution engine | On staff absence, suggest and assign free teachers, notify, log | The single most-used daily coordinator task in any school | M |
| TT-09 | Free-period / cover finder | Who is free in period 4 today | Needed for ad-hoc cover, invigilation and duty assignment | S |
| TT-10 | Exam-week override | Alternate timetable during exams and events | Regular timetable does not apply during exams; hard-coding one timetable breaks | S |
| TT-11 | Change log & notifications | Versioned timetable with push/SMS on change | Silent timetable changes cause missed classes and parent complaints | S |

---

## M8 — Attendance (student + staff + biometric)

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| AT-01 | Daily student attendance | Section-wise mark-all-present-then-exceptions with date lock | Zero occurrences of "attendance" in the repo; this is table-stakes function #1 | M |
| AT-02 | Period-wise attendance | Per-subject-period marking for senior classes | Required where students move between electives; also catches in-school truancy | M |
| AT-03 | Attendance codes | Present, absent, late, half-day, leave, excused, medical, holiday | A boolean present/absent cannot express leave or lateness policy | S |
| AT-04 | Guardian leave applications | Parent applies from app, class teacher approves, attendance auto-updates | Closes the loop between parent intent and the register | M |
| AT-05 | Absence auto-notification | SMS/WhatsApp/push to guardian within N minutes of marking absent | The single highest-perceived-value parent feature in South Asian school ERPs | M |
| AT-06 | Biometric / RFID integration | Device sync (ZKTeco et al.), punch ingestion, mapping to students/staff, dedup | Schools buy hardware first and demand the ERP consume it; polling and clock-skew handling are non-trivial | L |
| AT-07 | Gate entry/exit scan | Student in/out scanning with guardian notification | Safety feature parents pay for; also feeds late-arrival policy | M |
| AT-08 | Staff attendance | Punch in/out, late marks, early leaving, manual regularization | Feeds payroll deductions and substitution; also a compliance record | M |
| AT-09 | Attendance regularization | Correction requests with approval and full audit | Attendance edits are a fraud vector for both payroll and eligibility | S |
| AT-10 | Eligibility rules | Minimum attendance % gates exam eligibility, with warnings at thresholds | Boards commonly enforce a 75% rule; must be computed and warned early | M |
| AT-11 | Registers & statutory reports | Monthly attendance register per section in prescribed format, staff muster roll | Inspection artifact; must print exactly as the department expects | M |
| AT-12 | Mobile/offline marking | Teacher marks on phone, syncs later | Classrooms often have no reliable Wi-Fi | M |
| AT-13 | Attendance analytics | Chronic absentee identification, section/day-of-week patterns, staff punctuality | Feeds at-risk student alerts and HR conversations | S |

---

## M9 — Fees & finance

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| FE-01 | Fee heads | Tuition, admission, security, exam, lab, sports, ACR, transport, hostel, misc | "fee" appears zero times in the codebase; this module is the school's entire revenue | S |
| FE-02 | Fee structures | Per class × session × stream amounts, one-time vs recurring, installment plan | Different classes and streams pay different amounts; must be defined once, not per student | M |
| FE-03 | Student fee assignment | Apply structure to enrollments with per-student overrides and effective dates | Overrides are the norm (mid-year joiners, special arrangements) and must be auditable | M |
| FE-04 | Discounts & scholarships | Sibling, staff-child, merit, need-based, hardship; % or fixed, with approval workflow | Uncontrolled discounting is the most common source of revenue leakage in private schools | M |
| FE-05 | Late fee / fine rules | Grace period, flat/percent/slab fines, auto-application, waiver with approval | Drives on-time collection; must be rule-based to be defensible to parents | M |
| FE-06 | Invoice / challan generation | Batch monthly or term generation across classes with preview and rollback | The heartbeat operation of the finance office; a bad batch run is a school-wide incident | L |
| FE-07 | Printable bank challan | Multi-copy (bank/school/parent) challan with barcode, bank branch details, due dates | Bank-counter payment is still dominant; format must match the partner bank's spec | M |
| FE-08 | Online payment | JazzCash, EasyPaisa, 1LINK/Kuickpay, card, bank transfer, with callbacks and idempotency | Parents increasingly refuse to queue at banks; also accelerates cash flow | L |
| FE-09 | Payment reconciliation | Bank statement / gateway settlement import, auto-match to challans, exception queue | Unreconciled payments produce false defaulters and furious parents | L |
| FE-10 | Receipts & partial payments | Numbered receipts, part-payment allocation across heads, cash/cheque/online modes | Cheque bounce and partial payment handling are daily realities | M |
| FE-11 | Student & family fee ledger | Running statement of charges, payments, discounts, fines, arrears | The document every fee dispute is settled with | M |
| FE-12 | Defaulters & dunning | Aging buckets, automated reminder sequences, escalation, name-strike-off list | Collection rate is the metric the owner cares about most | M |
| FE-13 | Refunds, adjustments, security deposit | Refund workflow with approval, deposit hold and release at leaving | Legally required for refundable security deposits | M |
| FE-14 | Fee concession/freeze approvals | Multi-level approval for waivers above thresholds | Prevents a single clerk from writing off fees | S |
| FE-15 | Arrears carry-forward | Outstanding balance moves with the student across terms, sessions and branches | Rollover that drops arrears loses real money | M |
| FE-16 | Transport & hostel fee integration | Route/room allocation automatically bills the right amount, pro-rated | Manual double-entry between modules always drifts | M |
| FE-17 | Expenses & vouchers | Expense heads, payment vouchers, petty cash, approvals, attachments | Owners want net position, not just collections | M |
| FE-18 | Accounting core or export | Chart of accounts, day book, ledger, trial balance — or clean export to QuickBooks/Tally | Either you become the books of account or you integrate; doing neither strands the accountant | L |
| FE-19 | Vendor & purchase payments | Supplier master, bills, payment tracking, aging | Ties inventory purchases to actual cash out | M |
| FE-20 | Fee certificates & tax documents | Annual fee-paid certificate, advance-tax (FBR) certificate for parents | Parents need these for employer reimbursement and tax filing; requested every year en masse | S |
| FE-21 | Regulatory fee compliance | PSRA-style fee-increase caps, disclosure of fee schedule, change history | Provincial regulators cap annual increases; violations carry penalties and closure orders | M |
| FE-22 | Collection dashboards | Expected vs collected vs outstanding by class, branch, month, head | The owner's daily screen | M |

---

## M10 — Examinations, results & report cards

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| EX-01 | Exam term definitions | Named exams (First Term, Mid, Send-Up, Annual) with weightage toward final result | The existing product generates papers but has no concept of an exam event | M |
| EX-02 | Datesheet / exam schedule | Subject × date × time × duration × room per class, printable | Published to students, parents and staff weeks in advance | M |
| EX-03 | Seating plan | Room-wise seat allocation with mixing rules, printable charts and desk slips | Exam-hall management and anti-cheating; complements the existing shuffled-versions feature | M |
| EX-04 | Admit cards / roll number slips | Per-student card with photo, roll no, datesheet, dues clearance check | Gate control for the exam hall and a dues-enforcement lever | S |
| EX-05 | Invigilation duty roster | Assign staff to rooms/slots with conflict avoidance and relief | Every exam day requires it; today it's a whiteboard | M |
| EX-06 | Marks entry | Per-subject, per-section grid with theory/practical split, max validation, save-lock | The core bridge from the existing auto-grader into a real gradebook | M |
| EX-07 | Auto-grade ingestion | Push graded submission scores from the existing pipeline into the gradebook | This is the one place the current product actually connects to an SMS; without it the grader is a dead end | M |
| EX-08 | Grading scales & GPA | Configurable grade bands (A1/A/B…), GPA/percentage, per-board variants | FBISE, Punjab and Cambridge grade differently; hardcoding one is wrong for most customers | M |
| EX-09 | Pass criteria & pass/fail | Per-subject and aggregate pass marks, practical/theory minimums, compartment rules | Determines promotion; must match board rules exactly | M |
| EX-10 | Absent / exempt / grace marks | Codes for absent, medical exemption, and controlled grace-mark application with audit | Every result compilation hits these cases; ad-hoc handling invites tampering | S |
| EX-11 | Moderation & result approval | Review, moderation, sign-off workflow before results are visible | Publishing unreviewed marks to parents is unrecoverable | M |
| EX-12 | Result compilation & ranking | Totals, percentages, position in section/class/school, tie-breaking | Position is culturally central in Pakistani schools and computed wrongly by hand | M |
| EX-13 | Report card templates | Per-board, per-class designs with marks, grades, attendance, remarks, signatures, logo | The most-scrutinized printed artifact the school produces | L |
| EX-14 | Teacher remarks & conduct | Per-subject and overall qualitative remarks, remark bank | Parents read remarks before marks; required on nearly every template | S |
| EX-15 | Cumulative reports & transcripts | Multi-term and multi-year consolidated record and official transcript | Needed for transfers, foreign applications and alumni requests | M |
| EX-16 | Result publication | Release to portal/app/SMS with per-class timing control and dues gating | Controlled release prevents leaks and enforces fee clearance | M |
| EX-17 | Re-checking / re-appear / supplementary | Application, fee, re-mark, revised result with version history | Board-mirroring process that schools must run internally | M |
| EX-18 | Tabulation sheet | Statutory class-wise all-subject marks sheet in prescribed format | Inspected and archived document; must print exactly right | M |
| EX-19 | Continuous / formative assessment | Class tests, quizzes, projects, participation, rubrics feeding term weightage | Cambridge and SNC both require continuous assessment, not just terminal exams | M |
| EX-20 | Co-curricular & skills grading | Non-academic descriptors (discipline, punctuality, sports, art) on the report card | Standard on primary and Cambridge report cards | S |
| EX-21 | Item & cohort analytics | Question-level difficulty, subject-wise weak topics, teacher and section comparison | Genuine differentiator that leverages the existing question metadata | M |
| EX-22 | Promotion decision engine | Apply pass criteria + attendance + discipline to produce promote/detain lists | Ties results to the rollover engine; currently a manual meeting and a spreadsheet | M |
| EX-23 | Board result import & comparison | Import BISE/FBISE results, compare with internal predictions | Marketing and academic-quality measurement for the school | M |

---

## M11 — Homework, assignments & LMS

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| LM-01 | Homework assignment | Teacher posts per section/subject with description, attachments, due date | Daily-touch feature that keeps parents opening the app | M |
| LM-02 | Homework diary view | Parent/student consolidated daily diary across subjects | Replaces the physical diary — a concrete, sellable outcome | S |
| LM-03 | Online submission | Student uploads work, teacher sees submission status per section | Enables remote/blended teaching and creates an evidence trail | M |
| LM-04 | Assignment grading & feedback | Marks/rubric plus comments, returned to student, optionally into CIE | Closes the loop and feeds continuous assessment | M |
| LM-05 | Content library | Notes, videos, links, past papers organized by class/subject/topic | Natural extension of the existing book ingestion pipeline | M |
| LM-06 | Syllabus coverage tracking | Teacher marks topics covered against the plan; coordinator dashboard | Coordinators chase this weekly; currently done on paper | M |
| LM-07 | Online quizzes/tests | Timed, auto-marked online assessments with question bank reuse | Directly reuses the existing `bank_questions` and pattern engine | M |
| LM-08 | Live class integration | Zoom/Meet link per timetable slot with attendance capture | Expected baseline since 2020; also used for makeup classes | M |
| LM-09 | Doubt / discussion threads | Moderated Q&A per subject between students and teacher | Engagement feature; needs moderation and safeguarding controls | M |
| LM-10 | Learning progress tracking | Per-student completion, scores, time-on-task | Feeds at-risk detection and parent reporting | M |

---

## M12 — Library

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| LB-01 | Catalogue | Title, author, ISBN, publisher, category, Dewey/shelf, language | Basic asset control over a five-to-six-figure book inventory | S |
| LB-02 | Copies / accession register | Per-physical-copy accession number, barcode, condition, location | Issue/return operates on copies, not titles; the accession register is a statutory record | S |
| LB-03 | Membership & cards | Students and staff as members with borrowing limits and validity | Limits prevent hoarding; membership expires with enrollment | S |
| LB-04 | Issue / return / renew | Barcode-driven circulation with due dates and per-role loan periods | The counter operation; must be fast and offline-tolerant | M |
| LB-05 | Fines | Overdue calculation, waiver, payment (optionally through the fee ledger) | Enforces returns; must reconcile with finance rather than a cash tin | S |
| LB-06 | Reservations / holds | Queue for issued titles with notification on availability | Needed for scarce reference and textbook copies | S |
| LB-07 | Lost / damaged handling | Replacement charge, write-off approval, removal from stock | Otherwise stock counts drift permanently | S |
| LB-08 | Stock verification | Periodic scan-based audit with variance report | Annual audit requirement for school inventories | M |
| LB-09 | OPAC / student search | Students search and reserve from portal or app | Drives library usage, which schools report to boards and parents | S |
| LB-10 | Library analytics | Circulation by class/subject, most-read, dormant stock, per-student reading | Purchasing decisions and a reading-culture metric for marketing | S |
| LB-11 | Digital resources | E-books/links attached to catalogue entries with access control | Bridges the physical library and the existing digital book corpus | M |

---

## M13 — Transport

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| TR-01 | Vehicle master | Bus/van registration, capacity, fitness/route permit/insurance expiry | Expired fitness documents shut down a route and carry legal exposure | S |
| TR-02 | Driver & conductor records | Licence number and expiry, medical, police verification, assignment | Child-safety and regulatory requirement | S |
| TR-03 | Routes & stops | Ordered stops with timings, distance and fare slab per stop | The basis of transport billing and parent expectations | M |
| TR-04 | Student route allocation | Assign student to route, stop, pickup/drop, one-way vs both ways | Drives capacity planning and fee amount | M |
| TR-05 | Transport fee integration | Allocation auto-bills the fare slab, pro-rated on join/leave | Manual transport billing is the most error-prone fee head | M |
| TR-06 | GPS live tracking & ETA | Device ingestion, live map for parents, arrival ETA | The headline parent-app feature schools advertise | L |
| TR-07 | Boarding attendance | RFID/QR scan on board and alight with timestamp | Safety-critical: proves the child got on and off the right bus | M |
| TR-08 | Boarding notifications | Automatic push/SMS to guardian on pickup and drop | Directly reduces parent phone calls to the office | M |
| TR-09 | Maintenance & fuel log | Service schedule, repairs, fuel consumption per vehicle, cost per km | Transport is a major cost centre run blind without it | M |
| TR-10 | Driver duty roster & substitution | Daily assignment, leave cover, overtime | A missing driver strands a route; needs the same treatment as teacher substitution | S |
| TR-11 | Incident & complaint log | Accidents, breakdowns, parent complaints against drivers | Safeguarding record and insurance evidence | S |

---

## M14 — Hostel / boarding

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| HO-01 | Hostel & block master | Buildings, floors, gender designation, warden assignment | Boarding schools cannot be onboarded at all without it | S |
| HO-02 | Room & bed inventory | Rooms with type, capacity, bed-level occupancy | Allocation and billing operate at bed level | S |
| HO-03 | Allocation & vacating | Assign/transfer/vacate with dates and history | Drives occupancy reporting and pro-rated charges | M |
| HO-04 | Hostel & mess fee | Room-type charges and mess charges into the fee ledger | Second-largest revenue line in boarding schools | M |
| HO-05 | Mess menu & attendance | Weekly menu, meal attendance/headcount for provisioning | Controls the largest recurring hostel cost | M |
| HO-06 | Gate pass / in-out register | Leave-the-campus requests with warden and guardian approval, return logging | Core safeguarding control for resident minors | M |
| HO-07 | Visitor log | Who visited which boarder, when, with ID | Safeguarding and inspection requirement | S |
| HO-08 | Night attendance / roll call | Scheduled headcount with exception alerts | A missing boarder must be detected within the hour, not the next morning | S |
| HO-09 | Warden roster | Duty schedule and handover notes | 24-hour coverage accountability | S |
| HO-10 | Hostel discipline & incidents | Incidents, warnings, guardian notification | Separate from academic discipline; residential rules differ | S |
| HO-11 | Maintenance requests | Student/warden raises issue, tracked to closure | Occupant satisfaction and asset upkeep | S |

---

## M15 — Inventory, stores & assets

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| IV-01 | Item master & categories | Consumables, uniforms, books, stationery, lab items with units and reorder level | Foundation for any stock control | S |
| IV-02 | Stores / warehouses | Per-branch stock locations with separate balances | Chains hold stock per campus; single-pool stock is wrong | S |
| IV-03 | Purchase requisition → PO → GRN | Request, approval, order, goods receipt with partial receipts | Procurement control; prevents unapproved spending | M |
| IV-04 | Issue, return & consumption | Issue to department/staff/student with return tracking | Where stock actually leaves; the shrinkage control point | M |
| IV-05 | Uniform & book shop | Point-of-sale to students, billed to fee ledger or cash, with stock decrement | A real revenue line most schools run in a parallel notebook | M |
| IV-06 | Asset register | Furniture, IT, lab equipment with tags, location, custodian, depreciation | Annual audit and insurance requirement | M |
| IV-07 | Asset maintenance schedule | Preventive maintenance, service history, warranty/AMC expiry | Extends asset life and avoids exam-day equipment failures | S |
| IV-08 | Vendors & quotations | Supplier master, comparative quotes, rate contracts | Procurement transparency for trust/board scrutiny | S |
| IV-09 | Stock alerts & audit | Min-stock alerts and periodic physical count with variance | Stops the "we ran out of exam paper" incident | S |

---

## M16 — Communication (SMS / WhatsApp / push / email)

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| CM-01 | Provider adapters | Pluggable SMS (local gateways), WhatsApp Business API, email, push | The system today cannot send any message to anyone; every other module's value depends on this | L |
| CM-02 | Template management | Named templates with variables, per-language (Urdu/English), approval for WhatsApp | WhatsApp requires pre-approved templates; ad-hoc text will be rejected | M |
| CM-03 | Audience targeting | Send to class, section, route, hostel, defaulters, absentees, staff group, custom list | Blasting everyone destroys trust and burns credit | M |
| CM-04 | Triggered/automated messages | Event-driven: absent, fee due, result published, bus boarded, exam scheduled | Automation, not manual blasts, is where the perceived value is | M |
| CM-05 | Scheduled campaigns | Queue a message for a future date/time with quiet-hour respect | Reminders must land at useful hours, not 2am | S |
| CM-06 | Delivery status & retry | Per-recipient sent/delivered/failed with reason, retry, invalid-number quarantine | Schools are billed per message and will dispute undelivered ones | M |
| CM-07 | Credit wallet & cost tracking | Per-branch message credit balance, top-up, per-campaign cost | Communication is a real, metered cost that must be attributed | M |
| CM-08 | Opt-in / opt-out management | Per-channel consent, unsubscribe handling, do-not-disturb | Regulatory and deliverability requirement | S |
| CM-09 | Two-way parent–teacher inbox | Threaded in-app messaging with moderation, working-hours limits, archive | Parents will otherwise WhatsApp teachers' personal numbers — a real safeguarding issue | L |
| CM-10 | Message archive & audit | Immutable record of what was sent to whom by whom | Dispute resolution ("we were never informed") | S |
| CM-11 | Voice/IVR blast | Recorded call broadcast for emergencies and low-literacy households | Still effective in many Pakistani parent populations | M |

---

## M17 — Notice board, calendar & events

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| NB-01 | Notice board | Posts with audience targeting, attachments, pin, expiry | The school's official channel of record | S |
| NB-02 | Acknowledgement tracking | Require guardian to mark read/acknowledge, with report | Turns "we didn't know" into a data question | S |
| NB-03 | School calendar | Holidays, exams, events, PTMs, deadlines, per-branch and per-class | Feeds attendance working days, timetable and parent app | S |
| NB-04 | Event management | Create event, RSVP, ticketing/fee, attendance, volunteers | Sports days, annual functions and trips are logistics-heavy | M |
| NB-05 | Circulars with digital consent | Trip/medical/photo-consent forms signed digitally by guardian | Replaces the paper slip loop and creates a defensible record | M |
| NB-06 | Media gallery | Event photos/videos with class-level privacy controls | Marketing and parent engagement; needs strict child-image consent | M |
| NB-07 | Emergency broadcast | One-tap all-channel alert (closure, weather, security) with delivery report | Rare but existential; must not depend on someone assembling a list | S |
| NB-08 | Automated occasions | Birthdays, achievements, appreciation posts | Cheap, high-engagement retention feature | S |

---

## M18 — Discipline & behaviour

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| DS-01 | Incident record | Date, category, severity, description, witnesses, reporter, students involved | Currently no record exists; verbal discipline history disappears with staff turnover | M |
| DS-02 | Merit / demerit points | Positive and negative points with house/class aggregation | Behaviour-management systems schools actively market | S |
| DS-03 | Action workflow | Warning → detention → parent call → suspension → rustication, with approvals | Serious actions must be authorized and documented, not unilateral | M |
| DS-04 | Guardian notification & meetings | Auto-notify on incidents, log the parent meeting and commitments | Parents dispute unrecorded verbal warnings | S |
| DS-05 | Counselling notes | Restricted-visibility notes by counsellor with access control | Sensitive; must not be visible to every teacher | M |
| DS-06 | Safeguarding / child-protection case file | Highly restricted case records with strict access log and escalation path | Legal and ethical necessity once you hold data on minors | L |
| DS-07 | Behaviour analytics | Repeat offenders, hotspot times/locations, class-level trends | Turns discipline from reactive to preventive | S |
| DS-08 | Conduct feed into report card & certificates | Conduct grade derived from records, printed on report card and character certificate | Character certificates are legally issued on this basis | S |

---

## M19 — Health records

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| HL-01 | Medical profile | Allergies, chronic conditions, medications, disability, blood group, doctor contact | An allergy the school didn't know about is a life-safety failure | M |
| HL-02 | Immunization record | Vaccine schedule, doses received, due reminders | Required at admission in many jurisdictions; drives campaign reminders | S |
| HL-03 | Clinic / sick-bay visit log | Visit reason, treatment, outcome, sent-home decision, guardian notified | Liability record and a signal for chronic absence | S |
| HL-04 | Medicine administration | Dispensing log with guardian consent for prescribed medication | Administering medicine to a minor without a consent record is indefensible | S |
| HL-05 | Health screening & growth | Height, weight, BMI, vision, dental with trend charts | Routine annual screening most schools run and report to parents | M |
| HL-06 | Emergency protocol | Per-student instructions, consent to treat, hospital preference, insurance | The information needed in the first five minutes of an emergency | S |
| HL-07 | Confidentiality controls | Health data visible only to nurse, head and authorized staff | Health data is the most sensitive category the system will hold | M |
| HL-08 | Illness/absence surveillance | Aggregate illness reporting for outbreak detection and health-department returns | Post-COVID this is an expected capability and sometimes a mandate | S |

---

## M20 — Certificates & official documents

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| CT-01 | Certificate template designer | WYSIWYG templates with merge variables, logo, signatures, watermark | Every school wants its own wording and layout | M |
| CT-02 | School leaving / transfer certificate | SLC/TC with statutory serial, register entry, dues clearance gate, duplicate control | The single most-demanded document; legally required and serially registered | M |
| CT-03 | Character certificate | Conduct-based certificate drawing on discipline records | Required for onward admission and job applications | S |
| CT-04 | Bonafide / study certificate | Proof of current enrollment, on demand | Requested constantly for visas, bank accounts, scholarships | S |
| CT-05 | Fee & tax certificate | Annual fee-paid statement and advance-tax certificate | Peak demand every July; manual production is days of clerical work | S |
| CT-06 | Provisional result & marksheet reprint | Reissue of results and marksheets with duplicate marking | Lost documents are routine; duplicates must be marked as such | S |
| CT-07 | Staff service & experience certificate | Employment history certificate for departing staff | Standard exit deliverable, currently typed by hand | S |
| CT-08 | Verification QR & public verify page | Serial + QR that a third party can verify online | Combats forged school certificates, a real problem in the market | M |
| CT-09 | Issuance register & duplicate control | Log of every certificate issued, to whom, by whom, with reprint counts | Inspection artifact and forgery control | S |
| CT-10 | Batch issuance | Generate for a whole passing-out class at once | End-of-year peak; one-by-one is untenable | S |

---

## M21 — Alumni

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| AL-01 | Alumni registry | Passed-out students auto-converted to alumni with batch/year | Preserves the relationship instead of ending it at graduation | S |
| AL-02 | Alumni self-service profile | Alumni update contact, education, career | Contact data decays fast; self-service is the only sustainable path | M |
| AL-03 | Batch & reunion events | Year-group events, invitations, RSVP | The main reason alumni re-engage | S |
| AL-04 | Donations & fundraising | Pledges, receipts, campaign tracking, donor recognition | A revenue stream for trusts and non-profit schools | M |
| AL-05 | Mentorship / careers board | Alumni offer guidance, internships, jobs to current students | Genuine student-outcome value and a marketing asset | M |
| AL-06 | Alumni communications | Segmented newsletters and announcements | Reuses M16 infrastructure with a distinct audience | S |
| AL-07 | Outcome & placement analytics | Where graduates went: universities, fields, countries | The stat used in every admissions brochure; boards ask for it too | S |

---

## M22 — Analytics & dashboards

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| AN-01 | Role-based dashboards | Distinct home screens for owner, principal, coordinator, teacher, accountant, parent, student | The current dashboard shows book count, exam count and quota — nothing operational | M |
| AN-02 | Enrollment & retention analytics | Headcount by class/branch/session, joiners, leavers, churn and reasons | Enrollment is the business; churn is the leading indicator of trouble | M |
| AN-03 | Fee collection & aging | Collected vs expected, aging buckets, defaulter concentration, projection | Cash-flow management for the owner | M |
| AN-04 | Attendance analytics | Trends, chronic absentees, section/day patterns, staff punctuality | Drives intervention and payroll accuracy | S |
| AN-05 | Academic performance analytics | By class, subject, teacher, stream; term-over-term movement | The academic head's core instrument | M |
| AN-06 | Teacher workload & utilization | Periods taught, free periods, substitution load, marks-entry timeliness | Fair workload distribution and accountability | S |
| AN-07 | At-risk early warning | Composite score from attendance, marks trend, fee status, discipline | Turns four modules of raw data into an actionable list | M |
| AN-08 | Custom report builder | Filter/group/export without a developer | Every school asks for a report nobody anticipated | L |
| AN-09 | Scheduled report delivery | Email/WhatsApp a report on a schedule to named roles | The owner wants Monday numbers without logging in | S |
| AN-10 | Reporting data separation | Read replica or warehouse so heavy reports don't hit the transactional DB | Report queries over years of attendance will otherwise degrade the app | M |

---

## M23 — Parent, student & teacher mobile apps

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| MB-01 | Parent app | Attendance, fees + pay, homework, results, notices, bus tracking, messaging, multi-child | In this market the parent app *is* the product to the end user; the web app is not mobile-usable at all today | L |
| MB-02 | Student app | Timetable, homework, content, quizzes, results, notices | Secondary but expected for senior classes | L |
| MB-03 | Teacher app | Attendance, marks entry, homework post, substitution, leave, timetable | Teachers will not mark attendance on a laptop; adoption depends on this | L |
| MB-04 | Push notification infrastructure | Device registry, topics, FCM/APNs, deep links, delivery receipts | Push is far cheaper than SMS at scale and the economics matter | M |
| MB-05 | Mobile auth | OTP/phone login, PIN/biometric unlock, session management, multi-child switching | Parents cannot manage passwords; OTP is the only workable pattern | M |
| MB-06 | Offline caching | Timetable, homework, attendance queue available without network | Connectivity is intermittent for both teachers and parents | M |
| MB-07 | App store presence & release management | Store listings, review compliance, forced upgrade, staged rollout, white-label per school | Chains demand their own branded app in the store | L |
| MB-08 | In-app payments compliance | Route school fees through web/redirect flows to stay within store rules | Getting this wrong gets the app removed | M |
| MB-09 | Deep links from SMS/WhatsApp | Message links open the exact screen (invoice, result, notice) | Massively improves conversion from notification to action | S |

---

## M24 — Government & board reporting compliance (Pakistan)

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| GC-01 | Board candidate registration export | FBISE/BISE registration and enrolment data in prescribed file/format per class 9/11 | A missed or malformed registration blocks students from sitting the board exam | L |
| GC-02 | Board exam fee handling | Collect board fees from students, reconcile, prepare the board's submission schedule | Schools collect and remit these; errors are the school's liability | M |
| GC-03 | Provincial EMIS / SEMIS / ASC returns | Annual school census returns with enrollment, staff, facility data in the department's schema | Legally mandated; non-filing risks registration status | L |
| GC-04 | School registration & renewal tracking | Registration certificate, NOC, renewal dates, inspection reports, document vault | Expiry without renewal means operating illegally | S |
| GC-05 | Identity data validation | NADRA B-form/CNIC format and check-digit validation, duplicate detection | Board and EMIS submissions reject malformed identity numbers en masse | S |
| GC-06 | Teacher registration & qualification returns | Teacher counts, qualifications, licensing status in prescribed format | Part of census returns and inspection checklists | M |
| GC-07 | Statutory registers | GR register, attendance register, fee register, leaving-certificate register, stock register — in prescribed layout | These are what an inspector physically asks to see | L |
| GC-08 | Fee regulation compliance | PSRA-style increase caps, mandatory fee-schedule disclosure, change audit trail | Provincial regulators fine and order refunds for violations | M |
| GC-09 | Labour & social compliance | Minimum wage checks, EOBI and provincial social-security contributions and filings | Employer obligations with real penalties | M |
| GC-10 | Tax compliance | Income-tax withholding on salaries, advance tax on fees, withholding statements and certificates | FBR filing obligations tied directly to payroll and fee modules | L |
| GC-11 | Safeguarding policy records | Staff police verification, child-protection policy acknowledgement, training records | Increasingly checked by regulators and demanded by parents | M |
| GC-12 | Data protection & minor consent | Lawful-basis records, consent, retention schedules, subject-access and erasure handling | Pakistan's data-protection regime is tightening; minors' data is the highest-risk category | M |
| GC-13 | Inspection & visit log | Record of departmental/board visits, observations, corrective actions | Demonstrates responsiveness at the next inspection | S |

---

## M25 — Integrations & extensibility

| ID | Item | What it is | Why it matters | Eff |
|---|---|---|---|---|
| IN-01 | Public API + API keys | Documented REST/GraphQL with scoped keys and rate limits | Chains and partners integrate; also unblocks the mobile apps cleanly | M |
| IN-02 | Webhooks | Outbound events (payment received, student admitted, result published) | Lets schools wire their own automations without custom work | S |
| IN-03 | SSO for students/staff | Google Workspace / Microsoft 365 federation | Most schools already have Google Workspace for Education | M |
| IN-04 | Biometric device SDK integration | ZKTeco and similar device push/pull, user enrollment sync | Schools already own the hardware; this is a procurement precondition | L |
| IN-05 | Payment gateway adapters | JazzCash, EasyPaisa, 1LINK/Kuickpay, HBL/bank APIs, card processors | Each has its own reconciliation semantics; a generic adapter layer is required | L |
| IN-06 | SMS/WhatsApp gateway adapters | Local aggregators, masking/sender-ID registration, WhatsApp BSP onboarding | Sender-ID registration is a multi-week external process, not a code task | M |
| IN-07 | Accounting export | QuickBooks/Tally/Xero-compatible journal export | Accountants will not abandon their existing books | M |
| IN-08 | Classroom / conferencing integration | Google Classroom, Zoom, Meet linked to timetable and sections | Blended learning baseline | M |
| IN-09 | Migration toolkit | Importers for competitor exports and Excel legacy data, with mapping and reconciliation | Every deal is won or lost on "can you bring our five years of data across" | L |
| IN-10 | Hardware printing support | Thermal receipt printers, card printers, barcode scanners | Fee counters and library desks run on this hardware | M |
| IN-11 | Per-school data export & portability | Full-fidelity export of a school's own data on demand | Contractual and regulatory expectation; the existing org export covers only exam data | M |
| IN-12 | Demo/sandbox seeding | Realistic demo school with data, resettable | Sales demos and onboarding training depend on it | S |

---

## Rollup

| Module | Items | Rough weight |
|---|---|---|
| M0 Foundations | 20 | Blocking — nothing else ships first |
| M1 Multi-campus | 7 | M–L |
| M2 Academic structure | 15 | Blocking for M3–M11 |
| M3 Admissions | 12 | M |
| M4 Student info | 16 | Blocking, largest single gap |
| M5 Guardians | 9 | Blocking for M16, M23 |
| M6 Staff HR & payroll | 17 | L, effectively its own product |
| M7 Timetable | 11 | L |
| M8 Attendance | 13 | M–L, highest daily usage |
| M9 Fees & finance | 22 | L, highest commercial value |
| M10 Examinations | 23 | L, only module the current code touches |
| M11 Homework & LMS | 10 | M |
| M12 Library | 11 | M |
| M13 Transport | 11 | M–L |
| M14 Hostel | 11 | M |
| M15 Inventory | 9 | M |
| M16 Communication | 11 | L, blocking for perceived value |
| M17 Notices & events | 8 | S–M |
| M18 Discipline | 8 | M |
| M19 Health | 8 | M |
| M20 Certificates | 10 | M |
| M21 Alumni | 7 | S–M |
| M22 Analytics | 10 | M–L |
| M23 Mobile apps | 9 | L, three separate apps |
| M24 Gov/board compliance | 13 | L, market-entry gating |
| M25 Integrations | 12 | L |
| **Total** | **~213 items** | |

**Critical-path ordering.** F-01/F-02/F-03/F-05/F-07/F-09/F-11 → M2 (sessions, classes, sections, subjects) → M4 (student + enrollment) → M5 (guardian) → M8 (attendance) + M9 (fees) → M16 (communication) → M23 (parent app) → M10 (results/report cards) → everything else. Nothing in M3–M24 can be built before M2 and M4 exist, and M16 gates the perceived value of M8, M9, M10 and M23 simultaneously.

**Architectural warning for the backlog owner.** Three current design choices make all of the above materially more expensive if not changed first: (a) two-role enum with authorization by `org_id` alone — an ERP needs ~15 roles and field-level visibility for health, discipline and payroll; (b) no RLS, so tenancy is one forgotten `where` clause from a breach across student PII; (c) no `person` abstraction, so student/guardian/staff identity will fork into three incompatible shapes if M4/M5/M6 are built independently. Fix F-01, F-02 and F-03 before writing the first student table.

---

# Part 3 — Platform gaps blocking multi-tenant SaaS sales

## Verified baseline (what I actually checked, not what the docs claim)

| Claim | Evidence |
|---|---|
| Zero tests, zero test tooling | `find` for `*.test.*`/`*.spec.*`/vitest/jest/playwright configs → **0 files**. `turbo run test` has no implementation → `pnpm test` exits 0 having run nothing |
| No CI | no `.github/` directory at all |
| Observability is env-var theater | `SENTRY_DSN`, `NEXT_PUBLIC_POSTHOG_KEY` declared in `apps/web/lib/env.ts:32-33` and `turbo.json`; **zero references anywhere else in the codebase**. Logging is bare `console.*` (12 sites in `apps/worker/src/index.ts` alone), no logger lib, no request/correlation IDs |
| Nothing exists for | `audit`, `stripe`, `billing`, `invoice`, `subscription`, `feature flag`, `impersonat*`, `saml/oidc/scim`, `i18n/locale`, `otel/datadog`, `webhook` → **0 occurrences each** across all `.ts/.tsx/.sql/.json/.mjs` |
| `plan` column is dead | `organizations.plan` declared at `packages/shared/src/db/schema.ts:26`, **never read, never written** anywhere |
| Limits are unsettable | `monthlyExamLimit`/`monthlyCostCapUsd` read only in `apps/web/lib/quota.ts:33-34`; no code path writes them — changing a customer's plan requires manual SQL |
| No backup/DR story | `DEPLOY.md` covers deploy only; documents that free Supabase **auto-pauses after ~7 days idle** |
| Migrations are manual | `DEPLOY.md`: "Vercel does NOT run migrations automatically"; 7 migrations on disk |
| No security headers | `apps/web/next.config.mjs` sets none |
| Legal work landed but unfinished | `(legal)/privacy/page.tsx` is banner-marked **"TEMPLATE — not legal advice"** with live `[add contact email]` / `[add date before launch]` placeholders, and tells users to email to delete an org when self-serve delete already exists |

Effort scale: **S** ≤ 1 week · **M** 2–4 weeks · **L** 1–3 months, one engineer.

---

## Tier 0 — sell nothing until these exist

### 1. Testing strategy · **L** (but **S** to first real safety net)
**What:** Any automated test. There are none, and `pnpm test` returns green, which is worse than returning red.
**Why it blocks:** You auto-grade student work with an LLM and have zero regression tests on the grader — while the audit confirms the grading denominator comes from the LLM's reply rather than the answer key, and garbage grader output is stored as a successful 0/0. A school cannot buy a system that silently mis-scores a child, and you cannot honestly sell one. It also gates everything below: you cannot safely add RLS, RBAC, or billing to an untested 25-route surface.
**Minimum:** cross-tenant isolation tests (every route, wrong-org token → 404), a golden-set grader eval with known-correct marks, quota/rate-limit tests. Then CI on push.

### 2. Audit logging · **M**
**What:** Append-only record of who did what, when, from where. Currently zero.
**Why it blocks:** Two concrete school scenarios. (a) **Paper leak** — an exam paper escaping before exam day is a school's nightmare; you have shuffled anti-leak versions but no record of who exported which paper when, so a leak is uninvestigable. (b) **Grade tampering** — `PATCH /api/submissions/[id]` overwrites a student's marks; `reviewed_by`/`reviewed_at` capture only the *latest* editor, so prior values are destroyed with no history. Any grade dispute is unresolvable. Exam controllers will ask about both in the first meeting.

### 3. Tenant isolation model · **M**
**What:** Isolation is app-level only — every query manually filters `orgId`; no RLS.
**Why it blocks:** One missing `.where(eq(orgId))` across ~25 routes leaks another school's exam papers, and nothing would catch it: no tests, no lint rule, no DB backstop. Existing confirmed defects show the model already leaking — the `org_<orgId>/` storage guard is bypassable with `..` segments, and the worker trusts `orgId` from the job payload without verifying it against the row.

**RLS verdict — yes, but third, and it is not sufficient alone.**
The decisive point: **RLS only protects one of your three data stores.** Supabase Storage is accessed with `SUPABASE_SERVICE_ROLE_KEY`, which bypasses RLS entirely; Pinecone namespaces have no RLS concept at all. Turning on RLS and declaring isolation "solved" would be a false claim in a security questionnaire.

Sequence instead:
1. **Tests first** (item 1) — proves isolation and keeps it proven.
2. **Mandatory scoped-query helper** — a repository layer where `orgId` is a required argument, so unscoped access is a type error rather than a code-review miss. Highest leak-prevention per unit of effort.
3. **RLS as defense-in-depth** — real but costly here: `DEPLOY.md` puts Vercel on the Supabase **transaction pooler (6543)**, so session-level `SET` is unsafe and every query must run inside a transaction with `SET LOCAL app.org_id`. Also needs a dedicated non-owner role plus `FORCE ROW LEVEL SECURITY`, since the table owner bypasses policies.
4. **Path-normalise storage keys** and re-derive `orgId` in the worker from the DB row.

---

## Tier 1 — procurement will stop you here

### 4. RBAC beyond one role column · **M**
**What:** Exactly two roles (`admin`, `teacher`), enforced in only three places (`/api/org` DELETE, `/api/org/export`, `/settings/account`). Everything else authorises on `orgId` alone.
**Why it blocks:** In a 40-teacher school, **every teacher can export every exam, delete any textbook, wipe the question bank, and rewrite any student's grade.** Schools have a real hierarchy — exam controller, HoD, subject teacher, principal (read-only) — and will not accept flat access. Compounded by there being no member-management UI at all: no invite, no removal (and removal is a confirmed defect — membership is never revoked, so a departed teacher keeps full access).

### 5. Admin/support console + impersonation · **M–L**
**What:** No internal tooling. Supporting a customer today means running SQL against production.
**Why it blocks:** Direct production SQL is itself a finding on any security review, and it is the only way to change a plan (see item 7) or unstick a job. Impersonation must be consent-gated, time-boxed, and written to the audit log — which is why item 2 comes first.

### 6. GDPR / data deletion · **M** *(partially landed — verified)*
**Landed:** legal pages, admin-only org JSON export, org delete (cascades DB + Storage + Pinecone namespaces), opt-in nightly retention purge.
**Gaps:** privacy policy still carries its `TEMPLATE`/`[add contact email]` placeholders and contradicts the shipped self-serve delete; **no DPA and no sub-processor page**; deletion is all-or-nothing at org level — no way to delete one teacher or **one student** on a parent request; retention is off unless `SUBMISSION_RETENTION_DAYS` is set; `users` rows and the Clerk identity survive org deletion; no deletion-from-backups story; export is raw JSON, not a portability format.
**Why it blocks:** The school is the **controller**, you are the **processor** — they must be able to service *their* parents' erasure requests through you, and they will require a signed DPA before uploading a single minor's answer sheet. Right now a "delete my child's data" request can only be honoured by deleting the whole school.

### 7. Billing / subscriptions / invoicing · **L**
**What:** No payment integration, no self-serve plan change; `plan` is a dead column.
**Why it blocks:** No revenue path. Note the market specific: Pakistani schools typically pay **annually by bank transfer against a purchase order**, not by card — so Stripe self-serve alone is insufficient. You need quotes, POs, invoices with tax details, and manual plan assignment via the admin console (item 5).

### 8. SSO · **S–M** *(OAuth)* / **M** *(SAML + SCIM)*
**What:** Clerk email/password only.
**Why it blocks:** Schools run Google Workspace for Education or Microsoft 365 Education near-universally; IT will require staff sign in with existing accounts and, critically, that **deprovisioning a leaver removes access**. Today it does not (confirmed defect). Google/Microsoft OAuth is largely Clerk configuration plus domain-verified auto-join to the correct org; SCIM is the piece that actually fixes deprovisioning at district scale.

### 9. Data residency · **L**
**What:** No residency controls. The privacy policy already concedes cross-border processing.
**Why it blocks:** The hard problem is **OpenRouter routes to arbitrary underlying model providers, so you cannot produce a deterministic sub-processor list** — that fails any serious DPIA, and Cambridge-affiliated and elite private schools do ask. Textbook text *and scanned children's answer sheets* leave the country. You also have no zero-retention/no-training commitment from downstream providers to point at. Fixing this means pinned providers with contractual terms, and possibly regional deployment.

### 10. Backups & PITR · **S** *(enable)* / **M** *(tested restore)*
**What:** Nothing anywhere in the repo or docs.
**Why it blocks:** "What is your RPO/RTO" is a standard procurement question you currently cannot answer. Worse, the free Supabase tier **auto-pauses after ~7 days idle** — documented in your own `DEPLOY.md` — which is a data-availability incident waiting for a school holiday. Note the cross-store problem: Postgres, Storage, and Pinecone would each restore to different points in time, so you need a reconciliation procedure, not just snapshots. A backup you have never restored is not a backup.

### 11. Uptime SLOs · **S** *(define)* / **M** *(measure)*
**What:** No SLO, no measurement, no status page. `/api/health` exists but nothing consumes it.
**Why it blocks:** Contracts want a number with service credits. Free Vercel/Render/Supabase tiers cannot support any commitment — and downtime during exam week is not a degraded experience, it is a school's operations stopping.

---

## Tier 2 — will break you shortly after the first deal

### 12. Observability · **M**
Env vars validated and ignored; `console.*` only, no structured logs, no correlation IDs, no traces, metrics, or alerts. You cannot answer "why did this school's paper fail at 11pm the night before the exam" — you will not even know it happened until they email. Nothing pages anyone.

### 13. Incident response · **S–M** *(mostly process)*
No on-call, severity definitions, runbooks, status page, or customer-comms templates. Schools ask; and the one week you need it most is the week everything is load-bearing.

### 14. Background job visibility · **S–M**
BullMQ with no dashboard and no admin view of queue depth, failures, or retries. Confirmed defect: a worker restart mid-job strands books and submissions in `processing` **forever with no recovery path** — the teacher sees a spinner and support has no way to look, let alone requeue. `exam-export` is declared with no consumer. `bull-board` behind admin auth is the cheap first 80%.

### 15. Load testing · **M**
Never done; behaviour at 200 teachers unknown. Exam generation is inherently spiky — a whole school generates papers in the same week. Known landmines: PDF export renders up to 6 PDFs inline in a serverless function, `WORKER_CONCURRENCY` defaults to 2, list endpoints have no pagination, and org export buffers every exam and submission into one string.

### 16. Migration / zero-downtime deploys · **M**
Manual `drizzle-kit migrate` against the direct URL, not run by Vercel, no CI gate, no rollback plan, no expand/contract discipline, no advisory lock against concurrent runs. A botched migration during term is a total outage with no documented way back.

### 17. Rate limiting & abuse · **S–M** *(partially landed)*
**Landed:** Redis fixed-window per-org limits across 10 routes; monthly exam-count and USD cost caps.
**Gaps:** limits are **per-org only**, so one teacher can exhaust the whole school's window; fixed windows allow 2× bursts at the boundary; no IP or global limit; **unauthenticated `/api/health` runs a Postgres query and a Redis ping on every request with no limit** (trivial amplification); no limit on the exam `PATCH` that writes unbounded payloads; no signup abuse controls. Confirmed defects make the cost cap structurally unreliable: book ingest and rechunk spend LLM money with no quota check and record no cost, failed-after-billing calls are excluded from accounting, and the quota check is check-then-act with no reservation. When Redis is down, `rateLimit` throws into `apiError` and users get an opaque 400.

### 18. Usage metering · **M** *(partially landed)*
**Landed:** `generations` records model, tokens, latency, and cost per call.
**Gaps:** the most expensive operation in the product — book ingest/OCR — is never recorded; failed calls are dropped; the default rerank model is missing from `PRICING` so rerank bills at Sonnet rates; no per-teacher/per-seat rollup, no admin usage UI beyond a dashboard counter, no finance export. You cannot invoice on usage you do not measure, and you cannot price seats you do not count.

### 19. Onboarding / self-serve signup · **M**
Clerk signup works and auto-provisions a personal workspace, but there is no org-creation UX, no invite flow, no bulk import, and no guided first run. A school arrives with 30 teachers and there is no way to get them in. Confirmed defect: auto-provisioned personal workspaces have **no admin at all**, so export and deletion are permanently 403 for solo users — your entire self-serve funnel lands in a workspace that cannot exercise its own data rights.

### 20. Feature flags · **S** *(DB-backed)* / **M** *(vendor)*
None. The compelling case is a **kill switch**: if the LLM grader starts mis-scoring during exam week, you need to disable it in seconds without a deploy. Also needed to pilot with one school and to gate unfinished surfaces (DOCX is in the `export_format` enum with no renderer behind it).

### 21. i18n · **M–L**
UI is English-only. The product already generates Urdu and mixed-language papers (`language: en | ur | mixed`) while the interface around them is English-only — an obvious gap for government and semi-government schools. **RTL is the expensive part**, and the shell is already fragile (fixed 240px sidebar, no mobile nav). Related confirmed defect: the copyright guard is a total no-op on Urdu/Arabic script, so the Urdu path is less safe than the English one.

---

## Recommended sequence

1. **CI + tests** — isolation suite and grader golden set. Everything else is unsafe to build without it, and it converts a false green into a real signal.
2. **Fix the confirmed auth defects** — admin latch, membership revocation, adminless personal workspaces. Cheap, and items 4/5/8 all build on them.
3. **Audit log** — a prerequisite for impersonation, grade disputes, and leak investigation.
4. **Scoped-query layer, then RLS** — plus path-normalised storage keys and worker-side `orgId` re-derivation, since RLS covers only one of three stores.
5. **Observability + backups/PITR + job visibility** — the "can you operate this" tier.
6. **RBAC + member management + SSO** — the "can a real school use this" tier.
7. **Billing + metering + admin console** — the "can you get paid" tier.

Items 1–3 are the honest gate on a first paid pilot. Item 9 (data residency) is the one that may not be solvable at your current architecture without changing model providers — worth qualifying prospects on it early rather than discovering it in their DPIA.

---

# Part 4 — Supabase architecture assessment

# Supabase assessment for the school-management product

**Bottom line:** Supabase is the right substrate for the *data plane* (Postgres + RLS + Auth + Storage) and the wrong substrate for the *compute plane* (OCR, LLM generation, PDF rendering, queue workers). Build on Supabase, keep a container worker. Do not attempt a lift-and-shift of Seena's auth model — Clerk Organizations is the one piece with no Supabase equivalent, and porting `requireSession()`'s shape would reimplement three of the confirmed high-severity defects as architecture rather than as bugs.

---

## 1. Stack mapping

### Maps cleanly (do it)

| Current | Supabase | Notes |
|---|---|---|
| Self-hosted Postgres 16 (`infra/docker-compose.yml`) | Supabase Postgres | Same engine. Drizzle migrations run unchanged. |
| Supabase Storage bucket `books` | Supabase Storage | **Already Supabase.** `apps/web/lib/storage.ts` is a thin service-role wrapper — zero migration cost. |
| Drizzle + `postgres.js` | Drizzle on Supabase | Works, with two mandatory changes (below). |
| `retention` cron (`0 3 * * *`) | `pg_cron` | Only as a *trigger* that enqueues — see §5. |
| Redis fixed-window rate limit | — | Keep Redis (Upstash). Do not move counters into the OLTP DB. |

### Maps with real work

| Current | Supabase | The work |
|---|---|---|
| Clerk Auth | Supabase Auth | See §2. Orgs, roles, invites, and the whole membership model are yours to build. |
| Clerk Organizations | *nothing* | No equivalent. Custom tables + custom access token hook. |
| Pinecone (per-org namespaces, 3072-d) | pgvector | Indexable only via `halfvec` at 3072 dims. See §4. |
| BullMQ retry/backoff semantics | pgmq (Supabase Queues) | pgmq gives visibility timeout + archive. It does **not** give per-attempt exponential backoff, stalled-job recovery, `lockDuration`, concurrency control, or graceful drain — all four of which `apps/worker/src/index.ts` relies on (`LONG_JOB_OPTS = { lockDuration: 600_000, stalledInterval: 60_000 }`). |

### Does not map — keep off Supabase

- **Vision OCR / Document AI ingest** (10-minute lock duration is a declared design constraint).
- **Exam generation** (multi-minute LLM calls, `@anthropic-ai`/OpenRouter streaming).
- **`@react-pdf/renderer` export** (already a defect running inline in a Next route; Edge Functions explicitly do not support Node libs needing multithreading, and cap at 256MB).
- **BullMQ itself.** Queue churn (insert→lock→delete per job) in the same Postgres that serves 8:00am attendance roll-call is a self-inflicted autovacuum problem.

---

## 2. Clerk → Supabase Auth: the specific risks

### 2.1 There is no organization primitive. This is the whole risk.

`apps/web/lib/auth.ts` gets `{ userId, orgId, orgRole }` free from Clerk on every request. Supabase Auth gives you `auth.uid()` and nothing else. Everything else — orgs, membership, role, active-tenant selection, invitations, revocation — becomes application code you own.

That is arguably an *improvement*, because three confirmed high/medium defects are all consequences of Clerk-shape drift:

- admin role latch (stored role OR'd, never demoted)
- membership never revoked
- personal-mode picks an arbitrary historical membership via unordered `LIMIT 1`

Under a memberships table you control, all three become a single `where revoked_at is null` predicate. **Do not port "personal mode."** For a school product, an org must be explicitly provisioned; auto-creating `"<name>'s Workspace"` on first login is how you get orphan tenants with no admin (the third defect).

### 2.2 Custom claims: the hook is in the login critical path

Claims are injected by a Postgres function invoked by GoTrue on every sign-in *and every refresh*:

```sql
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb language plpgsql stable
security definer set search_path = '' as $$
declare
  claims jsonb := event->'claims';
  m record;
begin
  select m2.school_id, m2.campus_ids, m2.school_role
    into m
  from public.active_membership m2                    -- view: one row per user
  where m2.user_id = (event->>'user_id')::uuid;

  if m.school_id is not null then
    claims := jsonb_set(claims, '{school_id}',   to_jsonb(m.school_id));
    claims := jsonb_set(claims, '{school_role}', to_jsonb(m.school_role));
    claims := jsonb_set(claims, '{campus_ids}',  to_jsonb(coalesce(m.campus_ids,'{}'::uuid[])));
  end if;                                              -- fail CLOSED: no claim = no access
  return jsonb_set(event, '{claims}', claims);
end $$;

grant execute on function public.custom_access_token_hook to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook from authenticated, anon, public;
```

Four risks, all concrete:

1. **It is a global SPOF.** If this function raises, *nobody* can log in or refresh. It must be a single indexed lookup, and it must never throw. Fail closed (omit the claim), never fail open.
2. **Claims are stale for the token TTL.** Default 3600s. A teacher fired at 09:00 keeps a valid `school_role: 'teacher'` token until 10:00. This is the admin-latch defect *reintroduced as physics*. Mitigations: drop JWT TTL to 300–900s (accept the refresh traffic), and for genuinely destructive operations (bulk delete, fee ledger writes, result publication) re-check membership against the table server-side rather than trusting the claim.
3. **`user_metadata` is user-writable** via `supabase.auth.updateUser()`. Any tenancy claim placed there is a self-service privilege escalation. Claims must be top-level (from the hook) or in `app_metadata`. Write this into the code review checklist.
4. **No `setActive()`.** Clerk switches active org client-side. Supabase has no equivalent — switching school means writing `active_school_id`, then `supabase.auth.refreshSession()` to re-mint. There is a window where the old claim is still valid; a group-admin can act in the wrong school. Guard writes with an explicit school check, not just the claim.

**Do not put `class_ids` or `student_ids` in the JWT.** They are unbounded, and Supabase stores the session in cookies that chunk past 4KB. `school_id` + `school_role` + a *bounded* `campus_ids` (cap at ~20, else omit and fall back to a table lookup) is the entire budget.

### 2.3 User migration

- **Password hashes.** Clerk does not hand you bcrypt hashes on the self-serve plan; it's a support/enterprise request. Plan for one of: (a) negotiate the hash export and bulk-insert into `auth.users.encrypted_password` (Supabase accepts bcrypt/argon2), (b) force a password reset for the whole base at cutover, or (c) dual-run and lazily migrate on first login. **(c) requires your code to touch plaintext passwords** — I'd rather do (b) for a product this early than build that.
- **Social/OAuth users migrate by verified email only.** Matching on unverified email is an account-takeover vector. Verify `email_verified` on both sides or don't match.
- **MFA enrollments do not migrate at all.** Everyone re-enrolls.
- **Every session dies at cutover.**
- **Make `public.users.id = auth.users.id`.** Today the schema has a surrogate `users.id uuid` plus `clerk_id text unique`. Keep the surrogate and you pay a join inside every RLS policy forever. Backfill so `auth.uid()` *is* the FK, `id uuid primary key references auth.users(id) on delete cascade`, and drop `clerk_id` post-cutover.
- **Email deliverability.** Supabase's built-in SMTP is rate-limited to a couple of emails per hour. A school product onboarding parents in bulk will silently drop invites. Wire Resend/SES on day one, before the first invite ships.

### 2.4 Scale/pricing landmine specific to schools

Parents and students are the majority of accounts and the minority of logins. If every student gets an `auth.users` row you buy MAU for a population that signs in twice a term. **Recommendation:** students and parents are *domain rows*, not auth users, until there is a portal that justifies them. When the portal ships, give guardians accounts and keep students as records — which also aligns with the existing `/privacy` guidance about roll numbers over names.

---

## 3. RLS as the tenant-isolation mechanism — yes, with conditions

**Verdict: yes, mandatory.** Seena's model ("every query filters `orgId`") is one forgotten `where` clause from a cross-tenant leak, and the audit already found the storage-key equivalent (`..` traversal bypassing the `org_<orgId>/` guard). A school product holds attendance, discipline records, fee ledgers and minors' data. The isolation boundary has to be in the database.

But RLS is the **floor, not the only gate**, and it only works if you fix the connection role first.

### 3.1 The Drizzle problem (fix this before writing a single policy)

Supabase's `postgres` role has `BYPASSRLS`. `DATABASE_URL` pointing at it means **every policy you write is inert.** Two changes:

```sql
create role app_web login password '…' nobypassrls noinherit;
grant authenticated to app_web;
alter role app_web set role to 'authenticated';   -- default to the RLS-bound role on connect
```

```ts
export function withTenant<T>(jwt: string, fn: (tx: Tx) => Promise<T>) {
  return db.transaction(async (tx) => {
    await tx.execute(sql`select set_config('request.jwt.claims', ${jwt}, true)`); // true = LOCAL
    return fn(tx);
  });
}
```

The `alter role … set role` line is the important one: it makes a *forgotten* `withTenant` fail closed (`auth.uid()` is null → policies deny) instead of fail open. Also: `postgres.js` needs `prepare: false` behind Supavisor transaction pooling, and `SET LOCAL` is only safe inside an explicit transaction there.

**And: `service_role` bypasses RLS entirely.** Today `supabaseAdmin()` in `lib/storage.ts` is service-role. In the school product, service-role belongs in the worker and in explicitly-audited admin paths only. Every service-role call site in a request handler is an RLS hole.

### 3.2 Claim design

```json
{
  "sub": "…", "role": "authenticated", "exp": …,
  "school_id":   "8f1e…",
  "school_role": "owner|principal|campus_admin|teacher|accountant|guardian",
  "campus_ids":  ["a1…", "b2…"]
}
```

Design rules: flat top-level scalars, so the policy predicate is a plain equality against an indexed column and the planner can use the index. No arrays deeper than `campus_ids`. Nothing below campus level.

Helpers, each `stable` so they collapse into an initPlan:

```sql
create or replace function public.jwt_school_id() returns uuid
language sql stable as $$ select nullif(auth.jwt() ->> 'school_id','')::uuid $$;

create or replace function public.jwt_role() returns text
language sql stable as $$ select auth.jwt() ->> 'school_role' $$;

create or replace function public.my_class_ids() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(ct.class_id), '{}')
  from public.class_teachers ct
  where ct.teacher_id = (select auth.uid())
    and ct.school_id  = public.jwt_school_id()
    and ct.ends_on is null
$$;
create index on public.class_teachers (teacher_id, school_id) include (class_id) where ends_on is null;
```

**Always wrap `auth.*` calls in a scalar subselect inside policies** — `(select public.jwt_school_id())`. Unwrapped, Postgres re-evaluates per row; wrapped, it becomes an InitPlan evaluated once. On a 5M-row attendance table this is the difference between 8ms and 8s.

### 3.3 Denormalize the hierarchy, then make it unforgeable

Every row-level table carries `school_id`, `campus_id`, `class_id` — the policy must never traverse `student → class → campus → school`. That's the same instinct as the current `org_id`-everywhere schema, and it's correct. The part Seena is missing is that denormalized tenancy columns can *drift*, and a drifted `school_id` is a silent leak. Pin them with composite FKs:

```sql
alter table public.classes  add constraint classes_uk  unique (id, school_id, campus_id);
alter table public.students add constraint students_uk unique (id, school_id, campus_id, class_id);

alter table public.attendance
  add constraint attendance_student_fk
  foreign key (student_id, school_id, campus_id, class_id)
  references public.students (id, school_id, campus_id, class_id) on delete restrict;
```

Now it is *impossible* to write an attendance row whose `school_id` disagrees with its student's.

### 3.4 The policy shape

```sql
alter table public.attendance enable row level security;
alter table public.attendance force  row level security;

create policy attendance_select on public.attendance
for select to authenticated
using (
  school_id = (select public.jwt_school_id())            -- cheap, indexed, first
  and (
       (select public.jwt_role()) in ('owner','principal')
    or ((select public.jwt_role()) = 'campus_admin'
        and campus_id = any ((select array(
              select jsonb_array_elements_text(auth.jwt() -> 'campus_ids')))::uuid[]))
    or ((select public.jwt_role()) = 'teacher'
        and class_id = any ((select public.my_class_ids())))
    or ((select public.jwt_role()) = 'guardian'
        and exists (select 1 from public.guardian_students gs
                    where gs.guardian_id = (select auth.uid())
                      and gs.student_id  = attendance.student_id
                      and gs.revoked_at is null))
  )
);
```

Writes get their own policy, and **never trust a client-supplied `school_id`**:

```sql
alter table public.attendance
  alter column school_id set default (nullif(auth.jwt() ->> 'school_id','')::uuid);

create policy attendance_insert on public.attendance
for insert to authenticated
with check (
  school_id = (select public.jwt_school_id())
  and (select public.jwt_role()) in ('owner','principal','campus_admin','teacher')
  and ((select public.jwt_role()) <> 'teacher' or class_id = any ((select public.my_class_ids())))
);
```

Separate `for select` / `for insert` / `for update` / `for delete` policies — never one `for all`. `update` needs both `using` (rows you may target) and `with check` (rows you may produce), or a teacher can move a student into another campus.

Indexes for every policy column (per your own standing rule):

```sql
create index on public.attendance (school_id, class_id, taken_on desc);
create index on public.attendance (school_id, student_id, taken_on desc);
create index on public.guardian_students (guardian_id, student_id) where revoked_at is null;
```

At district scale, partition `attendance` by `range (taken_on)` — RLS composes with partition pruning fine, and it makes the retention purge a `detach partition` instead of the row-by-row delete the current retention job does.

### 3.5 Storage RLS closes the traversal defect for free

```sql
create policy school_reads_own on storage.objects
for select to authenticated
using (
  bucket_id = 'school-files'
  and (storage.foldername(name))[1] = (select auth.jwt() ->> 'school_id')
);
```

This checks the *stored object path*, not a client-supplied string, so the `..`-segment bypass found in `POST /api/books` cannot exist. This alone justifies moving off service-role-for-everything.

---

## 4. pgvector vs Pinecone

**Verdict: pgvector — but only after fixing two things the current design gets wrong.**

**Blocker 1 — dimensions.** `text-embedding-3-large` at 3072-d cannot be indexed by pgvector's `vector` type (HNSW/IVFFlat cap at 2000 dims). You have two options:

```sql
-- (a) halfvec: indexable to 4000 dims, 2 bytes/dim instead of 4
alter table chunk_embeddings add column embedding halfvec(3072);
create index on chunk_embeddings using hnsw (embedding halfvec_cosine_ops)
  with (m = 16, ef_construction = 64);
```
```
-- (b) better: Matryoshka-truncate at the API (dimensions: 1024) and use vector(1024)
```

I'd take (b). 3072 dims buys marginal recall on textbook chunks and costs 3× storage, 3× index memory, and 3× query time. Re-embedding at 1024 also gives you a clean cutover point.

**Blocker 2 — the corpus is duplicated per tenant.** `pineconeNamespace(orgId, model)` gives every org its own copy of what is, in Pakistan, a *national* corpus: Punjab Board Physics 9 is byte-identical across every school that uploads it. At 1000 schools × 50 books × 1500 chunks that's 75M vectors of ~99% duplication. Under Pinecone you pay for it repeatedly; under pgvector it simply doesn't fit.

Fix the model, not the vendor: a `school_id`-nullable embeddings table where `null` means *shared curriculum corpus*, plus per-school private uploads. That collapses the vector count by 2–3 orders of magnitude and makes pgvector comfortable:

```sql
create policy chunk_emb_read on public.chunk_embeddings
for select to authenticated
using (school_id is null or school_id = (select public.jwt_school_id()));
```

**The one thing to watch:** RLS and ANN compose badly. An HNSW scan returns its top-K *before* the RLS filter applies, so a tenant-filtered search silently returns fewer than K rows. pgvector 0.8+ fixes this with iterative scans — set it, and verify recall:

```sql
set hnsw.iterative_scan = 'relaxed_order';
set hnsw.max_scan_tuples = 20000;
```

**Keep Pinecone if:** you exceed ~20–50M live vectors, or you want vector index maintenance (HNSW builds are `maintenance_work_mem`-hungry and I/O heavy) off the box that serves attendance. For a school-management product where RAG is a *secondary* feature, keeping it off the OLTP instance has real merit — but the answer then is "a separate Postgres with pgvector," not Pinecone. One vendor fewer, same isolation.

Put embeddings in their own table (not on `chunks_meta`), so vacuum and index rebuilds don't touch hot rows. And note that `chunks_meta.chunking_id` has no FK today — fix that during the move, or you carry the orphan-chunks defect into the new product.

---

## 5. What must NOT run on Supabase

Confirmed limits (Supabase docs, Edge Functions): **256MB memory, 400s wall clock on paid / 150s free, 2s CPU per request, no Web Worker or Node `vm` API, no multithreaded native libs (`sharp`, `libvips` explicitly named).**

| Workload | Why not | Where instead |
|---|---|---|
| Vision OCR over scanned PDFs | The worker declares `lockDuration: 600_000` — 10 min. 25× the wall clock, and the CPU budget is 2s. | Container worker (Render/Fly/ECS). |
| `pdf-lib` / `pdf-parse` page loops | A 200-page scanned PDF in a 256MB isolate is an OOM, not a maybe. `pdf-parse` is CPU-bound, not I/O-bound — the 2s CPU limit bites immediately. | Same worker. |
| `@react-pdf/renderer` export | Node-specific, memory-heavy, and `versions: 1..6` renders up to 6 PDFs. Already a defect running inline in a Next route — the fix is the `exam-export` queue that's declared and never consumed, not an Edge Function. | Same worker. |
| Multi-minute LLM generation | Streaming past the wall clock is survivable with `EdgeRuntime.waitUntil` piping, but a non-streaming tool-call generation is not. | Node server or worker. |
| BullMQ replacement via pgmq | pgmq has no exponential backoff, no stalled-job recovery, no `lockDuration`, no graceful drain. All four are load-bearing today. Plus queue delete-churn bloats the OLTP DB. | Keep BullMQ + Redis. |
| Redis rate limiting | No Redis on Supabase. A Postgres counter means a write to your primary on *every* request. | Upstash Redis. |
| Retention purge (storage deletes) | `pg_cron` + `pg_net` is fire-and-forget with no retry. The existing defect — row deleted even when the file delete fails — gets strictly worse. | `pg_cron` enqueues; the worker does the two-phase delete (file first, then row). |

**Legitimate `pg_cron` uses:** enqueue jobs, refresh materialized views (attendance rollups, fee aging), `detach partition` for retention, nightly `analyze`. **Legitimate Edge Function uses:** webhooks (payment gateway callbacks), short auth-adjacent RPCs, signed-URL minting, third-party callbacks. Nothing that loops.

---

## 6. Recommended target architecture

```
Next.js (Vercel)  ──JWT──▶  Supabase Postgres  (RLS enforced; app_web role, NOBYPASSRLS)
       │                          ├─ auth.users + public.memberships (+ access token hook)
       │                          ├─ school/campus/class/student, RLS on every table
       │                          └─ chunk_embeddings (pgvector, halfvec/1024, shared corpus)
       ├──▶ Supabase Storage (RLS by school_id path prefix, no service-role in request path)
       ├──▶ Upstash Redis (rate limits + BullMQ)
       └──▶ Worker container (Render/Fly): OCR, LLM, PDF, retention — service_role, audited
                     ▲
              pg_cron ──enqueue──┘
```

**Migration order, and don't reorder it:**
1. Land the connection-role change (`app_web`, `NOBYPASSRLS`, `withTenant`) with **zero policies**. Verify nothing breaks — everything is still service-role-equivalent via explicit `SET`.
2. Build `memberships` + the access token hook + claims. Verify claim contents end-to-end.
3. Enable RLS table by table, `select` policies first, behind a feature flag. Each table gets its index before its policy.
4. Cut auth over (accept the forced password reset).
5. Move vectors last — it's the only reversible piece.

**The trap to avoid:** enabling RLS while `DATABASE_URL` still points at `postgres`. You get a green test suite, a false sense of isolation, and no enforcement at all.