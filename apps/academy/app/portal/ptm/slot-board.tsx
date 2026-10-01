'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { bookSlot, cancelBooking, joinWaitlist, type PtmSlot } from './actions';
import type { Lang } from '@/lib/i18n/messages';

const L = {
  en: { book: 'Book', cancel: 'Cancel booking', taken: 'Taken', yours: 'Your booking', waitlist: 'Notify me if it opens', waiting: 'You will be notified', noSlots: 'No slots have been published for this child yet.' },
  ur: { book: 'بک کریں', cancel: 'بکنگ منسوخ کریں', taken: 'بک ہو چکا', yours: 'آپ کی بکنگ', waitlist: 'دستیاب ہونے پر اطلاع دیں', waiting: 'آپ کو اطلاع دی جائے گی', noSlots: 'اس بچے کے لیے ابھی کوئی وقت شائع نہیں ہوا۔' },
} as const;

const time = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { timeZone: 'Asia/Karachi', hour: '2-digit', minute: '2-digit' });

export function SlotBoard({ studentId, initial, myBookings, lang }: { studentId: string; initial: PtmSlot[]; myBookings: Record<string, string>; lang: Lang }) {
  const router = useRouter();
  const t = L[lang];
  const [slots, setSlots] = useState(initial);
  const [message, setMessage] = useState<string | null>(null);
  const [waiting, setWaiting] = useState<string[]>([]);
  const [pending, startTransition] = useTransition();

  const book = (slotId: string) =>
    startTransition(async () => {
      const r = await bookSlot(slotId, studentId);
      if (r.ok) {
        setMessage(null);
        router.refresh();
        return;
      }
      setMessage(r.message);
      // A lost race comes back with the fresh list; show it straight away.
      if (r.slots) setSlots((cur) => [...cur.filter((s) => !r.slots!.some((n) => n.slot_id === s.slot_id)), ...r.slots!].sort((a, b) => a.teacher_name.localeCompare(b.teacher_name) || a.starts_at.localeCompare(b.starts_at)));
      else router.refresh();
    });
  const cancel = (bookingId: string) =>
    startTransition(async () => {
      const r = await cancelBooking(bookingId);
      setMessage(r.error);
      router.refresh();
    });
  const wait = (slotId: string) =>
    startTransition(async () => {
      const r = await joinWaitlist(slotId, studentId);
      setMessage(r.error);
      if (!r.error) setWaiting((cur) => [...cur, slotId]);
    });

  const teachers = [...new Map(slots.map((s) => [s.teacher_id, s.teacher_name])).entries()];
  if (slots.length === 0) return <p className="text-sm text-muted-foreground">{t.noSlots}</p>;
  return (
    <div className="space-y-4">
      {message && (
        <p role="alert" className="rounded-md border border-destructive/40 p-3 text-sm text-destructive" data-testid="ptm-message">
          {message}
        </p>
      )}
      {teachers.map(([teacherId, name]) => (
        <section key={teacherId} className="space-y-2">
          <h4 className="font-medium">{name}</h4>
          <div className="flex flex-wrap gap-2">
            {slots
              .filter((s) => s.teacher_id === teacherId)
              .map((s) => (
                <div key={s.slot_id} className="flex flex-col items-center gap-1 rounded-md border p-2 text-sm" data-testid="ptm-slot" data-available={s.available}>
                  <span className="font-medium">{time(s.starts_at)}</span>
                  {s.mine ? (
                    <button type="button" className="text-xs underline" disabled={pending} onClick={() => cancel(myBookings[s.slot_id]!)} data-testid="ptm-cancel">
                      {t.yours} · {t.cancel}
                    </button>
                  ) : s.available ? (
                    <button type="button" className="rounded bg-primary px-2 py-1 text-xs text-primary-foreground" disabled={pending} onClick={() => book(s.slot_id)} data-testid="ptm-book">
                      {t.book}
                    </button>
                  ) : waiting.includes(s.slot_id) ? (
                    <span className="text-xs text-muted-foreground">{t.waiting}</span>
                  ) : (
                    <>
                      <span className="text-xs text-muted-foreground">{t.taken}</span>
                      <button type="button" className="text-xs underline" disabled={pending} onClick={() => wait(s.slot_id)}>
                        {t.waitlist}
                      </button>
                    </>
                  )}
                </div>
              ))}
          </div>
        </section>
      ))}
    </div>
  );
}
