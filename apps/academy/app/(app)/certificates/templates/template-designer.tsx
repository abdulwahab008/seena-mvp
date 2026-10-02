'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { activateCertificateTemplate, createCertificateTemplate, saveCertificateTemplate } from './actions';
import { validateMergeFields, type CatalogField } from '@/lib/certificates/merge';
import {
  CERTIFICATE_LANGUAGES,
  CERTIFICATE_PAGE_SIZES,
  CERTIFICATE_TYPES,
  type CertificateLanguageCode,
  type CertificatePageSize,
  type CertificateType,
} from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type TemplateRow = {
  id: string;
  campus_id: string | null;
  certificate_type: CertificateType;
  board_code: string | null;
  language: CertificateLanguageCode;
  version: number;
  title: string;
  body_html: string;
  page_size: CertificatePageSize;
  status: 'draft' | 'active' | 'retired';
  activated_at: string | null;
  merge_field_whitelist: string[] | null;
  campus: { code: string; name: string } | null;
};

export type CatalogRow = CatalogField & { certificate_type: CertificateType };

export type CampusOption = { id: string; code: string; name: string };

const TYPE_LABEL: Record<CertificateType, string> = {
  transfer: 'Transfer / School Leaving',
  character: 'Character',
  bonafide: 'Bonafide',
};

const LANGUAGE_LABEL: Record<CertificateLanguageCode, string> = { en: 'English', ur: 'اردو (Urdu)' };

const TENANT_DEFAULT = '__tenant__';
const ANY_BOARD = 'Any board';

const STARTER_BODY =
  '<p>This is to certify that <b>{{student.name_en}}</b>, son/daughter of {{student.father_name_en}}, GR No. {{student.gr_number}}, was a student of this institution.</p>\n<p>Issued on {{issue.date}}.</p>';

function scopeLabel(t: TemplateRow): string {
  return t.campus ? `${t.campus.code}` : 'Tenant default';
}

