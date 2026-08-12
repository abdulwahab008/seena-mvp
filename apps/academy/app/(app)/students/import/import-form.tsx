'use client';

import { useRouter } from 'next/navigation';
import { useRef, useState, useTransition } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { MAX_IMPORT_FILE_SIZE } from '@/lib/student-import';
import { validateStudentImport } from './actions';

export type CampusChoice = { id: string; code: string; name: string };
export type SessionChoice = { id: string; name: string };

export function ImportForm({ campuses, sessions }: { campuses: CampusChoice[]; sessions: SessionChoice[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [campusId, setCampusId] = useState(campuses[0]?.id ?? '');
  const [sessionId, setSessionId] = useState(sessions[0]?.id ?? '');
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const onSubmit = (formData: FormData) => {
    const file = formData.get('file');
    if (!(file instanceof File) || file.size === 0) {
      setError('Choose a CSV file to validate.');
      return;
    }
    if (file.size > MAX_IMPORT_FILE_SIZE) {
      setError('Maximum file size 10 MB.');
      return;
    }
    formData.set('campusId', campusId);
    formData.set('sessionId', sessionId);
    setError(null);

    startTransition(async () => {
      const result = await validateStudentImport({ error: null, batchId: null }, formData);
      if (result.error) {
        setError(result.error);
        return;
      }
      toast.success('Dry run finished — nothing was imported.');
      if (fileRef.current) fileRef.current.value = '';
      router.push(`/students/import?batch=${result.batchId}`);
      router.refresh();
    });
  };

  return (
    <form action={onSubmit} className="space-y-4 rounded-lg border p-4" data-testid="import-form">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="import-campus">Campus</Label>
          <Select value={campusId} onValueChange={setCampusId}>
            <SelectTrigger id="import-campus" className="w-56" data-testid="import-campus-trigger">
              <SelectValue placeholder="Choose a campus" />
            </SelectTrigger>
            <SelectContent>
              {campuses.map((c) => (
                <SelectItem key={c.id} value={c.id} data-testid={`import-campus-option-${c.code}`}>
                  {c.name} ({c.code})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="import-session">Academic session</Label>
          <Select value={sessionId} onValueChange={setSessionId}>
            <SelectTrigger id="import-session" className="w-56" data-testid="import-session-trigger">
              <SelectValue placeholder="Choose a session" />
            </SelectTrigger>
            <SelectContent>
              {sessions.map((s) => (
                <SelectItem key={s.id} value={s.id} data-testid={`import-session-option-${s.id}`}>
                  {s.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="import-file">Student file (.csv)</Label>
          <Input id="import-file" ref={fileRef} name="file" type="file" accept=".csv,text/csv" data-testid="import-file-input" />
        </div>
      </div>

      <div className="flex items-center gap-4">
        <Button type="submit" disabled={pending || !campusId || !sessionId} data-testid="import-submit">
          {pending ? 'Validating…' : 'Validate (dry run)'}
        </Button>
        <a href="/students/import/template" className="text-sm underline" download data-testid="import-template-link">
          Download the template
        </a>
      </div>

      {error && (
        <p className="text-sm text-destructive" data-testid="import-error">
          {error}
        </p>
      )}
    </form>
  );
}
