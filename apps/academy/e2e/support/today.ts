// The school's calendar date. The app decides "today" in Asia/Karachi, so a
// spec that used the UTC date would look at yesterday between 19:00 and 24:00 UTC.
export const todayPk = (): string => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
