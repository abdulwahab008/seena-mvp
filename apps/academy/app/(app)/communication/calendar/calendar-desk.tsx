'use client';

import React, { useState } from 'react';
import {
  createCampusEventAction,
  createCampusEventOverrideAction,
  generateGuardianIcsTokenAction,
  revokeGuardianIcsTokenAction,
  recomputeRetroactiveHolidayAction,
  CampusEventInput,
  CampusEventOverrideInput,
} from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

interface CampusItem {
  id: string;
  name: string;
  code: string;
}

interface EffectiveEventItem {
  event_id: string;
  campus_id: string;
  title: string;
  description: string | null;
  event_type: 'holiday' | 'exam' | 'ptm' | 'sports' | 'cultural' | 'academic' | 'other';
  starts_at: string;
  ends_at: string;
  is_all_day: boolean;
  hijri_label: string | null;
  is_cancelled: boolean;
  is_override: boolean;
  override_id: string | null;
}

interface CalendarDeskProps {
  events: EffectiveEventItem[];
  campuses: CampusItem[];
}

export function CalendarDesk({ events, campuses }: CalendarDeskProps) {
  const [filterCampus, setFilterCampus] = useState<string>('all');
  const [filterType, setFilterType] = useState<string>('all');
  const [searchQuery, setSearchQuery] = useState('');

  // Modals state
  const [isNewEventOpen, setIsNewEventOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  // New Event Form
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [eventType, setEventType] = useState<'holiday' | 'exam' | 'ptm' | 'sports' | 'cultural' | 'academic' | 'other'>('holiday');
  const [campusId, setCampusId] = useState<string>(''); // empty = tenant-wide
  const [startsAt, setStartsAt] = useState('');
  const [endsAt, setEndsAt] = useState('');
  const [isAllDay, setIsAllDay] = useState(true);
  const [hijriLabel, setHijriLabel] = useState('');

  // Override Modal State (AC 2)
  const [selectedEventForOverride, setSelectedEventForOverride] = useState<EffectiveEventItem | null>(null);
  const [overrideCampusId, setOverrideCampusId] = useState<string>('');
  const [overrideType, setOverrideType] = useState<'modified' | 'cancelled' | 'rescheduled'>('rescheduled');
  const [overrideTitle, setOverrideTitle] = useState('');
  const [overrideStartsAt, setOverrideStartsAt] = useState('');
  const [overrideEndsAt, setOverrideEndsAt] = useState('');
  const [overrideReason, setOverrideReason] = useState('');

  // ICS Feed Modal State (AC 3)
  const [isIcsModalOpen, setIsIcsModalOpen] = useState(false);
  const [generatedToken, setGeneratedToken] = useState<string | null>(null);
  const [isGeneratingToken, setIsGeneratingToken] = useState(false);
  const [isRevokingToken, setIsRevokingToken] = useState(false);
  const [tokenStatusMessage, setTokenStatusMessage] = useState<string | null>(null);

  // Recompute Audit Modal State (AC 4)
  const [recomputeResult, setRecomputeResult] = useState<any | null>(null);
  const [isRecomputing, setIsRecomputing] = useState(false);

  // Campus map lookup
  const campusMap = new Map(campuses.map((c) => [c.id, c.name]));

  const filteredEvents = events.filter((ev) => {
    const matchesCampus = filterCampus === 'all' || ev.campus_id === filterCampus;
    const matchesType = filterType === 'all' || ev.event_type === filterType;
    const matchesSearch =
      searchQuery === '' ||
      ev.title.toLowerCase().includes(searchQuery.toLowerCase()) ||
      (ev.description && ev.description.toLowerCase().includes(searchQuery.toLowerCase())) ||
      (ev.hijri_label && ev.hijri_label.toLowerCase().includes(searchQuery.toLowerCase()));
    return matchesCampus && matchesType && matchesSearch;
  });

  const handleSaveEvent = async () => {
    setErrorMessage(null);
    setSuccessMessage(null);
    setIsSubmitting(true);

    try {
      const payload: CampusEventInput = {
        title,
        description: description || undefined,
        campus_id: campusId || null,
        event_type: eventType,
        starts_at: startsAt,
        ends_at: endsAt || startsAt,
        is_all_day: isAllDay,
        hijri_label: hijriLabel || undefined,
      };

      const res = await createCampusEventAction(payload);
      if (!res.success) {
        setErrorMessage(res.error || 'Failed to create event.');
      } else {
        setSuccessMessage(
          `Event "${title}" saved successfully!${
            res.isRetroactiveHoliday
              ? ' (Note: Retroactive holiday for past date saved without altering past records).'
              : ''
          }`
        );
        setIsNewEventOpen(false);
        // Reset form
        setTitle('');
        setDescription('');
        setStartsAt('');
        setEndsAt('');
        setHijriLabel('');
      }
    } catch (err: any) {
      setErrorMessage(err.message || 'An error occurred.');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleSaveOverride = async () => {
    if (!selectedEventForOverride) return;
    setIsSubmitting(true);
    setErrorMessage(null);

    try {
      const payload: CampusEventOverrideInput = {
        event_id: selectedEventForOverride.event_id,
        campus_id: overrideCampusId || selectedEventForOverride.campus_id,
        override_type: overrideType,
        title: overrideTitle || selectedEventForOverride.title,
        starts_at: overrideStartsAt || undefined,
        ends_at: overrideEndsAt || undefined,
        reason: overrideReason || undefined,
        is_cancelled: overrideType === 'cancelled',
      };

      const res = await createCampusEventOverrideAction(payload);
      if (!res.success) {
        setErrorMessage(res.error || 'Failed to save campus override.');
      } else {
        setSuccessMessage(`Campus override saved for "${selectedEventForOverride.title}".`);
        setSelectedEventForOverride(null);
      }
    } catch (err: any) {
      setErrorMessage(err.message || 'An error occurred.');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleGenerateIcsToken = async () => {
    setIsGeneratingToken(true);
    setTokenStatusMessage(null);
    try {
      const res = await generateGuardianIcsTokenAction();
      if (res.success && res.token) {
        setGeneratedToken(res.token);
      } else {
        setTokenStatusMessage(res.error || 'Failed to generate token.');
      }
    } catch (err: any) {
      setTokenStatusMessage(err.message || 'Generation error.');
    } finally {
      setIsGeneratingToken(false);
    }
  };

  const handleRevokeToken = async () => {
    if (!generatedToken) return;
    setIsRevokingToken(true);
    try {
      const res = await revokeGuardianIcsTokenAction(generatedToken);
      if (res.success) {
        setTokenStatusMessage('Token revoked! URL will now respond with 401 Unauthorized.');
        setGeneratedToken(null);
      } else {
        setTokenStatusMessage(res.error || 'Revocation failed.');
      }
    } catch (err: any) {
      setTokenStatusMessage(err.message || 'Revocation error.');
    } finally {
      setIsRevokingToken(false);
    }
  };

  const handleRecomputeImpact = async (eventId: string) => {
    setIsRecomputing(true);
    try {
      const res = await recomputeRetroactiveHolidayAction(eventId);
      if (res.success) {
        setRecomputeResult(res.result);
      } else {
        alert(res.error);
      }
    } catch (err: any) {
      alert(err.message);
    } finally {
      setIsRecomputing(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 border-b pb-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">Campus Events & Calendar</h1>
          <p className="text-sm text-muted-foreground">
            Manage official school holidays, examinations, PTM days, and campus-specific overrides with iCalendar feeds.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            id="btn-calendar-feed"
            variant="outline"
            onClick={() => {
              setIsIcsModalOpen(true);
              if (!generatedToken) handleGenerateIcsToken();
            }}
          >
            📅 iCal Feed (.ics)
          </Button>
          <Button id="btn-create-event" onClick={() => setIsNewEventOpen(true)}>
            + New Campus Event
          </Button>
        </div>
      </div>

      {/* Success / Error Messages */}
      {successMessage && (
        <div className="p-3 rounded-md bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-800 text-green-800 dark:text-green-300 text-sm">
          {successMessage}
        </div>
      )}
      {errorMessage && (
        <div className="p-3 rounded-md bg-destructive/10 border border-destructive/20 text-destructive text-sm">
          {errorMessage}
        </div>
      )}

      {/* Filter Bar */}
      <div className="flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-4 p-4 rounded-lg border bg-card text-card-foreground shadow-sm">
        <div className="flex flex-wrap items-center gap-3">
          <div>
            <Label htmlFor="filter-campus" className="text-xs text-muted-foreground">
              Campus Scope
            </Label>
            <select
              id="filter-campus"
              value={filterCampus}
              onChange={(e) => setFilterCampus(e.target.value)}
              className="w-48 mt-1 rounded-md border border-input bg-background px-3 py-1.5 text-sm"
            >
              <option value="all">All Campuses</option>
              {campuses.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name} ({c.code})
                </option>
              ))}
            </select>
          </div>

          <div>
            <Label htmlFor="filter-type" className="text-xs text-muted-foreground">
              Event Type
            </Label>
            <select
              id="filter-type"
              value={filterType}
              onChange={(e) => setFilterType(e.target.value)}
              className="w-40 mt-1 rounded-md border border-input bg-background px-3 py-1.5 text-sm capitalize"
            >
              <option value="all">All Types</option>
              <option value="holiday">Holiday</option>
              <option value="exam">Exam</option>
              <option value="ptm">PTM</option>
              <option value="sports">Sports</option>
              <option value="academic">Academic</option>
              <option value="cultural">Cultural</option>
              <option value="other">Other</option>
            </select>
          </div>
        </div>

        <div className="w-full sm:w-64">
          <Label htmlFor="search-events" className="text-xs text-muted-foreground">
            Search
          </Label>
          <Input
            id="search-events"
            placeholder="Search events..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="text-sm mt-1"
          />
        </div>
      </div>

      {/* Events List Table */}
      <div className="rounded-lg border bg-card text-card-foreground shadow-sm overflow-hidden">
        <table className="w-full text-sm text-left">
          <thead className="bg-muted/50 text-muted-foreground font-medium border-b text-xs uppercase tracking-wider">
            <tr>
              <th className="px-4 py-3">Event Details</th>
              <th className="px-4 py-3">Type</th>
              <th className="px-4 py-3">Campus Scope</th>
              <th className="px-4 py-3">Date & Time</th>
              <th className="px-4 py-3">Status & Overrides</th>
              <th className="px-4 py-3 text-right">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {filteredEvents.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                  No campus events found matching the filter criteria.
                </td>
              </tr>
            ) : (
              filteredEvents.map((ev, idx) => {
                const isPast = new Date(ev.starts_at) < new Date();
                const isRetroactiveHoliday = isPast && ev.event_type === 'holiday';

                return (
                  <tr key={`${ev.event_id}-${ev.campus_id}-${idx}`} className="hover:bg-muted/30 transition-colors">
                    <td className="px-4 py-3 max-w-xs">
                      <div className="font-semibold text-foreground flex items-center gap-1.5">
                        {ev.title}
                        {ev.hijri_label && (
                          <span className="text-[11px] px-1.5 py-0.5 rounded font-normal bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-300">
                            {ev.hijri_label}
                          </span>
                        )}
                      </div>
                      {ev.description && (
                        <div className="text-xs text-muted-foreground truncate">{ev.description}</div>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wider ${
                          ev.event_type === 'holiday'
                            ? 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'
                            : ev.event_type === 'exam'
                            ? 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300'
                            : ev.event_type === 'ptm'
                            ? 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-300'
                            : 'bg-muted text-muted-foreground'
                        }`}
                      >
                        {ev.event_type}
                      </span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <div className="font-medium text-foreground">
                        {campusMap.get(ev.campus_id) || 'Campus'}
                      </div>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-xs">
                      <div>
                        {new Date(ev.starts_at).toLocaleDateString([], {
                          month: 'short',
                          day: 'numeric',
                          year: 'numeric',
                        })}
                        {new Date(ev.ends_at).toDateString() !== new Date(ev.starts_at).toDateString() && (
                          <span>
                            {' '}
                            -{' '}
                            {new Date(ev.ends_at).toLocaleDateString([], {
                              month: 'short',
                              day: 'numeric',
                              year: 'numeric',
                            })}
                          </span>
                        )}
                      </div>
                      <div className="text-muted-foreground">
                        {ev.is_all_day ? 'All Day' : new Date(ev.starts_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex flex-col gap-1">
                        {ev.is_override ? (
                          <span className="inline-flex items-center px-2 py-0.5 rounded text-[11px] font-semibold bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-300">
                            ⚡ Campus Override (AC 2)
                          </span>
                        ) : (
                          <span className="inline-flex items-center px-2 py-0.5 rounded text-[11px] font-medium bg-muted text-muted-foreground">
                            Standard
                          </span>
                        )}
                        {ev.is_cancelled && (
                          <span className="inline-flex items-center px-2 py-0.5 rounded text-[11px] font-semibold bg-destructive/10 text-destructive">
                            Cancelled
                          </span>
                        )}
                        {isRetroactiveHoliday && (
                          <span className="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium bg-amber-50 text-amber-800 dark:bg-amber-900/20 dark:text-amber-400">
                            Retroactive Holiday
                          </span>
                        )}
                      </div>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex items-center justify-end gap-1.5">
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => {
                            setSelectedEventForOverride(ev);
                            setOverrideCampusId(ev.campus_id);
                            setOverrideTitle(ev.title);
                            setOverrideStartsAt(ev.starts_at.slice(0, 16));
                            setOverrideEndsAt(ev.ends_at.slice(0, 16));
                          }}
                          className="text-xs"
                        >
                          Override
                        </Button>
                        {isRetroactiveHoliday && (
                          <Button
                            variant="secondary"
                            size="sm"
                            onClick={() => handleRecomputeImpact(ev.event_id)}
                            disabled={isRecomputing}
                            className="text-xs whitespace-nowrap"
                          >
                            Recompute
                          </Button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* New Event Modal */}
      {isNewEventOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="relative w-full max-w-lg rounded-lg bg-card p-6 shadow-xl border">
            <h2 className="text-xl font-bold text-foreground mb-4">Create Campus Event</h2>
            <div className="space-y-4">
              <div>
                <Label htmlFor="event-title">Title *</Label>
                <Input
                  id="event-title"
                  placeholder="e.g. Eid-ul-Fitr Holidays"
                  value={title}
                  onChange={(e) => setTitle(e.target.value)}
                  className="mt-1"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <Label htmlFor="event-type">Event Type *</Label>
                  <select
                    id="event-type"
                    value={eventType}
                    onChange={(e: any) => setEventType(e.target.value)}
                    className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm capitalize"
                  >
                    <option value="holiday">Holiday</option>
                    <option value="exam">Exam</option>
                    <option value="ptm">PTM</option>
                    <option value="sports">Sports</option>
                    <option value="academic">Academic</option>
                    <option value="cultural">Cultural</option>
                    <option value="other">Other</option>
                  </select>
                </div>

                <div>
                  <Label htmlFor="event-campus">Campus Scope</Label>
                  <select
                    id="event-campus"
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
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <Label htmlFor="event-starts-at">Starts At *</Label>
                  <Input
                    id="event-starts-at"
                    type="datetime-local"
                    value={startsAt}
                    onChange={(e) => setStartsAt(e.target.value)}
                    className="mt-1 text-sm"
                  />
                </div>
                <div>
                  <Label htmlFor="event-ends-at">Ends At *</Label>
                  <Input
                    id="event-ends-at"
                    type="datetime-local"
                    value={endsAt}
                    onChange={(e) => setEndsAt(e.target.value)}
                    className="mt-1 text-sm"
                  />
                </div>
              </div>

              <div>
                <Label htmlFor="event-hijri">Hijri / Moon Sighting Label (Optional)</Label>
                <Input
                  id="event-hijri"
                  placeholder="e.g. 1st Shawwal / Confirmed by Ruet"
                  value={hijriLabel}
                  onChange={(e) => setHijriLabel(e.target.value)}
                  className="mt-1 text-sm"
                />
              </div>

              <div>
                <Label htmlFor="event-desc">Description (Optional)</Label>
                <textarea
                  id="event-desc"
                  rows={2}
                  placeholder="Additional notes for parents and staff..."
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
                />
              </div>
            </div>

            <div className="mt-6 flex justify-end gap-3 border-t pt-4">
              <Button variant="outline" onClick={() => setIsNewEventOpen(false)} disabled={isSubmitting}>
                Cancel
              </Button>
              <Button id="btn-save-event" onClick={handleSaveEvent} disabled={isSubmitting}>
                {isSubmitting ? 'Saving...' : 'Save Event'}
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Campus Override Modal (AC 2) */}
      {selectedEventForOverride && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="relative w-full max-w-lg rounded-lg bg-card p-6 shadow-xl border">
            <h2 className="text-xl font-bold text-foreground mb-4">
              Override Event for Campus (AC 2)
            </h2>
            <p className="text-xs text-muted-foreground mb-4">
              Create a campus-specific override without affecting other campuses.
            </p>

            <div className="space-y-4">
              <div>
                <Label htmlFor="override-campus">Target Campus *</Label>
                <select
                  id="override-campus"
                  value={overrideCampusId}
                  onChange={(e) => setOverrideCampusId(e.target.value)}
                  className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
                >
                  {campuses.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name} ({c.code})
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <Label htmlFor="override-type">Override Action</Label>
                  <select
                    id="override-type"
                    value={overrideType}
                    onChange={(e: any) => setOverrideType(e.target.value)}
                    className="w-full mt-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
                  >
                    <option value="rescheduled">Reschedule Dates</option>
                    <option value="modified">Modify Details</option>
                    <option value="cancelled">Cancel for this Campus</option>
                  </select>
                </div>

                <div>
                  <Label htmlFor="override-title">Overridden Title</Label>
                  <Input
                    id="override-title"
                    value={overrideTitle}
                    onChange={(e) => setOverrideTitle(e.target.value)}
                    className="mt-1 text-sm"
                  />
                </div>
              </div>

              {overrideType !== 'cancelled' && (
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <Label htmlFor="override-starts">New Start Date</Label>
                    <Input
                      id="override-starts"
                      type="datetime-local"
                      value={overrideStartsAt}
                      onChange={(e) => setOverrideStartsAt(e.target.value)}
                      className="mt-1 text-sm"
                    />
                  </div>
                  <div>
                    <Label htmlFor="override-ends">New End Date</Label>
                    <Input
                      id="override-ends"
                      type="datetime-local"
                      value={overrideEndsAt}
                      onChange={(e) => setOverrideEndsAt(e.target.value)}
                      className="mt-1 text-sm"
                    />
                  </div>
                </div>
              )}

              <div>
                <Label htmlFor="override-reason">Reason for Override</Label>
                <Input
                  id="override-reason"
                  placeholder="e.g. Local sports competition clash"
                  value={overrideReason}
                  onChange={(e) => setOverrideReason(e.target.value)}
                  className="mt-1 text-sm"
                />
              </div>
            </div>

            <div className="mt-6 flex justify-end gap-3 border-t pt-4">
              <Button variant="outline" onClick={() => setSelectedEventForOverride(null)} disabled={isSubmitting}>
                Cancel
              </Button>
              <Button id="btn-save-override" onClick={handleSaveOverride} disabled={isSubmitting}>
                {isSubmitting ? 'Saving...' : 'Save Override'}
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* iCal Feed Modal (AC 3) */}
      {isIcsModalOpen && (
        <div id="ics-feed-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="relative w-full max-w-lg rounded-lg bg-card p-6 shadow-xl border">
            <h2 className="text-xl font-bold text-foreground mb-2">Guardian iCalendar Feed (.ics)</h2>
            <p className="text-xs text-muted-foreground mb-4">
              Subscribe to official school events in Apple Calendar, Google Calendar, or Outlook.
              (Scoped strictly to campuses with active enrolled children).
            </p>

            {tokenStatusMessage && (
              <div className="p-3 mb-4 rounded bg-muted/40 border text-xs">
                {tokenStatusMessage}
              </div>
            )}

            {isGeneratingToken ? (
              <div className="py-6 text-center text-sm text-muted-foreground">Generating feed URL...</div>
            ) : generatedToken ? (
              <div className="space-y-4">
                <div>
                  <Label className="text-xs text-muted-foreground">Your Personal Feed URL</Label>
                  <div className="mt-1 flex items-center gap-2">
                    <Input
                      id="ics-url-input"
                      readOnly
                      value={`${typeof window !== 'undefined' ? window.location.origin : ''}/api/calendar/feed/${generatedToken}`}
                      className="font-mono text-xs"
                    />
                    <Button
                      size="sm"
                      onClick={() => {
                        navigator.clipboard.writeText(
                          `${window.location.origin}/api/calendar/feed/${generatedToken}`
                        );
                        alert('Feed URL copied to clipboard!');
                      }}
                      className="text-xs"
                    >
                      Copy
                    </Button>
                  </div>
                </div>

                <div className="p-3 bg-muted/20 border rounded text-xs space-y-1">
                  <div className="font-semibold text-foreground">Security & Scoping:</div>
                  <div className="text-muted-foreground">
                    This link automatically updates as dates change. If revoked, the feed URL returns HTTP 401 Unauthorized immediately.
                  </div>
                </div>

                <div className="flex justify-between items-center pt-2">
                  <Button
                    id="btn-revoke-feed"
                    variant="outline"
                    size="sm"
                    onClick={handleRevokeToken}
                    disabled={isRevokingToken}
                    className="text-xs text-destructive hover:text-destructive"
                  >
                    {isRevokingToken ? 'Revoking...' : 'Revoke Feed Access'}
                  </Button>
                  <Button variant="secondary" size="sm" onClick={() => setIsIcsModalOpen(false)}>
                    Close
                  </Button>
                </div>
              </div>
            ) : (
              <div className="space-y-4 pt-4">
                <div className="flex justify-end">
                  <Button variant="secondary" size="sm" onClick={() => setIsIcsModalOpen(false)}>
                    Close
                  </Button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Recompute Result Alert (AC 4) */}
      {recomputeResult && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="relative w-full max-w-md rounded-lg bg-card p-6 shadow-xl border space-y-4">
            <h3 className="text-lg font-bold text-foreground">Retroactive Impact Audit (AC 4)</h3>
            <p className="text-xs text-muted-foreground">
              Explicit recompute action executed safely. Already-computed late fees and attendance records were audited.
            </p>
            <div className="p-3 bg-muted/40 rounded border font-mono text-xs space-y-1">
              <div>Affected Attendance Days: {recomputeResult.affected_attendance_records}</div>
              <div>Audit Timestamp: {new Date(recomputeResult.recomputed_at).toLocaleTimeString()}</div>
            </div>
            <div className="flex justify-end">
              <Button size="sm" onClick={() => setRecomputeResult(null)}>
                Dismiss
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
