import { describe, expect, it } from 'vitest';
import { tempPassword } from './temp-password';
import { passwordSchema } from './password';

describe('tempPassword', () => {
  it('meets the password rules and avoids look-alike characters', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 200; i++) {
      const p = tempPassword();
      expect(passwordSchema.safeParse(p).success).toBe(true);
      expect(p).not.toMatch(/[01oOlI]/);
      seen.add(p);
    }
    expect(seen.size).toBe(200);
  });
});
