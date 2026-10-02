import { z } from 'zod';

/**
 * Password rules, kept in one place so the sign-up form, the reset form and
 * the on-screen help text can never drift apart.
 *
 * MIN_LENGTH mirrors auth.minimum_password_length in supabase/config.toml.
 * GoTrue rejects anything shorter itself; validating here too is what turns
 * an opaque 422 from the API into an inline field error before submit.
 * config.toml leaves auth.password_requirements empty, so character-class
 * rules are deliberately NOT invented here — a rule the server does not
 * actually enforce is just a lie told to the user.
 */
export const PASSWORD_MIN_LENGTH = 10;

export const PASSWORD_RULES = [
  `At least ${PASSWORD_MIN_LENGTH} characters long`,
  'Not one of the obvious ones, like "password123"',
] as const;

const BANNED = new Set([
  'password',
  'password1',
  'password12',
  'password123',
  'passw0rd123',
  '1234567890',
  '12345678901',
  'qwertyuiop',
  'letmein123',
  'iloveyou12',
  'administrator',
]);

export const passwordSchema = z
  .string()
  .min(PASSWORD_MIN_LENGTH, `Password must be at least ${PASSWORD_MIN_LENGTH} characters`)
  .refine((value) => !BANNED.has(value.toLowerCase()), 'That password is too easy to guess');

/**
 * The "both fields match" rule, as arguments for `.refine()`.
 *
 * Deliberately not a schema-wrapping helper: wrapping a generic
 * `ZodTypeAny` in `.superRefine()` erases the object shape, and
 * react-hook-form then widens every `errors.<field>.message` to
 * `string | FieldError | …` at the call site.
 */
export const passwordsMatch: [
  (value: { password: string; confirmPassword: string }) => boolean,
  { message: string; path: (string | number)[] },
] = [
  (value) => value.password === value.confirmPassword,
  { message: 'Passwords do not match', path: ['confirmPassword'] },
];
