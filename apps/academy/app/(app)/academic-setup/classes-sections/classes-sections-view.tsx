'use client';

import * as React from 'react';
import { toast } from 'sonner';
import {
  BookOpen,
  GraduationCap,
  Layers,
  Plus,
  School,
  UserCheck,
  Users,
  Search,
  CheckCircle2,
  AlertCircle,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Modal } from '@/components/ui/modal';
import { DatePicker } from '@/components/ui/date-picker';
import { createSection, assignClassTeacher } from './actions';

export interface ClassesSectionsViewProps {
  campus: { id: string; name: string; code: string } | null;
  campuses: { id: string; name: string; code: string }[];
  currentSession: { id: string; name: string } | null;
  sessions: { id: string; name: string }[];
  classLevels: { id: string; name_en: string; name_ur: string | null; code: string; ordinal: number }[];
  sections: {
    id: string;
    name: string;
    capacity: number;
    medium: string;
    shift: string;
    class_level_id: string;
    campus_id: string;
    session_id: string;
  }[];
  studentCountMap: Record<string, number>;
  teacherAssignmentMap: Record<string, string>;
  staffList: { user_id: string; full_name: string; app_role: string }[];
}

export function ClassesSectionsView({
  campus,
  currentSession,
  classLevels,
  sections,
  studentCountMap,
  teacherAssignmentMap,
  staffList,
}: ClassesSectionsViewProps) {
  const [search, setSearch] = React.useState('');
  const [selectedClassId, setSelectedClassId] = React.useState<string | null>(null);

  // Add Section Modal State
  const [addModalOpen, setAddModalOpen] = React.useState(false);
  const [targetClassId, setTargetClassId] = React.useState(classLevels[0]?.id ?? '');
  const [newSectionName, setNewSectionName] = React.useState('');
  const [newCapacity, setNewCapacity] = React.useState(40);
  const [newMedium, setNewMedium] = React.useState('ENGLISH');
  const [newShift, setNewShift] = React.useState('MORNING');
  const [isCreating, startCreateTransition] = React.useTransition();

  // Assign Class Teacher Modal State
  const [assignModalOpen, setAssignModalOpen] = React.useState(false);
  const [targetSection, setTargetSection] = React.useState<{ id: string; name: string; className: string } | null>(null);
  const [selectedStaffId, setSelectedStaffId] = React.useState('');
  const [effectiveDate, setEffectiveDate] = React.useState(new Date().toISOString().slice(0, 10));
  const [isAssigning, startAssignTransition] = React.useTransition();

  // Filter classes
  const filteredClasses = classLevels.filter((cl) =>
    cl.name_en.toLowerCase().includes(search.toLowerCase()) ||
    cl.code.toLowerCase().includes(search.toLowerCase())
  );

  // KPI calculations
  const totalClasses = classLevels.length;
  const totalSections = sections.length;
  const totalCapacity = sections.reduce((sum, s) => sum + (s.capacity || 40), 0);
  const totalEnrolled = Object.values(studentCountMap).reduce((sum, c) => sum + c, 0);
  const overallOccupancyPct = totalCapacity > 0 ? Math.round((totalEnrolled / totalCapacity) * 100) : 0;

  // Staff lookup map
  const staffMap = React.useMemo(() => {
    const map: Record<string, string> = {};
    staffList.forEach((s) => {
      map[s.user_id] = s.full_name;
    });
    return map;
  }, [staffList]);

  // Handlers
  const handleOpenAddModal = (classId?: string) => {
    if (classId) setTargetClassId(classId);
    setNewSectionName('');
    setNewCapacity(40);
    setAddModalOpen(true);
  };

  const handleCreateSection = (e: React.FormEvent) => {
    e.preventDefault();
    if (!campus || !currentSession || !targetClassId || !newSectionName.trim()) {
      toast.error('Please fill in all required fields');
      return;
    }

    const fd = new FormData();
    fd.set('campusId', campus.id);
    fd.set('sessionId', currentSession.id);
    fd.set('classLevelId', targetClassId);
    fd.set('name', newSectionName.trim().toUpperCase());
    fd.set('capacity', String(newCapacity));
    fd.set('medium', newMedium);
    fd.set('shift', newShift);

    startCreateTransition(async () => {
      const result = await createSection(fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(`Section ${newSectionName.trim().toUpperCase()} created successfully!`);
        setAddModalOpen(false);
      }
    });
  };

  const handleOpenAssignModal = (sec: { id: string; name: string }, className: string) => {
    setTargetSection({ id: sec.id, name: sec.name, className });
    setSelectedStaffId(teacherAssignmentMap[sec.id] ?? '');
    setEffectiveDate(new Date().toISOString().slice(0, 10));
    setAssignModalOpen(true);
  };

  const handleAssignTeacher = (e: React.FormEvent) => {
    e.preventDefault();
    if (!targetSection || !selectedStaffId) {
      toast.error('Please select a teacher to assign.');
      return;
    }

    const fd = new FormData();
    fd.set('sectionId', targetSection.id);
    fd.set('staffId', selectedStaffId);
    fd.set('effectiveFrom', effectiveDate);

    startAssignTransition(async () => {
      const result = await assignClassTeacher(fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        if (result.warning === 'DUAL_CLASS_TEACHER') {
          toast.warning('Teacher assigned. Note: This teacher is already in-charge of another section.');
        } else {
          toast.success('Class In-Charge Teacher assigned successfully!');
        }
        setAssignModalOpen(false);
      }
    });
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4 border-b pb-4">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-2xl font-bold tracking-tight">Classes & Sections</h1>
            <Badge variant="outline" className="bg-indigo-50 text-indigo-700 border-indigo-200 dark:bg-indigo-950/50 dark:text-indigo-300">
              Academic Architecture
            </Badge>
          </div>
          <p className="text-sm text-muted-foreground mt-0.5">
            Manage academic sections, seat capacities, and Class In-charge (Homeroom) assignments across class levels.
          </p>
        </div>

        <div className="flex items-center gap-2.5">
          <div className="text-xs text-muted-foreground text-right hidden sm:block">
            <span className="font-semibold text-foreground">{campus?.name ?? 'Main Campus'}</span>
            <br />
            <span>Session: {currentSession?.name ?? 'Current'}</span>
          </div>
          <Button
            onClick={() => handleOpenAddModal()}
            className="gap-1.5 bg-indigo-600 hover:bg-indigo-700 text-white shadow-sm"
            data-testid="create-section-btn"
          >
            <Plus className="h-4 w-4" />
            <span>Add Section</span>
          </Button>
        </div>
      </div>

      {/* KPI Overview */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Card className="p-4 shadow-sm border-border/80">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-muted-foreground">Class Levels</span>
            <GraduationCap className="h-4 w-4 text-indigo-500" />
          </div>
          <p className="text-2xl font-bold mt-1">{totalClasses}</p>
          <span className="text-xs text-muted-foreground">Playgroup to Grade 10/12</span>
        </Card>

        <Card className="p-4 shadow-sm border-border/80">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-muted-foreground">Active Sections</span>
            <Layers className="h-4 w-4 text-emerald-500" />
          </div>
          <p className="text-2xl font-bold mt-1">{totalSections}</p>
          <span className="text-xs text-muted-foreground">Across all class levels</span>
        </Card>

        <Card className="p-4 shadow-sm border-border/80">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-muted-foreground">Enrolled Students</span>
            <Users className="h-4 w-4 text-blue-500" />
          </div>
          <p className="text-2xl font-bold mt-1">{totalEnrolled}</p>
          <span className="text-xs text-muted-foreground">In active sections</span>
        </Card>

        <Card className="p-4 shadow-sm border-border/80">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-muted-foreground">Total Capacity</span>
            <School className="h-4 w-4 text-amber-500" />
          </div>
          <p className="text-2xl font-bold mt-1">
            {totalCapacity} <span className="text-xs font-normal text-muted-foreground">seats</span>
          </p>
          <span className="text-xs font-medium text-indigo-600 dark:text-indigo-400">
            {overallOccupancyPct}% occupied
          </span>
        </Card>
      </div>

      {/* Search & Filter Bar */}
      <div className="flex flex-col sm:flex-row items-center gap-3">
        <div className="relative flex-1 w-full">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search classes (e.g. Class 8, Nursery, Matric)..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9 h-9"
          />
        </div>
      </div>

      {/* Class & Section Listing */}
      <div className="space-y-4">
        {filteredClasses.length === 0 ? (
          <Card className="p-8 text-center text-muted-foreground">
            No class levels found matching &ldquo;{search}&rdquo;.
          </Card>
        ) : (
          filteredClasses.map((cl) => {
            const classSections = sections.filter((s) => s.class_level_id === cl.id);
            const classEnrolment = classSections.reduce((acc, s) => acc + (studentCountMap[s.id] ?? 0), 0);
            const classCapacity = classSections.reduce((acc, s) => acc + (s.capacity || 40), 0);

            return (
              <Card key={cl.id} className="overflow-hidden border-border/80 shadow-sm" data-testid={`class-card-${cl.code}`}>
                <div className="bg-muted/40 px-4 py-3 border-b flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
                  <div className="flex items-center gap-3">
                    <div className="h-8 w-8 rounded bg-primary/10 text-primary font-bold flex items-center justify-center text-xs">
                      {cl.code}
                    </div>
                    <div>
                      <h2 className="font-semibold text-sm leading-tight text-foreground">{cl.name_en}</h2>
                      <span className="text-xs text-muted-foreground">
                        {classSections.length} {classSections.length === 1 ? 'Section' : 'Sections'} •{' '}
                        {classEnrolment} / {classCapacity || 0} students
                      </span>
                    </div>
                  </div>

                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => handleOpenAddModal(cl.id)}
                    className="h-7 text-xs gap-1 self-start sm:self-auto"
                    data-testid={`add-section-to-${cl.code}`}
                  >
                    <Plus className="h-3 w-3" />
                    <span>Add Section</span>
                  </Button>
                </div>

                <CardContent className="p-4">
                  {classSections.length === 0 ? (
                    <div className="text-center py-5 border border-dashed rounded-lg bg-muted/10">
                      <p className="text-xs text-muted-foreground">No sections created for {cl.name_en} yet.</p>
                      <Button
                        size="sm"
                        variant="link"
                        onClick={() => handleOpenAddModal(cl.id)}
                        className="text-xs text-indigo-600 dark:text-indigo-400 font-semibold p-0 mt-1 h-auto"
                      >
                        + Create Section A now
                      </Button>
                    </div>
                  ) : (
                    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                      {classSections.map((sec) => {
                        const enrolled = studentCountMap[sec.id] ?? 0;
                        const capacity = sec.capacity || 40;
                        const occupancy = Math.round((enrolled / capacity) * 100);
                        const teacherId = teacherAssignmentMap[sec.id];
                        const teacherName = teacherId ? staffMap[teacherId] : null;

                        return (
                          <div
                            key={sec.id}
                            className="border rounded-lg p-3.5 bg-card hover:border-indigo-200 dark:hover:border-indigo-900 transition-colors space-y-3"
                            data-testid={`section-card-${sec.name}`}
                          >
                            <div className="flex items-center justify-between">
                              <div className="flex items-center gap-2">
                                <span className="font-bold text-base text-foreground">Section {sec.name}</span>
                                <Badge variant="default" className="text-[10px] px-1.5 py-0 h-4 uppercase">
                                  {sec.shift}
                                </Badge>
                              </div>
                              <Badge
                                variant={occupancy >= 100 ? 'destructive' : occupancy >= 80 ? 'outline' : 'default'}
                                className="text-xs"
                              >
                                {enrolled} / {capacity}
                              </Badge>
                            </div>

                            {/* Occupancy Progress Bar */}
                            <div className="space-y-1">
                              <div className="h-1.5 w-full bg-muted rounded-full overflow-hidden">
                                <div
                                  className={`h-full transition-all ${
                                    occupancy >= 100
                                      ? 'bg-destructive'
                                      : occupancy >= 80
                                      ? 'bg-amber-500'
                                      : 'bg-emerald-500'
                                  }`}
                                  style={{ width: `${Math.min(occupancy, 100)}%` }}
                                />
                              </div>
                              <div className="flex justify-between text-[11px] text-muted-foreground">
                                <span>{capacity - enrolled > 0 ? `${capacity - enrolled} seats left` : 'Section full'}</span>
                                <span>{occupancy}%</span>
                              </div>
                            </div>

                            {/* Class In-Charge (Homeroom Teacher) */}
                            <div className="pt-2 border-t flex items-center justify-between gap-2">
                              <div className="min-w-0 flex items-center gap-1.5 text-xs">
                                <UserCheck className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                                <span className="truncate text-muted-foreground">
                                  {teacherName ? (
                                    <span className="font-medium text-foreground">{teacherName}</span>
                                  ) : (
                                    <span className="italic text-amber-600 dark:text-amber-400">Unassigned</span>
                                  )}
                                </span>
                              </div>
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() => handleOpenAssignModal(sec, cl.name_en)}
                                className="h-6 text-[11px] px-2 text-indigo-600 dark:text-indigo-400 hover:text-indigo-700"
                                data-testid={`assign-teacher-${sec.id}`}
                              >
                                {teacherName ? 'Change' : 'Assign'}
                              </Button>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </CardContent>
              </Card>
            );
          })
        )}
      </div>

      {/* Modal: Add New Section */}
      <Modal
        open={addModalOpen}
        onClose={() => setAddModalOpen(false)}
        title="Add New Section"
        description="Configure a new section and its student seat capacity."
      >
        <form onSubmit={handleCreateSection} className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="target-class">Class Level</Label>
            <Select value={targetClassId} onValueChange={setTargetClassId}>
              <SelectTrigger id="target-class">
                <SelectValue placeholder="Select Class" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((cl) => (
                  <SelectItem key={cl.id} value={cl.id}>
                    {cl.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="sec-name">Section Name</Label>
              <Input
                id="sec-name"
                placeholder="e.g. B, C, Green"
                value={newSectionName}
                onChange={(e) => setNewSectionName(e.target.value)}
                required
                maxLength={10}
                data-testid="input-section-name"
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="sec-cap">Student Capacity</Label>
              <Input
                id="sec-cap"
                type="number"
                min={1}
                max={200}
                value={newCapacity}
                onChange={(e) => setNewCapacity(Number(e.target.value))}
                required
                data-testid="input-section-capacity"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="sec-medium">Medium</Label>
              <Select value={newMedium} onValueChange={setNewMedium}>
                <SelectTrigger id="sec-medium">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="ENGLISH">English</SelectItem>
                  <SelectItem value="URDU">Urdu</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="sec-shift">Shift</Label>
              <Select value={newShift} onValueChange={setNewShift}>
                <SelectTrigger id="sec-shift">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="MORNING">Morning</SelectItem>
                  <SelectItem value="AFTERNOON">Afternoon</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="flex justify-end gap-2 pt-2 border-t">
            <Button type="button" variant="outline" onClick={() => setAddModalOpen(false)}>
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={isCreating}
              className="bg-indigo-600 hover:bg-indigo-700 text-white"
              data-testid="submit-create-section"
            >
              {isCreating ? 'Creating Section…' : 'Create Section'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Modal: Assign Class Teacher */}
      <Modal
        open={assignModalOpen}
        onClose={() => setAssignModalOpen(false)}
        title="Assign Class In-Charge Teacher"
        description={
          targetSection
            ? `Select the teacher responsible for ${targetSection.className} - Section ${targetSection.name} daily attendance and homeroom duties.`
            : 'Assign teacher'
        }
      >
        <form onSubmit={handleAssignTeacher} className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="teacher-select">Select Faculty Member</Label>
            <Select value={selectedStaffId} onValueChange={setSelectedStaffId}>
              <SelectTrigger id="teacher-select" data-testid="select-teacher-trigger">
                <SelectValue placeholder="Choose a teacher" />
              </SelectTrigger>
              <SelectContent>
                {staffList.map((staff) => (
                  <SelectItem key={staff.user_id} value={staff.user_id}>
                    {staff.full_name} ({staff.app_role.replace(/_/g, ' ')})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="effective-date">Effective From</Label>
            <DatePicker
              id="effective-date"
              value={effectiveDate}
              onChange={setEffectiveDate}
              required
              data-testid="effective-date-picker"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2 border-t">
            <Button type="button" variant="outline" onClick={() => setAssignModalOpen(false)}>
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={isAssigning}
              className="bg-indigo-600 hover:bg-indigo-700 text-white"
              data-testid="submit-assign-teacher"
            >
              {isAssigning ? 'Assigning…' : 'Save Assignment'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
