import Link from 'next/link';
import { Button } from '@/components/ui/button';

export default function LandingPage() {
  return (
    <main className="container flex min-h-screen flex-col items-center justify-center gap-8 py-16 text-center">
      <div>
        <h1 className="text-4xl font-bold tracking-tight md:text-6xl">Seena Exams</h1>
        <p className="mt-4 text-lg text-muted-foreground md:text-xl">
          AI exam generator for Pakistani board patterns. Upload a textbook, get a paper.
        </p>
      </div>
      <div className="flex gap-3">
        <Button asChild size="lg">
          <Link href="/sign-in">Sign in</Link>
        </Button>
        <Button asChild size="lg" variant="outline">
          <Link href="/sign-up">Create account</Link>
        </Button>
      </div>
      <p className="max-w-xl text-sm text-muted-foreground">
        FBISE, Punjab Board, BISE Rawalpindi, Cambridge IGCSE — bring your own books, generate
        on-pattern papers with answer keys.
      </p>
    </main>
  );
}
