import Link from 'next/link';
import { UserButton } from '@clerk/nextjs';
import {
  BookOpen,
  FileText,
  MessageSquare,
  LayoutDashboard,
  Settings,
  Library,
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

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  await requireSession();
  return (
    <div className="grid min-h-screen grid-cols-[240px_1fr]">
      <aside className="border-r bg-muted/30 p-4 flex flex-col">
        <Link href="/dashboard" className="mb-6 text-lg font-semibold">
          Seena Exams
        </Link>
        <nav className="flex flex-col gap-1">
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
        </nav>
        <div className="mt-auto flex items-center gap-2 pt-4">
          <UserButton afterSignOutUrl="/" />
          <span className="text-xs text-muted-foreground">Account</span>
        </div>
      </aside>
      <main className="overflow-y-auto p-8">{children}</main>
    </div>
  );
}
