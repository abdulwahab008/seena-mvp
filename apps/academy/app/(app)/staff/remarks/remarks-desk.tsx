'use client';

import React, { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import {
  submitRemarkAction,
  editRemarkAction,
  moderateRemarkAction,
  toggleCampusPolicyAction,
} from './actions';

interface Student {
  id: string;
  name_en: string;
  name_ur?: string;
  gr_number: string;
}

interface RemarkItem {
  id: string;
  student_id: string;
  student_name: string;
  student_gr: string;
  author_id: string;
  author_name: string;
  status: string;
  current_version_id?: string;
  created_at: string;
  versions: {
    id: string;
    version_number: number;
    body: string;
    language: string;
    status: string;
    rejection_reason?: string;
    created_at: string;
    moderated_at?: string;
  }[];
}

interface CampusPolicy {
  campus_id: string;
  campus_name: string;
  require_remark_approval: boolean;
}

interface RemarksDeskProps {
  students: Student[];
  remarks: RemarkItem[];
  pendingVersions: {
    version_id: string;
    remark_id: string;
    student_name: string;
    student_gr: string;
    author_name: string;
    version_number: number;
    body: string;
    language: string;
    created_at: string;
  }[];
  policies: CampusPolicy[];
  currentUserId: string;
  userRole: string;
}

export function RemarksDesk({
  students,
  remarks,
  pendingVersions,
  policies,
  currentUserId,
  userRole,
}: RemarksDeskProps) {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState<'queue' | 'my-remarks' | 'compose' | 'policy'>('queue');
  const [isPending, startTransition] = useTransition();

  // Composer state
  const [selectedStudent, setSelectedStudent] = useState<string>(students[0]?.id || '');
  const [composeBody, setComposeBody] = useState<string>('');
  const [composeLanguage, setComposeLanguage] = useState<'en' | 'ur'>('en');
  const [composeMessage, setComposeMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  // Edit remark state
  const [editingRemark, setEditingRemark] = useState<RemarkItem | null>(null);
  const [editBody, setEditBody] = useState<string>('');
  const [editLanguage, setEditLanguage] = useState<'en' | 'ur'>('en');

  // Rejection modal state
  const [rejectingVersionId, setRejectingVersionId] = useState<string | null>(null);
  const [rejectionReason, setRejectionReason] = useState<string>('');
  const [rejectError, setRejectError] = useState<string | null>(null);

  const canModerate = ['principal', 'vice_principal', 'super_admin', 'owner', 'admin'].includes(userRole);

  const handleComposeSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedStudent || !composeBody.trim()) return;

    startTransition(async () => {
      const res = await submitRemarkAction(selectedStudent, composeBody, composeLanguage);
      if (res.success) {
        setComposeMessage({ type: 'success', text: 'Remark submitted successfully!' });
        setComposeBody('');
        router.refresh();
        setActiveTab('my-remarks');
      } else {
        setComposeMessage({ type: 'error', text: res.error || 'Failed to submit remark.' });
      }
    });
  };

  const handleEditSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingRemark || !editBody.trim()) return;

    startTransition(async () => {
      const res = await editRemarkAction(editingRemark.id, editBody, editLanguage);
      if (res.success) {
        setEditingRemark(null);
        setEditBody('');
        router.refresh();
      } else {
        alert(res.error || 'Failed to save edit.');
      }
    });
  };

  const handleApprove = (versionId: string) => {
    startTransition(async () => {
      const res = await moderateRemarkAction(versionId, 'approved');
      if (res.success) {
        router.refresh();
      } else {
        alert(res.error || 'Approval failed.');
      }
    });
  };

  const handleRejectConfirm = () => {
    if (!rejectingVersionId) return;
    if (!rejectionReason.trim()) {
      setRejectError('Please specify a rejection reason.');
      return;
    }

    startTransition(async () => {
      const res = await moderateRemarkAction(rejectingVersionId, 'rejected', rejectionReason);
      if (res.success) {
        setRejectingVersionId(null);
        setRejectionReason('');
        setRejectError(null);
        router.refresh();
      } else {
        setRejectError(res.error || 'Rejection failed.');
      }
    });
  };

  const handleTogglePolicy = (campusId: string, currentVal: boolean) => {
    startTransition(async () => {
      await toggleCampusPolicyAction(campusId, !currentVal);
      router.refresh();
    });
  };

  return (
    <div className="space-y-6">
      {/* Tab Navigation */}
      <div className="border-b border-border flex flex-wrap gap-2 text-sm font-medium">
        {canModerate && (
          <button
            onClick={() => setActiveTab('queue')}
            className={`pb-3 px-3 border-b-2 transition-colors flex items-center gap-2 ${
              activeTab === 'queue'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            <span>Moderation Queue</span>
            {pendingVersions.length > 0 && (
              <span className="bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-200 text-xs px-2 py-0.5 rounded-full font-semibold">
                {pendingVersions.length}
              </span>
            )}
          </button>
        )}

        <button
          onClick={() => setActiveTab('my-remarks')}
          className={`pb-3 px-3 border-b-2 transition-colors ${
            activeTab === 'my-remarks'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          All Remarks & History
        </button>

        <button
          onClick={() => setActiveTab('compose')}
          className={`pb-3 px-3 border-b-2 transition-colors ${
            activeTab === 'compose'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          + Compose Remark
        </button>

        {canModerate && (
          <button
            onClick={() => setActiveTab('policy')}
            className={`pb-3 px-3 border-b-2 transition-colors ${
              activeTab === 'policy'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Approval Policies
          </button>
        )}
      </div>

      {/* ── TAB 1: MODERATION QUEUE (AC 1, AC 3) ── */}
      {activeTab === 'queue' && canModerate && (
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <h3 className="text-base font-semibold">Pending Approval Queue</h3>
            <p className="text-xs text-muted-foreground">
              Review and approve teacher remarks before they become visible to guardians.
            </p>
          </div>

          {pendingVersions.length === 0 ? (
            <div className="p-8 text-center rounded-lg border bg-card text-muted-foreground">
              <p className="text-sm">No pending remarks awaiting moderation.</p>
            </div>
          ) : (
            <div className="grid gap-4">
              {pendingVersions.map((item) => {
                const isUrdu = item.language === 'ur';
                return (
                  <div
                    key={item.version_id}
                    className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm space-y-3"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2 border-b pb-2">
                      <div className="flex items-center gap-2">
                        <span className="font-semibold text-sm">{item.student_name}</span>
                        <span className="text-xs px-2 py-0.5 rounded bg-muted text-muted-foreground">
                          GR: {item.student_gr}
                        </span>
                        <span className="text-xs text-muted-foreground">
                          By: {item.author_name}
                        </span>
                        <span className="text-xs text-muted-foreground font-mono">
                          v{item.version_number}
                        </span>
                      </div>

                      <span
                        className={`text-xs px-2 py-0.5 rounded font-medium ${
                          isUrdu ? 'bg-amber-100 text-amber-900' : 'bg-blue-100 text-blue-900'
                        }`}
                      >
                        {isUrdu ? 'Urdu / اردو' : 'English'}
                      </span>
                    </div>

                    {/* Content */}
                    <div
                      dir={isUrdu ? 'rtl' : 'ltr'}
                      className={`text-sm leading-relaxed p-3 rounded bg-muted/40 ${
                        isUrdu ? 'text-right font-serif text-base' : 'text-left'
                      }`}
                    >
                      {item.body}
                    </div>

                    {/* Action buttons */}
                    <div className="flex items-center justify-end gap-2 pt-1">
                      <button
                        onClick={() => {
                          setRejectingVersionId(item.version_id);
                          setRejectionReason('');
                          setRejectError(null);
                        }}
                        disabled={isPending}
                        className="px-3 py-1.5 text-xs font-medium rounded border border-red-300 text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400 dark:hover:bg-red-950/40"
                      >
                        Reject...
                      </button>
                      <button
                        onClick={() => handleApprove(item.version_id)}
                        disabled={isPending}
                        className="px-3 py-1.5 text-xs font-medium rounded bg-emerald-600 text-white hover:bg-emerald-700 dark:bg-emerald-500"
                      >
                        Approve for Guardians
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* ── TAB 2: ALL REMARKS & HISTORY (AC 2, AC 3) ── */}
      {activeTab === 'my-remarks' && (
        <div className="space-y-4">
          <h3 className="text-base font-semibold">Teacher Remarks Directory</h3>
          {remarks.length === 0 ? (
            <div className="p-8 text-center rounded-lg border bg-card text-muted-foreground">
              <p className="text-sm">No remarks found. Author a remark using the Compose tab.</p>
            </div>
          ) : (
            <div className="grid gap-4">
              {remarks.map((r) => {
                const latestVersion = r.versions[r.versions.length - 1];
                const isUrdu = latestVersion?.language === 'ur';

                return (
                  <div
                    key={r.id}
                    className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm space-y-3"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2 border-b pb-2">
                      <div className="flex items-center gap-2">
                        <span className="font-semibold text-sm">{r.student_name}</span>
                        <span className="text-xs px-2 py-0.5 rounded bg-muted text-muted-foreground">
                          GR: {r.student_gr}
                        </span>
                        <span className="text-xs text-muted-foreground">Author: {r.author_name}</span>
                      </div>

                      <div className="flex items-center gap-2">
                        <span
                          className={`text-xs px-2 py-0.5 rounded font-semibold capitalize ${
                            r.status === 'approved'
                              ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300'
                              : r.status === 'rejected'
                              ? 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300'
                              : 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300'
                          }`}
                        >
                          {r.status}
                        </span>
                        <button
                          onClick={() => {
                            setEditingRemark(r);
                            setEditBody(latestVersion?.body || '');
                            setEditLanguage((latestVersion?.language as any) || 'en');
                          }}
                          className="px-2.5 py-1 text-xs rounded border hover:bg-muted"
                        >
                          Edit / New Version
                        </button>
                      </div>
                    </div>

                    {/* Latest version display */}
                    <div
                      dir={isUrdu ? 'rtl' : 'ltr'}
                      className={`text-sm leading-relaxed p-3 rounded bg-muted/20 ${
                        isUrdu ? 'text-right font-serif text-base' : 'text-left'
                      }`}
                    >
                      {latestVersion?.body}
                    </div>

                    {/* Rejection notice if latest version was rejected (AC 3) */}
                    {latestVersion?.status === 'rejected' && latestVersion?.rejection_reason && (
                      <div className="p-3 rounded bg-red-50 dark:bg-red-950/40 border border-red-200 dark:border-red-900 text-xs text-red-800 dark:text-red-300">
                        <span className="font-bold">Principal Feedback / Rejection Reason: </span>
                        {latestVersion.rejection_reason}
                      </div>
                    )}

                    {/* Version History Accordion */}
                    {r.versions.length > 1 && (
                      <div className="pt-2 border-t text-xs text-muted-foreground space-y-1.5">
                        <span className="font-semibold text-foreground">Version History:</span>
                        {r.versions.map((v) => (
                          <div
                            key={v.id}
                            className="flex items-center justify-between p-1.5 rounded bg-muted/30"
                          >
                            <span>
                              v{v.version_number} ({v.language.toUpperCase()}):{' '}
                              <span className="truncate inline-block max-w-[240px] sm:max-w-md align-bottom">
                                {v.body}
                              </span>
                            </span>
                            <span className="capitalize font-mono font-medium">{v.status}</span>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* ── TAB 3: COMPOSE REMARK ── */}
      {activeTab === 'compose' && (
        <div className="max-w-xl mx-auto rounded-lg border bg-card p-6 shadow-sm space-y-4">
          <h3 className="text-base font-semibold">Author Remark for Guardian</h3>

          {composeMessage && (
            <div
              className={`p-3 rounded text-sm ${
                composeMessage.type === 'success'
                  ? 'bg-emerald-50 text-emerald-800 border border-emerald-200'
                  : 'bg-red-50 text-red-800 border border-red-200'
              }`}
            >
              {composeMessage.text}
            </div>
          )}

          <form onSubmit={handleComposeSubmit} className="space-y-4">
            <div>
              <label className="block text-xs font-semibold text-muted-foreground mb-1">
                Target Student
              </label>
              <select
                value={selectedStudent}
                onChange={(e) => setSelectedStudent(e.target.value)}
                className="w-full rounded border px-3 py-2 text-sm bg-background"
                required
              >
                {students.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name_en} (GR: {s.gr_number})
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-xs font-semibold text-muted-foreground mb-1">
                Language
              </label>
              <div className="flex gap-4 text-sm">
                <label className="flex items-center gap-1.5 cursor-pointer">
                  <input
                    type="radio"
                    name="composeLang"
                    value="en"
                    checked={composeLanguage === 'en'}
                    onChange={() => setComposeLanguage('en')}
                  />
                  <span>English</span>
                </label>
                <label className="flex items-center gap-1.5 cursor-pointer">
                  <input
                    type="radio"
                    name="composeLang"
                    value="ur"
                    checked={composeLanguage === 'ur'}
                    onChange={() => setComposeLanguage('ur')}
                  />
                  <span>اردو (Urdu)</span>
                </label>
              </div>
            </div>

            <div>
              <label className="block text-xs font-semibold text-muted-foreground mb-1">
                Remark Text
              </label>
              <textarea
                value={composeBody}
                onChange={(e) => setComposeBody(e.target.value)}
                dir={composeLanguage === 'ur' ? 'rtl' : 'ltr'}
                rows={4}
                placeholder={
                  composeLanguage === 'ur'
                    ? 'یہاں طالب علم کے بارے میں رائے درج کریں...'
                    : 'Enter observation, feedback, or commendation...'
                }
                className={`w-full rounded border p-3 text-sm bg-background ${
                  composeLanguage === 'ur' ? 'text-right font-serif text-base' : 'text-left'
                }`}
                required
              />
            </div>

            <p className="text-xs text-muted-foreground">
              Remarks require Principal approval when campus policy is active. Once approved, notes are
              permanently versioned and visible in the Parent Portal.
            </p>

            <button
              type="submit"
              disabled={isPending || !composeBody.trim()}
              className="w-full py-2 px-4 rounded bg-primary text-primary-foreground font-medium text-sm hover:opacity-90 disabled:opacity-50"
            >
              {isPending ? 'Submitting...' : 'Submit for Moderation'}
            </button>
          </form>
        </div>
      )}

      {/* ── TAB 4: CAMPUS POLICY SETTINGS (AC 1) ── */}
      {activeTab === 'policy' && canModerate && (
        <div className="space-y-4 max-w-xl">
          <h3 className="text-base font-semibold">Campus Portal Remark Policies</h3>
          <p className="text-xs text-muted-foreground">
            Configure whether teacher remarks must pass Principal moderation before guardian dispatch.
          </p>

          <div className="grid gap-3">
            {policies.map((pol) => (
              <div
                key={pol.campus_id}
                className="p-4 rounded-lg border bg-card flex items-center justify-between gap-4"
              >
                <div>
                  <h4 className="font-semibold text-sm">{pol.campus_name}</h4>
                  <p className="text-xs text-muted-foreground">
                    Status:{' '}
                    {pol.require_remark_approval ? (
                      <span className="text-emerald-600 font-medium">Principal Moderation Required</span>
                    ) : (
                      <span className="text-amber-600 font-medium">Auto-approved (Direct Publish)</span>
                    )}
                  </p>
                </div>

                <button
                  onClick={() => handleTogglePolicy(pol.campus_id, pol.require_remark_approval)}
                  disabled={isPending}
                  className={`px-3 py-1.5 rounded text-xs font-semibold ${
                    pol.require_remark_approval
                      ? 'bg-amber-100 text-amber-900 hover:bg-amber-200'
                      : 'bg-emerald-100 text-emerald-900 hover:bg-emerald-200'
                  }`}
                >
                  {pol.require_remark_approval ? 'Disable Approval' : 'Enable Approval'}
                </button>
              </div>
            ))}
          </div>

          <div className="p-4 rounded bg-muted/40 border text-xs text-muted-foreground space-y-1">
            <span className="font-semibold text-foreground">Compliance Notice:</span>
            <p>
              A written negative remark about a minor, delivered to a guardian and screenshot-shareable,
              is defamation and PECA-2016 exposure for the school. Keeping approval enabled protects teachers
              and the institution.
            </p>
          </div>
        </div>
      )}

      {/* ── REJECTION REASON MODAL (AC 3) ── */}
      {rejectingVersionId && (
        <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
          <div className="bg-card border rounded-lg max-w-md w-full p-5 space-y-4 shadow-lg">
            <h4 className="font-semibold text-base text-foreground">Reject Remark</h4>
            <p className="text-xs text-muted-foreground">
              Provide feedback for the class teacher explaining why this remark cannot be published.
              The guardian will never see the remark or this reason.
            </p>

            {rejectError && (
              <div className="p-2 rounded bg-red-50 text-red-800 border border-red-200 text-xs">
                {rejectError}
              </div>
            )}

            <textarea
              value={rejectionReason}
              onChange={(e) => setRejectionReason(e.target.value)}
              placeholder="e.g. Please specify the project name, or maintain positive developmental tone..."
              className="w-full border rounded p-2.5 text-sm bg-background"
              rows={3}
              required
            />

            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setRejectingVersionId(null)}
                className="px-3 py-1.5 rounded border text-xs text-muted-foreground hover:bg-muted"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleRejectConfirm}
                disabled={isPending || !rejectionReason.trim()}
                className="px-3 py-1.5 rounded bg-red-600 text-white text-xs font-semibold hover:bg-red-700"
              >
                {isPending ? 'Rejecting...' : 'Confirm Rejection'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── EDIT REMARK MODAL (AC 2) ── */}
      {editingRemark && (
        <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
          <div className="bg-card border rounded-lg max-w-md w-full p-5 space-y-4 shadow-lg">
            <h4 className="font-semibold text-base text-foreground">Edit Remark (Create New Version)</h4>
            <p className="text-xs text-muted-foreground">
              Editing an approved remark creates a new version with status &apos;pending&apos;. The previously
              approved version remains visible to guardians until this revision is approved.
            </p>

            <form onSubmit={handleEditSubmit} className="space-y-3">
              <div className="flex gap-4 text-xs">
                <label className="flex items-center gap-1 cursor-pointer">
                  <input
                    type="radio"
                    name="editLang"
                    value="en"
                    checked={editLanguage === 'en'}
                    onChange={() => setEditLanguage('en')}
                  />
                  <span>English</span>
                </label>
                <label className="flex items-center gap-1 cursor-pointer">
                  <input
                    type="radio"
                    name="editLang"
                    value="ur"
                    checked={editLanguage === 'ur'}
                    onChange={() => setEditLanguage('ur')}
                  />
                  <span>اردو (Urdu)</span>
                </label>
              </div>

              <textarea
                value={editBody}
                onChange={(e) => setEditBody(e.target.value)}
                dir={editLanguage === 'ur' ? 'rtl' : 'ltr'}
                className={`w-full border rounded p-2.5 text-sm bg-background ${
                  editLanguage === 'ur' ? 'text-right font-serif text-base' : 'text-left'
                }`}
                rows={4}
                required
              />

              <div className="flex justify-end gap-2 pt-2">
                <button
                  type="button"
                  onClick={() => setEditingRemark(null)}
                  className="px-3 py-1.5 rounded border text-xs text-muted-foreground hover:bg-muted"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isPending || !editBody.trim()}
                  className="px-3 py-1.5 rounded bg-primary text-primary-foreground text-xs font-semibold hover:opacity-90"
                >
                  {isPending ? 'Submitting...' : 'Save as New Version'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
