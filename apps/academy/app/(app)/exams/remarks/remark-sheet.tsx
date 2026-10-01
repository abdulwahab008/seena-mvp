'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { REMARK_MAX_LENGTH } from '@/lib/validation';
import { addLibraryEntry, applyRemark, saveRemark, seedLibrary, setRemarksRequired } from './actions';
import { Button } from '@/components/ui/button';

export type SheetRow = { enrolmentId: string; grNumber: string; name: string; nameUr: string | null; rollNo: number | null; text: string; libraryId: string | null };
export type LibraryOption = { id: string; category: string; textEn: string; textUr: string | null };

type LibLang = 'en' | 'ur';
const pick = (o: LibraryOption, lang: LibLang) => (lang === 'ur' && o.textUr ? o.textUr : o.textEn);

function LibrarySelect({ options, lang, onPick, label }: { options: LibraryOption[]; lang: LibLang; onPick: (o: LibraryOption) => void; label: string }) {
  return (
    <select
      aria-label={label}
      className="h-9 w-full rounded-md border bg-background px-2 text-sm"
      value=""
      onChange={(e) => {
        const o = options.find((x) => x.id === e.target.value);
        if (o) onPick(o);
      }}
    >
      <option value="">From the library…</option>
      {options.map((o) => (
        <option key={o.id} value={o.id}>
          [{o.category}] {pick(o, lang).slice(0, 70)}
        </option>
      ))}
    </select>
  );
}

function Counter({ value }: { value: string }) {
  const n = [...value].length;
  return (
    <span className={`text-xs ${n >= REMARK_MAX_LENGTH ? 'text-destructive' : 'text-muted-foreground'}`} data-testid="remark-counter">
      {n}/{REMARK_MAX_LENGTH}
    </span>
  );
}

function RemarkRow({ row, examTermId, options, lang, selected, onToggle }: { row: SheetRow; examTermId: string; options: LibraryOption[]; lang: LibLang; selected: boolean; onToggle: () => void }) {
  const router = useRouter();
  const [text, setText] = useState(row.text);
  const [libraryId, setLibraryId] = useState<string | null>(row.libraryId);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const dirty = text !== row.text;
  const save = () =>
    startTransition(async () => {
      const r = await saveRemark({ enrolmentId: row.enrolmentId, examTermId, text, libraryId: libraryId ?? '' });
      setError(r.error);
      if (!r.error) {
        toast.success('Remark saved.');
        router.refresh();
      }
    });
  return (
    <tr className="border-b align-top" data-testid="remark-row" data-gr={row.grNumber}>
      <td className="py-2 pr-2">
        <input type="checkbox" checked={selected} onChange={onToggle} aria-label={`Select ${row.name}`} />
      </td>
      <td className="pr-2">
        {row.rollNo ?? ''}
        <span className="block text-xs text-muted-foreground">{row.grNumber}</span>
      </td>
      <td className="pr-2">
        {row.name}
        {row.nameUr && (
          <span className="block text-xs text-muted-foreground" dir="rtl">
            {row.nameUr}
          </span>
        )}
      </td>
      <td className="w-64 pr-2">
        <LibrarySelect
          options={options}
          lang={lang}
          label={`Library remark for ${row.name}`}
          onPick={(o) => {
            setText(pick(o, lang).slice(0, REMARK_MAX_LENGTH));
            setLibraryId(o.id);
          }}
        />
      </td>
      <td className="w-[28rem]">
        <textarea
          aria-label={`Remark for ${row.name}`}
          dir="auto"
          rows={2}
          maxLength={REMARK_MAX_LENGTH}
          value={text}
          onChange={(e) => {
            setText(e.target.value.slice(0, REMARK_MAX_LENGTH));
            setLibraryId(null);
          }}
          className="w-full rounded-md border bg-background px-2 py-1 text-sm"
        />
        <div className="flex items-center justify-between gap-2">
          <Counter value={text} />
          <Button size="sm" variant={dirty ? 'default' : 'outline'} disabled={pending || text.trim() === ''} onClick={save} data-testid="save-remark">
            Save
          </Button>
        </div>
        {error && (
          <p role="alert" className="text-xs text-destructive" data-testid="remark-error">
            {error}
          </p>
        )}
      </td>
    </tr>
  );
}

