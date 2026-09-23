'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import {
  FileText,
  Plus,
  Search,
  CheckCircle2,
  AlertTriangle,
  History,
  Languages,
  Eye,
  Send,
  Layers,
  Sparkles,
  Info,
  ShieldAlert,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Modal } from '@/components/ui/modal';
import {
  MessageTemplateRow,
  MessageTemplateVersionRow,
  TemplatePlaceholderRow,
  CommRecipientType,
  SmsEncoding,
  MessageClass,
  getTemplates,
  createTemplate,
  createNextVersion,
  publishTemplateVersion,
  previewRender,
} from './actions';

export function calculateSmsSegments(
  body: string,
  encoding: SmsEncoding = 'auto'
): {
  length: number;
  isUcs2: boolean;
  segments: number;
  limitSingle: number;
  limitConcat: number;
  charsRemaining: number;
} {
  const len = body.length;
  if (len === 0) {
    return {
      length: 0,
      isUcs2: false,
      segments: 0,
      limitSingle: 160,
      limitConcat: 153,
      charsRemaining: 160,
    };
  }

  let isUcs2 = false;
  if (encoding === 'ucs2') {
    isUcs2 = true;
  } else if (encoding === 'gsm7') {
    isUcs2 = false;
  } else {
    const nonGsmRegex = /[^\x20-\x7E\r\n\t£$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¡ÄÖÑÜ§¿äöñüà€]/;
    isUcs2 = nonGsmRegex.test(body);
  }

  if (isUcs2) {
    const segments = len <= 70 ? 1 : Math.ceil(len / 67);
    const maxCapacity = segments <= 1 ? 70 : segments * 67;
    return {
      length: len,
      isUcs2: true,
      segments,
      limitSingle: 70,
      limitConcat: 67,
      charsRemaining: maxCapacity - len,
    };
  } else {
    const segments = len <= 160 ? 1 : Math.ceil(len / 153);
    const maxCapacity = segments <= 1 ? 160 : segments * 153;
    return {
      length: len,
      isUcs2: false,
      segments,
      limitSingle: 160,
      limitConcat: 153,
      charsRemaining: maxCapacity - len,
    };
  }
}

