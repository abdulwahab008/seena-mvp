'use client';

import { useActionState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { changeStudentPasswordAction, PasswordChangeState } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { KeyRound, ShieldAlert } from 'lucide-react';

const initialState: PasswordChangeState = {
  error: null,
  success: false,
};

export function ForcePasswordChange({ studentName }: { studentName?: string }) {
  const router = useRouter();
  const [state, formAction, isPending] = useActionState(changeStudentPasswordAction, initialState);

  useEffect(() => {
    if (state.success) {
      window.location.href = '/student/timetable';
    }
  }, [state.success]);

  return (
    <div className="flex min-h-[70vh] items-center justify-center p-4">
      <div className="w-full max-w-md space-y-6 rounded-lg border bg-card p-6 shadow-sm">
        <div className="flex items-center gap-3 text-amber-600">
          <ShieldAlert className="h-8 w-8 flex-shrink-0" />
          <div>
            <h1 className="text-xl font-bold text-foreground">Password Change Required</h1>
            <p className="text-sm text-muted-foreground">
              {studentName ? `Welcome, ${studentName}. ` : ''}
              First login requires setting a personal password before continuing.
            </p>
          </div>
        </div>

        <form action={formAction} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="newPassword">New Password</Label>
            <div className="relative">
              <Input
                id="newPassword"
                name="newPassword"
                type="password"
                placeholder="At least 6 characters"
                required
                minLength={6}
                disabled={isPending}
                autoFocus
              />
            </div>
          </div>

          <div className="space-y-2">
            <Label htmlFor="confirmPassword">Confirm New Password</Label>
            <Input
              id="confirmPassword"
              name="confirmPassword"
              type="password"
              placeholder="Re-enter new password"
              required
              minLength={6}
              disabled={isPending}
            />
          </div>

          {state.error && (
            <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive" role="alert">
              {state.error}
            </div>
          )}

          {state.success && (
            <div className="rounded-md bg-emerald-500/15 p-3 text-sm text-emerald-600" role="status">
              Password updated successfully! Reloading portal...
            </div>
          )}

          <Button type="submit" className="w-full gap-2" disabled={isPending}>
            <KeyRound className="h-4 w-4" />
            {isPending ? 'Updating Password...' : 'Set New Password & Enter Portal'}
          </Button>
        </form>
      </div>
    </div>
  );
}
