import { z } from 'zod';

export const classTestSchema = z.object({
  sectionId: z.string().uuid('Choose a class and section'),
  subjectId: z.string().uuid().or(z.literal('')),
  title: z.string().trim().min(1, 'Give the test a name').max(100),
  testDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  totalMarks: z.coerce.number().positive('Total marks must be more than 0').max(1000),
});

export const marksSchema = z.object({
  testId: z.string().uuid(),
  rows: z.array(z.object({ student_id: z.string().uuid(), marks: z.number().min(0).nullable(), absent: z.boolean() })).min(1),
});

export const CLASS_TEST_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department', 'exam_controller', 'class_teacher', 'subject_teacher'];