export function TemplateDesk({
  initialTemplates,
  placeholders,
}: {
  initialTemplates: MessageTemplateRow[];
  placeholders: TemplatePlaceholderRow[];
}) {
  const router = useRouter();
  const [templates, setTemplates] = React.useState<MessageTemplateRow[]>(initialTemplates);
  const [search, setSearch] = React.useState('');
  const [selectedCategory, setSelectedCategory] = React.useState('all');
  const [selectedAudience, setSelectedAudience] = React.useState('all');

  React.useEffect(() => {
    setTemplates(initialTemplates);
  }, [initialTemplates]);

  // Modals & Panels
  const [isCreateOpen, setIsCreateOpen] = React.useState(false);
  const [selectedTemplate, setSelectedTemplate] = React.useState<MessageTemplateRow | null>(null);
  const [isVersionDrawerOpen, setIsVersionDrawerOpen] = React.useState(false);
  const [isPreviewOpen, setIsPreviewOpen] = React.useState(false);
  const [previewVersion, setPreviewVersion] = React.useState<MessageTemplateVersionRow | null>(null);

  // New Template Form State
  const [createName, setCreateName] = React.useState('');
  const [createAudience, setCreateAudience] = React.useState<CommRecipientType>('guardian');
  const [createCategory, setCreateCategory] = React.useState('attendance');
  const [createDesc, setCreateDesc] = React.useState('');
  const [createBodyEn, setCreateBodyEn] = React.useState('');
  const [createBodyUr, setCreateBodyUr] = React.useState('');
  const [createEncoding, setCreateEncoding] = React.useState<SmsEncoding>('auto');
  const [createPublishNow, setCreatePublishNow] = React.useState(true);
  const [createError, setCreateError] = React.useState<string | null>(null);
  const [isCreating, setIsCreating] = React.useState(false);

  // New Version Form State (for existing template)
  const [newVersionBodyEn, setNewVersionBodyEn] = React.useState('');
  const [newVersionBodyUr, setNewVersionBodyUr] = React.useState('');
  const [newVersionSummary, setNewVersionSummary] = React.useState('');
  const [newVersionEncoding, setNewVersionEncoding] = React.useState<SmsEncoding>('auto');
  const [newVersionPublishNow, setNewVersionPublishNow] = React.useState(false);
  const [newVersionError, setNewVersionError] = React.useState<string | null>(null);
  const [isCreatingVersion, setIsCreatingVersion] = React.useState(false);

  // Preview State
  const [previewLang, setPreviewLang] = React.useState<'en' | 'ur'>('en');
  const [previewContext, setPreviewContext] = React.useState<Record<string, string>>({});
  const [renderedPreview, setRenderedPreview] = React.useState<string>('');
  const [previewError, setPreviewError] = React.useState<string | null>(null);
  const [isRendering, setIsRendering] = React.useState(false);

  // Categories
  const categories = [
    { id: 'all', label: 'All Categories' },
    { id: 'attendance', label: 'Attendance' },
    { id: 'fee', label: 'Fee & Billing' },
    { id: 'academic', label: 'Academic & Exams' },
    { id: 'general', label: 'General Notices' },
  ];

  // Filter templates
  const filteredTemplates = templates.filter((t) => {
    if (selectedCategory !== 'all' && t.category !== selectedCategory) return false;
    if (selectedAudience !== 'all' && t.audience_entity !== selectedAudience) return false;
    if (search.trim()) {
      const q = search.trim().toLowerCase();
      const inName = t.name.toLowerCase().includes(q);
      const inDesc = t.description?.toLowerCase().includes(q) || false;
      const inBody =
        t.latest_version?.body_en.toLowerCase().includes(q) ||
        t.latest_version?.body_ur?.toLowerCase().includes(q) ||
        false;
      if (!inName && !inDesc && !inBody) return false;
    }
    return true;
  });

  // Available tokens for current selected audience
  const currentTokens = (audience: CommRecipientType) =>
    placeholders.filter((p) => p.entity === audience || p.entity === 'custom');

  // Insert token into active textarea
  const insertToken = (
    token: string,
    field: 'en' | 'ur',
    setter: React.Dispatch<React.SetStateAction<string>>
  ) => {
    setter((prev) => `${prev}{{${token}}}`);
  };

  // Open Version Drawer for a template
  const openVersions = (tmpl: MessageTemplateRow) => {
    setSelectedTemplate(tmpl);
    const latest = tmpl.latest_version || tmpl.versions?.[0];
    setNewVersionBodyEn(latest?.body_en || '');
    setNewVersionBodyUr(latest?.body_ur || '');
    setNewVersionSummary('');
    setNewVersionEncoding(latest?.sms_encoding || 'auto');
    setNewVersionPublishNow(false);
    setNewVersionError(null);
    setIsVersionDrawerOpen(true);
  };

  // Open Preview for a version
  const openPreview = (tmpl: MessageTemplateRow, ver: MessageTemplateVersionRow) => {
    setSelectedTemplate(tmpl);
    setPreviewVersion(ver);
    // Prefill context with placeholder samples
    const sampleCtx: Record<string, string> = {};
    const relevant = currentTokens(tmpl.audience_entity);
    relevant.forEach((p) => {
      sampleCtx[p.token] = p.sample_value;
    });
    setPreviewContext(sampleCtx);
    setPreviewError(null);
    setRenderedPreview('');
    setIsPreviewOpen(true);
  };

  // Handle Live Render
  React.useEffect(() => {
    if (isPreviewOpen && previewVersion) {
      handleLiveRender();
    }
  }, [isPreviewOpen, previewVersion, previewLang, previewContext]);

  const handleLiveRender = async () => {
    if (!previewVersion) return;
    setIsRendering(true);
    setPreviewError(null);
    try {
      const res = await previewRender(previewVersion.id, previewContext, previewLang);
      if (res.success && res.renderedText) {
        setRenderedPreview(res.renderedText);
      } else {
        setPreviewError(res.error || 'Failed to render template');
        setRenderedPreview('');
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Render error';
      setPreviewError(msg);
      setRenderedPreview('');
    } finally {
      setIsRendering(false);
    }
  };

  // Handle Template Creation
  const handleCreateTemplate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!createName.trim()) {
      setCreateError('Template name is required.');
      return;
    }
    if (!createBodyEn.trim()) {
      setCreateError('English body text is required.');
      return;
    }

    setIsCreating(true);
    setCreateError(null);

    const res = await createTemplate({
      name: createName,
      audience_entity: createAudience,
      category: createCategory,
      description: createDesc,
      body_en: createBodyEn,
      body_ur: createBodyUr || undefined,
      sms_encoding: createEncoding,
      publish_immediately: createPublishNow,
    });

    setIsCreating(false);

    if (res.success) {
      setIsCreateOpen(false);
      setCreateName('');
      setCreateBodyEn('');
      setCreateBodyUr('');
      setCreateDesc('');
      try {
        const fresh = await getTemplates();
        setTemplates(fresh);
      } catch (e) {
        console.error(e);
      }
      router.refresh();
    } else {
      setCreateError(res.error || 'Failed to create template');
    }
  };

  // Handle Creating New Version for existing template
  const handleCreateVersion = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedTemplate) return;
    if (!newVersionBodyEn.trim()) {
      setNewVersionError('English body text is required.');
      return;
    }

    setIsCreatingVersion(true);
    setNewVersionError(null);

    const res = await createNextVersion({
      template_id: selectedTemplate.id,
      body_en: newVersionBodyEn,
      body_ur: newVersionBodyUr || undefined,
      sms_encoding: newVersionEncoding,
      change_summary: newVersionSummary,
      publish_immediately: newVersionPublishNow,
    });

    setIsCreatingVersion(false);

    if (res.success) {
      setIsVersionDrawerOpen(false);
      try {
        const fresh = await getTemplates();
        setTemplates(fresh);
      } catch (e) {
        console.error(e);
      }
      router.refresh();
    } else {
      setNewVersionError(res.error || 'Failed to create version');
    }
  };

  // Handle Publish Version
  const handlePublish = async (verId: string) => {
    const res = await publishTemplateVersion(verId);
    if (res.success) {
      try {
        const fresh = await getTemplates();
        setTemplates(fresh);
      } catch (e) {
        console.error(e);
      }
      router.refresh();
      setIsVersionDrawerOpen(false);
    } else {
      alert(`Publish rejected: ${res.error}`);
    }
  };

  // Real-time segments for create form
  const createSegEn = calculateSmsSegments(createBodyEn, createEncoding);
  const createSegUr = calculateSmsSegments(createBodyUr, createEncoding);

  // Real-time segments for version form
  const versionSegEn = calculateSmsSegments(newVersionBodyEn, newVersionEncoding);
  const versionSegUr = calculateSmsSegments(newVersionBodyUr, newVersionEncoding);

  return (
    <div className="space-y-6">
      {/* Top Banner / Metrics */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 border-b border-border pb-5">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-2xl font-bold tracking-tight">Message Template Library</h1>
            <span className="text-xs bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300 font-semibold px-2 py-0.5 rounded-full">
              FR-M03 · FR-M04
            </span>
          </div>
          <p className="text-sm text-muted-foreground mt-1">
            Immutable versioned templates, audience-scoped placeholder validation, and Pakistani GSM/UCS-2 SMS segment costing.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            onClick={() => {
              setCreateError(null);
              setIsCreateOpen(true);
            }}
            className="flex items-center gap-1.5"
          >
            <Plus className="w-4 h-4" />
            New Template
          </Button>
        </div>
      </div>

      {/* Filters & Search */}
      <div className="flex flex-col md:flex-row gap-3 items-stretch md:items-center justify-between">
        <div className="flex flex-wrap gap-2">
          {categories.map((c) => (
            <button
              key={c.id}
              onClick={() => setSelectedCategory(c.id)}
              className={`px-3 py-1.5 text-xs font-medium rounded-md transition-colors ${
                selectedCategory === c.id
                  ? 'bg-primary text-primary-foreground'
                  : 'bg-muted hover:bg-muted/80 text-muted-foreground'
              }`}
            >
              {c.label}
            </button>
          ))}
        </div>

        <div className="flex items-center gap-2">
          <select
            value={selectedAudience}
            onChange={(e) => setSelectedAudience(e.target.value)}
            className="text-xs border border-input bg-background rounded-md px-2.5 py-1.5 focus:outline-none focus:ring-1 focus:ring-ring"
          >
            <option value="all">All Audiences</option>
            <option value="guardian">Parents / Guardians</option>
            <option value="student">Students</option>
            <option value="staff">Staff Members</option>
            <option value="custom">Custom / Generic</option>
          </select>

          <div className="relative min-w-[200px]">
            <Search className="w-4 h-4 absolute left-2.5 top-2.5 text-muted-foreground" />
            <input
              type="text"
              placeholder="Search templates..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="text-xs pl-8 pr-3 py-1.5 border border-input rounded-md w-full bg-background focus:outline-none focus:ring-1 focus:ring-ring"
            />
          </div>
        </div>
      </div>

      {/* Templates Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {filteredTemplates.map((t) => {
          const latest = t.latest_version;
          const segEn = latest ? calculateSmsSegments(latest.body_en, latest.sms_encoding) : null;
          const segUr = latest?.body_ur ? calculateSmsSegments(latest.body_ur, latest.sms_encoding) : null;

          return (
            <div
              key={t.id}
              className="border border-border rounded-lg p-4 bg-card hover:border-primary/40 transition-all flex flex-col justify-between shadow-sm"
            >
              <div>
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <h3 className="font-semibold text-base leading-snug">{t.name}</h3>
                    <div className="flex items-center gap-2 mt-1">
                      <span className="text-[10px] uppercase font-bold tracking-wider px-2 py-0.5 bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300 rounded">
                        {t.category}
                      </span>
                      <span className="text-[10px] font-medium px-2 py-0.5 bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300 rounded capitalize">
                        {t.audience_entity}
                      </span>
                    </div>
                  </div>
                  {latest && (
                    <span
                      className={`text-[11px] font-semibold px-2 py-0.5 rounded-full flex items-center gap-1 ${
                        latest.is_published
                          ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300'
                          : 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300'
                      }`}
                    >
                      {latest.is_published ? (
                        <>
                          <CheckCircle2 className="w-3 h-3" /> v{latest.version_no}
                        </>
                      ) : (
                        <>
                          <AlertTriangle className="w-3 h-3" /> v{latest.version_no} Draft
                        </>
                      )}
                    </span>
                  )}
                </div>

                {t.description && (
                  <p className="text-xs text-muted-foreground mt-2 line-clamp-1">{t.description}</p>
                )}

                {/* English Body Snippet */}
                {latest && (
                  <div className="mt-3 space-y-2">
                    <div className="p-2.5 rounded bg-muted/50 border border-border/50 text-xs">
                      <div className="flex items-center justify-between text-[10px] text-muted-foreground font-semibold mb-1">
                        <span>ENGLISH</span>
                        {segEn && (
                          <span
                            className={
                              segEn.isUcs2
                                ? 'text-amber-600 font-bold'
                                : 'text-slate-600 dark:text-slate-400'
                            }
                          >
                            {segEn.length} chars · {segEn.segments} SMS seg ({segEn.isUcs2 ? 'UCS-2' : 'GSM-7'})
                          </span>
                        )}
                      </div>
                      <p className="font-mono text-[11px] text-foreground/90 line-clamp-2">
                        {latest.body_en}
                      </p>
                    </div>

                    {/* Urdu Body Snippet (if present) */}
                    {latest.body_ur && (
                      <div className="p-2.5 rounded bg-emerald-50/50 dark:bg-emerald-950/20 border border-emerald-200/50 dark:border-emerald-800/40 text-xs">
                        <div className="flex items-center justify-between text-[10px] text-emerald-700 dark:text-emerald-400 font-semibold mb-1">
                          <span>اردو (NASTALIQ)</span>
                          {segUr && (
                            <span className="font-bold">
                              {segUr.length} chars · {segUr.segments} SMS seg (UCS-2)
                            </span>
                          )}
                        </div>
                        <p
                          dir="rtl"
                          className="text-[12px] leading-relaxed text-foreground/90 line-clamp-2 text-right font-serif"
                        >
                          {latest.body_ur}
                        </p>
                      </div>
                    )}
                  </div>
                )}
              </div>

              {/* Actions Footer */}
              <div className="mt-4 pt-3 border-t border-border flex items-center justify-between">
                <span className="text-[11px] text-muted-foreground flex items-center gap-1">
                  <History className="w-3.5 h-3.5" />
                  {t.version_count || 1} {t.version_count === 1 ? 'version' : 'versions'}
                </span>
                <div className="flex items-center gap-1.5">
                  {latest && (
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => openPreview(t, latest)}
                      className="h-7 text-xs px-2.5 flex items-center gap-1"
                    >
                      <Eye className="w-3.5 h-3.5" /> Test
                    </Button>
                  )}
                  <Button
                    size="sm"
                    variant="secondary"
                    onClick={() => openVersions(t)}
                    className="h-7 text-xs px-2.5 flex items-center gap-1"
                  >
                    <Layers className="w-3.5 h-3.5" /> Versions
                  </Button>
                </div>
              </div>
            </div>
          );
        })}

        {filteredTemplates.length === 0 && (
          <div className="col-span-full py-12 text-center border border-dashed rounded-lg">
            <FileText className="w-10 h-10 mx-auto text-muted-foreground/50 mb-2" />
            <h3 className="font-semibold text-sm">No templates found</h3>
            <p className="text-xs text-muted-foreground mt-1">
              Try adjusting your category, audience filter, or search keywords.
            </p>
          </div>
        )}
      </div>

      {/* CREATE TEMPLATE MODAL */}
      <Modal
        open={isCreateOpen}
        onClose={() => setIsCreateOpen(false)}
        title="Create Message Template"
        description="Compose version 1 of a new reusable message template. Placeholders are validated against the entity whitelist."
      >
        <form onSubmit={handleCreateTemplate} className="space-y-4 pt-2">
          {createError && (
            <div className="p-3 bg-destructive/10 text-destructive text-xs rounded-md border border-destructive/20 flex items-center gap-2">
              <ShieldAlert className="w-4 h-4 shrink-0" />
              <span>{createError}</span>
            </div>
          )}

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="text-xs font-semibold text-foreground">Template Name *</label>
              <input
                type="text"
                required
                placeholder="e.g. Student Absence Notice"
                value={createName}
                onChange={(e) => setCreateName(e.target.value)}
                className="mt-1 w-full text-xs border border-input rounded-md px-3 py-2 bg-background focus:ring-1 focus:ring-ring"
              />
            </div>

            <div>
              <label className="text-xs font-semibold text-foreground">Audience Entity *</label>
              <select
                value={createAudience}
                onChange={(e) => setCreateAudience(e.target.value as CommRecipientType)}
                className="mt-1 w-full text-xs border border-input rounded-md px-2.5 py-2 bg-background focus:ring-1 focus:ring-ring"
              >
                <option value="guardian">Parents / Guardians</option>
                <option value="student">Students</option>
                <option value="staff">Staff Members</option>
                <option value="custom">Custom / Generic</option>
              </select>
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="text-xs font-semibold text-foreground">Category *</label>
              <select
                value={createCategory}
                onChange={(e) => setCreateCategory(e.target.value)}
                className="mt-1 w-full text-xs border border-input rounded-md px-2.5 py-2 bg-background focus:ring-1 focus:ring-ring"
              >
                <option value="attendance">Attendance</option>
                <option value="fee">Fee & Billing</option>
                <option value="academic">Academic & Exams</option>
                <option value="general">General Notices</option>
              </select>
            </div>

            <div>
              <label className="text-xs font-semibold text-foreground">SMS Encoding (FR-M04)</label>
              <select
                value={createEncoding}
                onChange={(e) => setCreateEncoding(e.target.value as SmsEncoding)}
                className="mt-1 w-full text-xs border border-input rounded-md px-2.5 py-2 bg-background focus:ring-1 focus:ring-ring"
              >
                <option value="auto">Auto-detect (Recommended)</option>
                <option value="gsm7">Force GSM-7 (Roman Urdu / ASCII)</option>
                <option value="ucs2">Force UCS-2 (Unicode / Nastaliq)</option>
              </select>
            </div>
          </div>

          {/* Placeholder Tokens Palette */}
          <div>
            <div className="flex items-center justify-between mb-1.5">
              <label className="text-xs font-semibold text-foreground">
                Whitelisted Placeholders for ({createAudience}):
              </label>
              <span className="text-[10px] text-muted-foreground">Click to insert into English</span>
            </div>
            <div className="flex flex-wrap gap-1.5 p-2.5 bg-muted/40 border border-border rounded-md max-h-24 overflow-y-auto">
              {currentTokens(createAudience).map((p) => (
                <button
                  type="button"
                  key={p.token}
                  onClick={() => insertToken(p.token, 'en', setCreateBodyEn)}
                  title={`${p.description} (Sample: ${p.sample_value})`}
                  className="px-2 py-0.5 text-[11px] font-mono bg-background border border-border/80 hover:border-primary hover:bg-primary/5 rounded text-foreground transition-colors"
                >
                  {`{{${p.token}}}`}
                </button>
              ))}
            </div>
          </div>

          {/* English Body Area */}
          <div>
            <div className="flex items-center justify-between mb-1">
              <label className="text-xs font-semibold text-foreground">English Body *</label>
              <span
                className={`text-[11px] font-mono ${
                  createSegEn.isUcs2 ? 'text-amber-600 font-semibold' : 'text-muted-foreground'
                }`}
              >
                {createSegEn.length} chars · {createSegEn.segments} segment{createSegEn.segments === 1 ? '' : 's'} (
                {createSegEn.isUcs2 ? 'UCS-2' : 'GSM-7'})
              </span>
            </div>
            <textarea
              data-testid="create-body-en"
              required
              rows={3}
              placeholder="e.g. Dear Guardian, {{student_name}} was marked absent on {{attendance_date}}."
              value={createBodyEn}
              onChange={(e) => setCreateBodyEn(e.target.value)}
              className="w-full text-xs font-mono border border-input rounded-md p-2.5 bg-background focus:ring-1 focus:ring-ring"
            />
          </div>

          {/* Urdu Body Area */}
          <div>
            <div className="flex items-center justify-between mb-1">
              <label className="text-xs font-semibold text-foreground">Urdu Body (Nastaliq or Roman-Urdu)</label>
              <span className="text-[11px] font-mono text-emerald-700 dark:text-emerald-400">
                {createSegUr.length} chars · {createSegUr.segments} segment{createSegUr.segments === 1 ? '' : 's'} (
                {createSegUr.isUcs2 ? 'UCS-2' : 'GSM-7'})
              </span>
            </div>
            <textarea
              data-testid="create-body-ur"
              rows={2}
              dir="rtl"
              placeholder="محترم والدین، آپ کے بچے {{student_name}} ..."
              value={createBodyUr}
              onChange={(e) => setCreateBodyUr(e.target.value)}
              className="w-full text-xs font-serif text-right border border-input rounded-md p-2.5 bg-background focus:ring-1 focus:ring-ring"
            />
          </div>

          <div className="flex items-center gap-2 pt-1">
            <input
              type="checkbox"
              id="publish_now"
              checked={createPublishNow}
              onChange={(e) => setCreatePublishNow(e.target.checked)}
              className="rounded border-input text-primary focus:ring-primary"
            />
            <label htmlFor="publish_now" className="text-xs font-medium cursor-pointer text-foreground">
              Publish immediately (runs token whitelist validation)
            </label>
          </div>

          <div className="flex justify-end gap-2 pt-3 border-t border-border">
            <Button type="button" variant="outline" onClick={() => setIsCreateOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={isCreating}>
              {isCreating ? 'Saving...' : createPublishNow ? 'Save & Publish' : 'Save Draft Version'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* VERSION MANAGEMENT & COMPOSER DRAWER */}
      {selectedTemplate && (
        <Modal
          open={isVersionDrawerOpen}
          onClose={() => setIsVersionDrawerOpen(false)}
          title={`Versions: ${selectedTemplate.name}`}
          description={`Audience: ${selectedTemplate.audience_entity} · Category: ${selectedTemplate.category}`}
        >
          <div className="space-y-5 pt-1 max-h-[75vh] overflow-y-auto pr-1">
            {/* Existing Versions History */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-muted-foreground mb-2 flex items-center gap-1.5">
                <History className="w-3.5 h-3.5" /> Version History (Immutable once published)
              </h4>
              <div className="space-y-2">
                {selectedTemplate.versions?.map((v) => (
                  <div
                    key={v.id}
                    className="p-3 border border-border rounded-md bg-card/60 flex flex-col justify-between gap-2"
                  >
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <span className="font-bold text-xs">Version {v.version_no}</span>
                        {v.is_published ? (
                          <span className="text-[10px] bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300 font-semibold px-2 py-0.5 rounded-full flex items-center gap-1">
                            <CheckCircle2 className="w-2.5 h-2.5" /> Published
                          </span>
                        ) : (
                          <span className="text-[10px] bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300 font-semibold px-2 py-0.5 rounded-full flex items-center gap-1">
                            <AlertTriangle className="w-2.5 h-2.5" /> Draft
                          </span>
                        )}
                        {v.change_summary && (
                          <span className="text-xs text-muted-foreground italic">({v.change_summary})</span>
                        )}
                      </div>
                      <div className="flex items-center gap-1.5">
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => openPreview(selectedTemplate, v)}
                          className="h-6 text-[11px] px-2"
                        >
                          <Eye className="w-3 h-3 mr-1" /> Test
                        </Button>
                        {!v.is_published && (
                          <Button
                            size="sm"
                            variant="default"
                            onClick={() => handlePublish(v.id)}
                            className="h-6 text-[11px] px-2 bg-emerald-600 hover:bg-emerald-700 text-white"
                          >
                            Publish
                          </Button>
                        )}
                      </div>
                    </div>
                    <p className="text-xs font-mono text-muted-foreground bg-muted/40 p-2 rounded">
                      {v.body_en}
                    </p>
                    {v.body_ur && (
                      <p
                        dir="rtl"
                        className="text-xs font-serif text-right text-muted-foreground bg-emerald-50/30 dark:bg-emerald-950/20 p-2 rounded"
                      >
                        {v.body_ur}
                      </p>
                    )}
                  </div>
                ))}
              </div>
            </div>

            {/* Compose Next Version */}
            <div className="border-t border-border pt-4">
              <h4 className="text-xs font-bold uppercase tracking-wider text-muted-foreground mb-2 flex items-center gap-1.5">
                <Plus className="w-3.5 h-3.5" /> Compose Next Version (v{(selectedTemplate.versions?.[0]?.version_no || 0) + 1})
              </h4>

              {newVersionError && (
                <div className="p-2.5 bg-destructive/10 text-destructive text-xs rounded-md border border-destructive/20 mb-3 flex items-center gap-1.5">
                  <ShieldAlert className="w-4 h-4 shrink-0" />
                  <span>{newVersionError}</span>
                </div>
              )}

              <form onSubmit={handleCreateVersion} className="space-y-3">
                <div>
                  <div className="flex items-center justify-between mb-1">
                    <label className="text-xs font-semibold">Change Summary</label>
                    <span className="text-[10px] text-muted-foreground">Audit reason for this revision</span>
                  </div>
                  <input
                    type="text"
                    placeholder="e.g. Updated fee deadline phrasing & added school phone"
                    value={newVersionSummary}
                    onChange={(e) => setNewVersionSummary(e.target.value)}
                    className="w-full text-xs border border-input rounded-md px-3 py-1.5 bg-background"
                  />
                </div>

                {/* Placeholder pills */}
                <div>
                  <label className="text-xs font-semibold block mb-1">Insert Whitelisted Tokens:</label>
                  <div className="flex flex-wrap gap-1 p-2 bg-muted/30 border border-border rounded max-h-20 overflow-y-auto">
                    {currentTokens(selectedTemplate.audience_entity).map((p) => (
                      <button
                        type="button"
                        key={p.token}
                        onClick={() => insertToken(p.token, 'en', setNewVersionBodyEn)}
                        className="px-1.5 py-0.5 text-[10px] font-mono bg-background border border-border rounded hover:border-primary"
                      >
                        {`{{${p.token}}}`}
                      </button>
                    ))}
                  </div>
                </div>

                <div>
                  <div className="flex items-center justify-between mb-1">
                    <label className="text-xs font-semibold">English Body *</label>
                    <span className="text-[10px] font-mono text-muted-foreground">
                      {versionSegEn.length} chars · {versionSegEn.segments} seg ({versionSegEn.isUcs2 ? 'UCS-2' : 'GSM-7'})
                    </span>
                  </div>
                  <textarea
                    data-testid="v2-body-en"
                    required
                    rows={3}
                    value={newVersionBodyEn}
                    onChange={(e) => setNewVersionBodyEn(e.target.value)}
                    className="w-full text-xs font-mono border border-input rounded-md p-2 bg-background"
                  />
                </div>

                <div>
                  <div className="flex items-center justify-between mb-1">
                    <label className="text-xs font-semibold">Urdu Body</label>
                    <span className="text-[10px] font-mono text-emerald-700 dark:text-emerald-400">
                      {versionSegUr.length} chars · {versionSegUr.segments} seg
                    </span>
                  </div>
                  <textarea
                    data-testid="v2-body-ur"
                    rows={2}
                    dir="rtl"
                    value={newVersionBodyUr}
                    onChange={(e) => setNewVersionBodyUr(e.target.value)}
                    className="w-full text-xs font-serif text-right border border-input rounded-md p-2 bg-background"
                  />
                </div>

                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="version_publish_now"
                    checked={newVersionPublishNow}
                    onChange={(e) => setNewVersionPublishNow(e.target.checked)}
                    className="rounded border-input text-primary"
                  />
                  <label htmlFor="version_publish_now" className="text-xs font-medium cursor-pointer">
                    Publish immediately (validates tokens against whitelist)
                  </label>
                </div>

                <div className="flex justify-end gap-2 pt-2">
                  <Button type="button" variant="outline" onClick={() => setIsVersionDrawerOpen(false)}>
                    Close
                  </Button>
                  <Button type="submit" disabled={isCreatingVersion}>
                    {isCreatingVersion
                      ? 'Saving...'
                      : newVersionPublishNow
                      ? 'Create & Publish'
                      : 'Create Draft Version'}
                  </Button>
                </div>
              </form>
            </div>
          </div>
        </Modal>
      )}

      {/* LIVE TEST / PREVIEW MODAL */}
      {selectedTemplate && previewVersion && (
        <Modal
          open={isPreviewOpen}
          onClose={() => setIsPreviewOpen(false)}
          title={`Test Render: ${selectedTemplate.name} (v${previewVersion.version_no})`}
          description="Verify placeholder substitution and strict null enforcement before dispatch."
        >
          <div className="space-y-4 pt-1 max-h-[75vh] overflow-y-auto pr-1">
            {previewError && (
              <div className="p-3 bg-amber-50 dark:bg-amber-950/30 border border-amber-300 dark:border-amber-800 text-amber-900 dark:text-amber-200 text-xs rounded-md flex items-start gap-2">
                <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5 text-amber-600" />
                <div>
                  <strong className="font-semibold">AC 3 Enforced: </strong>
                  {previewError}
                </div>
              </div>
            )}

            {/* Language Switcher */}
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold">Render Language:</span>
              <div className="flex rounded-md border border-border p-0.5 bg-muted">
                <button
                  type="button"
                  onClick={() => setPreviewLang('en')}
                  className={`px-3 py-1 text-xs rounded font-medium ${
                    previewLang === 'en'
                      ? 'bg-background shadow-sm text-foreground'
                      : 'text-muted-foreground'
                  }`}
                >
                  English
                </button>
                <button
                  type="button"
                  onClick={() => setPreviewLang('ur')}
                  disabled={!previewVersion.body_ur}
                  className={`px-3 py-1 text-xs rounded font-medium ${
                    previewLang === 'ur'
                      ? 'bg-background shadow-sm text-foreground'
                      : 'text-muted-foreground disabled:opacity-40'
                  }`}
                >
                  اردو (Urdu)
                </button>
              </div>
            </div>

            {/* Test Context Variables Editor */}
            <div>
              <label className="text-xs font-semibold block mb-1.5">Context Variables (Test Inputs):</label>
              <div className="space-y-2 max-h-48 overflow-y-auto p-2 border border-border rounded-md bg-muted/20">
                {currentTokens(selectedTemplate.audience_entity).map((p) => (
                  <div key={p.token} className="flex items-center gap-2">
                    <span className="text-[11px] font-mono w-32 shrink-0 truncate text-foreground font-semibold">
                      {`{{${p.token}}}`}
                    </span>
                    <input
                      type="text"
                      placeholder={`Empty / null (${p.sample_value})`}
                      value={previewContext[p.token] || ''}
                      onChange={(e) =>
                        setPreviewContext((prev) => ({
                          ...prev,
                          [p.token]: e.target.value,
                        }))
                      }
                      className="text-xs border border-input rounded px-2.5 py-1 w-full bg-background font-mono"
                    />
                  </div>
                ))}
              </div>
            </div>

            {/* Rendered Preview Box */}
            <div>
              <div className="flex items-center justify-between mb-1">
                <label className="text-xs font-semibold">Final Output Message (Zero Raw Placeholders):</label>
                {renderedPreview && (
                  <span className="text-[10px] text-muted-foreground font-mono">
                    {renderedPreview.length} chars ·{' '}
                    {calculateSmsSegments(renderedPreview, previewVersion.sms_encoding).segments} SMS Segments
                  </span>
                )}
              </div>
              <div
                data-testid="preview-output"
                dir={previewLang === 'ur' ? 'rtl' : 'ltr'}
                className={`p-3 rounded-md border min-h-[70px] text-xs leading-relaxed ${
                  renderedPreview
                    ? 'bg-emerald-50/50 dark:bg-emerald-950/20 border-emerald-200 dark:border-emerald-850 text-foreground'
                    : 'bg-muted/40 border-dashed border-border text-muted-foreground flex items-center justify-center'
                } ${previewLang === 'ur' ? 'font-serif text-right text-[13px]' : 'font-mono'}`}
              >
                {isRendering ? (
                  <span className="text-muted-foreground">Rendering preview...</span>
                ) : renderedPreview ? (
                  renderedPreview
                ) : (
                  <span className="italic">Fix missing token context above to render final message</span>
                )}
              </div>
            </div>

            <div className="flex justify-end pt-2 border-t border-border">
              <Button type="button" variant="outline" onClick={() => setIsPreviewOpen(false)}>
                Close Preview
              </Button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
