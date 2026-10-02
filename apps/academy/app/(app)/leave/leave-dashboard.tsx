'use client';

import { useState, useTransition, useMemo } from 'react';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';
import { PageHeader, Stat } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Table,
  TableHeader,
  TableBody,
  TableRow,
  TableHead,
  TableCell,
} from '@/components/ui/table';
import {
  CalendarCheck,
  Clock,
  Users,
  ShieldCheck,
  Search,
  CheckCircle2,
  AlertCircle,
  Calendar,
  FileText,
  RotateCcw,
  Sparkles,
  Info,
  Plus,
  Pencil,
  Power,
} from 'lucide-react';
import { ApplyLeaveForm, type LeaveType, type StaffOption } from './apply-leave-form';
import { ApplicationList, type ApplicationRow } from './application-list';
import { ApprovalQueue, type PendingRow } from './approval-queue';
import { cancelLeave, initializeStandardLeavePolicies, toggleLeavePolicyActive } from './actions';
import { LeavePolicyModal } from './leave-policy-modal';

export type LeaveRosterRow = {
  id: string;
  from_date: string;
  to_date: string;
  is_half_day: boolean;
  working_days: number;
  reason: string | null;
  status: string;
  submitted_at: string;
  leave_type: { code: string; name_en: string; is_paid: boolean } | null;
  staff: { id: string; full_name: string; employee_code: string } | null;
};

export type LeavePolicy = {
  id: string;
  code: string;
  name_en: string;
  entitlement_days: number;
  accrual_method: string;
  is_paid: boolean;
  doc_required_after_days: number | null;
  eligible_genders: string[];
  eligible_contract_types: string[];
  is_active: boolean;
};

export type LeaveDashboardProps = {
  isApprover: boolean;
  userRole: string;
  staffId?: string | null;
  staffList: StaffOption[];
  leaveTypes: LeaveType[];
  balances: Record<string, number>;
  myApplications: ApplicationRow[];
  pendingApplications: PendingRow[];
  allApplications: LeaveRosterRow[];
  policies: LeavePolicy[];
  metrics: {
    onLeaveToday: number;
    pendingApprovals: number;
    totalActiveStaff: number;
    totalPaidQuota: number;
  };
};

function statusBadgeVariant(status: string): 'warning' | 'success' | 'destructive' | 'outline' {
  switch (status) {
    case 'pending':
      return 'warning';
    case 'approved':
      return 'success';
    case 'rejected':
      return 'destructive';
    default:
      return 'outline';
  }
}

