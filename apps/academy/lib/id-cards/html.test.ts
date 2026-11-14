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

  it('prints a photo when there is one and the placeholder otherwise', () => {
    const html = buildIdCardsHtml({
      schoolName: 'Seena',
      logoDataUri: null,
      kindLabel: 'Student card',
      validUntil: '31 Mar 2027',
      cards: [
        { name: 'Ali', code: 'GR-1', photo: 'data:image/jpeg;base64,AAAA', lines: [] },
        { name: 'Sara', code: 'GR-2', lines: [] },
      ],
    });
    expect(html).toContain('<div class="photo"><img src="data:image/jpeg;base64,AAAA" alt=""></div>');
    expect(html).toContain('<div class="photo">Photo</div>');
  });

  it('prints portrait fronts and backs in the chosen colour and ignores an unsafe colour', () => {
    const base = { schoolName: 'Seena', logoDataUri: null, kindLabel: 'Student card', validUntil: '31 Mar 2027', cards: [{ name: 'Ali', code: 'GR-1', lines: [] }] };
    const both = buildIdCardsHtml({ ...base, orientation: 'portrait', side: 'both', color: '#0f766e' });
    expect(both).toContain('class="sheet portrait"');
    expect(both.match(/class="card"/g)).toHaveLength(1);
    expect(both.match(/class="card back"/g)).toHaveLength(1);
    expect(both).toContain('background: #0f766e');
    const backOnly = buildIdCardsHtml({ ...base, side: 'back', color: 'red;}</style><script>' });
    expect(backOnly).not.toContain('class="card"');
    expect(backOnly).toContain('background: #1e3a8a');
    expect(backOnly).not.toContain('<script>');
  });
});
