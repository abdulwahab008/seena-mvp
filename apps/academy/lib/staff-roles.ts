// Every staff role a school can hand out. Parent and student accounts are created through the
// guardian and student flows, never through a staff invitation. invite_user() still decides
// whether the inviter may grant a given role (app.fn_can_grant_role).
export const STAFF_ROLE_OPTIONS = [
  { value: 'subject_teacher', label: 'Subject Teacher' },
  { value: 'class_teacher', label: 'Class Teacher' },
  { value: 'head_of_department', label: 'Head of Department' },
  { value: 'principal', label: 'Principal' },
  { value: 'vice_principal', label: 'Vice Principal' },
  { value: 'admissions_officer', label: 'Admissions Officer' },
  { value: 'receptionist', label: 'Receptionist' },
  { value: 'accountant', label: 'Accountant' },
  { value: 'exam_controller', label: 'Exam Controller' },
  { value: 'hr_manager', label: 'HR Manager' },
  { value: 'librarian', label: 'Librarian' },
  { value: 'transport_manager', label: 'Transport Manager' },
  { value: 'nurse', label: 'Nurse' },
  { value: 'super_admin', label: 'Super Admin (every campus)' },
] as const;

export type StaffRole = (typeof STAFF_ROLE_OPTIONS)[number]['value'];
export const STAFF_ROLES = STAFF_ROLE_OPTIONS.map((o) => o.value) as [StaffRole, ...StaffRole[]];

const LABELS: Record<string, string> = Object.fromEntries(STAFF_ROLE_OPTIONS.map((o) => [o.value, o.label]));
export const roleLabel = (role: string): string =>
  LABELS[role] ?? (role === 'owner' ? 'Owner' : role.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()));