export function LeaveDashboard({
  isApprover,
  userRole,
  staffId,
  staffList,
  leaveTypes,
  balances,
  myApplications,
  pendingApplications,
  allApplications,
  policies,
  metrics,
}: LeaveDashboardProps) {
  // If the user is an approver and has pending items, default to 'approvals'
  // Otherwise, default to 'apply' for teachers and self-service.
  const [activeTab, setActiveTab] = useState<string>(
    isApprover && pendingApplications.length > 0 ? 'approvals' : 'apply'
  );

  // Search & Filter state for Roster
  const [searchTerm, setSearchTerm] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('all');

  // Policy Modal state
  const [policyModalOpen, setPolicyModalOpen] = useState(false);
  const [selectedPolicyForEdit, setSelectedPolicyForEdit] = useState<LeavePolicy | null>(null);

  // Policy re-sync & status toggle transitions
  const [syncing, startSyncTransition] = useTransition();
  const [togglingId, setTogglingId] = useState<string | null>(null);
  const [, startToggleTransition] = useTransition();
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const [, startCancelTransition] = useTransition();

  // Dynamically compute the school's active paid leave categories and total paid quota
  const activePaidPolicies = useMemo(() => {
    return policies.filter((p) => p.is_paid && (p.is_active ?? true));
  }, [policies]);

  const dynamicPaidQuota = useMemo(() => {
    return activePaidPolicies.reduce((acc, p) => acc + p.entitlement_days, 0);
  }, [activePaidPolicies]);

  const dynamicPaidHint = useMemo(() => {
    if (activePaidPolicies.length === 0) return 'No paid categories configured';
    return (
      activePaidPolicies
        .map((p) => `${p.entitlement_days}d ${p.code}`)
        .join(' + ') + ' (All others unpaid)'
    );
  }, [activePaidPolicies]);

  const handleSyncPolicies = () => {
    startSyncTransition(async () => {
      const res = await initializeStandardLeavePolicies();
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Standard school leave policies synchronized successfully.');
      }
    });
  };

  const handleTogglePolicyStatus = (policy: LeavePolicy) => {
    const newStatus = !policy.is_active;
    setTogglingId(policy.id);
    startToggleTransition(async () => {
      const res = await toggleLeavePolicyActive(policy.id, newStatus);
      setTogglingId(null);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success(`Policy "${policy.name_en}" ${newStatus ? 'activated' : 'deactivated'}.`);
      }
    });
  };

  const handleCancelApplication = (applicationId: string) => {
    setCancellingId(applicationId);
    startCancelTransition(async () => {
      const res = await cancelLeave(applicationId);
      setCancellingId(null);
      if (res.error) {
        toast.error(res.error);
      } else {
        toast.success('Application cancelled successfully.');
      }
    });
  };

  // Filtered Roster
  const filteredRoster = useMemo(() => {
    return allApplications.filter((row) => {
      const matchesStatus = statusFilter === 'all' || row.status === statusFilter;
      const searchLower = searchTerm.toLowerCase();
      const matchesSearch =
        !searchTerm ||
        row.staff?.full_name?.toLowerCase().includes(searchLower) ||
        row.staff?.employee_code?.toLowerCase().includes(searchLower) ||
        row.leave_type?.name_en?.toLowerCase().includes(searchLower) ||
        row.leave_type?.code?.toLowerCase().includes(searchLower) ||
        row.reason?.toLowerCase().includes(searchLower);
      return matchesStatus && matchesSearch;
    });
  }, [allApplications, statusFilter, searchTerm]);

  const tabs = [
    ...(isApprover
      ? [
          {
            id: 'approvals',
            label: 'Pending Approvals',
            icon: Clock,
            badge: pendingApplications.length > 0 ? pendingApplications.length : null,
            badgeVariant: 'warning' as const,
          },
        ]
      : []),
    {
      id: 'apply',
      label: isApprover ? 'Apply for Leave' : 'My Leave Desk',
      icon: Calendar,
    },
    ...(isApprover
      ? [
          {
            id: 'roster',
            label: 'Staff Leave Roster',
            icon: Users,
            badge: allApplications.length > 0 ? allApplications.length : null,
            badgeVariant: 'default' as const,
          },
        ]
      : []),
    {
      id: 'policies',
      label: `Policies & Quotas (${dynamicPaidQuota}d Paid)`,
      icon: ShieldCheck,
    },
  ];

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <PageHeader
        title="Staff Leave & Policy Management"
        description="Comprehensive portal for leave requests, balance tracking, dynamic quota management, and school policy enforcement."
        actions={
          isApprover ? (
            <div className="flex flex-wrap items-center gap-2">
              <Button
                size="sm"
                onClick={() => {
                  setSelectedPolicyForEdit(null);
                  setPolicyModalOpen(true);
                }}
                className="gap-1.5 text-xs h-9"
              >
                <Plus className="h-3.5 w-3.5" />
                Add Leave Policy
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={handleSyncPolicies}
                disabled={syncing}
                className="gap-1.5 text-xs h-9"
              >
                <RotateCcw className={cn('h-3.5 w-3.5', syncing && 'animate-spin')} />
                {syncing ? 'Syncing…' : 'Reset Standard Quotas'}
              </Button>
            </div>
          ) : undefined
        }
      />

      {/* KPI Stats Row */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <Stat
          label="On Leave Today"
          value={metrics.onLeaveToday}
          hint="Approved active leaves today"
          icon={CalendarCheck}
          tone={metrics.onLeaveToday > 0 ? 'warning' : 'default'}
        />
        <Stat
          label="Pending Approvals"
          value={metrics.pendingApprovals}
          hint={metrics.pendingApprovals > 0 ? 'Awaiting administrative action' : 'No backlog'}
          icon={Clock}
          tone={metrics.pendingApprovals > 0 ? 'warning' : 'success'}
        />
        <Stat
          label="Active Staff"
          value={metrics.totalActiveStaff}
          hint="Entitled to annual quotas"
          icon={Users}
          tone="default"
        />
        <Stat
          label="Paid Leave Quota"
          value={`${dynamicPaidQuota} Days`}
          hint={dynamicPaidHint}
          icon={ShieldCheck}
          tone="success"
        />
      </div>

      {/* Navigation Tabs */}
      <div className="flex border-b border-border overflow-x-auto no-scrollbar gap-2">
        {tabs.map((t) => {
          const Icon = t.icon;
          const isActive = activeTab === t.id;
          return (
            <button
              key={t.id}
              type="button"
              onClick={() => setActiveTab(t.id)}
              className={cn(
                'flex items-center gap-2 border-b-2 px-4 py-2.5 text-sm font-medium transition-all whitespace-nowrap -mb-px',
                isActive
                  ? 'border-primary text-foreground font-semibold'
                  : 'border-transparent text-muted-foreground hover:border-muted-foreground/30 hover:text-foreground'
              )}
            >
              <Icon className={cn('h-4 w-4', isActive ? 'text-primary' : 'text-muted-foreground')} />
              <span>{t.label}</span>
              {t.badge !== null && t.badge !== undefined && (
                <Badge variant={t.badgeVariant ?? 'default'} className="ml-1 text-[11px] py-0 px-1.5">
                  {t.badge}
                </Badge>
              )}
            </button>
          );
        })}
      </div>

      {/* Tab 1: Approvals Queue */}
      {activeTab === 'approvals' && isApprover && (
        <div className="space-y-4 animate-in fade-in-50 duration-200">
          <ApprovalQueue applications={pendingApplications} />
        </div>
      )}

      {/* Tab 2: Apply Leave & Personal Applications */}
      {activeTab === 'apply' && (
        <div className="space-y-6 animate-in fade-in-50 duration-200">
          <ApplyLeaveForm
            staffId={staffId}
            leaveTypes={leaveTypes}
            balances={balances}
            staffList={staffList}
            isApprover={isApprover}
          />
          {(staffId || myApplications.length > 0) && (
            <ApplicationList applications={myApplications} />
          )}
        </div>
      )}

      {/* Tab 3: Staff Leave Roster */}
      {activeTab === 'roster' && isApprover && (
        <div className="space-y-4 animate-in fade-in-50 duration-200">
          <Card>
            <CardHeader className="p-4 pb-3">
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                <div>
                  <CardTitle className="text-base">All Staff Leave Roster & History</CardTitle>
                  <CardDescription className="text-xs">
                    Comprehensive log of all submitted, approved, rejected, and cancelled applications.
                  </CardDescription>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <div className="relative w-full sm:w-64">
                    <Search className="absolute left-2.5 top-2.5 h-3.5 w-3.5 text-muted-foreground" />
                    <Input
                      placeholder="Search staff, leave type…"
                      value={searchTerm}
                      onChange={(e) => setSearchTerm(e.target.value)}
                      className="pl-8 h-8 text-xs bg-background"
                    />
                  </div>
                </div>
              </div>

              {/* Status Filter Buttons */}
              <div className="flex flex-wrap items-center gap-1.5 pt-3">
                {['all', 'pending', 'approved', 'rejected', 'cancelled'].map((st) => (
                  <button
                    key={st}
                    type="button"
                    onClick={() => setStatusFilter(st)}
                    className={cn(
                      'px-2.5 py-1 text-xs rounded-full font-medium transition-colors capitalize',
                      statusFilter === st
                        ? 'bg-primary text-primary-foreground'
                        : 'bg-muted text-muted-foreground hover:bg-muted/80'
                    )}
                  >
                    {st}
                  </button>
                ))}
              </div>
            </CardHeader>

            <CardContent className="p-0">
              {filteredRoster.length === 0 ? (
                <div className="p-8 text-center text-muted-foreground text-sm">
                  No leave records matching your search or filters.
                </div>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Staff Member</TableHead>
                      <TableHead>Leave Type</TableHead>
                      <TableHead>Dates & Duration</TableHead>
                      <TableHead>Pay Type</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Reason</TableHead>
                      <TableHead className="text-right">Actions</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {filteredRoster.map((row) => (
                      <TableRow key={row.id}>
                        <TableCell>
                          <div className="font-medium text-foreground text-xs">
                            {row.staff?.full_name ?? 'Unknown Staff'}
                          </div>
                          <div className="text-[11px] text-muted-foreground">
                            {row.staff?.employee_code ?? '—'}
                          </div>
                        </TableCell>
                        <TableCell className="text-xs font-medium">
                          {row.leave_type?.name_en ?? 'Leave'}
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground">
                          <div>
                            {row.from_date} to {row.to_date}
                          </div>
                          <div className="font-semibold text-foreground text-[11px]">
                            {row.working_days}d {row.is_half_day ? '(half-day)' : ''}
                          </div>
                        </TableCell>
                        <TableCell>
                          {row.leave_type?.is_paid ? (
                            <Badge variant="success" className="text-[10px] py-0 px-1.5">
                              Paid
                            </Badge>
                          ) : (
                            <Badge variant="outline" className="text-[10px] py-0 px-1.5 text-muted-foreground">
                              Unpaid
                            </Badge>
                          )}
                        </TableCell>
                        <TableCell>
                          <Badge variant={statusBadgeVariant(row.status)} className="capitalize text-xs font-semibold">
                            {row.status}
                          </Badge>
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground max-w-xs truncate">
                          {row.reason || '—'}
                        </TableCell>
                        <TableCell className="text-right">
                          {row.status === 'approved' && (
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              onClick={() => handleCancelApplication(row.id)}
                              disabled={cancellingId === row.id}
                              className="text-xs h-7 text-destructive hover:bg-destructive/10"
                            >
                              {cancellingId === row.id ? 'Cancelling…' : 'Cancel'}
                            </Button>
                          )}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </div>
      )}

      {/* Tab 4: Policies & Quotas */}
      {activeTab === 'policies' && (
        <div className="space-y-6 animate-in fade-in-50 duration-200">
          {/* Policy Summary Callout */}
          <div className="rounded-xl border border-emerald-500/30 bg-emerald-50/50 dark:bg-emerald-950/20 p-5 shadow-xs">
            <div className="flex items-start gap-3">
              <div className="p-2 rounded-lg bg-emerald-500/10 text-emerald-600 dark:text-emerald-400">
                <ShieldCheck className="h-6 w-6" />
              </div>
              <div className="space-y-1">
                <h3 className="text-base font-semibold text-emerald-950 dark:text-emerald-200">
                  School Annual Paid Leave Quota: {dynamicPaidQuota} Days per Year
                </h3>
                <p className="text-xs text-emerald-800 dark:text-emerald-300 leading-relaxed max-w-3xl">
                  According to this school&apos;s current active policies, staff members receive{' '}
                  <strong>{dynamicPaidQuota} paid leave days</strong> per calendar year ({dynamicPaidHint}). Any
                  leave beyond {dynamicPaidQuota} days or under unpaid categories is treated as Loss of Pay.
                </p>
              </div>
            </div>
          </div>

          {/* Grid of Policy Cards */}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            {policies.slice(0, 3).map((p) => (
              <Card key={p.id} className={p.is_paid ? 'border-emerald-500/30' : 'border-muted'}>
                <CardHeader className="p-4 pb-2">
                  <div className="flex items-center justify-between">
                    <Badge variant={p.is_paid ? 'success' : 'outline'} className="text-xs font-semibold">
                      {p.is_paid ? 'Fully Paid' : 'Loss of Pay'}
                    </Badge>
                    <span className="text-xl font-bold text-foreground">{p.entitlement_days} Days</span>
                  </div>
                  <CardTitle className="text-sm font-semibold pt-2">
                    {p.name_en} ({p.code})
                  </CardTitle>
                  <CardDescription className="text-xs">
                    {p.doc_required_after_days
                      ? `Medical certificate mandatory after ${p.doc_required_after_days} days`
                      : 'Standard school policy quota'}
                  </CardDescription>
                </CardHeader>
                <CardContent className="p-4 pt-0 text-xs text-muted-foreground space-y-1">
                  <p>• Annual quota granted to active staff members.</p>
                  <p>• Status: {p.is_active ? 'Active policy' : 'Inactive'}</p>
                </CardContent>
              </Card>
            ))}
          </div>

          {/* Database Policy Table */}
          <Card>
            <CardHeader className="p-4 pb-3">
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                <div>
                  <CardTitle className="text-base">Configured School Leave Policies</CardTitle>
                  <CardDescription className="text-xs">
                    Customize annual quota ceilings, toggle remuneration, and set document rules for your school.
                  </CardDescription>
                </div>
                {isApprover && (
                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      size="sm"
                      onClick={() => {
                        setSelectedPolicyForEdit(null);
                        setPolicyModalOpen(true);
                      }}
                      className="text-xs h-8 gap-1.5"
                    >
                      <Plus className="h-3.5 w-3.5" />
                      Add Leave Policy
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={handleSyncPolicies}
                      disabled={syncing}
                      className="text-xs h-8 gap-1.5"
                    >
                      <RotateCcw className={cn('h-3.5 w-3.5', syncing && 'animate-spin')} />
                      {syncing ? 'Syncing…' : 'Reset Standard Quotas'}
                    </Button>
                  </div>
                )}
              </div>
            </CardHeader>
            <CardContent className="p-0">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Code</TableHead>
                    <TableHead>Leave Type Name</TableHead>
                    <TableHead>Annual Quota</TableHead>
                    <TableHead>Remuneration</TableHead>
                    <TableHead>Doc Rule</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {policies.map((p) => (
                    <TableRow key={p.id}>
                      <TableCell className="font-mono text-xs font-semibold text-foreground">
                        {p.code}
                      </TableCell>
                      <TableCell className="text-xs font-medium text-foreground">
                        {p.name_en}
                      </TableCell>
                      <TableCell className="text-xs font-semibold">
                        {p.entitlement_days} days
                      </TableCell>
                      <TableCell>
                        {p.is_paid ? (
                          <Badge variant="success" className="text-[10px] py-0 px-1.5">
                            Fully Paid
                          </Badge>
                        ) : (
                          <Badge variant="outline" className="text-[10px] py-0 px-1.5 text-muted-foreground">
                            Unpaid (Loss of Pay)
                          </Badge>
                        )}
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">
                        {p.doc_required_after_days
                          ? `Mandatory > ${p.doc_required_after_days}d`
                          : 'Not required'}
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant={p.is_active ? 'primary' : 'outline'}
                          className="text-[10px] py-0 px-1.5"
                        >
                          {p.is_active ? 'Active' : 'Disabled'}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-right">
                        {isApprover && (
                          <div className="flex items-center justify-end gap-1.5">
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              onClick={() => {
                                setSelectedPolicyForEdit(p);
                                setPolicyModalOpen(true);
                              }}
                              className="text-xs h-7 gap-1 px-2"
                              title="Edit Quota & Rules"
                            >
                              <Pencil className="h-3 w-3" />
                              Edit
                            </Button>
                            <Button
                              type="button"
                              variant={p.is_active ? 'ghost' : 'outline'}
                              size="sm"
                              onClick={() => handleTogglePolicyStatus(p)}
                              disabled={togglingId === p.id}
                              className="text-xs h-7 px-2 text-muted-foreground hover:text-foreground"
                              title={p.is_active ? 'Disable policy' : 'Enable policy'}
                            >
                              <Power className="h-3 w-3" />
                              {p.is_active ? 'Disable' : 'Enable'}
                            </Button>
                          </div>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </div>
      )}

      {/* Policy Edit/Create In-App Modal */}
      <LeavePolicyModal
        open={policyModalOpen}
        onClose={() => setPolicyModalOpen(false)}
        policy={selectedPolicyForEdit}
      />
    </div>
  );
}
