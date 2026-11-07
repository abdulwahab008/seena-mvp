'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { uploadDownload } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const schema = z.object({
  title: z.string().trim().min(1, 'Enter a title').max(200),
  category: z.enum(['syllabus', 'material', 'other']),
  classLevelId: z.string(),
  sectionId: z.string(),
  file: z.custom<FileList>((v) => v instanceof FileList && v.length === 1, 'Choose a file'),
});
type Values = z.infer<typeof schema>;

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function UploadForm({
  campusId,
  classes,
  sections,
}: {
  campusId: string;
  classes: { id: string; name: string }[];
  sections: { id: string; name: string; classLevelId: string }[];
}) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, watch, reset, formState: { errors } } = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: { category: 'material', classLevelId: '', sectionId: '' },
  });
  const classLevelId = watch('classLevelId');

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const fd = new FormData();
      fd.set('campusId', campusId);
      fd.set('title', v.title);
      fd.set('category', v.category);
      fd.set('classLevelId', v.classLevelId);
      fd.set('sectionId', v.classLevelId ? v.sectionId : '');
      fd.set('file', v.file[0]!);
      const r = await uploadDownload(fd);
      if (r.error) return void toast.error(r.error);
      toast.success('File shared.');
      reset({ category: 'material', classLevelId: '', sectionId: '', title: '' });
    }),
  );

  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle>Share a file</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="dl-title">Title</Label>
            <Input id="dl-title" {...register('title')} />
            {errors.title && <p className="text-sm text-destructive">{errors.title.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="dl-category">Type</Label>
            <select id="dl-category" className={SELECT} {...register('category')}>
              <option value="syllabus">Syllabus</option>
              <option value="material">Study material</option>
              <option value="other">Other</option>
            </select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="dl-class">Class</Label>
            <select id="dl-class" className={SELECT} {...register('classLevelId')}>
              <option value="">Whole campus</option>
              {classes.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </div>
          {classLevelId && (
            <div className="space-y-1">
              <Label htmlFor="dl-section">Section</Label>
              <select id="dl-section" className={SELECT} {...register('sectionId')}>
                <option value="">Every section</option>
                {sections
                  .filter((s) => s.classLevelId === classLevelId)
                  .map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
              </select>
            </div>
          )}
          <div className="space-y-1">
            <Label htmlFor="dl-file">File (up to 10 MB)</Label>
            <Input id="dl-file" type="file" accept=".pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.txt,.jpg,.jpeg,.png,.webp" {...register('file')} />
            {errors.file && <p className="text-sm text-destructive">{String(errors.file.message)}</p>}
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            {pending ? 'Uploading…' : 'Share'}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
