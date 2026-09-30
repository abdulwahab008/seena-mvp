'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { ConfirmDialog } from '@/components/ui/modal';

export function OrgDangerZone() {
  const [deleting, setDeleting] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);

  async function deleteOrg() {
    setDeleting(true);
    try {
      const res = await fetch('/api/org', { method: 'DELETE' });
      if (!res.ok) throw new Error(await res.text());
      toast.success('Organization data deleted.');
      window.location.href = '/';
    } catch (e) {
      toast.error((e as Error).message);
      setDeleting(false);
      setConfirmOpen(false);
    }
  }

  return (
    <Card>
      <CardContent className="space-y-5 p-6">
        <div>
          <h2 className="font-medium">Export data</h2>
          <p className="text-sm text-muted-foreground">
            Download all of this organization&rsquo;s data (books, exams, submissions, patterns,
            question bank) as JSON.
          </p>
          <a
            href="/api/org/export"
            className="mt-2 inline-flex h-9 items-center rounded-md border px-3 text-sm hover:bg-accent"
          >
            Export JSON
          </a>
        </div>
        <div className="border-t pt-4">
          <h2 className="font-medium text-red-700">Danger zone</h2>
          <p className="text-sm text-muted-foreground">
            Permanently delete this organization and all of its books, exams, submissions, and
            stored files. This cannot be undone.
          </p>
          <Button
            variant="outline"
            onClick={() => setConfirmOpen(true)}
            disabled={deleting}
            className="mt-2 border-red-300 text-red-700 hover:bg-red-50"
          >
            {deleting ? 'Deleting…' : 'Delete organization'}
          </Button>
        </div>
      </CardContent>

      <ConfirmDialog
        open={confirmOpen}
        onClose={() => setConfirmOpen(false)}
        onConfirm={() => void deleteOrg()}
        title="Delete Organization"
        description="Are you sure you want to delete this organization and ALL its data — books, exams, student submissions, and files? This cannot be undone."
        confirmLabel="Permanently Delete Organization"
        destructive
        pending={deleting}
      />
    </Card>
  );
}