export function RemarkSheet({ rows, examTermId, options, campusId }: { rows: SheetRow[]; examTermId: string; options: LibraryOption[]; campusId: string }) {
  const router = useRouter();
  const [lang, setLang] = useState<LibLang>('en');
  const [selected, setSelected] = useState<string[]>([]);
  const [bulkText, setBulkText] = useState('');
  const [bulkLibrary, setBulkLibrary] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const toggle = (id: string) => setSelected((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));
  const apply = () =>
    startTransition(async () => {
      const r = await applyRemark({ examTermId, enrolmentIds: selected, text: bulkText, libraryId: bulkLibrary ?? '' });
      setError(r.error);
      if (!r.error) {
        toast.success(`Remark applied to ${r.count ?? selected.length} students.`);
        setSelected([]);
        router.refresh();
      }
    });
  const seed = () =>
    startTransition(async () => {
      const r = await seedLibrary(campusId);
      setError(r.error);
      if (!r.error) router.refresh();
    });

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <label className="flex items-center gap-2">
          Library language
          <select value={lang} onChange={(e) => setLang(e.target.value as LibLang)} className="h-9 rounded-md border bg-background px-2" aria-label="Library language">
            <option value="en">English</option>
            <option value="ur">اردو</option>
          </select>
        </label>
        {options.length === 0 && (
          <Button size="sm" variant="outline" disabled={pending} onClick={seed} data-testid="seed-library">
            Load standard remarks
          </Button>
        )}
      </div>

      <div className="space-y-2 rounded-md border p-3 text-sm" data-testid="bulk-apply">
        <p className="font-medium">Apply one remark to the selected students ({selected.length} selected)</p>
        <LibrarySelect options={options} lang={lang} label="Library remark for the selection" onPick={(o) => { setBulkText(pick(o, lang).slice(0, REMARK_MAX_LENGTH)); setBulkLibrary(o.id); }} />
        <textarea
          aria-label="Remark for the selection"
          dir="auto"
          rows={2}
          maxLength={REMARK_MAX_LENGTH}
          value={bulkText}
          onChange={(e) => {
            setBulkText(e.target.value.slice(0, REMARK_MAX_LENGTH));
            setBulkLibrary(null);
          }}
          className="w-full rounded-md border bg-background px-2 py-1"
        />
        <div className="flex items-center justify-between gap-2">
          <Counter value={bulkText} />
          <Button size="sm" disabled={pending || selected.length === 0 || bulkText.trim() === ''} onClick={apply} data-testid="apply-selected">
            Apply to selected
          </Button>
        </div>
        {error && (
          <p role="alert" className="text-destructive" data-testid="bulk-error">
            {error}
          </p>
        )}
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm" data-testid="remark-table">
          <thead>
            <tr className="border-b text-muted-foreground">
              <th className="py-1">
                <input
                  type="checkbox"
                  aria-label="Select all students"
                  checked={selected.length === rows.length && rows.length > 0}
                  onChange={(e) => setSelected(e.target.checked ? rows.map((r) => r.enrolmentId) : [])}
                />
              </th>
              <th>Roll / GR</th>
              <th>Student</th>
              <th>Library</th>
              <th>Remark</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <RemarkRow key={`${r.enrolmentId}-${r.text}`} row={r} examTermId={examTermId} options={options} lang={lang} selected={selected.includes(r.enrolmentId)} onToggle={() => toggle(r.enrolmentId)} />
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export function RemarksRequiredToggle({ campusId, required }: { campusId: string; required: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="space-y-1 text-sm">
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          defaultChecked={required}
          disabled={pending}
          data-testid="remarks-required"
          onChange={(e) =>
            startTransition(async () => {
              const r = await setRemarksRequired(campusId, e.target.checked);
              setError(r.error);
              if (!r.error) router.refresh();
            })
          }
        />
        Require a remark for every student before report cards can be generated in bulk
      </label>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function LibraryEntryForm({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [category, setCategory] = useState('general');
  const [textEn, setTextEn] = useState('');
  const [textUr, setTextUr] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const add = () =>
    startTransition(async () => {
      const r = await addLibraryEntry(campusId, { category: category as 'general', textEn, textUr });
      setError(r.error);
      if (!r.error) {
        setTextEn('');
        setTextUr('');
        toast.success('Added to the library.');
        router.refresh();
      }
    });
  return (
    <div className="grid gap-2 text-sm sm:grid-cols-4">
      <select value={category} onChange={(e) => setCategory(e.target.value)} className="h-9 rounded-md border bg-background px-2" aria-label="Library category">
        {['praise', 'improvement', 'behaviour', 'attendance', 'general'].map((c) => (
          <option key={c} value={c}>
            {c}
          </option>
        ))}
      </select>
      <input aria-label="Library text in English" placeholder="English text" maxLength={REMARK_MAX_LENGTH} value={textEn} onChange={(e) => setTextEn(e.target.value)} className="h-9 rounded-md border bg-background px-2" />
      <input aria-label="Library text in Urdu" dir="rtl" placeholder="اردو متن" maxLength={REMARK_MAX_LENGTH} value={textUr} onChange={(e) => setTextUr(e.target.value)} className="h-9 rounded-md border bg-background px-2" />
      <Button size="sm" disabled={pending || textEn.trim() === ''} onClick={add} data-testid="add-library">
        Add to library
      </Button>
      {error && <p role="alert" className="text-xs text-destructive sm:col-span-4">{error}</p>}
    </div>
  );
}
