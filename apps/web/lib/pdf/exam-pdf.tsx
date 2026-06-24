import { Document, Page, Text, View, StyleSheet, Image, Font } from '@react-pdf/renderer';
import type { Exam } from '@seena/shared';

// Urdu/Arabic-script glyphs for bilingual papers — Times/Helvetica have none, so Urdu text
// would render as blank boxes without this. ponytail: fetched from jsDelivr at render (cached
// per process); vendor the .ttf if offline PDF export is ever required.
Font.register({
  family: 'NotoNaskhArabic',
  src: 'https://cdn.jsdelivr.net/gh/notofonts/notofonts.github.io/fonts/NotoNaskhArabic/full/ttf/NotoNaskhArabic-Regular.ttf',
});

const COLOR = {
  ink: '#0f172a',
  body: '#1f2937',
  muted: '#64748b',
  faint: '#94a3b8',
  rule: '#cbd5e1',
  surface: '#f8fafc',
  band: '#e2e8f0',
  accent: '#1e3a8a',
};

const styles = StyleSheet.create({
  page: {
    paddingTop: 48,
    paddingBottom: 56,
    paddingHorizontal: 48,
    fontSize: 11,
    fontFamily: 'Times-Roman',
    color: COLOR.body,
    lineHeight: 1.45,
  },
  none: {},
  rtl: { fontFamily: 'NotoNaskhArabic', textAlign: 'right' },

  // Header band
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-end',
    paddingBottom: 10,
    marginBottom: 6,
    borderBottomWidth: 2,
    borderBottomColor: COLOR.accent,
  },
  headerLeft: { flexDirection: 'column' },
  eyebrow: {
    fontSize: 8,
    letterSpacing: 1.5,
    color: COLOR.muted,
    fontFamily: 'Helvetica',
    marginBottom: 4,
    textTransform: 'uppercase',
  },
  org: {
    fontSize: 18,
    fontFamily: 'Times-Bold',
    color: COLOR.ink,
    letterSpacing: 0.2,
  },
  logo: { width: 48, height: 48, objectFit: 'contain' },

  // Title block
  titleBlock: { marginTop: 18, marginBottom: 14, alignItems: 'center' },
  title: {
    fontSize: 16,
    fontFamily: 'Times-Bold',
    textAlign: 'center',
    color: COLOR.ink,
    marginBottom: 4,
  },
  subtitle: { fontSize: 10, color: COLOR.muted, textAlign: 'center', fontFamily: 'Helvetica' },

  // Info bar
  infoRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 6,
    paddingHorizontal: 10,
    backgroundColor: COLOR.surface,
    borderTopWidth: 0.5,
    borderBottomWidth: 0.5,
    borderColor: COLOR.rule,
    marginBottom: 18,
  },
  infoCell: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  infoLabel: { fontSize: 8, color: COLOR.muted, fontFamily: 'Helvetica', textTransform: 'uppercase', letterSpacing: 0.8 },
  infoValue: { fontSize: 10, color: COLOR.ink, fontFamily: 'Helvetica-Bold' },

  // Section
  section: { marginBottom: 14 },
  sectionHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'baseline',
    paddingBottom: 6,
    marginBottom: 6,
    borderBottomWidth: 0.5,
    borderBottomColor: COLOR.rule,
  },
  sectionTitle: { fontSize: 12, fontFamily: 'Times-Bold', color: COLOR.ink },
  sectionMarks: { fontSize: 9, color: COLOR.muted, fontFamily: 'Helvetica' },
  sectionInstructions: { fontSize: 9.5, color: COLOR.muted, fontFamily: 'Times-Italic', marginBottom: 8 },

  // Question
  question: { flexDirection: 'row', marginBottom: 10 },
  qNumberCol: { width: 22 },
  qNumber: { fontSize: 11, fontFamily: 'Times-Bold', color: COLOR.ink },
  qBody: { flex: 1 },
  qPrompt: { fontSize: 11, color: COLOR.body },
  qMarks: { fontSize: 9, color: COLOR.muted, fontFamily: 'Helvetica' },

  // MCQ options
  options: { marginTop: 4, marginLeft: 4 },
  optionRow: { flexDirection: 'row', marginBottom: 2 },
  optionLetter: { width: 16, fontSize: 10.5, fontFamily: 'Helvetica-Bold', color: COLOR.ink },
  optionText: { flex: 1, fontSize: 10.5, color: COLOR.body },

  // Answer key
  answerKeyEyebrow: {
    fontSize: 8,
    letterSpacing: 2,
    color: COLOR.muted,
    fontFamily: 'Helvetica',
    textTransform: 'uppercase',
    textAlign: 'center',
    marginTop: 4,
  },
  answerKeyTitle: {
    fontSize: 16,
    fontFamily: 'Times-Bold',
    color: COLOR.ink,
    textAlign: 'center',
    marginBottom: 4,
  },
  answerKeyRule: {
    width: 60,
    height: 1.5,
    backgroundColor: COLOR.accent,
    alignSelf: 'center',
    marginBottom: 14,
  },
  answerSection: { marginBottom: 14 },
  answerSectionTitle: {
    fontSize: 11,
    fontFamily: 'Times-Bold',
    color: COLOR.ink,
    backgroundColor: COLOR.surface,
    paddingVertical: 4,
    paddingHorizontal: 6,
    marginBottom: 6,
  },
  answerRow: { flexDirection: 'row', marginBottom: 6 },
  answerNum: { width: 22, fontSize: 10, fontFamily: 'Times-Bold', color: COLOR.ink },
  answerBody: { flex: 1 },
  answerText: { fontSize: 10, color: COLOR.body },
  answerMeta: { fontSize: 8.5, color: COLOR.muted, fontFamily: 'Helvetica', marginTop: 1 },
  answerExpl: { fontSize: 9, color: COLOR.muted, fontFamily: 'Times-Italic', marginTop: 2 },

  // Footer
  footer: {
    position: 'absolute',
    bottom: 24,
    left: 48,
    right: 48,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingTop: 6,
    borderTopWidth: 0.5,
    borderTopColor: COLOR.rule,
  },
  footerLeft: { fontSize: 8.5, color: COLOR.faint, fontFamily: 'Helvetica' },
  footerRight: { fontSize: 8.5, color: COLOR.muted, fontFamily: 'Helvetica' },
});

