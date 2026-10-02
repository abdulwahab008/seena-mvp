'use client';

import * as React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  Zap,
  UserCheck,
  Building2,
  Plus,
  ArrowRight,
  CheckCircle2,
  RotateCcw,
  Printer,
  Receipt,
  Sparkles,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { DatePicker } from '@/components/ui/date-picker';
import { quickAdmission } from '@/app/(app)/admissions/applications/actions';
import { PrintableReceiptModal } from '@/components/admissions/printable-receipt-modal';

export interface WalkInFormProps {
  campuses: { id: string; name: string; code: string }[];
  sessions: { id: string; name: string }[];
  classLevels: { id: string; name_en: string; code: string }[];
  sections: { id: string; class_level_id: string; campus_id: string; session_id: string; name: string }[];
  recentAdmissions: {
    id: string;
    gr_number: string;
    name_en: string;
    created_at: string;
  }[];
}

export function WalkInForm({
  campuses,
  sessions,
  classLevels,
  sections: initialSections,
  recentAdmissions,
}: WalkInFormProps) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();

  const allSections = initialSections;

  // Form states
  const [campusId, setCampusId] = React.useState(campuses[0]?.id ?? '');
  const [sessionId, setSessionId] = React.useState(sessions[0]?.id ?? '');
  const [classLevelId, setClassLevelId] = React.useState(classLevels[0]?.id ?? '');
  const [sectionId, setSectionId] = React.useState('');
  const [childName, setChildName] = React.useState('');
  const [dob, setDob] = React.useState('');
  const [gender, setGender] = React.useState<'male' | 'female' | 'other'>('male');
  const [parentName, setParentName] = React.useState('');
  const [phone, setPhone] = React.useState('');
  const [bFormNo, setBFormNo] = React.useState('');
  const [admissionFee, setAdmissionFee] = React.useState('4000');
  const [paymentMode, setPaymentMode] = React.useState('cash');

  // Successful admission record
  const [admittedRecord, setAdmittedRecord] = React.useState<{
    grNumber: string;
    studentId: string;
    applicationNo: string;
    receiptNo: string;
    name: string;
    className: string;
    sectionName: string;
    fee: number;
    mode: string;
  } | null>(null);

  // Printable receipt modal state
  const [receiptModalOpen, setReceiptModalOpen] = React.useState(false);

  // Available sections filtered by campus, session, and class
  const availableSections = React.useMemo(() => {
    return allSections.filter(
      (s) =>
        (!campusId || s.campus_id === campusId) &&
        (!sessionId || s.session_id === sessionId) &&
        (!classLevelId || s.class_level_id === classLevelId)
    );
  }, [allSections, campusId, sessionId, classLevelId]);

  // Auto-select section when list changes
  React.useEffect(() => {
    if (availableSections.length > 0) {
      if (!sectionId || !availableSections.some((s) => s.id === sectionId)) {
        setSectionId(availableSections[0]!.id);
      }
    } else {
      setSectionId('');
    }
  }, [availableSections, sectionId]);

  const selectedClass = classLevels.find((c) => c.id === classLevelId);
  const selectedSection = availableSections.find((s) => s.id === sectionId);
  const selectedCampus = campuses.find((c) => c.id === campusId);
  const selectedSession = sessions.find((s) => s.id === sessionId);

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('classLevelId', classLevelId);
    fd.set('sectionId', sectionId);
    fd.set('childName', childName);
    fd.set('dob', dob);
    fd.set('gender', gender);
    fd.set('parentName', parentName);
    fd.set('phone', phone);
    fd.set('bFormNo', bFormNo);
    fd.set('admissionFee', admissionFee);
    fd.set('paymentMode', paymentMode);
    // Note: paymentReference is omitted so server action auto-generates official receipt sequence!

    startTransition(async () => {
      const res = await quickAdmission(
        { error: null, grNumber: null, studentId: null, applicationNo: null, receiptNo: null },
        fd
      );
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(`Enrolled! GR: ${res.grNumber} · Receipt: ${res.receiptNo}`);
        setAdmittedRecord({
          grNumber: res.grNumber ?? '',
          studentId: res.studentId ?? '',
          applicationNo: res.applicationNo ?? '',
          receiptNo: res.receiptNo ?? '',
          name: childName,
          className: selectedClass?.name_en ?? '',
          sectionName: selectedSection?.name ?? '',
          fee: Number(admissionFee) || 0,
          mode: paymentMode,
        });
        router.refresh();
      }
    });
  };

  const handleResetForNext = () => {
    setAdmittedRecord(null);
    setChildName('');
    setDob('');
    setGender('male');
    setParentName('');
    setPhone('');
    setBFormNo('');
  };



  return (
    <div className="space-y-6">
      {/* Top Breadcrumb & Minimal Context */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 border-b pb-3">
        <div className="flex items-center gap-3">
          <div className="h-9 w-9 rounded-lg bg-indigo-600 flex items-center justify-center text-white shadow-sm shrink-0">
            <Zap className="h-5 w-5 fill-white" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-xl font-bold tracking-tight">Walk-in Admission Desk</h1>
              <Badge variant="outline" className="text-[11px] font-normal border-indigo-200 text-indigo-700 dark:text-indigo-300">
                Counter POS
              </Badge>
            </div>
            <p className="text-xs text-muted-foreground">
              Direct spot enrolment: generates official GR#, auto-reconciles payment, and creates student record.
            </p>
          </div>
        </div>

        {/* Compact Campus & Session Selector */}
        <div className="flex items-center gap-2">
          <Select value={campusId} onValueChange={setCampusId}>
            <SelectTrigger className="h-8 text-xs w-[180px] bg-background">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {campuses.map((c) => (
                <SelectItem key={c.id} value={c.id}>
                  {c.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>

          <Select value={sessionId} onValueChange={setSessionId}>
            <SelectTrigger className="h-8 text-xs w-[140px] bg-background">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {sessions.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>

          <Link
            href="/admissions/enquiries"
            className="text-xs text-muted-foreground hover:text-foreground flex items-center gap-1 border px-2.5 py-1 rounded-md hover:bg-muted transition-colors shrink-0"
          >
            <span>Enquiries</span>
            <ArrowRight className="h-3 w-3" />
          </Link>
        </div>
      </div>

      {/* Success banner if just admitted */}
      {admittedRecord && (
        <Card className="border-green-300 dark:border-green-800 bg-green-50/70 dark:bg-green-950/30 shadow-sm animate-in fade-in-50 zoom-in-95">
          <CardContent className="p-4">
            <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
              <div className="flex items-center gap-3">
                <div className="h-10 w-10 rounded-full bg-green-100 dark:bg-green-900/60 flex items-center justify-center shrink-0 text-green-600 dark:text-green-400">
                  <CheckCircle2 className="h-6 w-6" />
                </div>
                <div>
                  <div className="flex items-center gap-2">
                    <h3 className="font-semibold text-green-950 dark:text-green-100 text-base">
                      {admittedRecord.name} Admitted Successfully!
                    </h3>
                    <Badge className="bg-green-700 text-white hover:bg-green-800 font-mono text-xs">
                      GR: {admittedRecord.grNumber}
                    </Badge>
                  </div>
                  <p className="text-xs text-green-800 dark:text-green-300 mt-0.5">
                    Placed in <strong>{admittedRecord.className} · Section {admittedRecord.sectionName}</strong> · Receipt: <span className="font-mono">{admittedRecord.receiptNo}</span> (Auto-reconciled)
                  </p>
                </div>
              </div>

              <div className="flex items-center gap-2 self-end sm:self-center">
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => setReceiptModalOpen(true)}
                  className="gap-1.5 border-green-400 text-green-900 dark:text-green-100 hover:bg-green-100 dark:hover:bg-green-900/50"
                  data-testid="print-receipt-btn"
                >
                  <Printer className="h-4 w-4" />
                  Print Fee Receipt
                </Button>

                {admittedRecord.studentId && (
                  <Button size="sm" asChild variant="outline" className="gap-1 border-green-300 hover:bg-green-100 dark:hover:bg-green-900/50">
                    <Link href={`/students/${admittedRecord.studentId}`}>
                      <UserCheck className="h-4 w-4" />
                      View Profile
                    </Link>
                  </Button>
                )}

                <Button size="sm" onClick={handleResetForNext} className="gap-1 bg-green-700 hover:bg-green-800 text-white">
                  <RotateCcw className="h-3.5 w-3.5" />
                  Next Student
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      )}

      {/* Main Clean Layout */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left 2 Cols: The Clean, Streamlined Intake Form */}
        <div className="lg:col-span-2">
          <Card className="shadow-sm border">
            <CardHeader className="pb-3 border-b">
              <CardTitle className="text-base font-semibold">
                Student Enrolment Form
              </CardTitle>
              <CardDescription className="text-xs">
                Enter child and guardian details. Submitting assigns a permanent GR Number and records the fee.
              </CardDescription>
            </CardHeader>

            <CardContent className="pt-5">
              <form onSubmit={handleSubmit} className="space-y-5">
                {/* 1. Student Particulars */}
                <div className="space-y-3">
                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                    <div className="space-y-1 sm:col-span-2">
                      <Label htmlFor="walkin-childName" className="text-xs font-medium">
                        Student Full Name <span className="text-destructive">*</span>
                      </Label>
                      <Input
                        id="walkin-childName"
                        value={childName}
                        onChange={(e) => setChildName(e.target.value)}
                        required
                        placeholder="e.g. Muhammad Ayaan"
                        className="h-9"
                      />
                    </div>

                    <div className="space-y-1">
                      <Label className="text-xs font-medium">
                        Date of Birth <span className="text-destructive">*</span>
                      </Label>
                      <DatePicker
                        value={dob}
                        onChange={setDob}
                        placeholder="Select DOB"
                        className="h-9"
                        data-testid="walkin-dob"
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <div className="space-y-1">
                      <Label className="text-xs font-medium">Gender</Label>
                      <div className="flex items-center gap-1">
                        {(['male', 'female', 'other'] as const).map((g) => (
                          <Button
                            key={g}
                            type="button"
                            size="sm"
                            variant={gender === g ? 'default' : 'outline'}
                            onClick={() => setGender(g)}
                            className={`flex-1 h-8 text-xs capitalize ${
                              gender === g ? 'bg-indigo-600 text-white' : ''
                            }`}
                          >
                            {g}
                          </Button>
                        ))}
                      </div>
                    </div>

                    <div className="space-y-1">
                      <Label htmlFor="walkin-bFormNo" className="text-xs font-medium">
                        B-Form / Child CRC (Optional)
                      </Label>
                      <Input
                        id="walkin-bFormNo"
                        value={bFormNo}
                        onChange={(e) => setBFormNo(e.target.value)}
                        placeholder="37405-1234567-1"
                        className="h-8 text-xs font-mono"
                      />
                    </div>
                  </div>
                </div>

                <div className="border-t pt-4 space-y-3">
                  {/* 2. Academic Placement with + Add Section Button */}
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <div className="space-y-1">
                      <Label className="text-xs font-medium">
                        Class Level <span className="text-destructive">*</span>
                      </Label>
                      <Select value={classLevelId} onValueChange={setClassLevelId}>
                        <SelectTrigger className="h-9">
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
                        Assigned Section <span className="text-destructive">*</span>
                      </Label>

                      {availableSections.length > 0 ? (
                        <Select value={sectionId} onValueChange={setSectionId}>
                          <SelectTrigger className="h-9" data-testid="walkin-section-select">
                            <SelectValue placeholder="Choose section" />
                          </SelectTrigger>
                          <SelectContent>
                            {availableSections.map((sec) => (
                              <SelectItem key={sec.id} value={sec.id}>
                                Section {sec.name}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      ) : (
                        <p className="text-xs text-amber-700 dark:text-amber-400 bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-800 rounded-md p-2">
                          No sections configured for this class. Contact the academic coordinator or principal.
                        </p>
                      )}
                    </div>
                  </div>
                </div>

                {/* 3. Guardian & Fee */}
                <div className="border-t pt-4 space-y-3">
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <div className="space-y-1">
                      <Label htmlFor="walkin-parentName" className="text-xs font-medium">
                        Parent / Guardian Name <span className="text-destructive">*</span>
                      </Label>
                      <Input
                        id="walkin-parentName"
                        value={parentName}
                        onChange={(e) => setParentName(e.target.value)}
                        required
                        placeholder="Parent name"
                        className="h-9"
                      />
                    </div>

                    <div className="space-y-1">
                      <Label htmlFor="walkin-phone" className="text-xs font-medium">
                        Mobile Phone Number <span className="text-destructive">*</span>
                      </Label>
                      <Input
                        id="walkin-phone"
                        value={phone}
                        onChange={(e) => setPhone(e.target.value)}
                        required
                        placeholder="03001234567"
                        className="h-9"
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end pt-1">
                    <div className="space-y-1">
                      <Label htmlFor="walkin-admissionFee" className="text-xs font-medium">
                        Admission Fee (PKR)
                      </Label>
                      <Input
                        id="walkin-admissionFee"
                        type="number"
                        value={admissionFee}
                        onChange={(e) => setAdmissionFee(e.target.value)}
                        min="0"
                        step="100"
                        className="h-9 font-semibold"
                      />
                    </div>

                    <div className="space-y-1">
                      <Label className="text-xs font-medium">Payment Mode</Label>
                      <Select value={paymentMode} onValueChange={setPaymentMode}>
                        <SelectTrigger className="h-9">
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem value="cash">Cash (Auto-reconciled)</SelectItem>
                          <SelectItem value="online">Online Transfer</SelectItem>
                          <SelectItem value="cheque">Cheque</SelectItem>
                          <SelectItem value="pay_order">Pay Order</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>

                    <div className="text-xs text-muted-foreground pb-2 flex items-center gap-1">
                      <Receipt className="h-3.5 w-3.5 text-indigo-600 shrink-0" />
                      <span>Receipt # auto-generated</span>
                    </div>
                  </div>
                </div>

                {/* Submit Action */}
                <div className="flex items-center justify-end gap-3 pt-3 border-t">
                  <Button
                    type="submit"
                    disabled={pending || !sectionId || !dob || !childName || !parentName || !phone}
                    className="bg-indigo-600 hover:bg-indigo-700 text-white min-w-[220px]"
                    data-testid="walkin-submit-btn"
                  >
                    {pending ? (
                      'Enrolling & Issuing GR…'
                    ) : (
                      <>
                        <Zap className="h-4 w-4 mr-1.5" />
                        Complete Spot Admission
                      </>
                    )}
                  </Button>
                </div>
              </form>
            </CardContent>
          </Card>
        </div>

        {/* Right 1 Col: Compact Recent Counter Log */}
        <div className="space-y-4">
          <Card className="border shadow-sm">
            <CardHeader className="pb-3 border-b">
              <CardTitle className="text-sm font-semibold flex items-center justify-between">
                <span>Today's Counter Enrolments</span>
                <Badge variant="outline" className="text-[10px]">
                  {recentAdmissions.length} active
                </Badge>
              </CardTitle>
            </CardHeader>
            <CardContent className="pt-2">
              {recentAdmissions.length === 0 ? (
                <p className="text-xs text-muted-foreground py-4 text-center">
                  No spot admissions recorded yet today.
                </p>
              ) : (
                <div className="divide-y text-xs">
                  {recentAdmissions.slice(0, 7).map((adm) => (
                    <div key={adm.id} className="py-2.5 flex items-center justify-between">
                      <div className="space-y-0.5">
                        <p className="font-medium text-foreground truncate max-w-[140px]">{adm.name_en}</p>
                        <p className="text-[10px] text-muted-foreground">
                          {new Date(adm.created_at).toLocaleDateString(undefined, {
                            month: 'short',
                            day: 'numeric',
                            hour: '2-digit',
                            minute: '2-digit',
                          })}
                        </p>
                      </div>
                      <Badge variant="outline" className="font-mono text-[10px] bg-muted/40">
                        {adm.gr_number}
                      </Badge>
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>
        </div>
      </div>



      {/* Official Printable Receipt Modal */}
      <PrintableReceiptModal
        open={receiptModalOpen}
        onClose={() => setReceiptModalOpen(false)}
        receiptData={
          admittedRecord
            ? {
                receiptNo: admittedRecord.receiptNo,
                studentName: admittedRecord.name,
                grNumber: admittedRecord.grNumber,
                applicationNo: admittedRecord.applicationNo,
                className: admittedRecord.className,
                sectionName: admittedRecord.sectionName,
                campusName: selectedCampus?.name ?? 'Seena Model School & College',
                sessionName: selectedSession?.name ?? '2027-2028',
                parentName,
                feeAmount: admittedRecord.fee,
                paymentMode: admittedRecord.mode,
                date: new Date().toLocaleDateString(undefined, {
                  year: 'numeric',
                  month: 'short',
                  day: 'numeric',
                }),
              }
            : null
        }
      />
    </div>
  );
}
