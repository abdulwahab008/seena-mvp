'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { recordLesson, saveHalqa, setMember } from './actions';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
type Option = { id: string; name: string };

const halqaSchema = z.object({ name: z.string().trim().min(1, 'Enter a name').max(100), stream: z.enum(['hifz', 'nazra', 'qaida']), teacherId: z.string() });

export function HalqaForm({ campusId, teachers }: { campusId: string; teachers: Option[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof halqaSchema>>({ resolver: zodResolver(halqaSchema), defaultValues: { stream: 'hifz', teacherId: '' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveHalqa({ ...v, campusId });
      if (r.error) return void toast.error(r.error);
      toast.success('Halqa created.');
      reset({ name: '', stream: 'hifz', teacherId: '' });
      router.push(`/hifz?halqa=${r.id}`);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-2 rounded-md border p-3" noValidate>
      <p className="text-sm font-medium">New halqa</p>
      <Label htmlFor="halqa-name">Name</Label>
      <Input id="halqa-name" {...register('name')} />
      {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
      <Label htmlFor="halqa-stream">Stream</Label>
      <select id="halqa-stream" className={SELECT} {...register('stream')}>
        <option value="hifz">Hifz</option>
        <option value="nazra">Nazra</option>
        <option value="qaida">Qaida</option>
      </select>
      <Label htmlFor="halqa-teacher">Teacher</Label>
      <select id="halqa-teacher" className={SELECT} {...register('teacherId')}>
        <option value="">Not assigned</option>
        {teachers.map((t) => (
          <option key={t.id} value={t.id}>
            {t.name}
          </option>
        ))}
      </select>
      <Button type="submit" size="sm" disabled={pending} className="w-full">
        Create halqa
      </Button>
    </form>
  );
}

const memberSchema = z.object({ studentId: z.string().uuid('Choose a student') });

export function AddMemberForm({ halqaId, students }: { halqaId: string; students: Option[] }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof memberSchema>>({ resolver: zodResolver(memberSchema), defaultValues: { studentId: '' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await setMember(halqaId, v.studentId, true);
      if (r.error) return void toast.error(r.error);
      toast.success('Student added.');
      reset({ studentId: '' });
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="min-w-64 flex-1 space-y-1">
        <Label htmlFor="member-student">Add a student to this halqa</Label>
        <select id="member-student" className={SELECT} {...register('studentId')}>
          <option value="">Choose a student</option>
          {students.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
        {errors.studentId && <p className="text-sm text-destructive">{errors.studentId.message}</p>}
      </div>
      <Button type="submit" variant="outline" disabled={pending}>
        Add
      </Button>
    </form>
  );
}

const lessonSchema = z.object({
  studentId: z.string().uuid('Choose a student'),
  lessonDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  lessonType: z.enum(['sabaq', 'sabqi', 'manzil']),
  paraFrom: z.string(),
  paraTo: z.string(),
  portion: z.string().max(200),
  lines: z.string(),
  mistakes: z.string(),
  tajweedMistakes: z.string(),
  grade: z.string(),
});
type LessonValues = z.infer<typeof lessonSchema>;

export function LessonForm({ halqaId, students }: { halqaId: string; students: Option[] }) {
  const [pending, startTransition] = useTransition();
  const blank: LessonValues = { studentId: '', lessonDate: todayPk(), lessonType: 'sabaq', paraFrom: '', paraTo: '', portion: '', lines: '', mistakes: '0', tajweedMistakes: '0', grade: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<LessonValues>({ resolver: zodResolver(lessonSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await recordLesson({ ...v, halqaId });
      if (r.error) return void toast.error(r.error);
      toast.success('Lesson saved.');
      reset({ ...blank, lessonDate: v.lessonDate, lessonType: v.lessonType });
    }),
  );
  const num = (id: string, label: string, name: 'paraFrom' | 'paraTo' | 'lines' | 'mistakes' | 'tajweedMistakes', max: number) => (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} type="number" min={name === 'paraFrom' || name === 'paraTo' ? 1 : 0} max={max} {...register(name)} />
    </div>
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Record a lesson</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="lesson-student">Student</Label>
            <select id="lesson-student" className={SELECT} {...register('studentId')}>
              <option value="">Choose a student</option>
              {students.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
            {errors.studentId && <p className="text-sm text-destructive">{errors.studentId.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="lesson-date">Date</Label>
            <Input id="lesson-date" type="date" max={todayPk()} {...register('lessonDate')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="lesson-type">Lesson</Label>
            <select id="lesson-type" className={SELECT} {...register('lessonType')}>
              <option value="sabaq">Sabaq (new)</option>
              <option value="sabqi">Sabqi (recent revision)</option>
              <option value="manzil">Manzil (old revision)</option>
            </select>
          </div>
          {num('lesson-para-from', 'Para from', 'paraFrom', 30)}
          {num('lesson-para-to', 'Para to', 'paraTo', 30)}
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="lesson-portion">Surah / ayat or pages</Label>
            <Input id="lesson-portion" {...register('portion')} />
          </div>
          {num('lesson-lines', 'Lines', 'lines', 1000)}
          {num('lesson-mistakes', 'Mistakes', 'mistakes', 500)}
          {num('lesson-tajweed', 'Tajweed mistakes', 'tajweedMistakes', 500)}
          <div className="space-y-1">
            <Label htmlFor="lesson-grade">Grade</Label>
            <select id="lesson-grade" className={SELECT} {...register('grade')}>
              <option value="">—</option>
              <option value="excellent">Excellent</option>
              <option value="good">Good</option>
              <option value="average">Average</option>
              <option value="weak">Weak</option>
              <option value="repeat">Repeat</option>
            </select>
          </div>
          <Button type="submit" disabled={pending} className="sm:col-span-4 sm:w-fit">
            Save lesson
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