function sectionTotalMarks(section: Exam['sections'][number]): number {
  return section.questions.reduce((sum, q) => sum + q.marks, 0);
}

function formatDate(d = new Date()): string {
  return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: '2-digit' });
}

export type ExamPdfProps = {
  exam: Exam;
  orgName: string;
  orgLogoUrl?: string | null;
  language?: 'en' | 'ur' | 'mixed';
};

export function ExamDocument({ exam, orgName, orgLogoUrl, language }: ExamPdfProps) {
  let questionCounter = 0;
  const totalQuestions = exam.sections.reduce((sum, s) => sum + s.questions.length, 0);
  const dateStr = formatDate();
  const isUrdu = language === 'ur' || language === 'mixed';
  const rtl = isUrdu ? styles.rtl : styles.none;

  return (
    <Document title={exam.title} author={orgName}>
      {/* === Cover + questions === */}
      <Page size="A4" style={styles.page}>
        {/* Header */}
        <View style={styles.header}>
          <View style={styles.headerLeft}>
            <Text style={styles.eyebrow}>Examination Paper</Text>
            <Text style={styles.org}>{orgName}</Text>
          </View>
          {orgLogoUrl ? <Image src={orgLogoUrl} style={styles.logo} /> : null}
        </View>

        {/* Title */}
        <View style={styles.titleBlock}>
          <Text style={[styles.title, rtl]}>{exam.title}</Text>
          <Text style={styles.subtitle}>{exam.pattern}</Text>
        </View>

        {/* Info bar */}
        <View style={styles.infoRow}>
          <View style={styles.infoCell}>
            <Text style={styles.infoLabel}>Total Marks: </Text>
            <Text style={styles.infoValue}>{exam.total_marks}</Text>
          </View>
          <View style={styles.infoCell}>
            <Text style={styles.infoLabel}>Questions: </Text>
            <Text style={styles.infoValue}>{totalQuestions}</Text>
          </View>
          <View style={styles.infoCell}>
            <Text style={styles.infoLabel}>Sections: </Text>
            <Text style={styles.infoValue}>{exam.sections.length}</Text>
          </View>
          <View style={styles.infoCell}>
            <Text style={styles.infoLabel}>Date: </Text>
            <Text style={styles.infoValue}>{dateStr}</Text>
          </View>
        </View>

        {/* Sections */}
        {exam.sections.map((section, si) => {
          const sectionMarks = sectionTotalMarks(section);
          return (
            <View key={si} style={styles.section}>
              <View style={styles.sectionHeader}>
                <Text style={[styles.sectionTitle, rtl]}>{section.title}</Text>
                <Text style={styles.sectionMarks}>
                  {section.questions.length} question{section.questions.length === 1 ? '' : 's'} · {sectionMarks} mark{sectionMarks === 1 ? '' : 's'}
                </Text>
              </View>
              <Text style={[styles.sectionInstructions, rtl]}>{section.instructions}</Text>

              {section.questions.map((q, qi) => {
                questionCounter += 1;
                return (
                  <View key={qi} style={styles.question} wrap={false}>
                    <View style={styles.qNumberCol}>
                      <Text style={styles.qNumber}>{questionCounter}.</Text>
                    </View>
                    <View style={styles.qBody}>
                      <Text style={[styles.qPrompt, rtl]}>
                        {q.prompt} <Text style={styles.qMarks}>({q.marks} mark{q.marks === 1 ? '' : 's'})</Text>
                      </Text>
                      {q.type === 'mcq' && 'options' in q && q.options ? (
                        <View style={styles.options}>
                          {q.options.map((opt: string, oi: number) => (
                            <View key={oi} style={styles.optionRow}>
                              <Text style={styles.optionLetter}>{String.fromCharCode(65 + oi)}.</Text>
                              <Text style={[styles.optionText, rtl]}>{opt}</Text>
                            </View>
                          ))}
                        </View>
                      ) : null}
                    </View>
                  </View>
                );
              })}
            </View>
          );
        })}

        <View style={styles.footer} fixed>
          <Text style={styles.footerLeft}>{orgName} · {exam.title}</Text>
          <Text
            style={styles.footerRight}
            render={({ pageNumber, totalPages }) => `Page ${pageNumber} of ${totalPages}`}
          />
        </View>
      </Page>

      {/* === Answer Key === */}
      <Page size="A4" style={styles.page}>
        <View style={styles.header}>
          <View style={styles.headerLeft}>
            <Text style={styles.eyebrow}>Answer Key · Teacher Copy</Text>
            <Text style={styles.org}>{orgName}</Text>
          </View>
          {orgLogoUrl ? <Image src={orgLogoUrl} style={styles.logo} /> : null}
        </View>

        <Text style={styles.answerKeyEyebrow}>Answers &amp; Source References</Text>
        <Text style={styles.answerKeyTitle}>{exam.title}</Text>
        <View style={styles.answerKeyRule} />

        {(() => {
          let n = 0;
          return exam.sections.map((section, si) => (
            <View key={si} style={styles.answerSection}>
              <Text style={[styles.answerSectionTitle, rtl]}>{section.title}</Text>
              {section.questions.map((q, qi) => {
                n += 1;
                const answer = (q as { answer?: string }).answer ?? '—';
                const pages = (q as { source_pages?: number[] }).source_pages ?? [];
                const explanation = (q as { explanation?: string }).explanation;
                return (
                  <View key={qi} style={styles.answerRow} wrap={false}>
                    <Text style={styles.answerNum}>{n}.</Text>
                    <View style={styles.answerBody}>
                      <Text style={[styles.answerText, rtl]}>{answer}</Text>
                      <Text style={styles.answerMeta}>
                        {q.marks} mark{q.marks === 1 ? '' : 's'} · source page{pages.length === 1 ? '' : 's'} {pages.join(', ') || '—'}
                      </Text>
                      {explanation ? <Text style={[styles.answerExpl, rtl]}>{explanation}</Text> : null}
                    </View>
                  </View>
                );
              })}
            </View>
          ));
        })()}

        <View style={styles.footer} fixed>
          <Text style={styles.footerLeft}>{orgName} · {exam.title} · Answer Key</Text>
          <Text
            style={styles.footerRight}
            render={({ pageNumber, totalPages }) => `Page ${pageNumber} of ${totalPages}`}
          />
        </View>
      </Page>
    </Document>
  );
}
