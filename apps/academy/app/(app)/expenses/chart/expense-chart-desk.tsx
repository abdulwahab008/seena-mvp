'use client';

import {
  useActionState,
  useEffect,
  useOptimistic,
  useRef,
  useState,
  useTransition,
} from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  createExpenseHead,
  saveExpenseBudget,
  updateExpenseHead,
  type ActionState,
  type ExpenseHeadRow,
} from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';

// ─── Types ───────────────────────────────────────────────────────────────────

type Campus = { id: string; code: string; name: string };
type Session = { id: string; name: string; status: string };

type TreeNode = ExpenseHeadRow & { children: TreeNode[] };

const INITIAL: ActionState = { error: null };

// ─── Helpers ─────────────────────────────────────────────────────────────────

function formatPKR(paisa: number | null): string {
  if (paisa === null || paisa === undefined) return '—';
  return new Intl.NumberFormat('en-PK', {
    style: 'currency',
    currency: 'PKR',
    maximumFractionDigits: 0,
  }).format(paisa / 100);
}

function buildTree(rows: ExpenseHeadRow[]): TreeNode[] {
  const map = new Map<string, TreeNode>();
  rows.forEach((r) => map.set(r.id, { ...r, children: [] }));
  const roots: TreeNode[] = [];
  rows.forEach((r) => {
    if (r.parent_id && map.has(r.parent_id)) {
      map.get(r.parent_id)!.children.push(map.get(r.id)!);
    } else {
      roots.push(map.get(r.id)!);
    }
  });
  return roots;
}

