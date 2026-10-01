/** Parent-facing syllabus titles: the Urdu title when the parent reads Urdu and one exists, otherwise English. */
export function pickTitle(lang: 'en' | 'ur', en: string, ur: string | null | undefined): string {
  if (lang === 'ur' && ur && ur.trim() !== '') return ur;
  return en;
}
