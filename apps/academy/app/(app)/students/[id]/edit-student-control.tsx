'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { updateStudentDetails } from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';

export type EditableStudent = {
  id: string;
  name_en: string;
  name_ur: string | null;
  dob: string;
  gender: string;
  father_name_en: string | null;
  b_form_no: string | null;
  category_id: string | null;
  region_id: string | null;
  previous_school_id: string | null;
};

type Option = { id: string; label: string };
export type StudentLookupOptions = { category: Option[]; region: Option[]; school: Option[] };

export function EditStudentControl({ student, options }: { student: EditableStudent; options: StudentLookupOptions }) {
  const lookups = [
    { name: 'categoryId', label: 'Category', value: student.category_id, options: options.category },
    { name: 'regionId', label: 'Region or area', value: student.region_id, options: options.region },
    { name: 'previousSchoolId', label: 'Previous school', value: student.previous_school_id, options: options.school },
  ];
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  return (
    <>
      <Button variant="outline" onClick={() => setOpen(true)} data-testid="edit-student">
        Edit details
      </Button>
      {open && (
        <Modal
          open={open}
          onClose={() => setOpen(false)}
          title="Edit student details"
          description="The GR number does not change."
        >
          <form
            className="grid gap-3 sm:grid-cols-2"
            onSubmit={(e) => {
              e.preventDefault();
              const fd = new FormData(e.currentTarget);
              // Send only what this user changed, so a stale form cannot overwrite another user's edit.
              const original: Record<string, string> = {
                nameEn: student.name_en,
                nameUr: student.name_ur ?? '',
                dob: student.dob,
                gender: student.gender,
                fatherNameEn: student.father_name_en ?? '',
                bFormNo: student.b_form_no ?? '',
                categoryId: student.category_id ?? '',
                regionId: student.region_id ?? '',
                previousSchoolId: student.previous_school_id ?? '',
              };
              for (const [name, value] of Object.entries(original)) if (fd.get(name) === value) fd.delete(name);
              startTransition(async () => {
                const r = await updateStudentDetails(student.id, { error: null }, fd);
                if (r.error) setError(r.error);
                else {
                  toast.success('Student details saved.');
                  setOpen(false);
                  router.refresh();
                }
              });
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="edit-nameEn">Name</Label>
              <Input id="edit-nameEn" name="nameEn" defaultValue={student.name_en} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="edit-nameUr">Name (Urdu)</Label>
              <Input
                id="edit-nameUr"
                name="nameUr"
                dir="rtl"
                defaultValue={student.name_ur ?? ''}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="edit-dob">Date of birth</Label>
              <Input id="edit-dob" name="dob" type="date" defaultValue={student.dob} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="edit-gender">Gender</Label>
              <select
                id="edit-gender"
                name="gender"
                defaultValue={student.gender}
                className="h-10 w-full rounded-md border bg-background px-3 text-sm"
              >
                <option value="male">Male</option>
                <option value="female">Female</option>
                <option value="other">Other</option>
              </select>
            </div>
            <div className="space-y-1">
              <Label htmlFor="edit-father">Father&apos;s name</Label>
              <Input
                id="edit-father"
                name="fatherNameEn"
                defaultValue={student.father_name_en ?? ''}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="edit-bform">B-Form number</Label>
              <Input
                id="edit-bform"
                name="bFormNo"
                defaultValue={student.b_form_no ?? ''}
                placeholder="35202-1234567-1"
              />
            </div>
            {lookups.map((l) => (
              <div key={l.name} className="space-y-1">
                <Label htmlFor={`edit-${l.name}`}>{l.label}</Label>
                <select
                  id={`edit-${l.name}`}
                  name={l.name}
                  defaultValue={l.value ?? ''}
                  className="h-10 w-full rounded-md border bg-background px-3 text-sm"
                >
                  <option value="">None</option>
                  {l.options.map((o) => (
                    <option key={o.id} value={o.id}>
                      {o.label}
                    </option>
                  ))}
                </select>
              </div>
            ))}
            {error && (
              <p role="alert" className="text-sm text-destructive sm:col-span-2">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2 sm:col-span-2">
              <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={pending}>
                {pending ? 'Saving…' : 'Save'}
              </Button>
            </div>
          </form>
        </Modal>
      )}
    </>
  );
}