function spendPercent(actual: number | null, budget: number | null): number {
  if (!budget || !actual) return 0;
  return Math.min(Math.round((actual / budget) * 100), 999);
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function LevelBadge({ level }: { level: number }) {
  const colours = [
    'bg-blue-100 text-blue-800',
    'bg-purple-100 text-purple-800',
    'bg-green-100 text-green-800',
    'bg-yellow-100 text-yellow-800',
    'bg-red-100 text-red-800',
  ];
  return (
    <span
      className={`inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium ${colours[(level - 1) % colours.length]}`}
    >
      L{level}
    </span>
  );
}

function SpendBar({
  actual,
  budget,
  isOverspent,
}: {
  actual: number | null;
  budget: number | null;
  isOverspent: boolean | null;
}) {
  const pct = spendPercent(actual, budget);
  if (budget === null || budget === 0) return <span className="text-xs text-muted-foreground">No budget</span>;
  return (
    <div className="flex items-center gap-2 min-w-[120px]">
      <div className="h-2 w-24 rounded-full bg-muted overflow-hidden">
        <div
          className={`h-full rounded-full transition-all ${isOverspent ? 'bg-red-500' : pct > 80 ? 'bg-yellow-500' : 'bg-green-500'}`}
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
      <span className={`text-xs font-medium ${isOverspent ? 'text-red-600' : ''}`}>
        {pct}%
      </span>
    </div>
  );
}

function HeadRow({
  node,
  depth,
  allHeads,
  canEdit,
  campusId,
  sessionId,
  month,
  onBudget,
  onEdit,
}: {
  node: TreeNode;
  depth: number;
  allHeads: ExpenseHeadRow[];
  canEdit: boolean;
  campusId: string | null;
  sessionId: string | null;
  month: string;
  onBudget: (head: ExpenseHeadRow) => void;
  onEdit: (head: ExpenseHeadRow) => void;
}) {
  const [open, setOpen] = useState(true);

  return (
    <>
      <tr
        className={`border-b hover:bg-muted/40 transition-colors ${!node.is_active ? 'opacity-50' : ''}`}
        data-testid={`head-row-${node.code}`}
      >
        {/* Indent + expand toggle */}
        <td className="py-2 px-3 text-sm font-mono">
          <div className="flex items-center gap-1" style={{ paddingLeft: depth * 20 }}>
            {node.children.length > 0 ? (
              <button
                className="text-muted-foreground hover:text-foreground w-4 text-center"
                onClick={() => setOpen((o) => !o)}
                aria-label={open ? 'Collapse' : 'Expand'}
              >
                {open ? '▾' : '▸'}
              </button>
            ) : (
              <span className="w-4 text-center text-muted-foreground">·</span>
            )}
            <span className="font-semibold">{node.code}</span>
          </div>
        </td>
        <td className="py-2 px-3 text-sm">
          <div>
            <span>{node.name_en}</span>
            {node.name_ur && (
              <span className="ml-2 text-muted-foreground text-xs" dir="rtl">
                {node.name_ur}
              </span>
            )}
          </div>
        </td>
        <td className="py-2 px-3">
          <LevelBadge level={node.level} />
        </td>
        <td className="py-2 px-3 text-sm">
          {node.is_leaf ? (
            <span className="text-green-700 text-xs font-medium">Leaf</span>
          ) : (
            <span className="text-muted-foreground text-xs">Group</span>
          )}
        </td>
        <td className="py-2 px-3 text-sm">
          {node.requires_approval && (
            <span className="rounded bg-amber-100 text-amber-800 px-1.5 py-0.5 text-xs">
              Needs approval
            </span>
          )}
        </td>
        {/* Budget column */}
        <td className="py-2 px-3 text-sm text-right font-mono">
          {node.budget_paisa !== null ? formatPKR(node.budget_paisa) : '—'}
        </td>
        {/* Actual spend */}
        <td className="py-2 px-3 text-sm text-right font-mono">
          {node.actual_paisa !== null ? formatPKR(node.actual_paisa) : '—'}
        </td>
        {/* Remaining */}
        <td
          className={`py-2 px-3 text-sm text-right font-mono ${node.is_overspent ? 'text-red-600 font-semibold' : ''}`}
        >
          {node.remaining_paisa !== null ? formatPKR(node.remaining_paisa) : '—'}
          {node.is_overspent && (
            <span className="ml-1 rounded bg-red-100 text-red-700 px-1 py-0.5 text-xs">
              Over!
            </span>
          )}
        </td>
        {/* Progress bar */}
        <td className="py-2 px-3">
          <SpendBar
            actual={node.actual_paisa}
            budget={node.budget_paisa}
            isOverspent={node.is_overspent}
          />
        </td>
        {/* Actions */}
        {canEdit && (
          <td className="py-2 px-3 text-right">
            <div className="flex gap-1 justify-end">
              <Button
                variant="outline"
                size="sm"
                onClick={() => onBudget(node)}
                data-testid={`set-budget-${node.code}`}
              >
                Budget
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => onEdit(node)}
                data-testid={`edit-head-${node.code}`}
              >
                Edit
              </Button>
            </div>
          </td>
        )}
      </tr>
      {open &&
        node.children.map((child) => (
          <HeadRow
            key={child.id}
            node={child}
            depth={depth + 1}
            allHeads={allHeads}
            canEdit={canEdit}
            campusId={campusId}
            sessionId={sessionId}
            month={month}
            onBudget={onBudget}
            onEdit={onEdit}
          />
        ))}
    </>
  );
}

// ─── Create Head Modal ────────────────────────────────────────────────────────

