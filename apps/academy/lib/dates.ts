// Schools run on Pakistan wall-clock time. `toISOString()` is UTC, which is still "yesterday"
// between 00:00 and 05:00 PKT, so every calendar date the app derives from "now" goes through here.
export const SCHOOL_TIME_ZONE = 'Asia/Karachi';

export const toPkDate = (d: Date): string => d.toLocaleDateString('en-CA', { timeZone: SCHOOL_TIME_ZONE });

export const todayPk = (): string => toPkDate(new Date());
