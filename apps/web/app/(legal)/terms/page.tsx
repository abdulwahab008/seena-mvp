export const metadata = { title: 'Terms of Service — Seena Exams' };

export default function TermsPage() {
  return (
    <>
      <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-amber-900">
        <strong>TEMPLATE — not legal advice.</strong> Review and adapt with qualified counsel
        before public launch.
      </div>
      <h1 className="text-2xl font-bold">Terms of Service</h1>
      <p className="text-muted-foreground">Last updated: [add date before launch]</p>

      <h2 className="mt-6 text-lg font-semibold">1. The service</h2>
      <p>
        Seena Exams provides automated exam-paper generation and answer-sheet grading from content
        you provide.
      </p>

      <h2 className="mt-6 text-lg font-semibold">2. Accounts</h2>
      <p>
        You are responsible for your account, for keeping your credentials secure, and for all
        content uploaded under your organization.
      </p>

      <h2 className="mt-6 text-lg font-semibold">3. Acceptable use</h2>
      <p>
        Your use is governed by our Acceptable Use Policy, including representations about your
        rights to uploaded material and student data.
      </p>

      <h2 className="mt-6 text-lg font-semibold">4. Your content</h2>
      <p>
        You retain all rights to the material you upload. You grant us a limited licence to process
        that material solely to provide the service to you.
      </p>

      <h2 className="mt-6 text-lg font-semibold">5. Generated output</h2>
      <p>
        Exams, answer keys, and grades are produced by automated language models and{' '}
        <strong>may contain errors</strong>. You are responsible for reviewing all generated papers
        and grades before relying on them. The service is a tool, not a substitute for professional
        judgement.
      </p>

      <h2 className="mt-6 text-lg font-semibold">6. Availability and warranty</h2>
      <p>The service is provided &ldquo;as is&rdquo; and &ldquo;as available&rdquo;, without warranties of any kind.</p>

      <h2 className="mt-6 text-lg font-semibold">7. Limitation of liability</h2>
      <p>
        To the maximum extent permitted by law, we are not liable for indirect or consequential
        damages arising from use of the service. [Adapt to your jurisdiction.]
      </p>

      <h2 className="mt-6 text-lg font-semibold">8. Termination</h2>
      <p>We may suspend or terminate access for breach of these terms or the Acceptable Use Policy.</p>

      <h2 className="mt-6 text-lg font-semibold">9. Governing law</h2>
      <p>[Specify governing law and jurisdiction before launch.]</p>

      <h2 className="mt-6 text-lg font-semibold">Contact</h2>
      <p>[add contact email]</p>
    </>
  );
}
