// FR-A03: the 7 fixed onboarding steps, in wizard order. The DB enum
// (public.onboarding_step_key) has no inherent order — this is it.
export const STEP_META = [
  { key: 'campus_details', title: 'Campus details', description: 'Confirm your main campus name and code.', href: '/campuses' },
  { key: 'branding', title: 'Branding', description: 'Upload a logo and set your brand colours.', href: '/branding' },
  { key: 'academic_session', title: 'Academic session', description: 'Confirm the current academic session dates.', href: '/sessions' },
  { key: 'class_structure', title: 'Class and section structure', description: 'Pick a class preset to create sections in one step.', href: null },
  { key: 'fee_heads', title: 'Fee heads', description: 'Set up what you charge for — tuition, exam, transport and more.', href: '/fees/heads' },
  { key: 'staff_invitations', title: 'Staff invitations', description: 'Invite your first staff members.', href: '/staff' },
  { key: 'first_student', title: 'First student', description: 'Admit your first student.', href: '/students' },
] as const;

export type OnboardingStepKey = (typeof STEP_META)[number]['key'];
