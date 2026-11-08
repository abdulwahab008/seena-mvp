import { redirect } from 'next/navigation';

// Public sign-up is gone: an account that belongs to no school is a dead end.
// Old links land on the school registration request instead.
export default function SignUpPage() {
  redirect('/register-school');
}
