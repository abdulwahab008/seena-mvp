'use client';

import { useState, useRef, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  Upload,
  FileText,
  Check,
  X,
  ExternalLink,
  GraduationCap,
  Building2,
  Calendar,
  Eye,
  FileCheck,
} from 'lucide-react';
import { addStaffQualification, verifyStaffQualification, getStaffDocumentSignedUrl } from './actions';
import { addStaffQualificationSchema, QUALIFICATION_LEVELS, type AddStaffQualificationInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { cn } from '@/lib/utils';

type StaffOption = { user_id: string; full_name: string };
type QualificationRow = {
  id: string;
  staff_id: string;
  level: (typeof QUALIFICATION_LEVELS)[number];
  discipline: string;
  institution: string;
  year_completed: number;
  verification_status: 'pending' | 'verified' | 'rejected';
  document_id?: string | null;
  staff_document?: {
    id: string;
    label: string;
    storage_path: string | null;
  } | null;
};

type PreviewDocState = {
  qualificationId: string;
  title: string;
  staffName: string;
  level: string;
  yearCompleted: number;
  url: string;
  mimeType?: string;
  status: 'pending' | 'verified' | 'rejected';
};

export function QualificationRegistry({
  staff,
  qualifications,
  currentUser,
}: {
  staff: StaffOption[];
  qualifications: QualificationRow[];
  currentUser?: { userId: string; role: string; name: string };
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [previewLoadingId, setPreviewLoadingId] = useState<string | null>(null);
  const [previewDoc, setPreviewDoc] = useState<PreviewDocState | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const staffName = (id: string) => staff.find((s) => s.user_id === id)?.full_name ?? id;

  const {
    handleSubmit,
    control,
    register,
    reset,
    formState: { errors },
  } = useForm<AddStaffQualificationInput>({ resolver: zodResolver(addStaffQualificationSchema) });

  const onAdd = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('staffId', values.staffId);
    fd.set('level', values.level);
    fd.set('discipline', values.discipline);
    fd.set('institution', values.institution);
    fd.set('yearCompleted', String(values.yearCompleted));
    if (selectedFile) {
      fd.set('document', selectedFile);
    }

    startTransition(async () => {
      const result = await addStaffQualification({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success('Qualification saved.');
        reset({ staffId: values.staffId, discipline: '', institution: '' });
        setSelectedFile(null);
        if (fileInputRef.current) fileInputRef.current.value = '';
        router.refresh();
      }
    });
  });

  const onDecide = (qualificationId: string, status: 'verified' | 'rejected') => {
    const fd = new FormData();
    fd.set('qualificationId', qualificationId);
    fd.set('status', status);
    startTransition(async () => {
      const result = await verifyStaffQualification({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(status === 'verified' ? 'Qualification verified.' : 'Qualification rejected.');
        if (previewDoc && previewDoc.qualificationId === qualificationId) {
          setPreviewDoc((prev) => (prev ? { ...prev, status } : null));
        }
        router.refresh();
      }
    });
  };

  const handlePreviewDocument = async (q: QualificationRow) => {
    if (!q.document_id) return;
    setPreviewLoadingId(q.id);
    try {
      const res = await getStaffDocumentSignedUrl(q.document_id);
      if (res.error || !res.url) {
        toast.error(res.error ?? 'Could not open attached document.');
      } else {
        setPreviewDoc({
          qualificationId: q.id,
          title: q.staff_document?.label ?? `${q.level.toUpperCase()} - ${q.discipline}`,
          staffName: staffName(q.staff_id),
          level: q.level,
          yearCompleted: q.year_completed,
          url: res.url,
          mimeType: res.mimeType,
          status: q.verification_status,
        });
      }
    } catch {
      toast.error('Failed to load document preview.');
    } finally {
      setPreviewLoadingId(null);
    }
  };

  return (
    <div className="space-y-6">
      {/* Registration Card */}
      <div className="rounded-xl border bg-card p-5 shadow-sm space-y-4">
        <div className="flex items-center justify-between border-b pb-3">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
              <GraduationCap className="w-4 h-4" />
            </div>
            <div>
              <h2 className="text-sm font-semibold text-foreground">Record Staff Qualification</h2>
              <p className="text-xs text-muted-foreground">Attach degrees, transcripts, or professional certifications</p>
            </div>
          </div>
        </div>

        <form onSubmit={onAdd} className="space-y-4" noValidate>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="staffId" className="text-xs font-medium">Staff member</Label>
              <Controller
                control={control}
                name="staffId"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger id="staffId" data-testid="qualification-staff-trigger" className="h-9 text-xs">
                      <SelectValue placeholder="Select staff" />
                    </SelectTrigger>
                    <SelectContent>
                      {staff.map((s) => (
                        <SelectItem key={s.user_id} value={s.user_id} className="text-xs">
                          {s.full_name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
              {errors.staffId && <p className="text-xs text-destructive">{errors.staffId.message}</p>}
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="level" className="text-xs font-medium">Qualification level</Label>
              <Controller
                control={control}
                name="level"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger id="level" data-testid="qualification-level-trigger" className="h-9 text-xs">
                      <SelectValue placeholder="Select level" />
                    </SelectTrigger>
                    <SelectContent>
                      {QUALIFICATION_LEVELS.map((l) => (
                        <SelectItem key={l} value={l} className="text-xs capitalize">
                          {l}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
              {errors.level && <p className="text-xs text-destructive">{errors.level.message}</p>}
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="discipline" className="text-xs font-medium">Discipline / Major</Label>
              <Input
                id="discipline"
                placeholder="e.g. Chemistry, Mathematics"
                data-testid="qualification-discipline-input"
                className="h-9 text-xs"
                {...register('discipline')}
              />
              {errors.discipline && <p className="text-xs text-destructive">{errors.discipline.message}</p>}
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="institution" className="text-xs font-medium">Awarding Institution</Label>
              <Input
                id="institution"
                placeholder="e.g. University of the Punjab"
                data-testid="qualification-institution-input"
                className="h-9 text-xs"
                {...register('institution')}
              />
              {errors.institution && <p className="text-xs text-destructive">{errors.institution.message}</p>}
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="yearCompleted" className="text-xs font-medium">Year completed</Label>
              <Input
                id="yearCompleted"
                type="number"
                placeholder="e.g. 2018"
                data-testid="qualification-year-input"
                className="h-9 text-xs"
                {...register('yearCompleted')}
              />
              {errors.yearCompleted && <p className="text-xs text-destructive">{errors.yearCompleted.message}</p>}
            </div>
          </div>

          {/* Document / Transcript Upload Bar */}
          <div className="p-3 rounded-lg border border-dashed bg-muted/20 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
            <div className="flex items-center gap-2.5">
              <div className="w-7 h-7 rounded-md bg-background border flex items-center justify-center shrink-0">
                <FileText className="w-3.5 h-3.5 text-muted-foreground" />
              </div>
              <div>
                <span className="text-xs font-medium text-foreground block">Degree or Transcript Document</span>
                <span className="text-[11px] text-muted-foreground">
                  Optional scan / certificate (PDF, JPG, PNG up to 10MB) for HR verification
                </span>
              </div>
            </div>

            <div className="flex items-center gap-2 shrink-0">
              <input
                ref={fileInputRef}
                type="file"
                accept=".pdf,.jpg,.jpeg,.png,application/pdf,image/jpeg,image/png"
                className="hidden"
                id="transcript-file-input"
                data-testid="qualification-file-input"
                onChange={(e) => {
                  const f = e.target.files?.[0];
                  if (f) {
                    if (f.size > 10 * 1024 * 1024) {
                      toast.error('File size exceeds 10 MB limit');
                      e.target.value = '';
                      return;
                    }
                    setSelectedFile(f);
                  }
                }}
              />

              {!selectedFile ? (
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-8 text-xs gap-1.5"
                  onClick={() => fileInputRef.current?.click()}
                  data-testid="qualification-browse-file-btn"
                >
                  <Upload className="w-3.5 h-3.5 text-primary" />
                  Attach Document
                </Button>
              ) : (
                <div className="flex items-center gap-2 px-2.5 py-1 rounded-md bg-primary/10 border border-primary/20 text-xs text-foreground">
                  <FileCheck className="w-3.5 h-3.5 text-primary shrink-0" />
                  <span className="max-w-[160px] truncate font-medium">{selectedFile.name}</span>
                  <span className="text-[10px] text-muted-foreground">
                    ({(selectedFile.size / (1024 * 1024)).toFixed(1)} MB)
                  </span>
                  <button
                    type="button"
                    onClick={() => {
                      setSelectedFile(null);
                      if (fileInputRef.current) fileInputRef.current.value = '';
                    }}
                    className="p-0.5 rounded hover:bg-destructive/10 text-muted-foreground hover:text-destructive"
                    title="Remove file"
                  >
                    <X className="w-3.5 h-3.5" />
                  </button>
                </div>
              )}

              <Button type="submit" disabled={pending} size="sm" className="h-8 text-xs font-medium">
                {pending ? 'Saving…' : 'Add qualification'}
              </Button>
            </div>
          </div>
        </form>
      </div>

      {/* Qualification Registry Table */}
      <div className="rounded-xl border bg-card shadow-sm overflow-hidden">
        <div className="px-5 py-3 border-b bg-muted/10 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-foreground">Registered Qualifications</h3>
          <span className="text-xs text-muted-foreground">
            {qualifications.length} {qualifications.length === 1 ? 'record' : 'records'} on file
          </span>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b text-left text-muted-foreground bg-muted/20 font-medium">
                <th className="py-2.5 px-3">Staff</th>
                <th className="py-2.5 px-3">Level</th>
                <th className="py-2.5 px-3">Discipline</th>
                <th className="py-2.5 px-3">Institution</th>
                <th className="py-2.5 px-3">Year</th>
                <th className="py-2.5 px-3">Document</th>
                <th className="py-2.5 px-3">Status</th>
                <th className="py-2.5 px-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {qualifications.map((q) => (
                <tr
                  key={q.id}
                  data-testid={`qualification-row-${q.id}`}
                  className="hover:bg-muted/30 transition-colors"
                >
                  <td className="py-2.5 px-3 font-medium text-foreground">
                    {staffName(q.staff_id)}
                  </td>
                  <td className="py-2.5 px-3 capitalize">
                    <span className="inline-flex items-center px-2 py-0.5 rounded bg-muted text-[11px] font-medium">
                      {q.level}
                    </span>
                  </td>
                  <td className="py-2.5 px-3 text-foreground">{q.discipline}</td>
                  <td className="py-2.5 px-3 text-muted-foreground">{q.institution}</td>
                  <td className="py-2.5 px-3 text-muted-foreground">{q.year_completed}</td>

                  {/* Document Attachment Column */}
                  <td className="py-2.5 px-3">
                    {q.document_id ? (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={previewLoadingId === q.id}
                        onClick={() => handlePreviewDocument(q)}
                        data-testid={`qualification-view-doc-${q.id}`}
                        className="h-7 text-[11px] gap-1 px-2 border-blue-200 text-blue-700 dark:border-blue-800 dark:text-blue-300 hover:bg-blue-50 dark:hover:bg-blue-950/40"
                      >
                        <FileText className="w-3 h-3 text-blue-600 dark:text-blue-400" />
                        <span>{previewLoadingId === q.id ? 'Opening…' : 'View File'}</span>
                      </Button>
                    ) : (
                      <span className="text-[11px] text-muted-foreground/60 italic">No document</span>
                    )}
                  </td>

                  {/* Verification Status Badge */}
                  <td className="py-2.5 px-3" data-testid={`qualification-status-${q.id}`}>
                    <span
                      className={cn(
                        'inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-medium capitalize border',
                        q.verification_status === 'verified' &&
                          'bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-300 dark:border-emerald-800',
                        q.verification_status === 'rejected' &&
                          'bg-rose-50 text-rose-700 border-rose-200 dark:bg-rose-950/40 dark:text-rose-300 dark:border-rose-800',
                        q.verification_status === 'pending' &&
                          'bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-950/40 dark:text-amber-300 dark:border-amber-800'
                      )}
                    >
                      {q.verification_status}
                    </span>
                  </td>

                  {/* Actions Column */}
                  <td className="py-2.5 px-3 text-right">
                    {q.verification_status === 'pending' ? (
                      currentUser?.userId === q.staff_id ? (
                        <span
                          className="text-[11px] text-amber-600 dark:text-amber-400 font-medium italic"
                          title="Anti-fraud audit rule: You cannot verify your own degree. An independent Principal or HR Manager must verify it."
                        >
                          Self-verify blocked (2nd admin required)
                        </span>
                      ) : (
                        <div className="flex items-center justify-end gap-1.5">
                          <Button
                            type="button"
                            size="sm"
                            variant="outline"
                            disabled={pending}
                            onClick={() => onDecide(q.id, 'verified')}
                            data-testid={`qualification-verify-${q.id}`}
                            className="h-7 text-xs border-emerald-200 text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950/40"
                          >
                            <Check className="w-3 h-3 mr-1" />
                            Verify
                          </Button>
                          <Button
                            type="button"
                            size="sm"
                            variant="outline"
                            disabled={pending}
                            onClick={() => onDecide(q.id, 'rejected')}
                            data-testid={`qualification-reject-${q.id}`}
                            className="h-7 text-xs border-rose-200 text-rose-700 hover:bg-rose-50 dark:border-rose-800 dark:text-rose-300 dark:hover:bg-rose-950/40"
                          >
                            <X className="w-3 h-3 mr-1" />
                            Reject
                          </Button>
                        </div>
                      )
                    ) : (
                      <span className="text-[11px] text-muted-foreground">Decided</span>
                    )}
                  </td>
                </tr>
              ))}
              {qualifications.length === 0 && (
                <tr>
                  <td className="py-6 text-center text-muted-foreground" colSpan={8}>
                    No qualifications recorded yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* In-App Document Preview Modal */}
      {previewDoc && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm animate-in fade-in duration-150"
          onClick={(e) => {
            if (e.target === e.currentTarget) setPreviewDoc(null);
          }}
        >
          <div className="bg-background rounded-xl border shadow-xl w-full max-w-4xl max-h-[90vh] flex flex-col overflow-hidden">
            {/* Modal Header */}
            <div className="flex items-center justify-between px-5 py-3.5 border-b bg-muted/10">
              <div className="flex items-center gap-2.5">
                <div className="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
                  <FileText className="w-4 h-4" />
                </div>
                <div>
                  <h3 className="text-sm font-semibold leading-none text-foreground">{previewDoc.title}</h3>
                  <p className="text-xs text-muted-foreground mt-1">
                    {previewDoc.staffName} · <span className="capitalize">{previewDoc.level}</span> ({previewDoc.yearCompleted})
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <a
                  href={previewDoc.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-primary px-2.5 py-1.5 rounded-md hover:bg-muted/50 transition-colors"
                >
                  <ExternalLink className="w-3.5 h-3.5" />
                  <span>Open external</span>
                </a>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="h-8 w-8 p-0 rounded-full"
                  onClick={() => setPreviewDoc(null)}
                >
                  <X className="w-4 h-4" />
                </Button>
              </div>
            </div>

            {/* Modal Body / Viewer */}
            <div className="p-4 flex-1 overflow-auto bg-muted/10 min-h-[420px] flex flex-col items-center justify-center">
              {previewDoc.mimeType === 'application/pdf' || previewDoc.url.includes('.pdf') ? (
                <iframe
                  src={previewDoc.url}
                  className="w-full h-[520px] rounded-lg border bg-white shadow-inner"
                  title="Degree or Transcript Preview"
                />
              ) : (
                <div className="w-full flex items-center justify-center p-2">
                  <img
                    src={previewDoc.url}
                    alt="Degree or Transcript Scan"
                    className="max-h-[500px] max-w-full object-contain rounded-lg border shadow-sm bg-white"
                  />
                </div>
              )}
            </div>

            {/* Modal Footer with In-App Verification Decision */}
            <div className="flex items-center justify-between px-5 py-3 border-t bg-muted/20">
              <div className="flex items-center gap-2">
                <span className="text-xs text-muted-foreground">Status:</span>
                <span
                  className={cn(
                    'inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium capitalize border',
                    previewDoc.status === 'verified' && 'bg-emerald-50 text-emerald-700 border-emerald-200',
                    previewDoc.status === 'rejected' && 'bg-rose-50 text-rose-700 border-rose-200',
                    previewDoc.status === 'pending' && 'bg-amber-50 text-amber-700 border-amber-200'
                  )}
                >
                  {previewDoc.status}
                </span>
              </div>

              <div className="flex items-center gap-2">
                {previewDoc.status === 'pending' && (
                  currentUser?.userId && qualifications.find((q) => q.id === previewDoc.qualificationId)?.staff_id === currentUser.userId ? (
                    <span className="text-xs text-amber-600 dark:text-amber-400 font-medium mr-2">
                      Self-verification blocked: An independent Principal or HR Manager must verify your degree.
                    </span>
                  ) : (
                    <>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={pending}
                        onClick={() => onDecide(previewDoc.qualificationId, 'verified')}
                        className="text-xs border-emerald-200 text-emerald-700 hover:bg-emerald-50"
                      >
                        <Check className="w-3.5 h-3.5 mr-1" />
                        Verify Qualification
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={pending}
                        onClick={() => onDecide(previewDoc.qualificationId, 'rejected')}
                        className="text-xs border-rose-200 text-rose-700 hover:bg-rose-50"
                      >
                        <X className="w-3.5 h-3.5 mr-1" />
                        Reject
                      </Button>
                    </>
                  )
                )}
                <Button type="button" size="sm" variant="secondary" onClick={() => setPreviewDoc(null)}>
                  Close
                </Button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
