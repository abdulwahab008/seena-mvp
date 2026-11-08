'use client';

import { useTransition } from 'react';
import { toast } from 'sonner';
import { formatDatePk } from '@/lib/dates';
import { setRegistrationStatus } from './actions';

type Request = {
  id: string;
  school_name: string;
  contact_name: string;
  phone: string;
  email: string | null;
  city: string | null;
  students: number | null;
  message: string | null;
  status: string;
  created_at: string;
};
const STATUSES = [
  { value: 'new', label: 'New' },
  { value: 'contacted', label: 'Contacted' },
  { value: 'onboarded', label: 'Onboarded' },
  { value: 'declined', label: 'Declined' },
] as const;

function StatusSelect({ id, status }: { id: string; status: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <select
      aria-label="Request status"
      defaultValue={status}
      disabled={pending}
      className="h-9 rounded-md border bg-background px-2 text-sm"
      onChange={(e) => {
        const next = e.target.value as (typeof STATUSES)[number]['value'];
        startTransition(async () => {
          const r = await setRegistrationStatus({ id, status: next });
          if (r.error) toast.error(r.error);
        });
      }}
    >
      {STATUSES.map((s) => (
        <option key={s.value} value={s.value}>
          {s.label}
        </option>
      ))}
    </select>
  );
}

export function RegistrationRequests({ requests }: { requests: Request[] }) {
  if (requests.length === 0) return <p className="text-sm text-muted-foreground">No requests yet. Schools ask to join from /register-school.</p>;
  return (
    <ul className="divide-y rounded-md border">
      {requests.map((r) => (
        <li key={r.id} className="flex flex-wrap items-start justify-between gap-3 p-3 text-sm" data-testid="registration-request">
          <div className="min-w-0 space-y-0.5">
            <p className="font-medium">
              {r.school_name}
              {r.city ? <span className="font-normal text-muted-foreground"> · {r.city}</span> : null}
              {r.students ? <span className="font-normal text-muted-foreground"> · {r.students} students</span> : null}
            </p>
            <p>
              {r.contact_name} ·{' '}
              <a href={`tel:${r.phone}`} className="underline">
                {r.phone}
              </a>
              {r.email ? (
                <>
                  {' · '}
                  <a href={`mailto:${r.email}`} className="underline">
                    {r.email}
                  </a>
                </>
              ) : null}
            </p>
            {r.message && <p className="text-muted-foreground">{r.message}</p>}
            <p className="text-xs text-muted-foreground">Asked {formatDatePk(r.created_at.slice(0, 10))}</p>
          </div>
          <StatusSelect id={r.id} status={r.status} />
        </li>
      ))}
    </ul>
  );
}
