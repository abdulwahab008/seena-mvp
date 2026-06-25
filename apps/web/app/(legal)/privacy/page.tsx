export const metadata = { title: 'Privacy Policy — Seena Exams' };

export default function PrivacyPage() {
  return (
    <>
      <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-amber-900">
        <strong>TEMPLATE — not legal advice.</strong> Review and adapt with qualified counsel
        before public launch.
      </div>
      <h1 className="text-2xl font-bold">Privacy Policy</h1>
      <p className="text-muted-foreground">Last updated: [add date before launch]</p>

      <p>
        Seena Exams (&ldquo;we&rdquo;, &ldquo;us&rdquo;) provides exam-generation and grading tools
        to teachers and schools. This policy explains what we collect, why, and who we share it
        with.
      </p>

      <h2 className="mt-6 text-lg font-semibold">What we collect</h2>
      <ul className="list-disc space-y-1 pl-6">
        <li>Account details (name, email) via our authentication provider.</li>
        <li>Files you upload — textbooks/PDFs and scanned student answer sheets.</li>
        <li>Student names you choose to enter with a submission.</li>
        <li>Generated exams, grades, and feedback.</li>
        <li>Usage and cost telemetry (model, token counts, timestamps).</li>
      </ul>

      <h2 className="mt-6 text-lg font-semibold">How we use it</h2>
      <p>
        To provide the service (generate papers, grade answer sheets), enforce usage limits and
        cost controls, and maintain reliability and security.
      </p>

      <h2 className="mt-6 text-lg font-semibold">Sub-processors</h2>
      <p>We share data with these providers solely to operate the service:</p>
      <ul className="list-disc space-y-1 pl-6">
        <li>Authentication provider — account and session management.</li>
        <li>Supabase — database and file storage.</li>
        <li>Pinecone — vector search over your uploaded content.</li>
        <li>OpenRouter (and the underlying model providers) — exam generation, grading, and OCR.</li>
        <li>Google Document AI — optional OCR for scanned PDFs.</li>
      </ul>
      <p>
        <strong>Cross-border processing:</strong> some providers operate outside Pakistan. Text from
        uploaded books and student answer sheets may be transmitted to overseas providers for
        generation, OCR, and grading.
      </p>

      <h2 className="mt-6 text-lg font-semibold">Children&rsquo;s data</h2>
      <p>
        Student answer sheets may contain personal data of minors. You must have a lawful basis and
        any required parental/guardian consent before uploading a student&rsquo;s work — see the
        Acceptable Use Policy.
      </p>

      <h2 className="mt-6 text-lg font-semibold">Retention and deletion</h2>
      <p>
        You can delete books, exams, and submissions from within the app; deleting also removes the
        stored file. To delete your entire organization and all associated data, contact us at the
        address below.
      </p>

      <h2 className="mt-6 text-lg font-semibold">Your rights</h2>
      <p>
        You may request access, correction, or deletion of your data by contacting us at{' '}
        <strong>[add contact email]</strong>.
      </p>

      <h2 className="mt-6 text-lg font-semibold">Contact</h2>
      <p>[add contact email / business address]</p>
    </>
  );
}
