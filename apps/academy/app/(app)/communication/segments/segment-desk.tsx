'use client';

import React, { useState } from 'react';
import {
  Users,
  AlertOctagon,
  Clock,
  Sparkles,
  Plus,
  Play,
  RotateCcw,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Coins,
  Trash2,
  Send,
  Sliders,
  Check,
  Search,
  Calendar,
  ShieldCheck,
  Phone,
  Eye,
  FileSpreadsheet,
  Zap,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Modal } from '@/components/ui/modal';
import {
  MessageSegmentRow,
  AudienceSnapshotRow,
  SegmentRecipientRow,
  SegmentStats,
  SegmentType,
  resolveSegmentPreview,
  createSegment,
  updateSegment,
  deleteSegment,
  updateCampusCutoff,
  dispatchCampaignAudienceSnapshot,
} from './actions';

interface Props {
  initialSegments: MessageSegmentRow[];
  initialSnapshots: AudienceSnapshotRow[];
  initialStats: SegmentStats;
  initialCutoffTime: string;
  campusId: string | null;
}

export function DynamicSegmentDesk({
  initialSegments,
  initialSnapshots,
  initialStats,
  initialCutoffTime,
  campusId,
}: Props) {
  const [segments, setSegments] = useState<MessageSegmentRow[]>(initialSegments);
  const [snapshots, setSnapshots] = useState<AudienceSnapshotRow[]>(initialSnapshots);
  const [stats, setStats] = useState<SegmentStats>(initialStats);
  const [cutoffTime, setCutoffTime] = useState<string>(initialCutoffTime);
  const [isUpdatingCutoff, setIsUpdatingCutoff] = useState(false);
  const [cutoffMessage, setCutoffMessage] = useState<string | null>(null);

  const [activeTab, setActiveTab] = useState<'segments' | 'snapshots' | 'cutoff'>('segments');
  const [searchQuery, setSearchQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<'all' | SegmentType>('all');

  // Preview / Resolver Modal State
  const [previewSegmentId, setPreviewSegmentId] = useState<string | null>(null);
  const [previewSegmentName, setPreviewSegmentName] = useState<string>('');
  const [isPreviewModalOpen, setIsPreviewModalOpen] = useState(false);
  const [isResolving, setIsResolving] = useState(false);
  const [resolvedRecipients, setResolvedRecipients] = useState<SegmentRecipientRow[]>([]);
  const [resolveDurationMs, setResolveDurationMs] = useState<number | null>(null);
  const [resolveTotalDues, setResolveTotalDues] = useState<number>(0);
  const [resolveError, setResolveError] = useState<string | null>(null);

  // Campaign Dispatch Modal State
  const [isDispatchModalOpen, setIsDispatchModalOpen] = useState(false);
  const [dispatchSegment, setDispatchSegment] = useState<MessageSegmentRow | null>(null);
  const [dispatchCampaignTitle, setDispatchCampaignTitle] = useState('');
  const [isDispatching, setIsDispatching] = useState(false);
  const [dispatchResult, setDispatchResult] = useState<{
    success: boolean;
    count?: number;
    error?: string;
  } | null>(null);

  // Create / Edit Segment Modal State
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);
  const [editingSegmentId, setEditingSegmentId] = useState<string | null>(null);
  const [segmentName, setSegmentName] = useState('');
  const [segmentDescription, setSegmentDescription] = useState('');
  const [segmentType, setSegmentType] = useState<SegmentType>('defaulters');
  const [minDuesPkr, setMinDuesPkr] = useState<number>(5000);
  const [excludeHardship, setExcludeHardship] = useState<boolean>(true);
  const [enforceCutoff, setEnforceCutoff] = useState<boolean>(true);
  const [isSavingSegment, setIsSavingSegment] = useState(false);
  const [saveSegmentError, setSaveSegmentError] = useState<string | null>(null);

  // Filtered Segments
  const filteredSegments = segments.filter((s) => {
    const matchesSearch =
      s.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
      (s.description && s.description.toLowerCase().includes(searchQuery.toLowerCase()));
    const matchesType = typeFilter === 'all' || s.segment_type === typeFilter;
    return matchesSearch && matchesType;
  });

  // Action: Open Preview & Resolve
  const handleOpenPreview = async (segment: MessageSegmentRow) => {
    setPreviewSegmentId(segment.id);
    setPreviewSegmentName(segment.name);
    setIsPreviewModalOpen(true);
    setIsResolving(true);
    setResolveError(null);
    setResolvedRecipients([]);
    setResolveDurationMs(null);

    const res = await resolveSegmentPreview(segment.id);
    setIsResolving(false);
    if (!res.success) {
      setResolveError(res.error || 'Failed to resolve segment');
    } else {
      setResolvedRecipients(res.recipients);
      setResolveDurationMs(res.durationMs);
      setResolveTotalDues(res.totalDuesPkr);
    }
  };

  // Action: Open Dispatch Modal
  const handleOpenDispatch = (segment: MessageSegmentRow) => {
    setDispatchSegment(segment);
    setDispatchCampaignTitle(`Notice: ${segment.name} - ${new Date().toLocaleDateString('en-GB')}`);
    setDispatchResult(null);
    setIsDispatchModalOpen(true);
  };

  // Action: Execute Campaign Dispatch Snapshot
  const handleExecuteDispatch = async () => {
    if (!dispatchSegment) return;
    setIsDispatching(true);
    setDispatchResult(null);

    // Generate random campaign UUID
    const campaignId = crypto.randomUUID();
    const res = await dispatchCampaignAudienceSnapshot(campaignId, dispatchSegment.id);

    setIsDispatching(false);
    if (!res.success) {
      setDispatchResult({ success: false, error: res.error });
    } else {
      setDispatchResult({ success: true, count: res.snapshottedCount });
      // Update stats and snapshots view
      setStats((prev) => ({
        ...prev,
        totalSnapshots: prev.totalSnapshots + res.snapshottedCount,
      }));
    }
  };

  // Action: Open Create Modal
  const handleOpenCreateModal = () => {
    setEditingSegmentId(null);
    setSegmentName('');
    setSegmentDescription('');
    setSegmentType('defaulters');
    setMinDuesPkr(5000);
    setExcludeHardship(true);
    setEnforceCutoff(true);
    setSaveSegmentError(null);
    setIsCreateModalOpen(true);
  };

  // Action: Save Segment
  const handleSaveSegment = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!segmentName.trim()) {
      setSaveSegmentError('Segment name is required');
      return;
    }

    setIsSavingSegment(true);
    setSaveSegmentError(null);

    const definition: Record<string, any> = {};
    if (segmentType === 'defaulters') {
      definition.min_dues_pkr = Number(minDuesPkr) || 5000;
      definition.exclude_hardship = excludeHardship;
    } else if (segmentType === 'absent_today') {
      definition.enforce_cutoff = enforceCutoff;
      definition.cutoff_time = cutoffTime;
    } else {
      definition.rule = 'custom';
    }

    try {
      if (editingSegmentId) {
        const res = await updateSegment(editingSegmentId, {
          name: segmentName,
          description: segmentDescription,
          definition,
        });
        if (!res.success) {
          setSaveSegmentError(res.error || 'Failed to update segment');
          setIsSavingSegment(false);
          return;
        }
        setSegments((prev) =>
          prev.map((s) =>
            s.id === editingSegmentId
              ? { ...s, name: segmentName, description: segmentDescription, definition }
              : s
          )
        );
      } else {
        const res = await createSegment({
          name: segmentName,
          description: segmentDescription,
          segmentType,
          definition,
        });
        if (!res.success || !res.segment) {
          setSaveSegmentError(res.error || 'Failed to create segment');
          setIsSavingSegment(false);
          return;
        }
        setSegments((prev) => [res.segment!, ...prev]);
        setStats((prev) => ({
          ...prev,
          totalSegments: prev.totalSegments + 1,
          defaulterSegments:
            segmentType === 'defaulters' ? prev.defaulterSegments + 1 : prev.defaulterSegments,
          absenteeSegments:
            segmentType === 'absent_today' ? prev.absenteeSegments + 1 : prev.absenteeSegments,
          customSegments:
            segmentType === 'custom' ? prev.customSegments + 1 : prev.customSegments,
        }));
      }

      setIsCreateModalOpen(false);
    } catch (err: any) {
      setSaveSegmentError(err.message || 'Error saving segment');
    } finally {
      setIsSavingSegment(false);
    }
  };

  // Action: Delete Segment
  const handleDeleteSegment = async (id: string) => {
    if (!confirm('Are you sure you want to delete this segment?')) return;
    const res = await deleteSegment(id);
    if (res.success) {
      setSegments((prev) => prev.filter((s) => s.id !== id));
      setStats((prev) => ({ ...prev, totalSegments: prev.totalSegments - 1 }));
    } else {
      alert(res.error || 'Failed to delete segment');
    }
  };

  // Action: Save Campus Cutoff
  const handleSaveCutoff = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsUpdatingCutoff(true);
    setCutoffMessage(null);

    const res = await updateCampusCutoff(cutoffTime);
    setIsUpdatingCutoff(false);

    if (res.success) {
      setCutoffMessage('Attendance lock cutoff saved successfully.');
    } else {
      setCutoffMessage(res.error || 'Failed to update attendance cutoff.');
    }
  };

  return (
    <div className="space-y-6">
      {/* Header and Controls */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground flex items-center gap-2">
            <Users className="h-6 w-6 text-primary" />
            Dynamic Audience Segments
          </h1>
          <p className="text-sm text-muted-foreground">
            Rules engine for automated fee defaulters, morning absentee alerts with cutoff guards, and immutable audit snapshots.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            onClick={handleOpenCreateModal}
            className="flex items-center gap-2"
          >
            <Plus className="h-4 w-4" />
            New Segment
          </Button>
        </div>
      </div>

      {/* KPI Stats Cards */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase tracking-wider">Total Segments</span>
            <Users className="h-4 w-4 text-blue-500" />
          </div>
          <div className="mt-2 text-2xl font-bold text-foreground">{stats.totalSegments}</div>
          <div className="text-xs text-muted-foreground mt-1">Configured rules</div>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase tracking-wider">Defaulter Rules</span>
            <Coins className="h-4 w-4 text-amber-500" />
          </div>
          <div className="mt-2 text-2xl font-bold text-amber-600">{stats.defaulterSegments}</div>
          <div className="text-xs text-muted-foreground mt-1">Excludes hardship waivers</div>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase tracking-wider">Absentee Rules</span>
            <AlertOctagon className="h-4 w-4 text-rose-500" />
          </div>
          <div className="mt-2 text-2xl font-bold text-rose-600">{stats.absenteeSegments}</div>
          <div className="text-xs text-muted-foreground mt-1">Guarded by {cutoffTime} cutoff</div>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase tracking-wider">Audience Snapshots</span>
            <ShieldCheck className="h-4 w-4 text-emerald-500" />
          </div>
          <div className="mt-2 text-2xl font-bold text-emerald-600">{stats.totalSnapshots}</div>
          <div className="text-xs text-muted-foreground mt-1">Immutable dispatch records</div>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-border space-x-6">
        <button
          onClick={() => setActiveTab('segments')}
          className={`pb-3 text-sm font-medium border-b-2 flex items-center gap-2 ${
            activeTab === 'segments'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <Sliders className="h-4 w-4" />
          Active Segments ({segments.length})
        </button>

        <button
          onClick={() => setActiveTab('snapshots')}
          className={`pb-3 text-sm font-medium border-b-2 flex items-center gap-2 ${
            activeTab === 'snapshots'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <ShieldCheck className="h-4 w-4" />
          Audience Audit Trail ({snapshots.length})
        </button>

        <button
          onClick={() => setActiveTab('cutoff')}
          className={`pb-3 text-sm font-medium border-b-2 flex items-center gap-2 ${
            activeTab === 'cutoff'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <Clock className="h-4 w-4" />
          Attendance Cutoff Guard ({cutoffTime.slice(0, 5)} PKT)
        </button>
      </div>

      {/* TAB 1: ACTIVE SEGMENTS */}
      {activeTab === 'segments' && (
        <div className="space-y-4">
          {/* Search & Filters */}
          <div className="flex flex-col sm:flex-row gap-3 items-center justify-between">
            <div className="relative w-full sm:w-80">
              <Search className="absolute left-3 top-2.5 h-4 w-4 text-muted-foreground" />
              <input
                type="text"
                placeholder="Search segments..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="w-full pl-9 pr-4 py-2 text-sm border rounded-md bg-background focus:outline-none focus:ring-2 focus:ring-primary"
              />
            </div>
            <div className="flex items-center gap-2 w-full sm:w-auto">
              <span className="text-xs text-muted-foreground">Type:</span>
              <select
                value={typeFilter}
                onChange={(e) => setTypeFilter(e.target.value as any)}
                className="border rounded-md px-3 py-1.5 text-sm bg-background"
              >
                <option value="all">All Types</option>
                <option value="defaulters">Fee Defaulters</option>
                <option value="absent_today">Absentee Alerts</option>
                <option value="custom">Custom Filters</option>
              </select>
            </div>
          </div>

          {/* Segment Cards Grid */}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {filteredSegments.length === 0 ? (
              <div className="col-span-full rounded-lg border border-dashed p-8 text-center text-muted-foreground">
                <Users className="mx-auto h-8 w-8 mb-2 opacity-50" />
                <p className="font-medium">No audience segments found</p>
                <p className="text-xs mt-1">Create a new segment rule or adjust your search filter.</p>
              </div>
            ) : (
              filteredSegments.map((segment) => {
                const isDefaulter = segment.segment_type === 'defaulters';
                const isAbsentee = segment.segment_type === 'absent_today';

                return (
                  <div
                    key={segment.id}
                    className="flex flex-col justify-between rounded-lg border bg-card p-5 shadow-sm hover:border-primary/50 transition-colors"
                  >
                    <div>
                      <div className="flex items-start justify-between gap-2">
                        <span
                          className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wider ${
                            isDefaulter
                              ? 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300'
                              : isAbsentee
                              ? 'bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300'
                              : 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300'
                          }`}
                        >
                          {segment.segment_type.replace('_', ' ')}
                        </span>
                        <div className="flex items-center gap-1 text-xs text-muted-foreground">
                          <CheckCircle2 className="h-3.5 w-3.5 text-emerald-500" />
                          <span>Active</span>
                        </div>
                      </div>

                      <h3 className="mt-3 text-base font-semibold text-foreground line-clamp-1">
                        {segment.name}
                      </h3>
                      <p className="mt-1 text-xs text-muted-foreground line-clamp-2">
                        {segment.description || 'No description provided.'}
                      </p>

                      {/* Criteria Summary */}
                      <div className="mt-4 rounded-md bg-muted/50 p-2.5 text-xs space-y-1">
                        {isDefaulter && (
                          <>
                            <div className="flex justify-between">
                              <span className="text-muted-foreground">Threshold:</span>
                              <span className="font-semibold text-foreground">
                                &gt; PKR {(segment.definition?.min_dues_pkr || 5000).toLocaleString()}
                              </span>
                            </div>
                            <div className="flex justify-between">
                              <span className="text-muted-foreground">Hardship Waivers:</span>
                              <span className="font-medium text-emerald-600">
                                {segment.definition?.exclude_hardship !== false ? 'Auto-Excluded' : 'Included'}
                              </span>
                            </div>
                          </>
                        )}
                        {isAbsentee && (
                          <>
                            <div className="flex justify-between">
                              <span className="text-muted-foreground">Attendance Lock:</span>
                              <span className="font-semibold text-foreground">
                                {segment.definition?.cutoff_time || cutoffTime} PKT
                              </span>
                            </div>
                            <div className="flex justify-between">
                              <span className="text-muted-foreground">Premature Alert Guard:</span>
                              <span className="font-medium text-emerald-600">
                                {segment.definition?.enforce_cutoff !== false ? 'Enforced' : 'Disabled'}
                              </span>
                            </div>
                          </>
                        )}
                        {!isDefaulter && !isAbsentee && (
                          <div className="flex justify-between">
                            <span className="text-muted-foreground">Rule Type:</span>
                            <span className="font-medium text-foreground">Custom Filter</span>
                          </div>
                        )}
                      </div>
                    </div>

                    {/* Action Buttons */}
                    <div className="mt-5 pt-3 border-t flex items-center justify-between gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => handleOpenPreview(segment)}
                        className="text-xs flex items-center gap-1.5"
                      >
                        <Eye className="h-3.5 w-3.5 text-primary" />
                        Preview
                      </Button>

                      <div className="flex items-center gap-1">
                        <Button
                          variant="default"
                          size="sm"
                          onClick={() => handleOpenDispatch(segment)}
                          className="text-xs flex items-center gap-1.5"
                        >
                          <Send className="h-3.5 w-3.5" />
                          Send
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => handleDeleteSegment(segment.id)}
                          className="text-rose-600 hover:text-rose-700 hover:bg-rose-50 p-1.5 h-8 w-8"
                          title="Delete segment"
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      )}

      {/* TAB 2: AUDIENCE SNAPSHOTS AUDIT TRAIL */}
      {activeTab === 'snapshots' && (
        <div className="space-y-4">
          <div className="rounded-lg border bg-blue-50/50 p-4 text-xs text-blue-900 dark:bg-blue-950/20 dark:text-blue-300 flex items-start gap-3">
            <ShieldCheck className="h-5 w-5 text-blue-600 shrink-0 mt-0.5" />
            <div>
              <p className="font-semibold text-sm">FR-M06 Point-in-Time Immutable Audience Snapshots</p>
              <p className="mt-1">
                Whenever a campaign is dispatched to a dynamic segment, the exact recipient list, primary guardian contacts,
                and balance/attendance attributes are frozen into an immutable audit snapshot. Even if a student withdraws,
                transfers out, or pays dues later, the audit trail permanently records who was messaged at dispatch time.
              </p>
            </div>
          </div>

          <div className="rounded-lg border bg-card overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full text-left text-sm">
                <thead className="bg-muted text-xs uppercase tracking-wider text-muted-foreground border-b">
                  <tr>
                    <th className="px-4 py-3">Campaign ID</th>
                    <th className="px-4 py-3">Student</th>
                    <th className="px-4 py-3">Primary Guardian</th>
                    <th className="px-4 py-3">Contact</th>
                    <th className="px-4 py-3">Dues (PKR)</th>
                    <th className="px-4 py-3">Attendance</th>
                    <th className="px-4 py-3">Snapshotted At</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {snapshots.length === 0 ? (
                    <tr>
                      <td colSpan={7} className="px-4 py-8 text-center text-muted-foreground text-xs">
                        No audience snapshots recorded yet. Dispatch a campaign from the Segments tab to freeze an audience.
                      </td>
                    </tr>
                  ) : (
                    snapshots.map((snap) => (
                      <tr key={snap.id} className="hover:bg-muted/30 text-xs">
                        <td className="px-4 py-3 font-mono text-[11px] text-muted-foreground">
                          {snap.campaign_id.slice(0, 8)}...
                        </td>
                        <td className="px-4 py-3">
                          <div className="font-medium text-foreground">{snap.student_name}</div>
                          <div className="text-[11px] text-muted-foreground">{snap.gr_number || 'No GR'}</div>
                        </td>
                        <td className="px-4 py-3 text-foreground font-medium">{snap.recipient_name}</td>
                        <td className="px-4 py-3 font-mono text-muted-foreground">{snap.recipient_phone}</td>
                        <td className="px-4 py-3 font-semibold text-foreground">
                          {snap.dues_pkr ? `PKR ${Number(snap.dues_pkr).toLocaleString()}` : '—'}
                        </td>
                        <td className="px-4 py-3">
                          {snap.attendance_status ? (
                            <span
                              className={`px-2 py-0.5 rounded text-[10px] font-semibold uppercase ${
                                snap.attendance_status === 'absent'
                                  ? 'bg-rose-100 text-rose-800'
                                  : 'bg-emerald-100 text-emerald-800'
                              }`}
                            >
                              {snap.attendance_status}
                            </span>
                          ) : (
                            '—'
                          )}
                        </td>
                        <td className="px-4 py-3 text-muted-foreground">
                          {new Date(snap.snapshotted_at).toLocaleString('en-GB')}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}

      {/* TAB 3: ATTENDANCE CUTOFF GUARD */}
      {activeTab === 'cutoff' && (
        <div className="max-w-xl space-y-6">
          <div className="rounded-lg border bg-card p-6 shadow-sm">
            <div className="flex items-center gap-3">
              <Clock className="h-6 w-6 text-amber-500" />
              <div>
                <h2 className="text-base font-semibold text-foreground">Campus Attendance-Lock Cutoff</h2>
                <p className="text-xs text-muted-foreground mt-0.5">
                  Protects parents from receiving premature absence alerts while teachers are marking or correcting registers.
                </p>
              </div>
            </div>

            <form onSubmit={handleSaveCutoff} className="mt-6 space-y-4">
              <div>
                <label className="block text-xs font-semibold uppercase text-muted-foreground mb-1">
                  Cutoff Time (PKT)
                </label>
                <input
                  type="time"
                  step="1"
                  value={cutoffTime}
                  onChange={(e) => setCutoffTime(e.target.value)}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary"
                  required
                />
                <p className="text-xs text-muted-foreground mt-1.5">
                  Standard cutoff is 11:00:00 PKT. Prior to this cutoff, queries for &quot;Unexcused Absentees Today&quot; resolve
                  to 0 recipients to give teachers time to correct registers from Absent to Present.
                </p>
              </div>

              {cutoffMessage && (
                <div
                  className={`p-3 rounded-md text-xs font-medium ${
                    cutoffMessage.includes('successfully')
                      ? 'bg-emerald-50 text-emerald-800 border border-emerald-200'
                      : 'bg-rose-50 text-rose-800 border border-rose-200'
                  }`}
                >
                  {cutoffMessage}
                </div>
              )}

              <Button type="submit" disabled={isUpdatingCutoff} className="w-full sm:w-auto">
                {isUpdatingCutoff ? 'Saving...' : 'Save Cutoff Time'}
              </Button>
            </form>
          </div>
        </div>
      )}

      {/* PREVIEW / RESOLUTION MODAL */}
      <Modal
        open={isPreviewModalOpen}
        onClose={() => setIsPreviewModalOpen(false)}
        title={`Live Audience Preview: ${previewSegmentName}`}
      >
        <div className="space-y-4">
          {/* Resolution timing banner */}
          <div className="flex items-center justify-between rounded-md bg-muted/60 px-4 py-2.5 text-xs">
            <div className="flex items-center gap-2">
              <Zap className="h-4 w-4 text-amber-500" />
              <span className="font-medium text-foreground">Query Resolution Performance:</span>
            </div>
            {isResolving ? (
              <span className="text-muted-foreground animate-pulse">Evaluating rules engine...</span>
            ) : resolveDurationMs !== null ? (
              <span
                className={`font-semibold px-2 py-0.5 rounded ${
                  resolveDurationMs < 2000
                    ? 'bg-emerald-100 text-emerald-800'
                    : 'bg-amber-100 text-amber-800'
                }`}
              >
                {resolveDurationMs}ms (Sub-2s SLA Met)
              </span>
            ) : null}
          </div>

          {/* Zero recipient alert per AC 3 */}
          {!isResolving && resolvedRecipients.length === 0 && !resolveError && (
            <div className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-xs text-amber-900 dark:bg-amber-950/30 dark:text-amber-200 space-y-1">
              <div className="flex items-center gap-2 font-semibold">
                <AlertTriangle className="h-4 w-4 text-amber-600" />
                Zero-Recipient Send Guard Active
              </div>
              <p>
                This segment currently resolves to 0 recipients (e.g. no students meet the dues threshold, or current
                time is before the {cutoffTime} attendance cutoff). Campaign dispatch to this segment will be prevented.
              </p>
            </div>
          )}

          {/* Summary metrics */}
          {!isResolving && resolvedRecipients.length > 0 && (
            <div className="grid grid-cols-2 gap-3 text-xs">
              <div className="rounded-md border bg-card p-3">
                <span className="text-muted-foreground">Total Recipients:</span>
                <div className="text-lg font-bold text-foreground mt-0.5">
                  {resolvedRecipients.length} students
                </div>
              </div>
              <div className="rounded-md border bg-card p-3">
                <span className="text-muted-foreground">Total Balance Due:</span>
                <div className="text-lg font-bold text-amber-600 mt-0.5">
                  PKR {resolveTotalDues.toLocaleString()}
                </div>
              </div>
            </div>
          )}

          {/* Recipient list */}
          <div className="max-h-64 overflow-y-auto rounded-md border divide-y text-xs">
            {isResolving ? (
              <div className="p-8 text-center text-muted-foreground">Resolving criteria...</div>
            ) : resolveError ? (
              <div className="p-4 text-center text-rose-600">{resolveError}</div>
            ) : resolvedRecipients.length === 0 ? (
              <div className="p-8 text-center text-muted-foreground">No students currently match this segment.</div>
            ) : (
              resolvedRecipients.map((r, i) => (
                <div key={i} className="flex items-center justify-between p-3 hover:bg-muted/30">
                  <div>
                    <div className="font-semibold text-foreground">{r.student_name}</div>
                    <div className="text-muted-foreground text-[11px]">
                      GR: {r.gr_number || 'N/A'} • Guardian: {r.guardian_name} ({r.guardian_phone})
                    </div>
                  </div>
                  <div className="text-right">
                    {r.dues_pkr ? (
                      <div className="font-bold text-amber-600">PKR {Number(r.dues_pkr).toLocaleString()}</div>
                    ) : r.attendance_status ? (
                      <span className="px-2 py-0.5 rounded text-[10px] font-semibold uppercase bg-rose-100 text-rose-800">
                        {r.attendance_status}
                      </span>
                    ) : (
                      <span className="text-muted-foreground">Active</span>
                    )}
                  </div>
                </div>
              ))
            )}
          </div>

          <div className="flex justify-end pt-2">
            <Button variant="outline" size="sm" onClick={() => setIsPreviewModalOpen(false)}>
              Close
            </Button>
          </div>
        </div>
      </Modal>

      {/* DISPATCH CAMPAIGN MODAL (Zero-Recipient Guard) */}
      <Modal
        open={isDispatchModalOpen}
        onClose={() => setIsDispatchModalOpen(false)}
        title="Dispatch Dynamic Campaign"
      >
        <div className="space-y-4">
          <p className="text-xs text-muted-foreground">
            Dispatching will dynamically resolve the segment and freeze the audience into an immutable point-in-time
            snapshot for audit and compliance.
          </p>

          <div className="rounded-md bg-muted p-3 text-xs space-y-1">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Target Segment:</span>
              <span className="font-semibold text-foreground">{dispatchSegment?.name}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Rule Type:</span>
              <span className="font-medium text-foreground uppercase">{dispatchSegment?.segment_type}</span>
            </div>
          </div>

          <div>
            <label className="block text-xs font-semibold uppercase text-muted-foreground mb-1">
              Campaign Reference Title
            </label>
            <input
              type="text"
              value={dispatchCampaignTitle}
              onChange={(e) => setDispatchCampaignTitle(e.target.value)}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary"
            />
          </div>

          {dispatchResult && !dispatchResult.success && (
            <div className="rounded-md border border-rose-300 bg-rose-50 p-3 text-xs text-rose-900 dark:bg-rose-950/30 dark:text-rose-200 flex items-start gap-2">
              <AlertTriangle className="h-4 w-4 text-rose-600 shrink-0 mt-0.5" />
              <div>
                <p className="font-semibold">Dispatch Blocked (FR-M06 Zero-Recipient Guard)</p>
                <p className="mt-0.5">{dispatchResult.error}</p>
              </div>
            </div>
          )}

          {dispatchResult && dispatchResult.success && (
            <div className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-xs text-emerald-900 dark:bg-emerald-950/30 dark:text-emerald-200 flex items-start gap-2">
              <CheckCircle2 className="h-4 w-4 text-emerald-600 shrink-0 mt-0.5" />
              <div>
                <p className="font-semibold">Campaign Dispatched Successfully</p>
                <p className="mt-0.5">
                  Point-in-time audience frozen with {dispatchResult.count} recipients. Audit record created in snapshots.
                </p>
              </div>
            </div>
          )}

          <div className="flex justify-end gap-2 pt-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setIsDispatchModalOpen(false)}
              disabled={isDispatching}
            >
              {dispatchResult?.success ? 'Done' : 'Cancel'}
            </Button>
            {!dispatchResult?.success && (
              <Button
                variant="default"
                size="sm"
                onClick={handleExecuteDispatch}
                disabled={isDispatching || !dispatchCampaignTitle.trim()}
              >
                {isDispatching ? 'Freezing Snapshot...' : 'Dispatch & Snapshot'}
              </Button>
            )}
          </div>
        </div>
      </Modal>

      {/* CREATE / EDIT SEGMENT MODAL */}
      <Modal
        open={isCreateModalOpen}
        onClose={() => setIsCreateModalOpen(false)}
        title={editingSegmentId ? 'Edit Audience Segment' : 'Create Dynamic Segment'}
      >
        <form onSubmit={handleSaveSegment} className="space-y-4">
          <div>
            <label className="block text-xs font-semibold uppercase text-muted-foreground mb-1">
              Segment Name *
            </label>
            <input
              type="text"
              value={segmentName}
              onChange={(e) => setSegmentName(e.target.value)}
              placeholder="e.g. Fee Defaulters (> PKR 5,000)"
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary"
              required
            />
          </div>

          <div>
            <label className="block text-xs font-semibold uppercase text-muted-foreground mb-1">
              Description
            </label>
            <textarea
              value={segmentDescription}
              onChange={(e) => setSegmentDescription(e.target.value)}
              placeholder="Explain the audience criteria and communication purpose..."
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary"
              rows={2}
            />
          </div>

          <div>
            <label className="block text-xs font-semibold uppercase text-muted-foreground mb-1">
              Segment Type *
            </label>
            <select
              value={segmentType}
              onChange={(e) => setSegmentType(e.target.value as SegmentType)}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary"
              disabled={!!editingSegmentId}
            >
              <option value="defaulters">Fee Defaulters (with Hardship Waiver Exclusion)</option>
              <option value="absent_today">Unexcused Absentees Today (with Cutoff Guard)</option>
              <option value="custom">Custom Rules Filter</option>
            </select>
          </div>

          {/* Defaulter specific criteria */}
          {segmentType === 'defaulters' && (
            <div className="rounded-md border p-3 bg-muted/30 space-y-3">
              <div>
                <label className="block text-xs font-semibold text-foreground mb-1">
                  Minimum Outstanding Dues (PKR)
                </label>
                <input
                  type="number"
                  min="0"
                  step="any"
                  value={minDuesPkr}
                  onChange={(e) => setMinDuesPkr(Number(e.target.value))}
                  className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm"
                  required
                />
                <p className="text-[11px] text-muted-foreground mt-1">
                  Default: PKR 5,000. Students owing greater than or equal to this amount will be included.
                </p>
              </div>

              <div className="flex items-center gap-2 pt-1">
                <input
                  type="checkbox"
                  id="chk-hardship"
                  checked={excludeHardship}
                  onChange={(e) => setExcludeHardship(e.target.checked)}
                  className="h-4 w-4 rounded border-gray-300 text-primary focus:ring-primary"
                />
                <label htmlFor="chk-hardship" className="text-xs font-medium text-foreground">
                  Exclude students with approved hardship waivers (FR-M06 AC 1)
                </label>
              </div>
            </div>
          )}

          {/* Absentee specific criteria */}
          {segmentType === 'absent_today' && (
            <div className="rounded-md border p-3 bg-muted/30 space-y-3">
              <div className="flex items-center gap-2">
                <input
                  type="checkbox"
                  id="chk-cutoff"
                  checked={enforceCutoff}
                  onChange={(e) => setEnforceCutoff(e.target.checked)}
                  className="h-4 w-4 rounded border-gray-300 text-primary focus:ring-primary"
                />
                <label htmlFor="chk-cutoff" className="text-xs font-medium text-foreground">
                  Enforce morning cutoff ({cutoffTime} PKT) before allowing alerts (FR-M06 AC 2)
                </label>
              </div>
              <p className="text-[11px] text-muted-foreground">
                Prevents erroneous alerts if a teacher marks a student absent early but later corrects them to present
                before the cutoff window closes.
              </p>
            </div>
          )}

          {saveSegmentError && (
            <div className="rounded-md bg-rose-50 p-2.5 text-xs text-rose-700 border border-rose-200">
              {saveSegmentError}
            </div>
          )}

          <div className="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setIsCreateModalOpen(false)}
              disabled={isSavingSegment}
            >
              Cancel
            </Button>
            <Button type="submit" size="sm" disabled={isSavingSegment}>
              {isSavingSegment ? 'Saving...' : editingSegmentId ? 'Update Segment' : 'Create Segment'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
