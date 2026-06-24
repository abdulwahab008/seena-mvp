# Seena Exams — Feature Gap Research

_Deep-research synthesis, 2026-06-24. 30 sources fetched, 148 claims extracted, **133 verified** (127 high-confidence) and **15 refuted**. Where a refutation corrected a "fact," it's flagged ⚠ below — those corrections matter for the build._

**Headline (the contrarian finding):** In Pakistan, **AI auto-grading is the lowest-trust, lowest-adoption feature** — only **24%** of educators use AI for grading vs 56% for personalized learning ([arxiv 2509.25293](https://arxiv.org/pdf/2509.25293)), and Karachi's board e-marking **collapsed** in 2025 — 140k of 180k scripts unmarked — because of teacher-incentive and trust gaps, *not* technical failure ([Express Tribune](https://tribune.com.pk/story/2583221/teachers-fail-e-marking-system)). Meanwhile **paper generation** is the proven winner: 73% of teachers report it cuts their workload, and the live local competitors (Paper Point, Rising Stars) sell exactly this. **So: lead with board-perfect paper generation; make grading human-in-the-loop or it will not be trusted.**

---

## 1. The competitive bar — table-stakes [TS] vs differentiator [D]

### Angle 1 — Exam/paper generation
- **[TS] Multi-format questions** (MCQ, true/false, fill-blank, short, long/essay) — every competitor (PrepAI, Conker, QuizGecko, Quizizz's 15 types). [prepai.io](https://www.prepai.io/blog/quizizz-vs-prepai/)
- **[TS] Generate from source docs** (PDF/DOCX/topic) — universal.
- **[TS] Board-pattern templating** — Paper Point & Rising Stars both sell Punjab+FBISE patterns for Class 9-12 as the core value prop. [paperpoint.pk](https://www.paperpoint.pk/), [risingstarspakistan.com](https://risingstarspakistan.com/paper-generator/)
- **[TS] PDF export with answer key, branded, watermark-free** — Rising Stars gates branding+answer-key behind paid tiers; Paper Point sells watermark-free + monogram.
- **[D] Bloom's / cognitive-level targeting (HOTS)** — PrepAI, ClassPoint, MagicSchool all expose it. [classpoint.io](https://www.classpoint.io/blog/ai-question-generator)
- **[D] Difficulty calibration per question** — Questgen, Quizbot.
- **[D] Speed** — Rising Stars markets "professional paper in ~2 minutes."

### Angle 2 — Auto-grading of scanned/handwritten sheets
- **[TS] Human-in-the-loop review/override — NON-NEGOTIABLE.** Gradescope (the reference workflow) *never* auto-grades without instructor confirmation and deliberately uses **no LLM** for scoring. [apporto](https://www.apporto.com/gradescopes-ai-assisted-grading-explained), [Tech&Learning via Gradescope blog]
- **[TS] OCR accuracy bar:** Google Vision 80-95% on handwriting (usable); Tesseract 20-40% (only fit for OMR/printed). Even Google Vision leaves **8-12% of sheets needing human correction**. [eklavvya](https://www.eklavvya.com/blog/best-ocr-answersheet-evaluation/)
- **[TS] MCQ/OMR bubble-sheet grading** — FBISE itself uses OMR sheets; the recommended architecture is **hybrid**: Tesseract/OMR for bubbles + Vision for free-text.
- **[D] Confidence-routing (selective automation):** auto-accept high-confidence, flag uncertain for human review. A handwritten-calculus study could only fully automate **~30% of grading load** at human-level accuracy — the other 70% routed to humans. [arxiv 2510.05162](https://arxiv.org/pdf/2510.05162)
  - ⚠ **Refuted nuance:** the seductive claim "just ask the LLM for its confidence" rests on a *single un-peer-reviewed 2026 preprint*; broader literature finds verbalized LLM confidence often **poorly calibrated**. Treat confidence routing as a real pattern but **calibrate against held-out human marks**, don't trust raw self-reported confidence.
- **Known LLM-grading pitfalls (cite when arguing for human review):** same essay re-graded 78→95/100 by changing only the student name ([leonfurze](https://leonfurze.com/2024/05/27/dont-use-genai-to-grade-student-work/)); bias, hallucination, non-determinism, inconsistency across runs ([MDPI review](https://www.mdpi.com/2076-3417/15/10/5683)); 42% of teachers found AI feedback not useful ([arxiv 2506.07955](https://arxiv.org/pdf/2506.07955)).

### Angle 3 — Assessment validity & board compliance
- **[TS] Table of Specifications (ToS) + cognitive-level distribution.** FBISE papers are SLO-based with a mandated K/U/A split (±5%). ⚠ **Refuted/corrected:** the split is **per-subject, not a fixed 30/50/20** — FBISE **Maths SSC-I is 20% Knowledge / 50% Understanding / 30% Application** (the inverse). A generator must encode the **per-subject Assessment Framework**, not one global split. [FBISE Training Manual Vol II](https://www.fbise.edu.pk/Downloads/Training_Manual_Vol_II.pdf), [FBISE model papers](https://www.fbise.edu.pk/curriculum_model_paper.php)
- **[TS] FBISE 3-section structure:** Section A MCQs ~20%, B short ~50% (external choice ≤33%), C long ~30%; difficulty mix ~40% easy / 40% moderate / 20% difficult.
- **[TS] FBISE rubric rules for free-text:** positive marking only, no negative marking, **consequential (error-carried-forward) marking** — an error is penalized once. Any auto-grader must encode this.
- **[TS — Punjab] "Pairing scheme":** Punjab boards (incl. BISE Rawalpindi) publish a **per-year, chapter-wise** scheme — counts of MCQ/short/long per chapter and which chapters are *paired* for long-question choice. This is the single most board-specific Punjab constraint; generic tools that ignore it aren't trusted. [taleemweb pairing scheme](https://taleemweb.com/pairing-scheme-9th-class/)
- **[D — Cambridge] AO weightings + command words.** Match assessment-objective balance (AO1 knowledge / AO2 application / AO3 analysis / AO4 evaluation, per-syllabus) and standardized command words (Define/Explain/Calculate/Analyse/Evaluate). [Cambridge syllabus 0450](https://www.cambridgeinternational.org/Images/697146-2026-syllabus.pdf)
  - ⚠ **Refuted:** Cambridge **component weighting factors** are a *post-exam grade-conversion* tool, **not** a paper-construction constraint — don't bake raw→weighted scaling into generation; do match AO balance + component structure.
- **[D] Auto-tag each generated item to a Bloom level and enforce the target distribution** automatically. [IJMSE](https://www.ijmse.org/Volume6/Issue9/paper2.pdf)

### Angle 4 — Teacher & school workflow
- **[TS] Bilingual English/Urdu** papers/UI — baseline expectation, not a differentiator. [eSHEPP/PMC](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12752358/)
- **[TS] Reusable question bank** — Paper Point markets **500,000+** questions; TeleTaleem bundles an "item bank." Teachers expect to save/reuse, not regenerate cold each time.
- **[TS] Offline / print / low-bandwidth.** Only 25% of PK households have internet, 14% a computer; Sabaq ships an **offline Raspberry-Pi box**; Rising Stars ships an **Android APK with offline saved papers**. Printable PDF is mandatory; teachers demand paper copies in parallel. [arxiv 2509.25293](https://arxiv.org/pdf/2509.25293), [eduwik](https://eduwik.com/mobile-learning-for-low-bandwidth-regions/)
- **[TS] Multi-teacher / sub-accounts** — Paper Point gives unlimited team sub-accounts + a teacher portal.
- **[TS] Custom branding** (academy name + logo on papers) — paid gate in local tools.
- **[D] Leak prevention** — multiple shuffled paper versions per student + role-based question-bank access (table-stakes), with OTP/time-locked decryption as differentiators. Paper leaks are a known high-trust concern in PK. [eklavvya leak prevention](https://www.eklavvya.com/blog/prevent-question-paper-leak/)
- **[D] Export breadth** — Google Forms/Classroom (Conker), DOCX/Excel/JSON (PrepAI), Moodle/QTI. Global tools treat these as table-stakes; PK tools are PDF-first.

### Angle 5 — Monetization, pricing, trust/safety
- **[TS] PKR pricing + local rails (JazzCash/EasyPaisa/bank).** Card-only checkout is a non-starter. [smartcampuspk](https://smartcampuspk.com/pricing)
- **Pricing models in market (anchors):**
  - Per-paper micro: Rising Stars **Rs 30/paper**.
  - Per-institution subscription: Paper Point **Rs 6,000/3mo, Rs 12,000/yr**; reseller white-label **Rs 200,000/yr**.
  - Per-student/seat: Edusuite **Rs 30-100/student/mo**.
  - Per-school tier: Smart Campus **Rs 7,000-37,000/mo** by enrollment.
  - B2C exam-prep ceiling: Edkasa **Rs 899/subject, Rs 3,599/all** per month.
- **[D] White-label / reseller tier** — both Paper Point and Rising Stars monetize this.
- **[TS] Student-data trust.** PECA 2016 is the only in-force law (Section 38 criminalizes unconsented data transfer). The **draft PDPB 2023** adds child-data consent + **data-localization for critical data (must reside in Pakistan)** — a forward-looking hosting constraint since student submissions involve minors. [ICLG](https://iclg.com/practice-areas/data-protection-laws-and-regulations/pakistan/)
- **[TS] Adoption levers > feature breadth.** Teachers adopt only with a "big enough efficiency gain"; onboarding/training/support and a **familiar (WhatsApp-like) UI** measurably drive uptake among low-digital-literacy teachers. [EdTech Hub](https://edtechhub.org/2022/09/26/opinions-behaviours-and-frustrations-lessons-on-teacher-technology-use-in-pakistan/)

---

## 2. Seena gap table — HAVE / PARTIAL / MISSING

| Feature | Bar | Seena today | Verdict |
|---|---|---|---|
| Multi-format question generation | TS | exam schema supports MCQ/short/long etc. | ✅ HAVE |
| Generate from textbook (RAG) | TS | upload→OCR→chunk→embed→Pinecone | ✅ HAVE (a real edge vs template tools) |
| Board-pattern templating (FBISE/Punjab/Pindi/Cambridge) | TS | pattern specs + custom patterns | ✅ HAVE (structural) |
| Branded PDF + answer key | TS | PDF export w/ org logo + answer key + citations | ✅ HAVE |
| Copyright safety on generated content | — | 15-gram verbatim guard | ✅ HAVE (uncommon — a differentiator) |
| **Human-in-the-loop grading review/override** | **TS** | auto-grades → stores marks, **no teacher review/edit UI** | 🔴 **MISSING — #1 gap** |
| Confidence routing / flag-uncertain | D | grades everything, no confidence flag | 🔴 MISSING |
| **Bilingual English/Urdu papers** | **TS** | `language` field exists; Urdu *generation* quality unverified | 🟡 PARTIAL (verify) |
| **Per-subject cognitive ToS + difficulty mix** | **TS** | patterns are marks-per-section only; single `difficulty` field; no K/U/A per-subject, no 40/40/20 | 🔴 MISSING (validity) |
| **Punjab pairing scheme (per-year, chapter-wise)** | **TS(Punjab)** | Punjab patterns exist but not at pairing-scheme granularity | 🔴 MISSING |
| Cambridge AO balance + command words | D | Cambridge patterns structural only | 🟡 PARTIAL |
| FBISE consequential/positive-only marking in grader | TS | grader clamps marks; ECF rule not encoded | 🟡 PARTIAL |
| Reusable question bank | TS | regenerates from RAG each time; no saved bank | 🔴 MISSING |
| MCQ/OMR bubble-sheet grading | TS | free-text vision-OCR only; no OMR path | 🔴 MISSING |
| Multiple shuffled paper versions (anti-leak) | D | one paper per generation | 🔴 MISSING |
| Offline / mobile / low-bandwidth | TS | web-only; printable PDF ✅ but needs connectivity | 🟡 PARTIAL |
| DOCX / Google Forms export | TS(global) | PDF only (enum has docx, unimplemented) | 🟡 PARTIAL |
| Team / multi-teacher sub-accounts | TS | orgs+memberships exist; no invite/team UI | 🟡 PARTIAL |
| PKR billing + JazzCash/EasyPaisa | TS | `plan` + cost caps; **no payment integration** | 🔴 MISSING |
| Student-data privacy / localization posture | TS | submissions in Supabase (foreign cloud) | 🟡 PARTIAL (future PDPB risk) |
| Cost guardrails (quota + USD cap) | — | per-org monthly limit + cost cap + telemetry | ✅ HAVE (ahead of competitors) |

---

## 3. Prioritized roadmap

**P0 — trust & validity (without these, the product is either untrusted or board-non-compliant)**
1. **Human-in-the-loop grading UI** — teacher reviews/edits every AI mark before it's final; show the AI's per-question evidence. This is the *single highest-leverage* gap (research is unanimous; Gradescope never auto-grades blind).
2. **Per-subject cognitive ToS + difficulty distribution** in the pattern engine — encode FBISE per-subject K/U/A (e.g. Maths 20/50/30) and 40/40/20 difficulty; auto-tag each generated item to a Bloom level. This is what makes a paper *board-acceptable*.
3. **Verify/ship bilingual Urdu generation** — confirm Urdu papers actually generate well; it's baseline for this market.

**P1 — competitive parity for the local wedge**
4. **Punjab pairing-scheme support** (per-year chapter-wise + paired-chapter choice) — biggest Punjab differentiator.
5. **Reusable question bank** — save generated/edited questions, reuse across papers.
6. **Multiple shuffled versions** per exam (anti-leak) + role-based bank access.
7. **PKR billing + JazzCash/EasyPaisa**, per-institution subscription (anchor: Rs 6-12k/yr) with a per-paper option (Rs 30) and white-label reseller tier.
8. **Confidence routing** in grading — auto-accept high-confidence, flag the rest; calibrate thresholds on held-out human marks (don't trust raw LLM self-confidence).

**P2 — breadth & reach**
9. DOCX + Google Forms export. 10. OMR/bubble-sheet grading path (hybrid). 11. Offline/mobile (APK or PWA) for low-bandwidth. 12. Team/invite UI. 13. Data-localization plan ahead of PDPB 2023.

**Positioning takeaway:** Seena already has the hard parts competitors lack — **RAG from the teacher's own textbook + copyright guard + cost guardrails**. The wins are (a) make grading *trustworthy* (human review), (b) make papers *board-exact* (per-subject ToS + Punjab pairing), (c) make it *sellable locally* (Urdu, PKR rails). Don't market "AI grades your papers" — market "board-perfect papers in 2 minutes, you stay in control of marks."

---

## 4. Confidence note
133/148 claims passed 3-vote adversarial verification. The 15 refuted claims were mostly (a) an over-hyped LLM-confidence-calibration claim from one preprint, and (b) an over-generalized FBISE 30/50/20 split — both corrected inline above (⚠). Pricing/competitor/board-structure facts are high-confidence (vendor pages + official FBISE/Cambridge PDFs). Source dates skew 2024-2026.