function CreateHeadModal({
  allHeads,
  onClose,
}: {
  allHeads: ExpenseHeadRow[];
  onClose: () => void;
}) {
  const router = useRouter();
  const formRef = useRef<HTMLFormElement>(null);
  const [state, action, submitting] = useActionState(createExpenseHead, INITIAL);

  useEffect(() => {
    if (state.error) { toast.error(state.error); return; }
    if (state.success) {
      toast.success('Expense head created.');
      formRef.current?.reset();
      router.refresh();
      onClose();
    }
  }, [state, router, onClose]);

  const roots = allHeads.filter((h) => h.level < 5 && !h.is_leaf === false || h.level < 5);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
      <div className="bg-background rounded-lg shadow-xl p-6 w-full max-w-md space-y-4">
        <h2 className="text-lg font-semibold">New Expense Head</h2>
        <form ref={formRef} action={action} className="space-y-4">
          <div>
            <Label htmlFor="create-code">Code</Label>
            <Input
              id="create-code"
              name="code"
              required
              placeholder="e.g. UTILITIES_ELECTRIC"
              className="mt-1 uppercase"
            />
          </div>
          <div>
            <Label htmlFor="create-name-en">English Name</Label>
            <Input
              id="create-name-en"
              name="name_en"
              required
              placeholder="Electricity Bills"
              className="mt-1"
            />
          </div>
          <div>
            <Label htmlFor="create-name-ur">Urdu Name</Label>
            <Input
              id="create-name-ur"
              name="name_ur"
              required
              dir="rtl"
              placeholder="بجلی بل"
              className="mt-1"
            />
          </div>
          <div>
            <Label htmlFor="create-parent">Parent Head (optional)</Label>
            <Select name="parent_id">
              <SelectTrigger id="create-parent" className="mt-1">
                <SelectValue placeholder="Root (no parent)" />
              </SelectTrigger>
              <SelectContent>
                {allHeads
                  .filter((h) => h.level < 5)
                  .map((h) => (
                    <SelectItem key={h.id} value={h.id}>
                      {'  '.repeat(h.level - 1)}{h.code} — {h.name_en}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>
          <div className="flex items-center gap-2">
            <input
              id="create-approval"
              type="checkbox"
              name="requires_approval"
              value="true"
              className="rounded border-muted"
            />
            <Label htmlFor="create-approval">Always requires approval</Label>
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={submitting}>
              {submitting ? 'Creating…' : 'Create Head'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ─── Edit Head Modal ──────────────────────────────────────────────────────────

function EditHeadModal({
  head,
  allHeads,
  onClose,
}: {
  head: ExpenseHeadRow;
  allHeads: ExpenseHeadRow[];
  onClose: () => void;
}) {
  const router = useRouter();
  const [state, action, submitting] = useActionState(updateExpenseHead, INITIAL);

  useEffect(() => {
    if (state.error) { toast.error(state.error); return; }
    if (state.success) {
      toast.success('Head updated.');
      router.refresh();
      onClose();
    }
  }, [state, router, onClose]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
      <div className="bg-background rounded-lg shadow-xl p-6 w-full max-w-md space-y-4">
        <h2 className="text-lg font-semibold">Edit: {head.code}</h2>
        <form action={action} className="space-y-4">
          <input type="hidden" name="id" value={head.id} />
          <div>
            <Label htmlFor="edit-name-en">English Name</Label>
            <Input
              id="edit-name-en"
              name="name_en"
              defaultValue={head.name_en}
              className="mt-1"
            />
          </div>
          <div>
            <Label htmlFor="edit-name-ur">Urdu Name</Label>
            <Input
              id="edit-name-ur"
              name="name_ur"
              defaultValue={head.name_ur}
              dir="rtl"
              className="mt-1"
            />
          </div>
          <div className="flex items-center gap-2">
            <input
              id="edit-approval"
              type="checkbox"
              name="requires_approval"
              value="true"
              defaultChecked={head.requires_approval}
              className="rounded border-muted"
            />
            <Label htmlFor="edit-approval">Always requires approval</Label>
          </div>
          <div className="flex items-center gap-2">
            <input
              id="edit-active"
              type="checkbox"
              name="is_active"
              value="true"
              defaultChecked={head.is_active}
              className="rounded border-muted"
            />
            <Label htmlFor="edit-active">Active</Label>
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={submitting}>
              {submitting ? 'Saving…' : 'Save Changes'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ─── Set Budget Modal ─────────────────────────────────────────────────────────

function BudgetModal({
  head,
  campusId,
  sessionId,
  month,
  onClose,
}: {
  head: ExpenseHeadRow;
  campusId: string | null;
  sessionId: string | null;
  month: string;
  onClose: () => void;
}) {
  const router = useRouter();
  const [state, action, submitting] = useActionState(saveExpenseBudget, INITIAL);

  useEffect(() => {
    if (state.error) { toast.error(state.error); return; }
    if (state.success) {
      toast.success('Budget saved.');
      router.refresh();
      onClose();
    }
  }, [state, router, onClose]);

  const existingRupees = head.budget_paisa != null ? (head.budget_paisa / 100).toFixed(0) : '';

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
      <div className="bg-background rounded-lg shadow-xl p-6 w-full max-w-sm space-y-4">
        <h2 className="text-lg font-semibold">Set Monthly Budget</h2>
        <p className="text-sm text-muted-foreground">
          <strong>{head.code}</strong> — {head.name_en}
          <br />
          Month: {month}
        </p>
        <form action={action} className="space-y-4">
          <input type="hidden" name="head_id" value={head.id} />
          <input type="hidden" name="campus_id" value={campusId ?? ''} />
          <input type="hidden" name="session_id" value={sessionId ?? ''} />
          <input type="hidden" name="budget_month" value={`${month}-01`} />
          <div>
            <Label htmlFor="budget-amount">Amount (PKR)</Label>
            <Input
              id="budget-amount"
              name="amount_rupees"
              type="number"
              min="0"
              step="1"
              defaultValue={existingRupees}
              placeholder="0"
              className="mt-1"
              required
            />
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={submitting}>
              {submitting ? 'Saving…' : 'Save Budget'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ─── Main Desk Component ──────────────────────────────────────────────────────

export function ExpenseChartDesk({
  role,
  campuses,
  sessions,
  initialHeads,
  initialCampusId,
  initialSessionId,
  initialMonth,
}: {
  role: string;
  campuses: Campus[];
  sessions: Session[];
  initialHeads: ExpenseHeadRow[];
  initialCampusId: string | null;
  initialSessionId: string | null;
  initialMonth: string;
}) {
  const router = useRouter();
  const [campusId, setCampusId] = useState(initialCampusId);
  const [sessionId, setSessionId] = useState(initialSessionId);
  const [month, setMonth] = useState(initialMonth);
  const [showCreate, setShowCreate] = useState(false);
  const [editHead, setEditHead] = useState<ExpenseHeadRow | null>(null);
  const [budgetHead, setBudgetHead] = useState<ExpenseHeadRow | null>(null);

  const canEdit = ['super_admin', 'owner', 'principal', 'accountant'].includes(role);

  const tree = buildTree(initialHeads);

  const applyFilters = (
    nextCampus?: string | null,
    nextSession?: string | null,
    nextMonth?: string,
  ) => {
    const c = nextCampus ?? campusId;
    const s = nextSession ?? sessionId;
    const m = nextMonth ?? month;
    const params = new URLSearchParams();
    if (c) params.set('campus', c);
    if (s) params.set('session', s);
    if (m) params.set('month', m);
    router.push(`/expenses/chart?${params.toString()}`);
  };

  // Summary stats
  const totalBudget = initialHeads.reduce(
    (sum, h) => sum + (h.is_leaf ? (h.budget_paisa ?? 0) : 0),
    0,
  );
  const totalActual = initialHeads.reduce(
    (sum, h) => sum + (h.is_leaf ? (h.actual_paisa ?? 0) : 0),
    0,
  );
  const overspentCount = initialHeads.filter((h) => h.is_overspent).length;

  return (
    <div className="space-y-6">
      {/* ── Filter Bar ─────────────────────────────────────────────────── */}
      <div className="flex flex-wrap items-center gap-3">
        {campuses.length > 1 && (
          <div>
            <Label className="text-xs text-muted-foreground mb-1 block">Campus</Label>
            <Select
              value={campusId ?? ''}
              onValueChange={(v) => {
                setCampusId(v);
                applyFilters(v);
              }}
            >
              <SelectTrigger className="w-44">
                <SelectValue placeholder="All campuses" />
              </SelectTrigger>
              <SelectContent>
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.code} — {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        {sessions.length > 0 && (
          <div>
            <Label className="text-xs text-muted-foreground mb-1 block">Session</Label>
            <Select
              value={sessionId ?? ''}
              onValueChange={(v) => {
                setSessionId(v);
                applyFilters(undefined, v);
              }}
            >
              <SelectTrigger className="w-44">
                <SelectValue placeholder="Select session" />
              </SelectTrigger>
              <SelectContent>
                {sessions.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name} {s.status === 'current' ? '(Current)' : ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        <div>
          <Label className="text-xs text-muted-foreground mb-1 block">Month</Label>
          <Input
            type="month"
            value={month}
            onChange={(e) => {
              setMonth(e.target.value);
              applyFilters(undefined, undefined, e.target.value);
            }}
            className="w-40"
          />
        </div>
        <div className="ml-auto">
          {canEdit && (
            <Button
              onClick={() => setShowCreate(true)}
              data-testid="btn-new-expense-head"
            >
              + New Expense Head
            </Button>
          )}
        </div>
      </div>

      {/* ── Summary Cards ──────────────────────────────────────────────── */}
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-lg border p-4 space-y-1">
          <p className="text-xs text-muted-foreground">Total Budgeted (Leaf Heads)</p>
          <p className="text-xl font-semibold font-mono">{formatPKR(totalBudget)}</p>
        </div>
        <div className="rounded-lg border p-4 space-y-1">
          <p className="text-xs text-muted-foreground">Total Spent (Leaf Heads)</p>
          <p className="text-xl font-semibold font-mono">{formatPKR(totalActual)}</p>
        </div>
        <div className={`rounded-lg border p-4 space-y-1 ${overspentCount > 0 ? 'border-red-400 bg-red-50' : ''}`}>
          <p className="text-xs text-muted-foreground">Overspent Heads</p>
          <p className={`text-xl font-semibold ${overspentCount > 0 ? 'text-red-600' : ''}`}>
            {overspentCount}
          </p>
        </div>
      </div>

      {/* ── Tree Table ─────────────────────────────────────────────────── */}
      {initialHeads.length === 0 ? (
        <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground" data-testid="expense-chart-empty">
          No expense heads found. Create your first head using the button above.
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm" data-testid="expense-chart-table">
            <thead className="bg-muted/50">
              <tr>
                <th className="py-2 px-3 text-left font-medium text-muted-foreground">Code</th>
                <th className="py-2 px-3 text-left font-medium text-muted-foreground">Name</th>
                <th className="py-2 px-3 text-left font-medium text-muted-foreground">Level</th>
                <th className="py-2 px-3 text-left font-medium text-muted-foreground">Type</th>
                <th className="py-2 px-3 text-left font-medium text-muted-foreground">Flags</th>
                <th className="py-2 px-3 text-right font-medium text-muted-foreground">Budget</th>
                <th className="py-2 px-3 text-right font-medium text-muted-foreground">Actual</th>
                <th className="py-2 px-3 text-right font-medium text-muted-foreground">Remaining</th>
                <th className="py-2 px-3 text-left font-medium text-muted-foreground">Progress</th>
                {canEdit && (
                  <th className="py-2 px-3 text-right font-medium text-muted-foreground">Actions</th>
                )}
              </tr>
            </thead>
            <tbody>
              {tree.map((node) => (
                <HeadRow
                  key={node.id}
                  node={node}
                  depth={0}
                  allHeads={initialHeads}
                  canEdit={canEdit}
                  campusId={campusId}
                  sessionId={sessionId}
                  month={month}
                  onBudget={setBudgetHead}
                  onEdit={setEditHead}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* ── Modals ─────────────────────────────────────────────────────── */}
      {showCreate && (
        <CreateHeadModal
          allHeads={initialHeads}
          onClose={() => setShowCreate(false)}
        />
      )}
      {editHead && (
        <EditHeadModal
          head={editHead}
          allHeads={initialHeads}
          onClose={() => setEditHead(null)}
        />
      )}
      {budgetHead && (
        <BudgetModal
          head={budgetHead}
          campusId={campusId}
          sessionId={sessionId}
          month={month}
          onClose={() => setBudgetHead(null)}
        />
      )}
    </div>
  );
}
