'use client';

import { useState, useTransition, useMemo } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createRoom, batchCreateClassrooms, seedStandardFacilities } from './actions';
import { createRoomSchema, ROOM_TYPES, type CreateRoomInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import {
  PlusCircle,
  Building2,
  Layers,
  Users,
  Hash,
  MapPin,
  Sparkles,
  Zap,
  FlaskConical,
  GraduationCap,
  CheckCircle2,
} from 'lucide-react';

export type ClassLevelOption = {
  id: string;
  code: string;
  name_en: string;
  ordinal: number;
};

export type SectionOption = {
  id: string;
  name: string;
  class_level_id: string;
  home_room_id: string | null;
};

export function CreateRoomForm({
  campusId,
  classes = [],
  sections = [],
}: {
  campusId: string;
  classes?: ClassLevelOption[];
  sections?: SectionOption[];
}) {
  const [mode, setMode] = useState<'single' | 'batch' | 'preset'>('single');
  const [pending, startTransition] = useTransition();

  // --- SINGLE ROOM FORM STATE ---
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<CreateRoomInput>({
    resolver: zodResolver(createRoomSchema),
    defaultValues: { roomType: 'CLASSROOM' },
  });

  const onSubmitSingle = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('code', values.code);
    fd.set('name', values.name);
    fd.set('roomType', values.roomType);
    fd.set('capacity', String(values.capacity));
    if (values.blockLabel) fd.set('blockLabel', values.blockLabel);

    startTransition(async () => {
      const result = await createRoom(campusId, { error: null }, fd);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(`${values.name} added.`);
        reset({ roomType: 'CLASSROOM', code: '', name: '', blockLabel: '' });
      }
    });
  });

  // --- BATCH CLASSROOM GENERATOR STATE ---
  // Default to Class 10 or first class if available
  const defaultClass = classes.find((c) => c.name_en.toLowerCase().includes('10')) || classes[0];
  const [selectedClassId, setSelectedClassId] = useState<string>(defaultClass?.id || '');
  const [sectionNamesInput, setSectionNamesInput] = useState<string>('Jinnah, Iqbal, Fatima');
  const [batchCapacity, setBatchCapacity] = useState<number>(35);
  const [batchBlock, setBatchBlock] = useState<string>('Senior Wing');
  const [linkHomeroom, setLinkHomeroom] = useState<boolean>(true);

  const selectedClass = useMemo(() => {
    return classes.find((c) => c.id === selectedClassId) || classes[0];
  }, [classes, selectedClassId]);

  // Existing sections for this class
  const classSections = useMemo(() => {
    if (!selectedClassId) return [];
    return sections.filter((s) => s.class_level_id === selectedClassId);
  }, [sections, selectedClassId]);

  // Parsed section names
  const parsedSectionNames = useMemo(() => {
    return sectionNamesInput
      .split(/[,;\n]/)
      .map((s) => s.trim())
      .filter(Boolean);
  }, [sectionNamesInput]);

  const handleBatchGenerate = (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedClass) {
      toast.error('Please select a class');
      return;
    }
    if (parsedSectionNames.length === 0) {
      toast.error('Please enter at least one section name (e.g. Jinnah, Iqbal, Fatima)');
      return;
    }

    startTransition(async () => {
      const result = await batchCreateClassrooms(campusId, {
        classLevelId: selectedClass.id,
        classCode: selectedClass.code || selectedClass.name_en.replace(/[^0-9]/g, '') || 'CR',
        className: selectedClass.name_en,
        sectionNames: parsedSectionNames,
        capacity: batchCapacity,
        blockLabel: batchBlock.trim() || undefined,
        linkHomeroom,
      });

      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(`Successfully generated ${result.count} classrooms for ${selectedClass.name_en}!`);
      }
    });
  };

  const handleSeedFacilities = () => {
    startTransition(async () => {
      const result = await seedStandardFacilities(campusId);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(`Standard facilities generated (${result.count} rooms added).`);
        setMode('single');
      }
    });
  };

  return (
    <div className="rounded-xl border border-border/80 bg-card/60 p-5 shadow-sm backdrop-blur-sm">
      {/* Top Header & Mode Tabs */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between pb-4 border-b mb-4">
        <div className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary/10 text-primary">
            {mode === 'batch' ? (
              <Zap className="h-4 w-4" />
            ) : mode === 'preset' ? (
              <FlaskConical className="h-4 w-4" />
            ) : (
              <PlusCircle className="h-4 w-4" />
            )}
          </div>
          <div>
            <h2 className="text-sm font-semibold text-foreground">
              {mode === 'batch'
                ? 'Batch Classroom Generator (Multi-Section)'
                : mode === 'preset'
                ? 'Standard Campus Facilities Preset'
                : 'Register New Room / Venue'}
            </h2>
            <p className="text-xs text-muted-foreground">
              {mode === 'batch'
                ? 'Generate rooms for Jinnah, Iqbal, Fatima sections in 1 click'
                : mode === 'preset'
                ? '1-click standard Physics Lab, Chem Lab, IT Lab, Library & Exam Hall'
                : 'Add a physical classroom, laboratory, library, or examination hall'}
            </p>
          </div>
        </div>

        {/* Mode Switcher */}
        <div className="flex items-center rounded-lg border border-border/80 bg-muted/40 p-1 text-xs">
          <button
            type="button"
            onClick={() => setMode('single')}
            className={`rounded-md px-3 py-1 font-medium transition-all ${
              mode === 'single'
                ? 'bg-background text-foreground shadow-xs font-semibold'
                : 'text-muted-foreground hover:text-foreground'
            }`}
          >
            Single Room
          </button>
          <button
            type="button"
            onClick={() => setMode('batch')}
            className={`flex items-center gap-1 rounded-md px-3 py-1 font-medium transition-all ${
              mode === 'batch'
                ? 'bg-primary text-primary-foreground shadow-xs font-semibold'
                : 'text-muted-foreground hover:text-foreground'
            }`}
          >
            <Zap className="h-3 w-3" />
            Batch Classrooms
          </button>
          <button
            type="button"
            onClick={() => setMode('preset')}
            className={`flex items-center gap-1 rounded-md px-3 py-1 font-medium transition-all ${
              mode === 'preset'
                ? 'bg-emerald-600 text-white shadow-xs font-semibold'
                : 'text-muted-foreground hover:text-foreground'
            }`}
          >
            <Sparkles className="h-3 w-3" />
            Standard Labs
          </button>
        </div>
      </div>

      {/* --- MODE 1: SINGLE ROOM FORM (EXACT LABELS & TEST IDS PRESERVED) --- */}
      {mode === 'single' && (
        <form onSubmit={onSubmitSingle} className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5" noValidate>
          <div className="space-y-1.5">
            <Label htmlFor="code" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Hash className="h-3 w-3 text-muted-foreground" />
              Code
            </Label>
            <Input id="code" placeholder="SL-1, 101" className="h-9 font-mono" {...register('code')} />
            {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="name" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Building2 className="h-3 w-3 text-muted-foreground" />
              Name
            </Label>
            <Input id="name" placeholder="Science Lab 1" className="h-9" {...register('name')} />
            {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="roomType" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Layers className="h-3 w-3 text-muted-foreground" />
              Type
            </Label>
            <Controller
              control={control}
              name="roomType"
              render={({ field }) => (
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger id="roomType" data-testid="room-type-trigger" className="h-9">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {ROOM_TYPES.map((t) => (
                      <SelectItem key={t} value={t}>
                        {t.replace(/_/g, ' ')}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="capacity" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <Users className="h-3 w-3 text-muted-foreground" />
              Capacity
            </Label>
            <Input id="capacity" type="number" min={1} placeholder="30" className="h-9 font-semibold" {...register('capacity')} />
            {errors.capacity && <p className="text-xs text-destructive">{errors.capacity.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="blockLabel" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
              <MapPin className="h-3 w-3 text-muted-foreground" />
              Block (optional)
            </Label>
            <Input id="blockLabel" placeholder="Block C, Ground Floor" className="h-9" {...register('blockLabel')} />
          </div>

          <div className="col-span-full flex items-center justify-end gap-3 pt-2">
            <Button type="submit" disabled={pending} className="gap-2 px-5">
              <PlusCircle className="h-4 w-4" />
              {pending ? 'Adding room…' : 'Add room'}
            </Button>
          </div>
        </form>
      )}

      {/* --- MODE 2: BATCH CLASSROOM GENERATOR (FOR CLASS 10 JINNAH, IQBAL, FATIMA) --- */}
      {mode === 'batch' && (
        <form onSubmit={handleBatchGenerate} className="space-y-4">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {/* Class Dropdown */}
            <div className="space-y-1.5">
              <Label className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
                <GraduationCap className="h-3.5 w-3.5 text-primary" />
                Select Class
              </Label>
              <Select value={selectedClassId} onValueChange={setSelectedClassId}>
                <SelectTrigger className="h-9">
                  <SelectValue placeholder="Choose Class..." />
                </SelectTrigger>
                <SelectContent>
                  {classes.map((c) => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.name_en} {c.code ? `(${c.code})` : ''}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {/* Capacity Input */}
            <div className="space-y-1.5">
              <Label htmlFor="batchCapacity" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
                <Users className="h-3.5 w-3.5 text-muted-foreground" />
                Default Capacity per Room
              </Label>
              <Input
                id="batchCapacity"
                type="number"
                min={1}
                value={batchCapacity}
                onChange={(e) => setBatchCapacity(parseInt(e.target.value, 10) || 35)}
                className="h-9 font-semibold"
                required
              />
            </div>

            {/* Block / Wing Input */}
            <div className="space-y-1.5">
              <Label htmlFor="batchBlock" className="flex items-center gap-1.5 text-xs font-semibold text-foreground/80">
                <MapPin className="h-3.5 w-3.5 text-muted-foreground" />
                Building Block / Wing
              </Label>
              <Input
                id="batchBlock"
                placeholder="e.g. Senior Wing, Block A"
                value={batchBlock}
                onChange={(e) => setBatchBlock(e.target.value)}
                className="h-9"
              />
            </div>

            {/* Auto-link option */}
            <div className="flex flex-col justify-end space-y-1.5">
              <label className="flex items-center gap-2 text-xs font-medium text-foreground cursor-pointer rounded-lg border border-border/80 p-2 bg-muted/20">
                <input
                  type="checkbox"
                  checked={linkHomeroom}
                  onChange={(e) => setLinkHomeroom(e.target.checked)}
                  className="rounded border-border text-primary focus:ring-primary h-4 w-4"
                />
                <span>Auto-link as Section Homeroom</span>
              </label>
            </div>
          </div>

          {/* Section Names Input & Presets */}
          <div className="space-y-2 rounded-lg border border-border/70 bg-muted/20 p-3">
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
              <Label htmlFor="sectionNamesInput" className="text-xs font-semibold text-foreground/90">
                Section Names to Generate (Comma-separated)
              </Label>

              {/* Presets */}
              <div className="flex flex-wrap items-center gap-1.5 text-xs">
                <span className="text-muted-foreground text-[11px]">Quick Presets:</span>
                <button
                  type="button"
                  onClick={() => setSectionNamesInput('Jinnah, Iqbal, Fatima')}
                  className="rounded-md bg-background px-2 py-0.5 text-[11px] font-medium border hover:bg-muted"
                >
                  Jinnah, Iqbal, Fatima
                </button>
                <button
                  type="button"
                  onClick={() => setSectionNamesInput('A, B, C, D')}
                  className="rounded-md bg-background px-2 py-0.5 text-[11px] font-medium border hover:bg-muted"
                >
                  A, B, C, D
                </button>
                <button
                  type="button"
                  onClick={() => setSectionNamesInput('Blue, Green, Red, Yellow')}
                  className="rounded-md bg-background px-2 py-0.5 text-[11px] font-medium border hover:bg-muted"
                >
                  House Colors
                </button>
              </div>
            </div>

            <Input
              id="sectionNamesInput"
              value={sectionNamesInput}
              onChange={(e) => setSectionNamesInput(e.target.value)}
              placeholder="e.g. Jinnah, Iqbal, Fatima"
              className="h-9 bg-background font-medium"
              required
            />

            {/* Existing sections notice */}
            {classSections.length > 0 && (
              <div className="flex flex-wrap items-center gap-1 pt-1 text-[11px] text-muted-foreground">
                <span>Existing sections in school:</span>
                {classSections.map((sec) => (
                  <button
                    key={sec.id}
                    type="button"
                    onClick={() => {
                      const current = parsedSectionNames;
                      if (!current.includes(sec.name)) {
                        setSectionNamesInput([...current, sec.name].join(', '));
                      }
                    }}
                    className="rounded bg-primary/10 text-primary font-medium px-1.5 py-0.5 hover:bg-primary/20"
                  >
                    + {sec.name}
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Live Preview of Rooms to be Created */}
          <div className="space-y-1.5">
            <p className="text-xs font-semibold text-muted-foreground">
              Preview ({parsedSectionNames.length} classrooms will be generated):
            </p>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
              {parsedSectionNames.map((sec) => {
                const codeSuffix = sec.replace(/[^A-Za-z0-9]/g, '').slice(0, 4).toUpperCase();
                const codePrefix = selectedClass?.code || selectedClass?.name_en.replace(/[^0-9]/g, '') || 'CR';
                const code = `${codePrefix}-${codeSuffix}`;
                const name = `${selectedClass?.name_en || 'Class'} - Section ${sec}`;
                return (
                  <div key={sec} className="flex items-center justify-between rounded-lg border bg-background p-2.5 text-xs shadow-2xs">
                    <div className="min-w-0 flex-1">
                      <p className="font-semibold text-foreground truncate">{name}</p>
                      <p className="text-muted-foreground font-mono text-[11px]">
                        Code: {code} · {batchCapacity} seats
                      </p>
                    </div>
                    <CheckCircle2 className="h-4 w-4 text-primary shrink-0 ml-2" />
                  </div>
                );
              })}
            </div>
          </div>

          {/* Submit Button */}
          <div className="flex items-center justify-end gap-3 pt-2 border-t">
            <Button type="button" variant="outline" size="sm" onClick={() => setMode('single')}>
              Cancel
            </Button>
            <Button type="submit" disabled={pending || parsedSectionNames.length === 0} className="gap-2 px-6">
              <Zap className="h-4 w-4" />
              {pending ? 'Generating Rooms…' : `Generate ${parsedSectionNames.length} Classrooms`}
            </Button>
          </div>
        </form>
      )}

      {/* --- MODE 3: STANDARD FACILITIES PRESET --- */}
      {mode === 'preset' && (
        <div className="space-y-4">
          <p className="text-xs text-muted-foreground">
            Seed the 7 standard academic laboratories, library, and examination halls for your campus in one shot:
          </p>

          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3 text-xs">
            {[
              { code: 'SL-PHY', name: 'Physics Laboratory', capacity: 30, block: 'Science Wing' },
              { code: 'SL-CHM', name: 'Chemistry Laboratory', capacity: 30, block: 'Science Wing' },
              { code: 'SL-BIO', name: 'Biology Laboratory', capacity: 30, block: 'Science Wing' },
              { code: 'CL-1', name: 'Central Computer Lab', capacity: 35, block: 'IT Block' },
              { code: 'LIB-1', name: 'Main School Library', capacity: 50, block: 'Academic Block' },
              { code: 'HALL-1', name: 'Examination & Event Hall', capacity: 120, block: 'Main Block' },
              { code: 'PR-1', name: 'Prayer Area / Mosque', capacity: 100, block: 'Ground Floor' },
            ].map((fac) => (
              <div key={fac.code} className="flex items-center justify-between rounded-lg border bg-background p-2.5 shadow-2xs">
                <div>
                  <p className="font-semibold text-foreground">{fac.name}</p>
                  <p className="text-muted-foreground font-mono text-[11px]">
                    {fac.code} · {fac.capacity} seats · {fac.block}
                  </p>
                </div>
                <Sparkles className="h-4 w-4 text-emerald-500 shrink-0 ml-2" />
              </div>
            ))}
          </div>

          <div className="flex items-center justify-end gap-3 pt-2 border-t">
            <Button type="button" variant="outline" size="sm" onClick={() => setMode('single')}>
              Cancel
            </Button>
            <Button
              type="button"
              onClick={handleSeedFacilities}
              disabled={pending}
              className="gap-2 px-6 bg-emerald-600 hover:bg-emerald-700 text-white"
            >
              <Sparkles className="h-4 w-4" />
              {pending ? 'Seeding Facilities…' : 'Seed 7 Standard Facilities'}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
