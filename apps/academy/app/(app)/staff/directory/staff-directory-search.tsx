'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { searchStaffDirectory, type StaffDirectoryRow } from './actions';
import { searchStaffSchema, type SearchStaffInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function StaffDirectorySearch({ initialResults }: { initialResults: StaffDirectoryRow[] }) {
  const [pending, startTransition] = useTransition();
  const [results, setResults] = useState<StaffDirectoryRow[]>(initialResults);
  const { register, handleSubmit } = useForm<SearchStaffInput>({ resolver: zodResolver(searchStaffSchema) });

  const onSearch = handleSubmit((values) => {
    const fd = new FormData();
    if (values.q) fd.set('q', values.q);
    if (values.includeFormer) fd.set('includeFormer', 'on');

    startTransition(async () => {
      const result = await searchStaffDirectory({ error: null, results: null }, fd);
      if (result.error) toast.error(result.error);
      else setResults(result.results ?? []);
    });
  });

  return (
    <div className="space-y-4">
      <form onSubmit={onSearch} className="flex flex-wrap items-end gap-3 rounded-lg border p-4" noValidate>
        <div className="flex-1 space-y-1">
          <Label htmlFor="q">Search</Label>
          <Input id="q" data-testid="staff-directory-query" placeholder="Name or employee code" {...register('q')} />
        </div>
        <label className="flex items-center gap-2 pb-2 text-sm">
          <input type="checkbox" data-testid="staff-directory-include-former" {...register('includeFormer')} />
          Include former staff
        </label>
        <Button type="submit" disabled={pending} data-testid="staff-directory-search-button">
          {pending ? 'Searching…' : 'Search'}
        </Button>
      </form>

      <div className="rounded-lg border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="p-2">Name</th>
              <th className="p-2">Code</th>
              <th className="p-2">Designation</th>
              <th className="p-2">Department</th>
              <th className="p-2">Status</th>
              <th className="p-2">Mobile</th>
              <th className="p-2">Identity document</th>
            </tr>
          </thead>
          <tbody>
            {results.map((r) => (
              <tr key={r.staff_id} data-testid={`staff-directory-row-${r.full_name}`} className="border-b last:border-0">
                <td className="p-2">
                  {r.full_name}
                  {r.is_former && (
                    <span className="ml-2 rounded-full border px-2 py-0.5 text-xs text-muted-foreground" data-testid={`staff-directory-former-${r.full_name}`}>
                      former
                    </span>
                  )}
                </td>
                <td className="p-2">{r.employee_code}</td>
                <td className="p-2">{r.designation ?? '—'}</td>
                <td className="p-2">{r.department ?? '—'}</td>
                <td className="p-2 text-muted-foreground">{r.employment_status}</td>
                <td className="p-2" data-testid={`staff-directory-mobile-${r.full_name}`}>
                  {r.mobile ?? '—'}
                </td>
                <td className="p-2" data-testid={`staff-directory-idnum-${r.full_name}`}>
                  {r.identity_document_number ?? '—'}
                </td>
              </tr>
            ))}
            {results.length === 0 && (
              <tr>
                <td className="p-2 text-muted-foreground" colSpan={7}>
                  No staff found.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
