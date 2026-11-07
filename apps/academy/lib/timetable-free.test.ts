import { describe, expect, it } from 'vitest';
import { freeAt } from './timetable-free';

describe('freeAt', () => {
  it('leaves out teachers and rooms booked in the period', () => {
    const r = freeAt([{ id: 't1' }, { id: 't2' }], [{ id: 'r1' }, { id: 'r2' }], [{ staff_id: 't1', room_id: 'r2' }, { staff_id: null, room_id: null }]);
    expect(r.teachers.map((t) => t.id)).toEqual(['t2']);
    expect(r.rooms.map((x) => x.id)).toEqual(['r1']);
  });
});
