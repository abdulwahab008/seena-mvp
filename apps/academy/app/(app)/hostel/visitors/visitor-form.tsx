'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { supabaseBrowser } from '@/lib/supabase/client';
import { sniffMime } from '@/lib/uploads/sniff';
import { Button } from '@/components/ui/button';
import { findStudent, logVisit, lookupRelationship } from './actions';

const CONTROL = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

/**
 * Gate entry form. Typing the CNIC asks the database whether it belongs to a
 * guardian of the visited student and pre-fills the relationship; the photograph
 * (optional) goes to the private hostel-visitor-photos bucket first, at
 * tenant/campus/visit-id, before the entry is saved.
 */
export function VisitorForm() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [student, setStudent] = useState<{ id: string; name: string; campusId: string; tenantId: string } | null>(null);
  const [relationship, setRelationship] = useState('');
  const [match, setMatch] = useState<string | null>(null);

  const checkCnic = async (cnic: string) => {
    if (!student || cnic.replace(/\D/g, '').length !== 13) {
      setMatch(null);
      return;
    }
    const rel = await lookupRelationship(student.id, cnic);
    setMatch(rel);
    if (rel) setRelationship(rel);
  };

  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = e.currentTarget;
    const fd = new FormData(form);
    if (!student) {
      setError('Enter a valid GR number first.');
      return;
    }
    const visitId = crypto.randomUUID();
    const file = fd.get('photo') instanceof File && (fd.get('photo') as File).size > 0 ? (fd.get('photo') as File) : null;
    startTransition(async () => {
      let photoPath = '';
      if (file) {
        const mime = sniffMime(new Uint8Array(await file.slice(0, 16).arrayBuffer()));
        if (!mime || mime === 'application/pdf') {
          setError('The photograph must be a JPEG, PNG or WebP image.');
          return;
        }
        if (file.size > 3 * 1024 * 1024) {
          setError('The photograph must be 3 MB or smaller.');
          return;
        }
        const ext = mime === 'image/png' ? 'png' : mime === 'image/webp' ? 'webp' : 'jpg';
        photoPath = `${student.tenantId}/${student.campusId}/${visitId}.${ext}`;
        const { error: upErr } = await supabaseBrowser().storage.from('hostel-visitor-photos').upload(photoPath, file, { contentType: mime });
        if (upErr) {
          setError('The photograph could not be uploaded.');
          return;
        }
      }
      const r = await logVisit({
        studentId: student.id,
        visitId,
        visitorName: String(fd.get('visitorName') ?? ''),
        visitorCnic: String(fd.get('visitorCnic') ?? ''),
        relationship,
        phone: String(fd.get('phone') ?? ''),
        photoPath,
      });
      setError(r.error);
      if (!r.error) {
        toast.success(r.message ?? 'Visitor logged.');
        form.reset();
        setStudent(null);
        setRelationship('');
        setMatch(null);
        router.refresh();
      }
    });
  };

  return (
    <form onSubmit={onSubmit} className="space-y-3" data-testid="visitor-form" noValidate>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Student GR number *</span>
          <input
            name="gr"
            className={CONTROL}
            onBlur={async (e) => setStudent(e.target.value.trim() ? await findStudent(e.target.value) : null)}
          />
          {student && <span className="block text-xs text-muted-foreground" data-testid="visited-student">Visiting {student.name}</span>}
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Visitor name *</span>
          <input name="visitorName" className={CONTROL} />
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Visitor CNIC *</span>
          <input name="visitorCnic" className={CONTROL} placeholder="35202-1234567-1" onBlur={(e) => void checkCnic(e.target.value)} />
          {match && <span className="block text-xs text-success" data-testid="cnic-match">Recorded guardian: {match}</span>}
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Relationship</span>
          <input name="relationship" value={relationship} onChange={(e) => setRelationship(e.target.value)} className={CONTROL} readOnly={!!match} />
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Phone</span>
          <input name="phone" className={CONTROL} />
        </label>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Photograph (optional)</span>
          <input type="file" name="photo" accept="image/jpeg,image/png,image/webp" capture="user" className="block text-sm" />
        </label>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="visitor-form-error">
          {error}
        </p>
      )}
      <Button type="submit" size="sm" disabled={pending} data-testid="visitor-form-submit">
        Log entry
      </Button>
    </form>
  );
}
