import Link from 'next/link';

export default function LegalLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="mx-auto max-w-3xl px-6 py-12">
      <Link href="/" className="text-sm text-muted-foreground hover:underline">
        ← Seena Exams
      </Link>
      <div className="mt-6 space-y-3 text-sm leading-relaxed">{children}</div>
      <footer className="mt-12 flex gap-4 border-t pt-6 text-sm text-muted-foreground">
        <Link href="/privacy" className="hover:underline">
          Privacy
        </Link>
        <Link href="/terms" className="hover:underline">
          Terms
        </Link>
        <Link href="/acceptable-use" className="hover:underline">
          Acceptable Use
        </Link>
      </footer>
    </div>
  );
}
