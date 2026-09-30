'use client';

import { useState, useEffect, useTransition } from 'react';
import { toast } from 'sonner';
import { Modal } from '@/components/ui/modal';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { saveSubject, type SubjectInput } from './actions';
import { BookOpen, Sparkles, Check, FileCheck } from 'lucide-react';

export type SubjectItem = {
  id: string;
  code: string;
  name_en: string;
  subject_type: 'CORE' | 'ELECTIVE' | 'ADDITIONAL' | 'NON_EXAMINABLE';
  is_examinable: boolean;
  default_max_marks: number | null;
  is_active: boolean;
};

export function SubjectModal({
  open,
  onClose,
  subject,
  onSuccess,
}: {
  open: boolean;
  onClose: () => void;
  subject?: SubjectItem | null;
  onSuccess?: () => void;
}) {
  const isEditing = !!subject;
  const [pending, startTransition] = useTransition();

  const [code, setCode] = useState('');
  const [nameEn, setNameEn] = useState('');
  const [subjectType, setSubjectType] = useState<'CORE' | 'ELECTIVE' | 'ADDITIONAL' | 'NON_EXAMINABLE'>('CORE');
  const [isExaminable, setIsExaminable] = useState<boolean>(true);
  const [defaultMarks, setDefaultMarks] = useState<number | ''>(100);

  useEffect(() => {
    if (subject) {
      setCode(subject.code);
      setNameEn(subject.name_en);
      setSubjectType(subject.subject_type);
      setIsExaminable(subject.is_examinable);
      setDefaultMarks(subject.default_max_marks ?? '');
    } else {
      setCode('');
      setNameEn('');
      setSubjectType('CORE');
      setIsExaminable(true);
      setDefaultMarks(100);
    }
  }, [subject, open]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    if (!code.trim()) {
      toast.error('Subject code is required (e.g. MTH, PHY, ENG).');
      return;
    }
    if (!nameEn.trim()) {
      toast.error('Subject name is required.');
      return;
    }

    const payload: SubjectInput = {
      id: subject?.id,
      code: code.trim().toUpperCase(),
      name_en: nameEn.trim(),
      subject_type: subjectType,
      is_examinable: isExaminable,
      default_max_marks: isExaminable && defaultMarks !== '' ? Number(defaultMarks) : null,
    };

    startTransition(async () => {
      const res = await saveSubject(payload);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(
          isEditing
            ? `Subject "${nameEn}" updated successfully.`
            : `Subject "${nameEn}" added to catalog.`
        );
        onClose();
        if (onSuccess) onSuccess();
      }
    });
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={isEditing ? `Edit Subject: ${subject.name_en}` : 'Add New Subject'}
      description="Configure subject code, title, curriculum classification, and examination defaults."
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-5 pt-2">
        {/* Code & Name Row */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="subjectCode" className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Subject Code <span className="text-destructive">*</span>
            </Label>
            <Input
              id="subjectCode"
              placeholder="e.g. MTH"
              value={code}
              onChange={(e) => setCode(e.target.value.toUpperCase())}
              maxLength={10}
              disabled={pending}
              className="font-mono uppercase font-semibold"
              required
            />
            <p className="text-[11px] text-muted-foreground">Short code (2-6 letters)</p>
          </div>

          <div className="sm:col-span-2 space-y-1.5">
            <Label htmlFor="subjectName" className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Subject Name (English) <span className="text-destructive">*</span>
            </Label>
            <Input
              id="subjectName"
              placeholder="e.g. Mathematics"
              value={nameEn}
              onChange={(e) => setNameEn(e.target.value)}
              disabled={pending}
              className="font-medium"
              required
            />
            <p className="text-[11px] text-muted-foreground">Full English title</p>
          </div>
        </div>

        {/* Subject Type Selection */}
        <div className="space-y-2">
          <Label className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
            Curriculum Classification
          </Label>
          <div className="grid grid-cols-2 gap-2">
            {[
              { type: 'CORE' as const, label: 'Core Compulsory', desc: 'Required for all students in class' },
              { type: 'ELECTIVE' as const, label: 'Elective Option', desc: 'Choice between elective groups' },
              { type: 'ADDITIONAL' as const, label: 'Additional', desc: 'Supplementary subject' },
              { type: 'NON_EXAMINABLE' as const, label: 'Non-Examinable', desc: 'Co-curricular / non-graded' },
            ].map((opt) => (
              <button
                key={opt.type}
                type="button"
                onClick={() => {
                  setSubjectType(opt.type);
                  if (opt.type === 'NON_EXAMINABLE') {
                    setIsExaminable(false);
                    setDefaultMarks('');
                  }
                }}
                className={`p-3 rounded-lg border text-left transition-all ${
                  subjectType === opt.type
                    ? 'border-primary bg-primary/5 ring-1 ring-primary'
                    : 'border-border/60 hover:border-border hover:bg-muted/30'
                }`}
              >
                <div className="flex items-center justify-between">
                  <span className="text-xs font-semibold">{opt.label}</span>
                  {subjectType === opt.type && <Check className="w-3.5 h-3.5 text-primary" />}
                </div>
                <p className="text-[11px] text-muted-foreground mt-0.5 leading-snug">{opt.desc}</p>
              </button>
            ))}
          </div>
        </div>

        {/* Examination Configuration */}
        <div className="rounded-lg border border-border/60 p-4 bg-muted/20 space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <div className="text-sm font-medium flex items-center gap-1.5">
                <FileCheck className="w-4 h-4 text-primary" />
                Examinable Subject
              </div>
              <p className="text-xs text-muted-foreground mt-0.5">
                Include this subject in term examinations, report cards, and grading sheets.
              </p>
            </div>
            <input
              type="checkbox"
              id="isExaminable"
              checked={isExaminable}
              onChange={(e) => {
                const checked = e.target.checked;
                setIsExaminable(checked);
                if (!checked) setDefaultMarks('');
                else if (defaultMarks === '') setDefaultMarks(100);
              }}
              className="w-4 h-4 text-primary rounded border-input focus:ring-primary"
            />
          </div>

          {isExaminable && (
            <div className="pt-2 border-t border-border/50">
              <div className="flex items-center justify-between gap-4">
                <div className="space-y-0.5">
                  <Label htmlFor="defaultMarks" className="text-xs font-semibold">
                    Default Maximum Marks
                  </Label>
                  <p className="text-[11px] text-muted-foreground">Standard marks for terms (can be customized per exam).</p>
                </div>
                <div className="w-32">
                  <Input
                    id="defaultMarks"
                    type="number"
                    min={1}
                    max={500}
                    value={defaultMarks}
                    onChange={(e) => setDefaultMarks(e.target.value === '' ? '' : Number(e.target.value))}
                    disabled={pending}
                    className="text-right font-medium"
                    placeholder="100"
                  />
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Footer Actions */}
        <div className="flex items-center justify-end gap-2.5 pt-3 border-t">
          <Button type="button" variant="outline" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button type="submit" disabled={pending} className="gap-1.5">
            {pending ? (
              'Saving...'
            ) : (
              <>
                <BookOpen className="w-4 h-4" />
                {isEditing ? 'Update Subject' : 'Add Subject'}
              </>
            )}
          </Button>
        </div>
      </form>
    </Modal>
  );
}
