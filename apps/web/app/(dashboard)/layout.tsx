import Link from 'next/link';
import { UserButton } from '@clerk/nextjs';
import {
  BookOpen,
  FileText,
  MessageSquare,
  LayoutDashboard,
  Settings,
  Library,
  Menu,
} from 'lucide-react';
import { requireSession } from '@/lib/auth';

const NAV = [
  { href: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { href: '/books', label: 'Books', icon: BookOpen },
  { href: '/exams', label: 'Exams', icon: FileText },
  { href: '/bank', label: 'Question Bank', icon: Library },
  { href: '/chat', label: 'Chat', icon: MessageSquare },
  { href: '/settings/patterns', label: 'Settings', icon: Settings },
];

function NavLinks() {
  return (
    <>
      {NAV.map((item) => {
        const Icon = item.icon;
        return (
          <Link
            key={item.href}
            href={item.href}
            className="flex items-center gap-2 rounded-md px-3 py-2 text-sm hover:bg-accent"
          >
            <Icon className="h-4 w-4" />
            {item.label}
          </Link>
        );
      })}
    </>
  );
}

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  await requireSession();
  return (
    <div className="grid min-h-screen grid-cols-1 md:grid-cols-[240px_1fr]">
      <aside className="hidden md:flex flex-col border-r bg-muted/30 p-4">
        <Link href="/dashboard" className="mb-6 text-lg font-semibold">
          Seena Exams
        </Link>
        <nav className="flex flex-col gap-1">
          <NavLinks />
        </nav>
        <div className="mt-auto flex items-center gap-2 pt-4">
          <UserButton afterSignOutUrl="/" />
          <span className="text-xs text-muted-foreground">Account</span>
        </div>
      </aside>

      {/* Mobile: a native, zero-JS disclosure — no client component needed. */}
      <details className="border-b bg-muted/30 md:hidden">
        <summary className="flex list-none items-center justify-between p-4 [&::-webkit-details-marker]:hidden">
          <span className="text-lg font-semibold">Seena Exams</span>
          <Menu className="h-5 w-5" />
        </summary>
        <nav className="flex flex-col gap-1 px-4 pb-4">
          <NavLinks />
          <div className="flex items-center gap-2 pt-2">
            <UserButton afterSignOutUrl="/" />
            <span className="text-xs text-muted-foreground">Account</span>
          </div>
        </nav>
      </details>

      <main className="overflow-y-auto p-4 md:p-8">{children}</main>
    </div>
  );
}
