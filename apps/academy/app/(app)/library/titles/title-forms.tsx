'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { LIBRARY_LANGUAGES, libraryTitleSchema, type LibraryTitleInput } from '@/lib/validation';
import { normaliseIsbn13 } from '@/lib/library';
import { saveTitle, uploadCover } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const LANGUAGE_LABEL: Record<(typeof LIBRARY_LANGUAGES)[number], string> = { en: 'English', ur: 'Urdu', ar: 'Arabic', pa: 'Punjabi', sd: 'Sindhi', other: 'Other' };

export function TitleForm({ subjects, initial, titleId }: { subjects: { id: string; name: string }[]; initial?: LibraryTitleInput; titleId?: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<LibraryTitleInput>({
    resolver: zodResolver(libraryTitleSchema),
    defaultValues: initial ?? { title: '', titleUr: '', rawIsbn: '', author: '', publisher: '', edition: '', language: 'en', dewey: '', subjectId: '' },
  });
  const isbn = form.watch('rawIsbn');
  let isbnHint: string | null = null;
  try {
    const n = normaliseIsbn13(isbn);
    isbnHint = n ? `Stored as ISBN-13 ${n}` : 'No ISBN: fine for locally printed books.';
  } catch {
    isbnHint = 'This is not a valid ISBN.';
  }

  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveTitle(v, titleId);
      setError(r.error);
      if (!r.error) {
        toast.success(titleId ? 'Title updated.' : 'Title catalogued.');
        if (!titleId) form.reset();
        router.refresh();
      }
    }),
  );

  const field = (name: keyof LibraryTitleInput, label: string, props: { placeholder?: string; dir?: 'rtl' } = {}) => (
    <div className="space-y-1">
      <Label htmlFor={`title-${name}`}>{label}</Label>
      <Input id={`title-${name}`} {...props} {...form.register(name)} />
      {form.formState.errors[name] && <p className="text-xs text-destructive">{String(form.formState.errors[name]?.message)}</p>}
    </div>
  );

  return (
    <form onSubmit={onSubmit} className="grid gap-3 md:grid-cols-3" noValidate>
      {field('title', 'Title')}
      {field('titleUr', 'Title (Urdu)', { dir: 'rtl' })}
      <div className="space-y-1">
        <Label htmlFor="title-rawIsbn">ISBN (optional)</Label>
        <Input id="title-rawIsbn" placeholder="978-969-352-601-1" {...form.register('rawIsbn')} />
        <p className="text-xs text-muted-foreground" data-testid="isbn-hint">{isbnHint}</p>
        {form.formState.errors.rawIsbn && <p className="text-xs text-destructive">{form.formState.errors.rawIsbn.message}</p>}
      </div>
      {field('author', 'Author')}
      {field('publisher', 'Publisher')}
      {field('edition', 'Edition')}
      <div className="space-y-1">
        <Label htmlFor="title-language">Language</Label>
        <select id="title-language" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('language')}>
          {LIBRARY_LANGUAGES.map((l) => (
            <option key={l} value={l}>
              {LANGUAGE_LABEL[l]}
            </option>
          ))}
        </select>
      </div>
      {field('dewey', 'Dewey class', { placeholder: '297' })}
      <div className="space-y-1">
        <Label htmlFor="title-subjectId">Subject</Label>
        <select id="title-subjectId" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('subjectId')}>
          <option value="">None</option>
          {subjects.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
      </div>
      <div className="flex items-end gap-3 md:col-span-3">
        <Button type="submit" disabled={pending} data-testid="save-title">
          {titleId ? 'Save changes' : 'Catalogue title'}
        </Button>
        {error && (
          <p role="alert" className="text-sm text-destructive" data-testid="title-error">
            {error}
          </p>
        )}
      </div>
    </form>
  );
}

export function CoverUpload({ titleId }: { titleId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <form
      className="flex items-center gap-2"
      onSubmit={(e) => {
        e.preventDefault();
        const fd = new FormData(e.currentTarget);
        startTransition(async () => {
          const r = await uploadCover(titleId, fd);
          setError(r.error);
          if (!r.error) {
            toast.success('Cover saved.');
            router.refresh();
          }
        });
      }}
    >
      <input type="file" name="cover" accept="image/jpeg,image/png,image/webp" aria-label="Cover image" className="text-xs" />
      <Button type="submit" size="sm" variant="outline" disabled={pending}>
        Upload cover
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </form>
  );
}
