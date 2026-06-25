'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';

const BOARDS = [
  { value: 'FBISE', label: 'FBISE (Federal)' },
  { value: 'PUNJAB', label: 'Punjab Board' },
  { value: 'PINDI', label: 'BISE Rawalpindi' },
  { value: 'SINDH', label: 'Sindh' },
  { value: 'KP', label: 'Khyber Pakhtunkhwa' },
  { value: 'AJK', label: 'AJK' },
  { value: 'CAMBRIDGE_IGCSE', label: 'Cambridge IGCSE' },
  { value: 'CAMBRIDGE_O_LEVEL', label: 'Cambridge O Level' },
  { value: 'CAMBRIDGE_A_LEVEL', label: 'Cambridge A Level' },
  { value: 'OTHER', label: 'Other' },
];

export function BookUploader() {
  const router = useRouter();
  const [file, setFile] = useState<File | null>(null);
  const [title, setTitle] = useState('');
  const [grade, setGrade] = useState<string>('');
  const [subject, setSubject] = useState('');
  const [board, setBoard] = useState('PUNJAB');
  const [language, setLanguage] = useState('en');
  const [submitting, setSubmitting] = useState(false);
  const [rightsAck, setRightsAck] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!file) return toast.error('Pick a PDF first.');
    if (!title || !subject) return toast.error('Title and subject are required.');
    if (!rightsAck) return toast.error('Please confirm you have the right to upload this material.');
    setSubmitting(true);
    try {
      const urlRes = await fetch('/api/books/upload-url', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ filename: file.name, contentType: file.type }),
      });
      if (!urlRes.ok) throw new Error(await urlRes.text());
      const { signedUrl, key } = await urlRes.json();

      const putRes = await fetch(signedUrl, {
        method: 'PUT',
        headers: { 'content-type': file.type || 'application/pdf' },
        body: file,
      });
      if (!putRes.ok) throw new Error(`upload failed: ${putRes.status}`);

      const create = await fetch('/api/books', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          title,
          grade: grade ? Number(grade) : null,
          subject,
          board,
          language,
          storageKey: key,
        }),
      });
      if (!create.ok) throw new Error(await create.text());
      toast.success('Uploaded — processing in the background.');
      router.push('/books');
    } catch (err) {
      toast.error((err as Error).message);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Card>
      <CardContent className="p-6">
        <form onSubmit={onSubmit} className="grid gap-4">
          <div>
            <Label htmlFor="file">PDF</Label>
            <Input
              id="file"
              type="file"
              accept="application/pdf"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              className="mt-1"
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <Label htmlFor="title">Title</Label>
              <Input
                id="title"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="Physics 9 — Punjab Curriculum"
                className="mt-1"
              />
            </div>
            <div>
              <Label htmlFor="subject">Subject</Label>
              <Input
                id="subject"
                value={subject}
                onChange={(e) => setSubject(e.target.value)}
                placeholder="Physics"
                className="mt-1"
              />
            </div>
          </div>
          <div className="grid grid-cols-3 gap-4">
            <div>
              <Label htmlFor="grade">Grade</Label>
              <Input
                id="grade"
                type="number"
                min={1}
                max={14}
                value={grade}
                onChange={(e) => setGrade(e.target.value)}
                placeholder="9"
                className="mt-1"
              />
            </div>
            <div>
              <Label htmlFor="board">Board</Label>
              <select
                id="board"
                value={board}
                onChange={(e) => setBoard(e.target.value)}
                className="mt-1 flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
              >
                {BOARDS.map((b) => (
                  <option key={b.value} value={b.value}>
                    {b.label}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <Label htmlFor="language">Language</Label>
              <select
                id="language"
                value={language}
                onChange={(e) => setLanguage(e.target.value)}
                className="mt-1 flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
              >
                <option value="en">English</option>
                <option value="ur">Urdu (best-effort)</option>
                <option value="mixed">Mixed</option>
              </select>
            </div>
          </div>
          <label className="flex items-start gap-2 text-sm text-muted-foreground">
            <input
              type="checkbox"
              checked={rightsAck}
              onChange={(e) => setRightsAck(e.target.checked)}
              className="mt-0.5"
            />
            <span>
              I have the right to upload this material and to have it processed (see the{' '}
              <a href="/acceptable-use" target="_blank" className="underline">
                Acceptable Use Policy
              </a>
              ).
            </span>
          </label>
          <Button type="submit" disabled={submitting}>
            {submitting ? 'Uploading…' : 'Upload'}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
