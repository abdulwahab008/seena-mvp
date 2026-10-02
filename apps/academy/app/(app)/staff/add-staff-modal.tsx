'use client';

import * as React from 'react';
import { toast } from 'sonner';
import {
  UserPlus,
  UserCheck,
  ChevronDown,
  Check,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { DatePicker } from '@/components/ui/date-picker';
import { useRouter } from 'next/navigation';
import { registerStaffMember } from './actions';

export const STAFF_ROLE_OPTIONS = [
  { value: 'subject_teacher', label: 'Teacher (Subject Teacher)' },
  { value: 'principal', label: 'Principal' },
  { value: 'admissions_officer', label: 'Admissions Officer' },
  { value: 'accountant', label: 'Accountant' },
  { value: 'exam_controller', label: 'Exam Controller' },
  { value: 'hr_manager', label: 'HR Manager' },
] as const;

export interface AddStaffModalProps {
  campusId: string;
  campusName?: string;
  subjects?: { id: string; name_en: string; code: string }[];
  departments?: { id: string; name_en: string; code: string; name_ur?: string | null }[];
  triggerButton?: React.ReactNode;
}

export function AddStaffModal({
  campusId,
  campusName,
  subjects = [],
  departments = [],
  triggerButton,
}: AddStaffModalProps) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();

  // Form State
  const [fullName, setFullName] = React.useState('');
  const [fullNameUr, setFullNameUr] = React.useState('');
  const [gender, setGender] = React.useState<'male' | 'female' | 'other'>('male');
  const [idDocType, setIdDocType] = React.useState<'cnic' | 'passport'>('cnic');
  const [cnic, setCnic] = React.useState('');
  const [passportNo, setPassportNo] = React.useState('');
  const [dob, setDob] = React.useState('');
  const [doj, setDoj] = React.useState<string>(new Date().toISOString().split('T')[0] || '');
  const [contractType, setContractType] = React.useState<'permanent' | 'contractual' | 'visiting'>('permanent');
  const [mobile, setMobile] = React.useState('');
  const [altMobile, setAltMobile] = React.useState('');
  const [address, setAddress] = React.useState('');
  const [emergencyContact, setEmergencyContact] = React.useState('');
  const [role, setRole] = React.useState<string>('subject_teacher');
  const [departmentId, setDepartmentId] = React.useState<string>('');
  const [email, setEmail] = React.useState('');
  const [selectedSubjectIds, setSelectedSubjectIds] = React.useState<string[]>([]);

  // Registration Result
  const [createdStaff, setCreatedStaff] = React.useState<{
    staff_id: string;
    employee_code: string;
    full_name: string;
  } | null>(null);

  const resetForm = () => {
    setFullName('');
    setFullNameUr('');
    setGender('male');
    setIdDocType('cnic');
    setCnic('');
    setPassportNo('');
    setDob('');
    setDoj(new Date().toISOString().split('T')[0] || '');
    setContractType('permanent');
    setMobile('');
    setAltMobile('');
    setAddress('');
    setEmergencyContact('');
    setRole('subject_teacher');
    setDepartmentId('');
    setEmail('');
    setSelectedSubjectIds([]);
    setCreatedStaff(null);
  };

  const toggleSubject = (subjectId: string) => {
    setSelectedSubjectIds((prev) =>
      prev.includes(subjectId) ? prev.filter((id) => id !== subjectId) : [...prev, subjectId]
    );
  };

  // CNIC automatic formatting (xxxxx-xxxxxxx-x)
  const handleCnicChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    let val = e.target.value.replace(/\D/g, '').slice(0, 13);
    if (val.length > 5 && val.length <= 12) {
      val = `${val.slice(0, 5)}-${val.slice(5)}`;
    } else if (val.length > 12) {
      val = `${val.slice(0, 5)}-${val.slice(5, 12)}-${val.slice(12, 13)}`;
    }
    setCnic(val);
  };

  // Mobile formatting (03xx-xxxxxxx)
  const handleMobileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    let val = e.target.value.replace(/\D/g, '').slice(0, 11);
    if (val.length > 4) {
      val = `${val.slice(0, 4)}-${val.slice(4)}`;
    }
    setMobile(val);
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!fullName.trim()) {
      toast.error('Full name is required.');
      return;
    }
    if (idDocType === 'cnic' && (!cnic || cnic.replace(/\D/g, '').length < 13)) {
      toast.error('Valid 13-digit CNIC is required (e.g. 35201-1234567-1).');
      return;
    }
    if (idDocType === 'passport' && !passportNo.trim()) {
      toast.error('Passport number is required.');
      return;
    }
    if (!dob) {
      toast.error('Date of birth is required.');
      return;
    }
    if (!mobile.trim() || mobile.replace(/\D/g, '').length < 10) {
      toast.error('Valid mobile number is required (e.g. 0300-1234567).');
      return;
    }

    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('fullName', fullName);
    if (fullNameUr) fd.set('fullNameUr', fullNameUr);
    fd.set('gender', gender);
    fd.set('idDocumentType', idDocType);
    if (idDocType === 'cnic') fd.set('cnic', cnic);
    if (idDocType === 'passport') fd.set('passportNo', passportNo);
    fd.set('dob', dob);
    fd.set('doj', doj);
    fd.set('contractType', contractType);
    fd.set('mobile', mobile);
    if (altMobile) fd.set('altMobile', altMobile);
    if (address) fd.set('address', address);
    if (emergencyContact) fd.set('emergencyContact', emergencyContact);
    fd.set('role', role);
    if (departmentId && departmentId !== 'none') fd.set('departmentId', departmentId);
    if (email) fd.set('email', email);

    startTransition(async () => {
      const result = await registerStaffMember(fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(`Staff member registered! Employee Code: ${result.data?.employee_code}`);
        setCreatedStaff(result.data ?? null);
        router.refresh();
        if (typeof window !== 'undefined') {
          window.dispatchEvent(
            new CustomEvent('staff-directory-updated', {
              detail: {
                ...result.data,
                departmentId: departmentId && departmentId !== 'none' ? departmentId : null,
                role,
              },
            })
          );
        }
      }
    });
  };

  return (
    <>
      {triggerButton ? (
        <div
          onClick={() => {
            resetForm();
            setOpen(true);
          }}
        >
          {triggerButton}
        </div>
      ) : (
        <Button
          onClick={() => {
            resetForm();
            setOpen(true);
          }}
          data-testid="open-add-staff-modal"
          className="gap-2 bg-indigo-600 hover:bg-indigo-700 text-white"
        >
          <UserPlus className="h-4 w-4" />
          <span>Register Staff Member</span>
        </Button>
      )}

      <Modal
        open={open}
        onClose={() => {
          const wasCreated = Boolean(createdStaff);
          setOpen(false);
          resetForm();
          if (wasCreated) {
            router.refresh();
          }
        }}
        title={createdStaff ? 'Staff Member Registered' : 'Register New Staff Member'}
        description={
          createdStaff
            ? 'Official employee profile has been created successfully.'
            : campusName
            ? `Register staff member or faculty for ${campusName}.`
            : 'Register a new staff member or teacher.'
        }
        size="lg"
      >
        {createdStaff ? (
          <div className="space-y-6 py-2" data-testid="staff-created-success-card">
            <div className="rounded-xl border border-emerald-200 bg-emerald-50/60 dark:border-emerald-900/50 dark:bg-emerald-950/20 p-5 space-y-3">
              <div className="flex items-center gap-3">
                <div className="h-10 w-10 rounded-full bg-emerald-500 text-white flex items-center justify-center font-bold">
                  <UserCheck className="h-5 w-5" />
                </div>
                <div>
                  <h3 className="font-bold text-lg text-emerald-950 dark:text-emerald-200">
                    {createdStaff.full_name}
                  </h3>
                  <p className="text-xs text-emerald-700 dark:text-emerald-400">
                    Official Employee Code: <span className="font-mono font-bold">{createdStaff.employee_code}</span>
                  </p>
                </div>
              </div>
              <p className="text-sm text-muted-foreground">
                The staff profile is active in the directory and linked to their department.
              </p>
            </div>

            <div className="flex justify-end gap-3 pt-2">
              <Button
                variant="outline"
                onClick={() => {
                  resetForm();
                  setCreatedStaff(null);
                  router.refresh();
                }}
              >
                Register Another Staff
              </Button>
              <Button
                onClick={() => {
                  setOpen(false);
                  resetForm();
                  router.refresh();
                }}
              >
                Done
              </Button>
            </div>
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-6 py-2">
            {/* 1. Personal & Identity */}
            <div className="space-y-4">
              <div className="text-xs font-semibold uppercase tracking-wider text-muted-foreground pb-1 border-b">
                1. Personal & Identity Details
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="staff-full-name">Full Name *</Label>
                  <Input
                    id="staff-full-name"
                    data-testid="staff-full-name"
                    placeholder="e.g. Syed Tariq Mehmood"
                    value={fullName}
                    onChange={(e) => setFullName(e.target.value)}
                    required
                  />
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="staff-full-name-ur">Alternative / Certificate Name (Optional)</Label>
                  <Input
                    id="staff-full-name-ur"
                    data-testid="staff-full-name-ur"
                    placeholder="e.g. Tariq Mehmood Chishti"
                    value={fullNameUr}
                    onChange={(e) => setFullNameUr(e.target.value)}
                  />
                </div>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="staff-gender">Gender *</Label>
                  <div className="relative">
                    <select
                      id="staff-gender"
                      data-testid="staff-gender-select"
                      value={gender}
                      onChange={(e) => setGender(e.target.value as any)}
                      className="flex h-10 w-full appearance-none items-center justify-between rounded-md border border-input bg-background px-3 py-2 pr-8 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2"
                    >
                      <option value="male">Male</option>
                      <option value="female">Female</option>
                      <option value="other">Other</option>
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-3 top-3 h-4 w-4 opacity-50" />
                  </div>
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="staff-id-doc-type">ID Document *</Label>
                  <div className="relative">
                    <select
                      id="staff-id-doc-type"
                      data-testid="staff-id-doc-type-select"
                      value={idDocType}
                      onChange={(e) => setIdDocType(e.target.value as any)}
                      className="flex h-10 w-full appearance-none items-center justify-between rounded-md border border-input bg-background px-3 py-2 pr-8 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2"
                    >
                      <option value="cnic">National CNIC</option>
                      <option value="passport">Passport</option>
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-3 top-3 h-4 w-4 opacity-50" />
                  </div>
                </div>

                {idDocType === 'cnic' ? (
                  <div className="space-y-1.5">
                    <Label htmlFor="staff-cnic">CNIC Number *</Label>
                    <Input
                      id="staff-cnic"
                      data-testid="staff-cnic"
                      placeholder="35201-1234567-1"
                      value={cnic}
                      onChange={handleCnicChange}
                      maxLength={15}
                      required
                    />
                  </div>
                ) : (
                  <div className="space-y-1.5">
                    <Label htmlFor="staff-passport">Passport Number *</Label>
                    <Input
                      id="staff-passport"
                      data-testid="staff-passport"
                      placeholder="e.g. PK1234567"
                      value={passportNo}
                      onChange={(e) => setPassportNo(e.target.value)}
                      required
                    />
                  </div>
                )}
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="staff-dob">Date of Birth *</Label>
                  <DatePicker
                    id="staff-dob"
                    data-testid="staff-dob"
                    value={dob}
                    onChange={setDob}
                    placeholder="Select date of birth"
                    required
                  />
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="staff-doj">Date of Joining *</Label>
                  <DatePicker
                    id="staff-doj"
                    data-testid="staff-doj"
                    value={doj}
                    onChange={setDoj}
                    placeholder="Select date of joining"
                    required
                  />
                </div>
              </div>
            </div>

            {/* 2. Role & Department */}
            <div className="space-y-4">
              <div className="text-xs font-semibold uppercase tracking-wider text-muted-foreground pb-1 border-b">
                2. Role & Department Appointment
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="staff-role">School Role *</Label>
                  <div className="relative">
                    <select
                      id="staff-role"
                      data-testid="staff-role-select"
                      value={role}
                      onChange={(e) => setRole(e.target.value)}
                      className="flex h-10 w-full appearance-none items-center justify-between rounded-md border border-input bg-background px-3 py-2 pr-8 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2"
                    >
                      {STAFF_ROLE_OPTIONS.map((opt) => (
                        <option key={opt.value} value={opt.value}>
                          {opt.label}
                        </option>
                      ))}
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-3 top-3 h-4 w-4 opacity-50" />
                  </div>
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="staff-contract-type">Contract Type *</Label>
                  <div className="relative">
                    <select
                      id="staff-contract-type"
                      data-testid="staff-contract-type-select"
                      value={contractType}
                      onChange={(e) => setContractType(e.target.value as any)}
                      className="flex h-10 w-full appearance-none items-center justify-between rounded-md border border-input bg-background px-3 py-2 pr-8 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2"
                    >
                      <option value="permanent">Permanent</option>
                      <option value="contractual">Contractual</option>
                      <option value="visiting">Visiting / Part-time</option>
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-3 top-3 h-4 w-4 opacity-50" />
                  </div>
                </div>
              </div>

              <div className="space-y-1.5">
                <Label htmlFor="staff-department">Academic Department</Label>
                <div className="relative">
                  <select
                    id="staff-department"
                    data-testid="staff-department-select"
                    value={departmentId}
                    onChange={(e) => setDepartmentId(e.target.value)}
                    className="flex h-10 w-full appearance-none items-center justify-between rounded-md border border-input bg-background px-3 py-2 pr-8 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2"
                  >
                    <option value="">-- Select Academic Department --</option>
                    <option value="none">-- General Administration / None --</option>
                    {departments.map((dept) => (
                      <option key={dept.id} value={dept.id}>
                        {dept.code} — {dept.name_en}
                      </option>
                    ))}
                  </select>
                  <ChevronDown className="pointer-events-none absolute right-3 top-3 h-4 w-4 opacity-50" />
                </div>
              </div>

              {/* Teachable Subjects (Visible for Teaching Roles) */}
              {role.includes('teacher') && subjects.length > 0 && (
                <div className="space-y-2 pt-1">
                  <Label className="text-xs">Teachable Subject Specialties</Label>
                  <div className="flex flex-wrap gap-2 max-h-36 overflow-y-auto p-2 rounded-lg border bg-muted/20">
                    {subjects.map((sub) => {
                      const isSelected = selectedSubjectIds.includes(sub.id);
                      return (
                        <button
                          key={sub.id}
                          type="button"
                          onClick={() => toggleSubject(sub.id)}
                          className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium border transition-colors cursor-pointer ${
                            isSelected
                              ? 'bg-indigo-600 text-white border-indigo-600'
                              : 'bg-card text-foreground hover:bg-muted border-border'
                          }`}
                        >
                          {isSelected && <Check className="h-3 w-3" />}
                          <span>{sub.name_en}</span>
                          <span className="text-[10px] opacity-75">({sub.code})</span>
                        </button>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>

            {/* 3. Contact Details */}
            <div className="space-y-4">
              <div className="text-xs font-semibold uppercase tracking-wider text-muted-foreground pb-1 border-b">
                3. Contact & Address
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="staff-mobile">Mobile Number (WhatsApp) *</Label>
                  <Input
                    id="staff-mobile"
                    data-testid="staff-mobile"
                    placeholder="0300-1234567"
                    value={mobile}
                    onChange={handleMobileChange}
                    maxLength={12}
                    required
                  />
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="staff-alt-mobile">Alternative Phone (Optional)</Label>
                  <Input
                    id="staff-alt-mobile"
                    placeholder="e.g. 042-35891234"
                    value={altMobile}
                    onChange={(e) => setAltMobile(e.target.value)}
                  />
                </div>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="staff-address">Residential Address (Optional)</Label>
                  <Input
                    id="staff-address"
                    placeholder="House / Street, Area, City"
                    value={address}
                    onChange={(e) => setAddress(e.target.value)}
                  />
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="staff-emergency">Emergency Contact (Optional)</Label>
                  <Input
                    id="staff-emergency"
                    placeholder="e.g. Brother: 0321-9876543"
                    value={emergencyContact}
                    onChange={(e) => setEmergencyContact(e.target.value)}
                  />
                </div>
              </div>
            </div>

            {/* 4. Portal Account */}
            <div className="space-y-3">
              <div className="text-xs font-semibold uppercase tracking-wider text-muted-foreground pb-1 border-b">
                4. Portal Account (Optional)
              </div>

              <div className="space-y-1.5">
                <Label htmlFor="staff-email">Staff Portal Account (Optional)</Label>
                <Input
                  id="staff-email"
                  data-testid="staff-email"
                  type="email"
                  placeholder="teacher@school.edu.pk"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                />
                <p className="text-[11px] text-muted-foreground">
                  If provided, an invitation email with a temporary password link will be sent.
                </p>
              </div>
            </div>

            {/* Actions */}
            <div className="flex justify-end gap-3 pt-3 border-t">
              <Button type="button" variant="outline" onClick={() => setOpen(false)}>
                Cancel
              </Button>
              <Button
                type="submit"
                disabled={pending}
                data-testid="submit-staff-registration"
                className="bg-indigo-600 hover:bg-indigo-700 text-white"
              >
                {pending ? 'Registering Staff…' : 'Register Staff Member'}
              </Button>
            </div>
          </form>
        )}
      </Modal>
    </>
  );
}
