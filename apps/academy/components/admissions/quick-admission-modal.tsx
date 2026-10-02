'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Zap, UserPlus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Modal } from '@/components/ui/modal';
import { DatePicker } from '@/components/ui/date-picker';
import { quickAdmission } from '@/app/(app)/admissions/applications/actions';

export interface QuickAdmissionModalProps {
  campuses: { id: string; name: string }[];
  sessions: { id: string; name: string }[];
  classLevels: { id: string; name_en: string }[];
  sections: { id: string; class_level_id: string; campus_id: string; session_id: string; name: string }[];
  triggerVariant?: 'default' | 'outline' | 'secondary';
  triggerText?: string;
}

export function QuickAdmissionModal({
  campuses,
  sessions,
  classLevels,
  sections,
  triggerVariant = 'default',
  triggerText = 'Quick Walk-in Admission',
}: QuickAdmissionModalProps) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();

  const [campusId, setCampusId] = React.useState(campuses[0]?.id ?? '');
  const [sessionId, setSessionId] = React.useState(sessions[0]?.id ?? '');
  const [classLevelId, setClassLevelId] = React.useState(classLevels[0]?.id ?? '');
  const [sectionId, setSectionId] = React.useState('');
  const [dob, setDob] = React.useState('');
  const [gender, setGender] = React.useState<'male' | 'female' | 'other'>('male');
  const [paymentMode, setPaymentMode] = React.useState('cash');

  // Filter sections dynamically when campus, session, or class changes
  const availableSections = React.useMemo(() => {
    return sections.filter(
      (s) =>
        (!campusId || s.campus_id === campusId) &&
        (!sessionId || s.session_id === sessionId) &&
        (!classLevelId || s.class_level_id === classLevelId)
    );
  }, [sections, campusId, sessionId, classLevelId]);

  // Update default section selection when available sections change
  React.useEffect(() => {
    if (availableSections.length > 0) {
      if (!sectionId || !availableSections.some((s) => s.id === sectionId)) {
        setSectionId(availableSections[0]!.id);
      }
    } else {
      setSectionId('');
    }
  }, [availableSections, sectionId]);

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('classLevelId', classLevelId);
    fd.set('sectionId', sectionId);
    fd.set('dob', dob);
    fd.set('gender', gender);
    fd.set('paymentMode', paymentMode);

    startTransition(async () => {
      const res = await quickAdmission({ error: null, grNumber: null, studentId: null, applicationNo: null, receiptNo: null }, fd);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(`Admitted successfully! GR: ${res.grNumber} (${res.applicationNo})`);
        setOpen(false);
        router.refresh();
      }
    });
  };

  return (
    <>
      <Button
        type="button"
        variant={triggerVariant}
        size="sm"
        onClick={() => setOpen(true)}
        className="gap-2 bg-indigo-600 hover:bg-indigo-700 text-white shadow-sm"
        data-testid="quick-admission-button"
      >
        <Zap className="h-4 w-4" />
        <span>{triggerText}</span>
      </Button>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Quick Walk-in Admission"
        description="Streamlined 1-step intake: records student details, assigns section, logs admission fee, and enrols immediately with a GR Number."
        size="lg"
      >

        <form onSubmit={handleSubmit} className="space-y-4 pt-2">
          {/* Campus & Session */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 p-3 bg-muted/40 rounded-lg border">
            <div className="space-y-1">
              <Label className="text-xs font-medium">Campus</Label>
              <Select value={campusId} onValueChange={setCampusId}>
                <SelectTrigger className="h-8">
                  <SelectValue placeholder="Select campus" />
                </SelectTrigger>
                <SelectContent>
                  {campuses.map((c) => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-1">
              <Label className="text-xs font-medium">Academic Session</Label>
              <Select value={sessionId} onValueChange={setSessionId}>
                <SelectTrigger className="h-8">
                  <SelectValue placeholder="Select session" />
                </SelectTrigger>
                <SelectContent>
                  {sessions.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          {/* Student Info */}
          <div className="space-y-3">
            <h4 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Student Particulars</h4>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <div className="space-y-1 sm:col-span-2">
                <Label htmlFor="quick-childName" className="text-xs font-medium">
                  Child Full Name <span className="text-destructive">*</span>
                </Label>
                <Input id="quick-childName" name="childName" required placeholder="e.g. Muhammad Ali" className="h-8" />
              </div>

              <div className="space-y-1">
                <Label className="text-xs font-medium">
                  Date of Birth <span className="text-destructive">*</span>
                </Label>
                <DatePicker
                  value={dob}
                  onChange={setDob}
                  placeholder="Select DOB"
                  className="h-8"
                  data-testid="quick-admission-dob"
                />
              </div>

              <div className="space-y-1">
                <Label className="text-xs font-medium">Gender</Label>
                <Select value={gender} onValueChange={(v) => setGender(v as any)}>
                  <SelectTrigger className="h-8">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="male">Male</SelectItem>
                    <SelectItem value="female">Female</SelectItem>
                    <SelectItem value="other">Other</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label htmlFor="quick-bFormNo" className="text-xs font-medium">B-Form / CRC (Optional)</Label>
                <Input id="quick-bFormNo" name="bFormNo" placeholder="37405-1234567-1" className="h-8" />
              </div>

              <div className="space-y-1">
                <Label htmlFor="quick-fatherNameEn" className="text-xs font-medium">Father's Name (Optional)</Label>
                <Input id="quick-fatherNameEn" name="fatherNameEn" placeholder="Father's name" className="h-8" />
              </div>
            </div>
          </div>

          {/* Academic Placement */}
          <div className="space-y-3">
            <h4 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Class & Section Placement</h4>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label className="text-xs font-medium">
                  Class <span className="text-destructive">*</span>
                </Label>
                <Select value={classLevelId} onValueChange={setClassLevelId}>
                  <SelectTrigger className="h-8">
                    <SelectValue placeholder="Choose class" />
                  </SelectTrigger>
                  <SelectContent>
                    {classLevels.map((cl) => (
                      <SelectItem key={cl.id} value={cl.id}>
                        {cl.name_en}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label className="text-xs font-medium">
                  Section <span className="text-destructive">*</span>
                </Label>
                <Select value={sectionId} onValueChange={setSectionId} disabled={availableSections.length === 0}>
                  <SelectTrigger className="h-8">
                    <SelectValue placeholder={availableSections.length ? 'Choose section' : 'No sections found'} />
                  </SelectTrigger>
                  <SelectContent>
                    {availableSections.map((sec) => (
                      <SelectItem key={sec.id} value={sec.id}>
                        Section {sec.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          </div>

          {/* Guardian & Contact */}
          <div className="space-y-3">
            <h4 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Guardian Contact</h4>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label htmlFor="quick-parentName" className="text-xs font-medium">
                  Parent / Guardian Name <span className="text-destructive">*</span>
                </Label>
                <Input id="quick-parentName" name="parentName" required placeholder="Parent name" className="h-8" />
              </div>

              <div className="space-y-1">
                <Label htmlFor="quick-phone" className="text-xs font-medium">
                  Mobile Phone <span className="text-destructive">*</span>
                </Label>
                <Input id="quick-phone" name="phone" required placeholder="03001234567" className="h-8" />
              </div>
            </div>
          </div>

          {/* Admission Fee & Payment */}
          <div className="space-y-3 p-3 bg-muted/40 rounded-lg border">
            <h4 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Admission Fee & Immediate Payment</h4>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <div className="space-y-1">
                <Label htmlFor="quick-admissionFee" className="text-xs font-medium">Fee Amount (PKR)</Label>
                <Input id="quick-admissionFee" name="admissionFee" type="number" defaultValue="4000" min="0" step="100" className="h-8" />
              </div>

              <div className="space-y-1">
                <Label className="text-xs font-medium">Payment Mode</Label>
                <Select value={paymentMode} onValueChange={setPaymentMode}>
                  <SelectTrigger className="h-8">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="cash">Cash (Auto-reconciled)</SelectItem>
                    <SelectItem value="online">Online Transfer (Auto-reconciled)</SelectItem>
                    <SelectItem value="cheque">Cheque</SelectItem>
                    <SelectItem value="pay_order">Pay Order</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label htmlFor="quick-paymentReference" className="text-xs font-medium">Receipt / Ref #</Label>
                <Input id="quick-paymentReference" name="paymentReference" placeholder="e.g. REC-019" className="h-8" />
              </div>
            </div>
          </div>

          <div className="flex items-center justify-end gap-2 border-t pt-4">
            <Button type="button" variant="outline" size="sm" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button
              type="submit"
              size="sm"
              disabled={pending || !sectionId || !dob}
              className="bg-indigo-600 hover:bg-indigo-700 text-white"
              data-testid="quick-admission-submit"
            >
              {pending ? 'Admitting…' : 'Complete Admission'}
            </Button>
          </div>
        </form>
      </Modal>
    </>
  );
}
