'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export function OrgDangerZone() {
  const [deleting, setDeleting] = useState(false);

  async function deleteOrg() {
    if (
      !confirm(
        'Delete this organization and ALL its data — books, exams, student submissions, and files? This cannot be undone.',
      )
    )
      return;
    setDeleting(true);
    try {
      const res = await fetch('/api/org', { method: 'DELETE' });
      if (!res.ok) throw new Error(await res.text());
      toast.success('Organization data deleted.');
      window.location.href = '/';
    } catch (e) {
      toast.error((e as Error).message);
      setDeleting(false);
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
            onClick={() => void deleteOrg()}
            disabled={deleting}
            className="mt-2 border-red-300 text-red-700 hover:bg-red-50"
          >
            {deleting ? 'Deleting…' : 'Delete organization'}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
