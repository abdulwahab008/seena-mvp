import { describe, expect, it } from 'vitest';
import { expandUsernameLogin } from './login-id';

describe('expandUsernameLogin', () => {
  it('expands username@school to the hidden login address', () => {
    expect(expandUsernameLogin(' Ahmed.T@Seena-Main ')).toBe('ahmed.t@seena-main.users.seena.local');
  });
  it('leaves real emails and GR numbers alone', () => {
    expect(expandUsernameLogin('owner@school.edu.pk')).toBe('owner@school.edu.pk');
    expect(expandUsernameLogin('GR-1234')).toBe('GR-1234');
  });
});
