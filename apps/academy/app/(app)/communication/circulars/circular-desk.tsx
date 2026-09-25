'use client';

import React, { useState } from 'react';
import {
  createCircularAction,
  publishCircularAction,
  unpublishCircularAction,
  CircularAttachmentInput,
} from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

interface MessageSegment {
  id: string;
  name: string;
  segment_type: string;
}

interface CircularItem {
  id: string;
  title: string;
  body_en: string | null;
  body_ur: string | null;
  publish_at: string;
  expires_at: string | null;
  status: 'draft' | 'published' | 'unpublished' | 'archived';
  created_at: string;
  circular_attachment: {
    id: string;
    file_name: string;
    mime_type: string;
    size_bytes: number;
    storage_path: string;
  }[];
  circular_audience: {
    id: string;
    segment_id: string;
    message_segment: {
      id: string;
      name: string;
      segment_type: string;
    };
  }[];
}

interface CircularDeskProps {
  circulars: CircularItem[];
  segments: MessageSegment[];
  campuses: { id: string; name: string }[];
}

const MAX_ATTACHMENT_SIZE_BYTES = 10 * 1024 * 1024; // 10MB
const MAX_ATTACHMENTS = 5;

export function CircularDesk({ circulars, segments, campuses }: CircularDeskProps) {
  const [filterStatus, setFilterStatus] = useState<string>('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [isComposeOpen, setIsComposeOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  // Form State
  const [title, setTitle] = useState('');
  const [bodyEn, setBodyEn] = useState('');
  const [bodyUr, setBodyUr] = useState('');
  const [campusId, setCampusId] = useState('');
  const [publishAtOption, setPublishAtOption] = useState<'now' | 'schedule'>('now');
  const [scheduleDateTime, setScheduleDateTime] = useState('');
  const [expiresDateTime, setExpiresDateTime] = useState('');
  const [selectedSegmentIds, setSelectedSegmentIds] = useState<string[]>([]);
  const [attachments, setAttachments] = useState<CircularAttachmentInput[]>([]);
  const [attachmentError, setAttachmentError] = useState<string | null>(null);

  const filteredCirculars = circulars.filter((c) => {
    const matchesStatus = filterStatus === 'all' || c.status === filterStatus;
    const matchesSearch =
      searchQuery === '' ||
      c.title.toLowerCase().includes(searchQuery.toLowerCase()) ||
      (c.body_en && c.body_en.toLowerCase().includes(searchQuery.toLowerCase()));
    return matchesStatus && matchesSearch;
  });

  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    setAttachmentError(null);
    const files = e.target.files;
    if (!files || files.length === 0) return;

    if (attachments.length + files.length > MAX_ATTACHMENTS) {
      setAttachmentError(`Maximum ${MAX_ATTACHMENTS} attachments allowed per circular.`);
      return;
    }

    const newAttachments: CircularAttachmentInput[] = [];

    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      if (!file) continue;

      // AC 1: Validate file size (<= 10MB)
      if (file.size > MAX_ATTACHMENT_SIZE_BYTES) {
        setAttachmentError(
          `Attachment "${file.name}" (${(file.size / 1024 / 1024).toFixed(2)} MB) exceeds the 10 MB maximum limit.`
        );
        return;
      }

      newAttachments.push({
        file_name: file.name,
        mime_type: file.type || 'application/octet-stream',
        size_bytes: file.size,
        storage_path: `circulars/${Date.now()}_${file.name}`,
      });
    }

    setAttachments([...attachments, ...newAttachments]);
  };

  const removeAttachment = (index: number) => {
    setAttachments(attachments.filter((_, idx) => idx !== index));
  };

  const handleSaveCircular = async (status: 'draft' | 'published') => {
    setErrorMessage(null);
    setSuccessMessage(null);
    setAttachmentError(null);

    if (!title.trim()) {
      setErrorMessage('Please enter a circular title.');
      return;
    }

    if (!bodyEn.trim() && !bodyUr.trim()) {
      setErrorMessage('Please enter circular body content in English or Urdu.');
      return;
    }

    let publishAt = new Date().toISOString();
    if (publishAtOption === 'schedule') {
      if (!scheduleDateTime) {
        setErrorMessage('Please select a scheduled publish date and time.');
        return;
      }
      publishAt = new Date(scheduleDateTime).toISOString();
    }

    let expiresAt: string | undefined = undefined;
    if (expiresDateTime) {
      expiresAt = new Date(expiresDateTime).toISOString();
    }

    setIsSubmitting(true);
    try {
      const res = await createCircularAction({
        title,
        body_en: bodyEn,
        body_ur: bodyUr,
        campus_id: campusId || undefined,
        publish_at: publishAt,
        expires_at: expiresAt,
        status,
        segment_ids: selectedSegmentIds,
        attachments,
      });

      if (!res.success) {
        setErrorMessage(res.error || 'Failed to save circular.');
      } else {
        setSuccessMessage(`Circular "${title}" successfully ${status === 'published' ? 'published' : 'saved as draft'}.`);
        setIsComposeOpen(false);
        // Reset form
        setTitle('');
        setBodyEn('');
        setBodyUr('');
        setCampusId('');
        setSelectedSegmentIds([]);
        setAttachments([]);
      }
    } catch (err: any) {
      setErrorMessage(err.message || 'An unexpected error occurred.');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleTogglePublish = async (circular: CircularItem) => {
    if (circular.status === 'published') {
      const res = await unpublishCircularAction(circular.id);
      if (!res.success) {
        alert(res.error);
      }
    } else {
      const res = await publishCircularAction(circular.id);
      if (!res.success) {
        alert(res.error);
      }
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 border-b pb-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">Circular Publishing Desk</h1>
          <p className="text-sm text-muted-foreground">
            Publish school circulars with bilingual text (English & Urdu), target specific segments, and attach up to 5 files (max 10MB each).
          </p>
        </div>
        <Button
          id="compose-circular-btn"
          onClick={() => setIsComposeOpen(true)}
          className="bg-primary text-primary-foreground hover:bg-primary/90"
        >
          Compose Circular
        </Button>
      </div>

      {successMessage && (
        <div className="p-4 rounded-md bg-green-500/10 border border-green-500/20 text-green-700 dark:text-green-300 text-sm">
          {successMessage}
        </div>
      )}

      {/* Filter & Search Bar */}
      <div className="flex flex-col sm:flex-row gap-4 items-center justify-between">
        <div className="flex gap-2 items-center">
          <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Status:</span>
          {['all', 'published', 'draft', 'unpublished', 'archived'].map((status) => (
            <button
              key={status}
              onClick={() => setFilterStatus(status)}
              className={`px-3 py-1 text-xs font-medium rounded-full capitalize transition-colors ${
                filterStatus === status
                  ? 'bg-primary text-primary-foreground'
                  : 'bg-muted text-muted-foreground hover:bg-muted/80'
              }`}
            >
              {status}
            </button>
          ))}
        </div>
        <div className="w-full sm:w-64">
          <Input
            placeholder="Search circulars..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="text-sm"
          />
        </div>
      </div>

      {/* Circulars List */}
      <div className="rounded-lg border bg-card text-card-foreground shadow-sm overflow-hidden">
        <table className="w-full text-sm text-left">
          <thead className="bg-muted/50 text-muted-foreground font-medium border-b text-xs uppercase tracking-wider">
            <tr>
              <th className="px-4 py-3">Title & Preview</th>
              <th className="px-4 py-3">Target Audience</th>
              <th className="px-4 py-3">Publish Date</th>
              <th className="px-4 py-3">Attachments</th>
              <th className="px-4 py-3">Status</th>
              <th className="px-4 py-3 text-right">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {filteredCirculars.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                  No circulars found matching the filter criteria.
                </td>
              </tr>
            ) : (
              filteredCirculars.map((circ) => {
                const isFuture = new Date(circ.publish_at) > new Date();
                return (
                  <tr key={circ.id} className="hover:bg-muted/30 transition-colors">
                    <td className="px-4 py-3 max-w-xs">
                      <div className="font-semibold text-foreground truncate">{circ.title}</div>
                      {circ.body_en && (
                        <div className="text-xs text-muted-foreground line-clamp-1">{circ.body_en}</div>
                      )}
                      {circ.body_ur && (
                        <div className="text-xs text-muted-foreground line-clamp-1 font-arabic" dir="rtl">
                          {circ.body_ur}
                        </div>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      {circ.circular_audience.length === 0 ? (
                        <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300">
                          All Campus Students
                        </span>
                      ) : (
                        <div className="flex flex-wrap gap-1">
                          {circ.circular_audience.map((aud) => (
                            <span
                              key={aud.id}
                              className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-purple-100 dark:bg-purple-900/30 text-purple-800 dark:text-purple-300"
                            >
                              {aud.message_segment?.name || 'Segment'}
                            </span>
                          ))}
                        </div>
                      )}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <div>{new Date(circ.publish_at).toLocaleDateString()}</div>
                      <div className="text-xs text-muted-foreground">
                        {new Date(circ.publish_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                        {isFuture && <span className="ml-1 text-amber-600 font-semibold">(Scheduled)</span>}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      {circ.circular_attachment.length > 0 ? (
                        <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-secondary text-secondary-foreground">
                          📎 {circ.circular_attachment.length} files
                        </span>
                      ) : (
                        <span className="text-xs text-muted-foreground">None</span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-semibold uppercase tracking-wider ${
                          circ.status === 'published'
                            ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300'
                            : circ.status === 'draft'
                            ? 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300'
                            : circ.status === 'unpublished'
                            ? 'bg-orange-100 text-orange-800 dark:bg-orange-900/30 dark:text-orange-300'
                            : 'bg-muted text-muted-foreground'
                        }`}
                      >
                        {circ.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      {circ.status === 'published' ? (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleTogglePublish(circ)}
                          className="text-xs text-orange-600 hover:text-orange-700"
                        >
                          Unpublish
                        </Button>
                      ) : (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleTogglePublish(circ)}
                          className="text-xs text-green-600 hover:text-green-700"
                        >
                          Publish Now
                        </Button>
                      )}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* Compose Circular Modal */}
      {isComposeOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="relative w-full max-w-2xl max-h-[90vh] overflow-y-auto rounded-lg bg-card p-6 shadow-xl border">
            <h2 className="text-xl font-bold text-foreground mb-4">Compose New Circular</h2>

            {errorMessage && (
              <div className="p-3 mb-4 rounded bg-destructive/10 border border-destructive/20 text-destructive text-sm">
                {errorMessage}
              </div>
            )}

            <div className="space-y-4">
              <div>
                <Label htmlFor="circular-title">Title *</Label>
                <Input
                  id="circular-title"
                  placeholder="e.g. Science Fair 2026 Guidelines"
                  value={title}
                  onChange={(e) => setTitle(e.target.value)}
                  className="mt-1"
                />
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <Label htmlFor="circular-campus">Campus (Optional)</Label>
                  <select
                    id="circular-campus"
                    value={campusId}
                    onChange={(e) => setCampusId(e.target.value)}
                    className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
                  >
                    <option value="">All Campuses (Tenant-wide)</option>
                    {campuses.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.name}
                      </option>
                    ))}
                  </select>
                </div>

                <div>
                  <Label htmlFor="circular-segments">Target Audience Segments</Label>
                  <select
                    id="circular-segments"
                    multiple
                    value={selectedSegmentIds}
                    onChange={(e) => {
                      const options = Array.from(e.target.selectedOptions, (option) => option.value);
                      setSelectedSegmentIds(options);
                    }}
                    className="w-full mt-1 rounded-md border border-input bg-background px-3 py-1.5 text-sm h-24"
                  >
                    {segments.map((seg) => (
                      <option key={seg.id} value={seg.id}>
                        {seg.name} ({seg.segment_type})
                      </option>
                    ))}
                  </select>
                  <span className="text-xs text-muted-foreground">Hold Ctrl/Cmd to select multiple segments.</span>
                </div>
              </div>

              <div>
                <Label htmlFor="body-en">English Body Content</Label>
                <textarea
                  id="body-en"
                  rows={3}
                  placeholder="Dear Parents, please be informed that..."
                  value={bodyEn}
                  onChange={(e) => setBodyEn(e.target.value)}
                  className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
                />
              </div>

              <div>
                <Label htmlFor="body-ur">Urdu Body Content (اردو مواد)</Label>
                <textarea
                  id="body-ur"
                  rows={3}
                  dir="rtl"
                  placeholder="محترم والدین، مطلع کیا جاتا ہے کہ..."
                  value={bodyUr}
                  onChange={(e) => setBodyUr(e.target.value)}
                  className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm font-arabic"
                />
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <Label>Publish Schedule</Label>
                  <div className="mt-1 flex gap-4">
                    <label className="flex items-center gap-1.5 text-sm">
                      <input
                        type="radio"
                        name="publishOption"
                        checked={publishAtOption === 'now'}
                        onChange={() => setPublishAtOption('now')}
                      />
                      Immediately
                    </label>
                    <label className="flex items-center gap-1.5 text-sm">
                      <input
                        type="radio"
                        name="publishOption"
                        checked={publishAtOption === 'schedule'}
                        onChange={() => setPublishAtOption('schedule')}
                      />
                      Schedule for Future
                    </label>
                  </div>
                  {publishAtOption === 'schedule' && (
                    <Input
                      type="datetime-local"
                      value={scheduleDateTime}
                      onChange={(e) => setScheduleDateTime(e.target.value)}
                      className="mt-2 text-sm"
                    />
                  )}
                </div>

                <div>
                  <Label htmlFor="expires-at">Expiry Date & Time (Optional)</Label>
                  <Input
                    id="expires-at"
                    type="datetime-local"
                    value={expiresDateTime}
                    onChange={(e) => setExpiresDateTime(e.target.value)}
                    className="mt-1 text-sm"
                  />
                </div>
              </div>

              {/* Attachments Section */}
              <div className="border-t pt-4">
                <Label>Attachments (Max 5 files, 10MB per file)</Label>
                <Input
                  id="circular-attachment-input"
                  type="file"
                  multiple
                  onChange={handleFileUpload}
                  disabled={attachments.length >= MAX_ATTACHMENTS}
                  className="mt-1 text-sm"
                />

                {attachmentError && (
                  <p id="attachment-size-error" className="mt-1 text-xs text-destructive font-medium">
                    {attachmentError}
                  </p>
                )}

                {attachments.length > 0 && (
                  <div className="mt-3 space-y-1.5">
                    {attachments.map((att, idx) => (
                      <div
                        key={idx}
                        className="flex items-center justify-between p-2 rounded bg-muted/40 border text-xs"
                      >
                        <span className="font-medium truncate max-w-md">
                          📎 {att.file_name} ({(att.size_bytes / 1024 / 1024).toFixed(2)} MB)
                        </span>
                        <button
                          type="button"
                          onClick={() => removeAttachment(idx)}
                          className="text-destructive hover:underline text-xs"
                        >
                          Remove
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>

            <div className="mt-6 flex justify-end gap-3 border-t pt-4">
              <Button
                variant="outline"
                onClick={() => setIsComposeOpen(false)}
                disabled={isSubmitting}
              >
                Cancel
              </Button>
              <Button
                variant="secondary"
                onClick={() => handleSaveCircular('draft')}
                disabled={isSubmitting}
              >
                Save Draft
              </Button>
              <Button
                id="submit-circular-btn"
                onClick={() => handleSaveCircular('published')}
                disabled={isSubmitting}
              >
                {isSubmitting ? 'Saving...' : 'Publish Circular'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
