'use client';

import { useState, useEffect, useTransition } from 'react';
import { toast } from 'sonner';
import { Modal } from '@/components/ui/modal';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { saveSchoolLeavePolicy, type SaveLeavePolicyInput } from './actions';
import { ShieldCheck, Sparkles, FileText, Check } from 'lucide-react';
import type { LeavePolicy } from './leave-dashboard';

export function LeavePolicyModal({
  open,
  onClose,
  policy,
  onSuccess,
}: {
  open: boolean;
  onClose: () => void;
  policy?: LeavePolicy | null;
  onSuccess?: () => void;
}) {
  const isEditing = !!policy;
  const [pending, startTransition] = useTransition();

  const [code, setCode] = useState('');
  const [nameEn, setNameEn] = useState('');
  const [entitlementDays, setEntitlementDays] = useState<number>(10);
  const [isPaid, setIsPaid] = useState<boolean>(true);
  const [requireDoc, setRequireDoc] = useState<boolean>(false);
  const [docDays, setDocDays] = useState<number>(2);
  const [syncStaff, setSyncStaff] = useState<boolean>(true);

  useEffect(() => {
    if (policy) {
      setCode(policy.code);
      setNameEn(policy.name_en);
      setEntitlementDays(policy.entitlement_days);
      setIsPaid(policy.is_paid);
      setRequireDoc(policy.doc_required_after_days !== null && policy.doc_required_after_days !== undefined);
      setDocDays(policy.doc_required_after_days ?? 2);
      setSyncStaff(true);
    } else {
      setCode('');
      setNameEn('');
      setEntitlementDays(10);
      setIsPaid(true);
      setRequireDoc(false);
      setDocDays(2);
      setSyncStaff(true);
    }
  }, [policy, open]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    if (!nameEn.trim()) {
      toast.error('Policy name is required.');
      return;
    }
    if (!isEditing && !code.trim()) {
      toast.error('Policy code is required (e.g. STUDY, BEREAVEMENT).');
      return;
    }
    if (entitlementDays < 0) {
      toast.error('Entitlement days cannot be negative.');
      return;
    }

    const payload: SaveLeavePolicyInput = {
      id: policy?.id,
      code: isEditing ? policy.code : code.toUpperCase().trim(),
      name_en: nameEn.trim(),
      entitlement_days: entitlementDays,
      is_paid: isPaid,
      doc_required_after_days: requireDoc ? docDays : null,
      is_active: policy ? policy.is_active : true,
      sync_active_staff: syncStaff,
    };

    startTransition(async () => {
      const res = await saveSchoolLeavePolicy(payload);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(
          isEditing
            ? `Updated "${nameEn}" quota to ${entitlementDays} days.`
            : `Created leave policy "${nameEn}".`
        );
        onClose();
        if (onSuccess) onSuccess();
      }
    });
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={isEditing ? `Edit Policy Quota: ${policy.name_en}` : 'Add Custom Leave Category'}
      description={
        isEditing
          ? 'Customize the annual day quota, remuneration, and document requirements for this school.'
          : 'Define a new leave entitlement category specifically for your school campus.'
      }
      size="md"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Code & Name Row */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="policy-code">Policy Code</Label>
            {isEditing ? (
              <div className="flex items-center h-9 px-3 rounded-md bg-muted border font-mono text-xs font-semibold text-foreground">
                {policy.code}
              </div>
            ) : (
              <Input
                id="policy-code"
                placeholder="e.g. STUDY"
                value={code}
                onChange={(e) => setCode(e.target.value.toUpperCase())}
                className="font-mono uppercase text-xs"
                required
              />
            )}
            <p className="text-[11px] text-muted-foreground">Unique identifier</p>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="policy-name">Leave Name</Label>
            <Input
              id="policy-name"
              placeholder="e.g. Study / Exam Leave"
              value={nameEn}
              onChange={(e) => setNameEn(e.target.value)}
              className="text-xs"
              required
            />
            <p className="text-[11px] text-muted-foreground">Display label in dropdowns</p>
          </div>
        </div>

        {/* Quota Days & Remuneration */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="policy-days">Annual Quota (Days / Year)</Label>
            <Input
              id="policy-days"
              type="number"
              min="0"
              max="365"
              step="0.5"
              value={entitlementDays}
              onChange={(e) => setEntitlementDays(parseFloat(e.target.value) || 0)}
              className="text-xs font-semibold"
              required
            />
            <p className="text-[11px] text-muted-foreground">Allocated to active staff annually</p>
          </div>

          <div className="space-y-1.5">
            <Label>Remuneration Category</Label>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => setIsPaid(true)}
                className={`flex flex-col items-center justify-center p-2 rounded-lg border text-xs font-medium transition-all ${
                  isPaid
                    ? 'border-emerald-500 bg-emerald-50 text-emerald-900 dark:bg-emerald-950/40 dark:text-emerald-200'
                    : 'border-input bg-card hover:bg-muted text-muted-foreground'
                }`}
              >
                <span className="font-semibold">Fully Paid</span>
                <span className="text-[10px] opacity-80">100% Salary</span>
              </button>

              <button
                type="button"
                onClick={() => setIsPaid(false)}
                className={`flex flex-col items-center justify-center p-2 rounded-lg border text-xs font-medium transition-all ${
                  !isPaid
                    ? 'border-amber-500 bg-amber-50 text-amber-900 dark:bg-amber-950/40 dark:text-amber-200'
                    : 'border-input bg-card hover:bg-muted text-muted-foreground'
                }`}
              >
                <span className="font-semibold">Unpaid</span>
                <span className="text-[10px] opacity-80">Loss of Pay</span>
              </button>
            </div>
          </div>
        </div>

        {/* Document Requirements */}
        <div className="space-y-2 p-3 rounded-lg border bg-muted/30">
          <label className="flex items-center gap-2 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={requireDoc}
              onChange={(e) => setRequireDoc(e.target.checked)}
              className="h-4 w-4 rounded border-input text-primary focus:ring-primary"
            />
            <span className="text-xs font-semibold text-foreground">
              Require proof or medical certificate
            </span>
          </label>

          {requireDoc && (
            <div className="flex items-center gap-2 pt-1 pl-6">
              <span className="text-xs text-muted-foreground">Document mandatory if leave exceeds</span>
              <Input
                type="number"
                min="1"
                max="30"
                value={docDays}
                onChange={(e) => setDocDays(parseInt(e.target.value, 10) || 1)}
                className="w-16 h-7 text-xs text-center"
              />
              <span className="text-xs text-muted-foreground">consecutive days</span>
            </div>
          )}
        </div>

        {/* Sync Staff Balances Checkbox */}
        <div className="flex items-start gap-2 pt-1">
          <input
            id="sync-staff"
            type="checkbox"
            checked={syncStaff}
            onChange={(e) => setSyncStaff(e.target.checked)}
            className="h-4 w-4 mt-0.5 rounded border-input text-primary focus:ring-primary"
          />
          <Label htmlFor="sync-staff" className="text-xs font-normal text-muted-foreground cursor-pointer">
            <strong className="text-foreground">Sync to active staff:</strong> Automatically credit or adjust
            active staff members&apos; leave balances for the current calendar year.
          </Label>
        </div>

        {/* Footer Actions */}
        <div className="flex items-center justify-end gap-2 pt-3 border-t">
          <Button type="button" variant="outline" size="sm" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button type="submit" size="sm" disabled={pending} className="gap-1.5">
            {pending ? (
              'Saving…'
            ) : (
              <>
                <Check className="h-3.5 w-3.5" />
                {isEditing ? 'Update Policy' : 'Create Policy'}
              </>
            )}
          </Button>
        </div>
      </form>
    </Modal>
  );
}
