// Portal strings. English is the source of truth and the fallback: a missing
// Urdu string renders English, never the raw key. Numerals stay Latin in
// Urdu — challan numbers, CNIC digits and amounts are read off paper by bank
// tellers — so no value here may contain Eastern Arabic digits (tested).

export const LANGS = ['en', 'ur'] as const;
export type Lang = (typeof LANGS)[number];

export function isLang(value: unknown): value is Lang {
  return typeof value === 'string' && (LANGS as readonly string[]).includes(value);
}

export const en = {
  'portal.title': 'Parent Portal',
  'nav.attendance': 'Attendance',
  'nav.fees': 'Fees',
  'nav.homework': 'Homework',
  'nav.timetable': 'Timetable',
  'nav.results': 'Results',
  'nav.consent': 'Consent',
  'nav.circulars': 'Circulars',
  'nav.calendar': 'Calendar',
  'nav.remarks': 'Remarks',
  'nav.tickets': 'Support & Complaints',
  'nav.linkChild': 'Add child',
  'lang.switchTo': 'اردو',
  'lang.switchLabel': 'Switch to Urdu',
  'fees.title': 'Fee Dues & Billing',
  'fees.balance': 'Balance',
  'fees.lateFee': 'Late fee',
  'fees.totalDue': 'Total due',
  'fees.outstanding': 'Current Outstanding Balance',
  'fees.underReconciliation': 'Payment under reconciliation',
  'fees.doNotPayAgain': 'Do not pay again — this challan will show as paid once the school confirms the payment with the bank.',
  'fees.downloadChallan': 'Download challan (PDF)',
  'fees.orDownload': 'or download the challan',
  'fees.payWith': 'Pay {amount} with {gateway}',
  'fees.voucherHint': 'In your bank app choose 1LINK bill payment and enter reference {reference}.',
  'fees.paid': 'Paid',
  'fees.unpaid': 'Unpaid',
  'fees.partPaid': 'Partially Paid',
} as const;

export type MessageKey = keyof typeof en;

export const ur: Partial<Record<MessageKey, string>> = {
  'portal.title': 'والدین پورٹل',
  'nav.attendance': 'حاضری',
  'nav.fees': 'فیس',
  'nav.homework': 'ہوم ورک',
  'nav.timetable': 'ٹائم ٹیبل',
  'nav.results': 'نتائج',
  'nav.consent': 'رضامندی',
  'nav.circulars': 'سرکلرز',
  'nav.calendar': 'کیلنڈر',
  'nav.remarks': 'ریمارکس',
  'nav.tickets': 'شکایات اور مدد',
  'nav.linkChild': 'بچہ شامل کریں',
  'lang.switchTo': 'English',
  'lang.switchLabel': 'انگریزی میں تبدیل کریں',
  'fees.title': 'فیس واجبات اور بلنگ',
  'fees.balance': 'بقایا',
  'fees.lateFee': 'تاخیری جرمانہ',
  'fees.totalDue': 'کل واجب الادا',
  'fees.outstanding': 'موجودہ بقایا رقم',
  'fees.underReconciliation': 'ادائیگی کی تصدیق جاری ہے',
  'fees.doNotPayAgain': 'دوبارہ ادائیگی نہ کریں — بینک سے تصدیق ہونے پر یہ چالان ادا شدہ دکھایا جائے گا۔',
  'fees.downloadChallan': 'چالان ڈاؤن لوڈ کریں (PDF)',
  'fees.orDownload': 'یا چالان ڈاؤن لوڈ کریں',
  'fees.payWith': '{gateway} سے {amount} ادا کریں',
  'fees.voucherHint': 'اپنی بینک ایپ میں 1LINK بل ادائیگی منتخب کریں اور حوالہ نمبر {reference} درج کریں۔',
  'fees.paid': 'ادا شدہ',
  'fees.unpaid': 'غیر ادا شدہ',
  'fees.partPaid': 'جزوی ادا شدہ',
};

export function t(lang: Lang, key: MessageKey, vars?: Record<string, string>): string {
  const template = (lang === 'ur' ? ur[key] : undefined) ?? en[key];
  return vars ? template.replace(/\{(\w+)\}/g, (_, name: string) => vars[name] ?? `{${name}}`) : template;
}

export function dirFor(lang: Lang): 'ltr' | 'rtl' {
  return lang === 'ur' ? 'rtl' : 'ltr';
}

export function coverage(): { translated: number; total: number } {
  const keys = Object.keys(en) as MessageKey[];
  return { translated: keys.filter((k) => Boolean(ur[k])).length, total: keys.length };
}
