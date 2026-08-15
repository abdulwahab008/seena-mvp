'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Search } from 'lucide-react';
import { cn } from '@/lib/utils';
import { globalSearch, type GlobalSearchHit } from './global-search-actions';

const ENTITY_LABEL: Record<string, string> = {
  student: 'Student',
  guardian: 'Guardian',
  staff: 'Staff',
  fee_challan: 'Challan',
};

const MATCH_LABEL: Record<string, string> = {
  gr_number: 'GR number',
  b_form_no: 'B-Form',
  cnic: 'CNIC',
  phone: 'Phone',
  challan_no: 'Challan no.',
  employee_code: 'Code',
  name_ur: 'Urdu name',
};

export function GlobalSearch() {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [query, setQuery] = React.useState('');
  const [results, setResults] = React.useState<GlobalSearchHit[]>([]);
  const [truncated, setTruncated] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(false);
  const [active, setActive] = React.useState(0);

  const inputRef = React.useRef<HTMLInputElement>(null);
  // Responses can land out of order; only the newest query may paint.
  const seq = React.useRef(0);

  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setOpen(true);
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  React.useEffect(() => {
    if (open) inputRef.current?.focus();
    else {
      setQuery('');
      setResults([]);
      setTruncated(false);
      setError(null);
      setActive(0);
    }
  }, [open]);

  React.useEffect(() => {
    const q = query.trim();
    if (q.length < 2) {
      setResults([]);
      setTruncated(false);
      setError(null);
      setLoading(false);
      return;
    }

    setLoading(true);
    const ticket = ++seq.current;
    const timer = setTimeout(async () => {
      const state = await globalSearch(q);
      if (ticket !== seq.current) return;
      setResults(state.results ?? []);
      setTruncated(state.truncated);
      setError(state.error);
      setActive(0);
      setLoading(false);
    }, 250);

    return () => clearTimeout(timer);
  }, [query]);

  const go = React.useCallback(
    (hit: GlobalSearchHit | undefined) => {
      if (!hit?.href) return;
      setOpen(false);
      router.push(hit.href);
    },
    [router],
  );

  const onInputKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      setOpen(false);
      return;
    }
    if (results.length === 0) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setActive((i) => (i + 1) % results.length);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setActive((i) => (i - 1 + results.length) % results.length);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      go(results[active]);
    }
  };

  const showEmpty = !loading && !error && query.trim().length >= 2 && results.length === 0;

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label="Search"
        aria-keyshortcuts="Meta+K Control+K"
        data-testid="global-search-trigger"
        className="flex items-center gap-2 rounded-md border bg-background px-2.5 py-1.5 text-sm text-muted-foreground transition-colors hover:bg-muted sm:w-56 sm:px-3"
      >
        <Search className="h-4 w-4 shrink-0" aria-hidden />
        <span className="hidden sm:inline">Search…</span>
        <kbd className="ml-auto hidden rounded border bg-muted px-1.5 font-sans text-[10px] sm:inline">
          ⌘K
        </kbd>
      </button>

      {open ? (
        <div className="fixed inset-0 z-[60]" role="dialog" aria-modal="true" aria-label="Search">
          <button
            type="button"
            className="absolute inset-0 animate-fade-in bg-foreground/40 backdrop-blur-[1px]"
            onClick={() => setOpen(false)}
            aria-label="Close search"
            tabIndex={-1}
          />
          <div className="absolute left-1/2 top-[12vh] w-[min(40rem,calc(100vw-2rem))] -translate-x-1/2 overflow-hidden rounded-xl border bg-popover text-popover-foreground shadow-2xl">
            <div className="flex items-center gap-2 border-b px-4">
              <Search className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={onInputKeyDown}
                placeholder="GR number, name, B-Form, CNIC, phone or challan no."
                data-testid="global-search-input"
                className="h-12 w-full bg-transparent text-sm outline-none placeholder:text-muted-foreground"
                role="combobox"
                aria-expanded={results.length > 0}
                aria-controls="global-search-results"
                aria-activedescendant={results.length > 0 ? `global-search-option-${active}` : undefined}
                aria-autocomplete="list"
                autoComplete="off"
              />
            </div>

            <div className="max-h-[min(24rem,60vh)] overflow-y-auto">
              {error ? (
                <p className="px-4 py-6 text-sm text-destructive" data-testid="global-search-error">
                  {error}
                </p>
              ) : null}

              {loading ? (
                <div className="space-y-2 p-4" data-testid="global-search-loading" aria-hidden>
                  {[0, 1, 2].map((i) => (
                    <div key={i} className="h-9 animate-pulse rounded bg-muted" />
                  ))}
                </div>
              ) : null}

              {showEmpty ? (
                <p className="px-4 py-6 text-sm text-muted-foreground" data-testid="global-search-empty">
                  Nothing matched “{query.trim()}”.
                </p>
              ) : null}

              {results.length > 0 ? (
                <ul id="global-search-results" role="listbox" aria-label="Search results">
                  {results.map((hit, i) => (
                    <li
                      key={`${hit.entity_type}-${hit.entity_id}`}
                      id={`global-search-option-${i}`}
                      role="option"
                      aria-selected={i === active}
                    >
                      <button
                        type="button"
                        onClick={() => go(hit)}
                        onMouseEnter={() => setActive(i)}
                        disabled={!hit.href}
                        data-testid={`global-search-result-${hit.display_label}`}
                        className={cn(
                          'flex w-full items-center gap-3 px-4 py-2.5 text-left text-sm',
                          i === active && 'bg-muted',
                          !hit.href && 'cursor-default opacity-70',
                        )}
                      >
                        <span className="w-16 shrink-0 text-xs text-muted-foreground">
                          {ENTITY_LABEL[hit.entity_type] ?? hit.entity_type}
                        </span>
                        <span className="min-w-0 flex-1">
                          <span className="block truncate font-medium">{hit.display_label}</span>
                          {hit.subtitle ? (
                            <span className="block truncate text-xs text-muted-foreground">
                              {hit.subtitle}
                            </span>
                          ) : null}
                        </span>
                        {MATCH_LABEL[hit.match_field] ? (
                          <span className="shrink-0 rounded-full border px-2 py-0.5 text-[10px] text-muted-foreground">
                            {MATCH_LABEL[hit.match_field]}
                          </span>
                        ) : null}
                      </button>
                    </li>
                  ))}
                </ul>
              ) : null}

              {/* The cap is disclosed rather than silently swallowing matches. */}
              {truncated ? (
                <p
                  className="border-t px-4 py-2 text-xs text-muted-foreground"
                  data-testid="global-search-truncated"
                >
                  More matches than shown — refine your search to narrow it down.
                </p>
              ) : null}
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
