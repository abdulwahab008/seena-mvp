import type { Metadata } from 'next';
import { ClerkProvider } from '@clerk/nextjs';
import { Toaster } from 'sonner';
import './globals.css';

export const metadata: Metadata = {
  title: 'Seena Exams — AI exam generator',
  description: 'Generate board-pattern exam papers from your textbooks with AI.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="min-h-screen bg-background font-sans antialiased">
        <ClerkProvider>{children}</ClerkProvider>
        <Toaster richColors position="top-right" />
      </body>
    </html>
  );
}
