// Schools run on Pakistan wall-clock time. `toISOString()` is UTC, which is still "yesterday"
// between 00:00 and 05:00 PKT, so every calendar date the app derives from "now" goes through here.
export const SCHOOL_TIME_ZONE = 'Asia/Karachi';

export const toPkDate = (d: Date): string => d.toLocaleDateString('en-CA', { timeZone: SCHOOL_TIME_ZONE });

export const todayPk = (): string => toPkDate(new Date());

// One way to show dates everywhere: "06 Nov 2026", "06 Nov 2026, 14:05", in Pakistan time.
// toLocaleDateString() with no arguments printed 11/20/2026 on one screen and 20/11/2026 on another,
// depending on the browser, and differed between the server render and the client.
export const formatDatePk = (value: string | number | Date): string =>
  new Date(value).toLocaleDateString('en-GB', { timeZone: SCHOOL_TIME_ZONE, day: '2-digit', month: 'short', year: 'numeric' });

export const formatDateTimePk = (value: string | number | Date): string =>
  new Date(value).toLocaleString('en-GB', {
    timeZone: SCHOOL_TIME_ZONE,
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