export function TemplateDesigner({
  templates,
  catalog,
  campuses,
  canAuthorTenantDefault,
}: {
  templates: TemplateRow[];
  catalog: CatalogRow[];
  campuses: CampusOption[];
  canAuthorTenantDefault: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  const [newType, setNewType] = useState<CertificateType>('transfer');
  const [newLanguage, setNewLanguage] = useState<CertificateLanguageCode>('en');
  const [newPageSize, setNewPageSize] = useState<CertificatePageSize>('A4');
  const [newScope, setNewScope] = useState<string>(campuses[0]?.id ?? TENANT_DEFAULT);
  const [newBoard, setNewBoard] = useState('');
  const [newTitle, setNewTitle] = useState('');
  const [newBody, setNewBody] = useState(STARTER_BODY);

  const [selectedId, setSelectedId] = useState<string | null>(templates[0]?.id ?? null);
  const [draftTitle, setDraftTitle] = useState(templates[0]?.title ?? '');
  const [draftBody, setDraftBody] = useState(templates[0]?.body_html ?? '');
  const [draftPageSize, setDraftPageSize] = useState<CertificatePageSize>(templates[0]?.page_size ?? 'A4');
  const [activateError, setActivateError] = useState<string | null>(null);

  const selected = templates.find((t) => t.id === selectedId) ?? null;
  const editorCatalog = catalog.filter((f) => f.certificate_type === (selected?.certificate_type ?? newType));
  const report = validateMergeFields(draftBody, editorCatalog);

  const select = (t: TemplateRow) => {
    setSelectedId(t.id);
    setDraftTitle(t.title);
    setDraftBody(t.body_html);
    setDraftPageSize(t.page_size);
    setActivateError(null);
  };

  const onCreate = () => {
    const fd = new FormData();
    fd.set('certificateType', newType);
    fd.set('title', newTitle);
    fd.set('bodyHtml', newBody);
    fd.set('boardCode', newBoard.trim().toUpperCase());
    fd.set('language', newLanguage);
    fd.set('pageSize', newPageSize);
    fd.set('campusId', newScope === TENANT_DEFAULT ? '' : newScope);

    startTransition(async () => {
      const result = await createCertificateTemplate(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success('Template created as a draft.');
      setSelectedId(result.templateId!);
      setDraftTitle(newTitle);
      setDraftBody(newBody);
      setDraftPageSize(newPageSize);
      setActivateError(null);
      setNewTitle('');
      router.refresh();
    });
  };

  const onSave = () => {
    if (!selectedId) return;
    const fd = new FormData();
    fd.set('templateId', selectedId);
    fd.set('title', draftTitle);
    fd.set('bodyHtml', draftBody);
    fd.set('pageSize', draftPageSize);

    startTransition(async () => {
      const result = await saveCertificateTemplate(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      // AC2: an edit to an activated version lands on a NEW draft row; the
      // editor follows it there so the author is never left typing into a
      // version that no longer receives her changes.
      const forked = result.templateId !== selectedId;
      setSelectedId(result.templateId!);
      setActivateError(null);
      toast.success(forked ? 'Saved as a new draft version — the active version is unchanged.' : 'Draft saved.');
      router.refresh();
    });
  };

  const onActivate = () => {
    if (!selectedId) return;
    startTransition(async () => {
      const result = await activateCertificateTemplate(selectedId);
      if (result.error) {
        setActivateError(result.error);
        toast.error('Activation rejected.');
        return;
      }
      setActivateError(null);
      toast.success('Template activated.');
      router.refresh();
    });
  };

  const insertField = (fieldPath: string) => setDraftBody((body) => `${body}{{${fieldPath}}}`);

  return (
    <div className="space-y-8">
      <section className="space-y-4 rounded-lg border p-4">
        <h2 className="text-lg font-medium">New template</h2>
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor="new-type">Certificate type</Label>
            <Select value={newType} onValueChange={(v) => setNewType(v as CertificateType)}>
              <SelectTrigger id="new-type" className="min-w-56" data-testid="cert-new-type-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CERTIFICATE_TYPES.map((t) => (
                  <SelectItem key={t} value={t} data-testid={`cert-new-type-${t}`}>
                    {TYPE_LABEL[t]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label htmlFor="new-scope">Scope</Label>
            <Select value={newScope} onValueChange={setNewScope}>
              <SelectTrigger id="new-scope" className="min-w-48" data-testid="cert-new-scope-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {canAuthorTenantDefault && (
                  <SelectItem value={TENANT_DEFAULT} data-testid="cert-new-scope-tenant">
                    Tenant default (all campuses)
                  </SelectItem>
                )}
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id} data-testid={`cert-new-scope-${c.code}`}>
                    {c.code} — {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label htmlFor="new-board">Board code</Label>
            <Input
              id="new-board"
              value={newBoard}
              onChange={(e) => setNewBoard(e.target.value)}
              placeholder={ANY_BOARD}
              className="w-40 uppercase"
              data-testid="cert-new-board"
            />
          </div>

          <div className="space-y-1">
            <Label htmlFor="new-language">Language</Label>
            <Select value={newLanguage} onValueChange={(v) => setNewLanguage(v as CertificateLanguageCode)}>
              <SelectTrigger id="new-language" className="min-w-36" data-testid="cert-new-language-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CERTIFICATE_LANGUAGES.map((l) => (
                  <SelectItem key={l} value={l} data-testid={`cert-new-language-${l}`}>
                    {LANGUAGE_LABEL[l]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label htmlFor="new-page-size">Page size</Label>
            <Select value={newPageSize} onValueChange={(v) => setNewPageSize(v as CertificatePageSize)}>
              <SelectTrigger id="new-page-size" className="min-w-28" data-testid="cert-new-page-size-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CERTIFICATE_PAGE_SIZES.map((p) => (
                  <SelectItem key={p} value={p} data-testid={`cert-new-page-size-${p}`}>
                    {p}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        <div className="space-y-1">
          <Label htmlFor="new-title">Title as printed</Label>
          <Input
            id="new-title"
            value={newTitle}
            onChange={(e) => setNewTitle(e.target.value)}
            placeholder="School Leaving Certificate"
            data-testid="cert-new-title"
          />
        </div>

        <div className="space-y-1">
          <Label htmlFor="new-body">Wording (HTML)</Label>
          <textarea
            id="new-body"
            value={newBody}
            onChange={(e) => setNewBody(e.target.value)}
            rows={6}
            className="flex w-full rounded-md border border-input bg-transparent px-3 py-2 font-mono text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            data-testid="cert-new-body"
          />
        </div>

        <Button type="button" disabled={pending} onClick={onCreate} data-testid="cert-new-submit">
          Create draft
        </Button>
      </section>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,20rem)_minmax(0,1fr)]">
        <section className="space-y-2">
          <h2 className="text-lg font-medium">Templates</h2>
          {templates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="cert-template-empty">
              No certificate templates yet.
            </p>
          ) : (
            templates.map((t) => (
              <Card
                key={t.id}
                className={t.id === selectedId ? 'border-foreground' : undefined}
                data-testid={`cert-template-${t.id}`}
              >
                <CardContent className="space-y-1 p-3 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="font-medium">{t.title}</span>
                    <span className="text-xs uppercase" data-testid={`cert-template-status-${t.id}`}>
                      {t.status}
                    </span>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {TYPE_LABEL[t.certificate_type]} · {t.board_code ?? ANY_BOARD} · {LANGUAGE_LABEL[t.language]} ·{' '}
                    {scopeLabel(t)} · v{t.version} · {t.page_size}
                  </p>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => select(t)}
                    data-testid={`cert-template-select-${t.id}`}
                  >
                    Open
                  </Button>
                </CardContent>
              </Card>
            ))
          )}
        </section>

        <section className="space-y-4">
          <h2 className="text-lg font-medium">Editor</h2>
          {!selected ? (
            <p className="text-sm text-muted-foreground">Select a template to edit its wording.</p>
          ) : (
            <div className="space-y-4" data-testid="cert-editor">
              <p className="text-sm text-muted-foreground" data-testid="cert-editor-heading">
                {TYPE_LABEL[selected.certificate_type]} · {selected.board_code ?? ANY_BOARD} ·{' '}
                {LANGUAGE_LABEL[selected.language]} · {scopeLabel(selected)} · v{selected.version} ·{' '}
                <span data-testid="cert-editor-status">{selected.status}</span>
              </p>

              <div className="space-y-1">
                <Label htmlFor="edit-title">Title as printed</Label>
                <Input id="edit-title" value={draftTitle} onChange={(e) => setDraftTitle(e.target.value)} data-testid="cert-edit-title" />
              </div>

              <div className="space-y-1">
                <Label htmlFor="edit-body">Wording (HTML)</Label>
                <textarea
                  id="edit-body"
                  value={draftBody}
                  onChange={(e) => setDraftBody(e.target.value)}
                  rows={12}
                  className="flex w-full rounded-md border border-input bg-transparent px-3 py-2 font-mono text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  data-testid="cert-edit-body"
                />
              </div>

              <div className="flex flex-wrap items-end gap-3">
                <div className="space-y-1">
                  <Label htmlFor="edit-page-size">Page size</Label>
                  <Select value={draftPageSize} onValueChange={(v) => setDraftPageSize(v as CertificatePageSize)}>
                    <SelectTrigger id="edit-page-size" className="min-w-28" data-testid="cert-edit-page-size-trigger">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {CERTIFICATE_PAGE_SIZES.map((p) => (
                        <SelectItem key={p} value={p} data-testid={`cert-edit-page-size-${p}`}>
                          {p}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <Button type="button" disabled={pending} onClick={onSave} data-testid="cert-edit-save">
                  Save
                </Button>
                <Button
                  type="button"
                  variant="secondary"
                  disabled={pending || selected.status !== 'draft'}
                  onClick={onActivate}
                  data-testid="cert-edit-activate"
                >
                  Activate
                </Button>
                <a
                  className="text-sm underline"
                  href={`/api/certificate-template/${selected.id}/preview`}
                  target="_blank"
                  rel="noreferrer"
                  data-testid="cert-edit-preview-link"
                >
                  Preview PDF
                </a>
              </div>

              {activateError && (
                <p className="rounded-md border border-destructive/50 p-3 text-sm text-destructive" data-testid="cert-activate-error">
                  {activateError}
                </p>
              )}

              <div className="space-y-3 rounded-lg border p-3 text-sm">
                <div>
                  <p className="font-medium">Merge fields in use</p>
                  <p className="text-xs text-muted-foreground" data-testid="cert-used-fields">
                    {report.used.length === 0 ? 'None' : report.used.join(', ')}
                  </p>
                </div>
                {report.unknown.length > 0 && (
                  <p className="text-xs text-destructive" data-testid="cert-unknown-fields">
                    Not in the whitelist: {report.unknown.join(', ')}
                  </p>
                )}
                {report.missingRequired.length > 0 && (
                  <p className="text-xs text-destructive" data-testid="cert-missing-required">
                    Required but missing: {report.missingRequired.join(', ')}
                  </p>
                )}
                <div>
                  <p className="font-medium">Whitelist for {TYPE_LABEL[selected.certificate_type]}</p>
                  <div className="mt-1 flex flex-wrap gap-1" data-testid="cert-whitelist">
                    {editorCatalog.map((f) => (
                      <button
                        key={f.field_path}
                        type="button"
                        onClick={() => insertField(f.field_path)}
                        title={f.label_en}
                        className={`rounded border px-1.5 py-0.5 font-mono text-xs ${
                          f.required ? 'border-foreground font-semibold' : 'text-muted-foreground'
                        }`}
                        data-testid={`cert-whitelist-${f.field_path}`}
                      >
                        {f.field_path}
                        {f.required ? ' *' : ''}
                      </button>
                    ))}
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground">* required for this certificate type.</p>
                </div>
              </div>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
