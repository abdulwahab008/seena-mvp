'use client';

import { useState } from 'react';
import Link from 'next/link';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Card, CardContent } from '@/components/ui/card';

type Book = {
  id: string;
  title: string;
  subject: string;
  grade: number | null;
  board: string;
  status: string;
};

type PatternOption = {
  id: string;
  name: string;
  format: string;
  board: string;
  kind: 'builtIn' | 'custom';
};

type Message =
  | { role: 'user'; content: string }
  | { role: 'assistant'; content: string }
  | { role: 'assistant-exam'; examId: string; title: string };

const SUGGESTIONS = [
  'Generate FBISE 9th Physics paper from Chapter 2.',
  'Make a Punjab Board paper, mixed difficulty, full marks.',
  'Create a Cambridge IGCSE structured-question test from this book.',
];

export function ChatPanel({
  books,
  patterns = [],
}: {
  books: Book[];
  patterns?: PatternOption[];
}) {
  const [input, setInput] = useState('');
  const [messages, setMessages] = useState<Message[]>([]);
  const [busy, setBusy] = useState(false);
  const [patternId, setPatternId] = useState<string>('');
  const ready = books.filter((b) => b.status === 'ready');

  const selectedPattern = patterns.find((p) => p.id === patternId) ?? null;

  async function send(text?: string) {
    const raw = (text ?? input).trim();
    if (!raw || busy) return;
    const content = selectedPattern
      ? `using pattern ${selectedPattern.name}: ${raw}`
      : raw;
    setMessages((m) => [...m, { role: 'user', content }]);
    setInput('');
    setBusy(true);
    try {
      const res = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ message: content }),
      });
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      if (data.kind === 'exam') {
        setMessages((m) => [
          ...m,
          { role: 'assistant-exam', examId: data.exam.id, title: data.exam.title },
        ]);
      } else {
        setMessages((m) => [
          ...m,
          { role: 'assistant', content: data.message ?? 'OK.' },
        ]);
      }
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      {ready.length === 0 ? (
        <Card>
          <CardContent className="p-4 text-sm text-muted-foreground">
            You don't have any processed books yet.{' '}
            <Link href="/books/new" className="underline">
              Upload a book
            </Link>{' '}
            to start generating exams.
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardContent className="p-4 text-sm">
            <div className="mb-2 text-muted-foreground">Books ready ({ready.length}):</div>
            <ul className="grid gap-1">
              {ready.map((b) => (
                <li key={b.id}>
                  · {b.title} <span className="text-muted-foreground">— {b.subject} · grade {b.grade ?? '?'} · {b.board}</span>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      {patterns.length > 0 ? (
        <div className="flex items-center gap-2 text-xs">
          <span className="rounded-full border bg-muted px-3 py-1 font-medium">Pattern</span>
          <select
            value={patternId}
            onChange={(e) => setPatternId(e.target.value)}
            className="h-8 rounded-md border border-input bg-background px-2 text-xs"
          >
            <option value="">Auto</option>
            <optgroup label="Built-in">
              {patterns
                .filter((p) => p.kind === 'builtIn')
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
            </optgroup>
            {patterns.some((p) => p.kind === 'custom') ? (
              <optgroup label="Your patterns">
                {patterns
                  .filter((p) => p.kind === 'custom')
                  .map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
              </optgroup>
            ) : null}
          </select>
          {selectedPattern ? (
            <button
              type="button"
              onClick={() => setPatternId('')}
              className="text-muted-foreground underline"
            >
              clear
            </button>
          ) : null}
        </div>
      ) : null}

      <div className="space-y-3">
        {messages.map((m, i) => (
          <Card key={i}>
            <CardContent className="p-4 text-sm">
              {m.role === 'user' ? (
                <>
                  <div className="text-xs text-muted-foreground mb-1">You</div>
                  {m.content}
                </>
              ) : m.role === 'assistant-exam' ? (
                <>
                  <div className="text-xs text-muted-foreground mb-1">Generated</div>
                  <Link href={`/exams/${m.examId}`} className="underline font-medium">
                    {m.title}
                  </Link>
                </>
              ) : (
                <>
                  <div className="text-xs text-muted-foreground mb-1">Seena</div>
                  {m.content}
                </>
              )}
            </CardContent>
          </Card>
        ))}
      </div>

      {messages.length === 0 ? (
        <div className="flex flex-wrap gap-2">
          {SUGGESTIONS.map((s) => (
            <Button key={s} variant="outline" size="sm" onClick={() => send(s)} disabled={busy}>
              {s}
            </Button>
          ))}
        </div>
      ) : null}

      <div className="flex items-end gap-2">
        <Textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder='e.g. "Generate FBISE 9th Physics paper from Chapter 2"'
          rows={3}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) send();
          }}
        />
        <Button onClick={() => send()} disabled={busy}>
          {busy ? 'Generating…' : 'Send'}
        </Button>
      </div>
    </div>
  );
}
