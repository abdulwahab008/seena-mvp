import { describe, expect, it } from 'vitest';
import { buildIdCardsHtml } from './html';

describe('buildIdCardsHtml', () => {
  it('renders one escaped card per person with a barcode of their code', () => {
    const html = buildIdCardsHtml({
      schoolName: 'Seena <School>',
      logoDataUri: null,
      kindLabel: 'Student card',
      validUntil: '31 Mar 2027',
      cards: [
        { name: 'Ali', code: 'GR-1', lines: [{ label: 'Class', value: 'Grade 5 A' }, { label: 'Blood group', value: null }] },
        { name: 'Sara', code: 'GR-2', lines: [] },
      ],
    });
    expect(html.match(/class="card"/g)).toHaveLength(2);
    expect(html).toContain('Seena &lt;School&gt;');
    expect(html).toContain('Grade 5 A');
    expect(html).not.toContain('Blood group');
    expect(html.match(/<svg/g)).toHaveLength(2);
  });
});
