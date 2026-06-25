export const metadata = { title: 'Acceptable Use Policy — Seena Exams' };

export default function AcceptableUsePage() {
  return (
    <>
      <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-amber-900">
        <strong>TEMPLATE — not legal advice.</strong> Review and adapt with qualified counsel
        before public launch.
      </div>
      <h1 className="text-2xl font-bold">Acceptable Use Policy</h1>
      <p className="text-muted-foreground">Last updated: [add date before launch]</p>

      <h2 className="mt-6 text-lg font-semibold">1. Rights to uploaded material</h2>
      <p>
        You represent and warrant that you own, or have permission to upload and process, all
        material you upload — including textbooks and answer sheets. Do not upload copyrighted
        material without authorisation from the rights holder.
      </p>

      <h2 className="mt-6 text-lg font-semibold">2. Student data</h2>
      <p>
        You must have a lawful basis and any required parental or guardian consent before uploading a
        student&rsquo;s work or personal data. Use student identifiers (e.g. roll numbers) instead of
        full names where possible.
      </p>

      <h2 className="mt-6 text-lg font-semibold">3. Prohibited conduct</h2>
      <ul className="list-disc space-y-1 pl-6">
        <li>Attempting to access another organization&rsquo;s data.</li>
        <li>Reverse engineering, scraping, or abusing the automated systems or rate limits.</li>
        <li>Uploading unlawful, infringing, or harmful content.</li>
      </ul>

      <h2 className="mt-6 text-lg font-semibold">4. Copyright and takedown</h2>
      <p>
        If you believe content on the service infringes your copyright, contact us at{' '}
        <strong>[add takedown email]</strong> with a description of the work, its location, and your
        contact details. We will review and remove infringing material where appropriate.
      </p>

      <h2 className="mt-6 text-lg font-semibold">5. Consequences</h2>
      <p>Violations may result in suspension or termination of access.</p>

      <h2 className="mt-6 text-lg font-semibold">Contact</h2>
      <p>[add contact email]</p>
    </>
  );
}
