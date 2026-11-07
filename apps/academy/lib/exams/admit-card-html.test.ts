import { describe, expect, it } from 'vitest';
import { buildAdmitCardsHtml } from './admit-card-html';

const paper = { subject: 'Maths', start_at: '2026-12-08T04:00:00Z', end_at: '2026-12-08T06:00:00Z', hall: 'Main Hall', seat: 'R1-S2' };

describe('buildAdmitCardsHtml', () => {
  it('prints a slip per student with papers in Karachi time, and marks students with dues as held', () => {
    const html = buildAdmitCardsHtml(
      {
        term: 'First Term',
        class_name: 'Class 9 A',
        students: [
          { name: 'Paid <Kid>', father_name: null, gr_number: 'GR-1', balance_paisa: 0, papers: [paper] },
          { name: 'Owing Kid', father_name: 'Mr X', gr_number: 'GR-2', balance_paisa: 150000, papers: [paper] },
        ],
      },
      'Seena School',
    );
    expect(html.match(/class="slip"/g)).toHaveLength(2);
    expect(html).toContain('Paid &lt;Kid&gt;');
    expect(html).toContain('09:00–11:00');
    expect(html).toContain('R1-S2');
    expect(html.match(/class="held"/g)).toHaveLength(1);
    expect(html).toContain('PKR 1,500.00');
  });
});
